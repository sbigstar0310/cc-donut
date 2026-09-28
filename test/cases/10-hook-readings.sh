#!/usr/bin/env bash
# 10-hook-readings — the quota-guard hook and the readings it judges.
# Sections: §1, §2, §3, §4, §5, §15, §27b, §27c, §44
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "1. file_age() — the Linux stat regression"
# shellcheck disable=SC1090
eval "$(sed -n '/^file_age()/,/^}/p' "$ROOT/scripts/quota-guard.sh")"
probe="$FAKE/probe"; : > "$probe"
python3 - "$probe" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time()-3600, time.time()-3600))
PY
age=$(file_age "$probe")
case "$age" in
  ''|*[!0-9]*) bad "file_age returns an integer" "got: '$age'" ;;
  *) [ "$age" -ge 3500 ] && [ "$age" -le 3700 ] \
       && ok "file_age ≈ 3600s for a 1h-old file (got $age)" \
       || bad "file_age plausible" "got $age" ;;
esac
[ "$(file_age "$FAKE/does-not-exist")" = "999999" ] && ok "missing file → 999999" || bad "missing file → 999999"


head_ "2. quota cache refreshes when stale"
mkdir -p "$FAKE/.claude/ccd"
stub_usage 58 96
echo '{}' > "$FAKE/.claude/ccd/quota-cache.json"
python3 - "$FAKE/.claude/ccd/quota-cache.json" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))
PY
"$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
got=$(python3 -c "import json;print((json.load(open('$FAKE/.claude/ccd/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "96" ] && ok "stale cache refreshed (7d=96)" || bad "stale cache refreshed" "got: $got"


head_ "3. 95%+ emits the ccd escape guidance"
rm -f "$FAKE/.claude/ccd/last-warn"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit 2>/dev/null)
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "★QUOTA NEARLY EXHAUSTED★ injected at 96%" ;;
  *) bad "escape guidance at 96%" "got: ${out:0:120}" ;;
esac
case "$out" in *"ccd -c"*) ok "escape command present" ;; *) bad "escape command present" ;; esac


head_ "4. 10-minute warn throttle"
out2=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit 2>/dev/null)
[ -z "$out2" ] && ok "second warning suppressed within TTL" || bad "throttle" "re-warned: ${out2:0:80}"


head_ "5. concurrent hooks don't corrupt the cache"
python3 - "$FAKE/.claude/ccd/quota-cache.json" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))
PY
for _ in 1 2 3 4 5 6; do "$ROOT/scripts/quota-guard.sh" PostToolUse >/dev/null 2>&1 & done; wait
python3 -c "import json;json.load(open('$FAKE/.claude/ccd/quota-cache.json'))" 2>/dev/null \
  && ok "cache still valid JSON after 6 concurrent runs" || bad "cache valid after concurrency"
[ -z "$(ls "$FAKE/.claude/ccd"/quota-cache.json.tmp* 2>/dev/null)" ] && ok "no leftover tmp files" || bad "no leftover tmp files"


head_ "15. recovery: quota reset → flag recorded + green statusline"
# The round-trip claim: hook notices a reset transition and the statusline shows it.
mkdir -p "$FAKE/.claude/ccd"   # section 13's uninstall --purge removed it
# Fresh quota data with a NEW 7-day reset id and low percent (the stub node serves it).
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"fiveHourReset":"R1","sevenDayPercent":3,"sevenDayReset":"D2"}}\n' > "$FAKE/.stub-usage.json"
# Prior observation: 97% under the OLD reset id — the transition must be detected.
cat > "$FAKE/.claude/ccd/run-state.json" <<'EOF'
{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"last_seven_day_percent":97,"last_seven_day_reset":"D1"}
EOF
rm -f "$FAKE/.claude/ccd/quota-cache.json"   # force a refresh from the stub
# Block the cost path's real curl; recovery tracking must not depend on it.
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
echo 200
EOF
chmod +x "$FAKE/fakebin/curl"
CCD_ACTIVE=1 "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
python3 - "$FAKE/.claude/ccd/run-state.json" <<'PY' \
  && ok "reset transition records the recovery flag" || bad "recovery flag"
import json, sys
s = json.load(open(sys.argv[1]))
assert s.get("recovery_notified_window") == "seven_day", s
assert s.get("recovery_notified_reset") == "D2", s
PY
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in
  *"Claude recovered"*) ok "statusline shows the green recovery banner" ;;
  *) bad "recovery banner" "got: ${row:0:120}" ;;
esac
curl_reject


head_ "27b. the escape hatch fires on a reading, not on a memory"
# §21–§26 left a live login on file, and `use --force` banks it before it
# installs the next one: with nothing to bank there is no swap to observe.
wall_login
# The loudest thing ccd puts on screen, in bold red, was the least qualified: it read
# one number out of quota-cache.json with no age check, no window check, and no check
# that the reading was even usable. The arming path next door applies all three, and
# for the same reason — "a 96% sample taken before a reset still reads 96%
# afterwards" (scripts/quota-guard.sh:275).
WDIR="$FAKE/.claude/ccd"
mkdir -p "$WDIR"
rm -rf "$FAKE/.claude/ccd/accounts"
warn_row() {
  printf '%s' '{"model":{"id":"claude-fable-5"}}' \
    | "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'
}
# Just the warning. The account segment shares the row and legitimately names the
# spare there, so matching on the whole line cannot tell the two apart. Cut from the
# ⚠ to the end rather than splitting on the box-drawing separator: `tr` works on
# bytes, so a multi-byte separator makes it mangle the row instead of dividing it,
# which is green on macOS and empty in both containers.
hatch() { warn_row | grep -o '⚠.*' || true; }
wcache() { # $1=5h $2=7d $3=5h reset $4=7d reset [$5=age seconds]
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"sevenDayPercent":%s,"fiveHourReset":"%s","sevenDayReset":"%s"}}\n' \
    "$1" "$2" "$3" "$4" > "$WDIR/quota-cache.json"
  [ -n "${5:-}" ] && python3 -c "
import os, sys, time
t = time.time() - float(sys.argv[2])
os.utime(sys.argv[1], (t, t))" "$WDIR/quota-cache.json" "$5"
  return 0
}

# The baseline the rest of this section moves away from.
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
case "$(warn_row)" in
  *"quota 99%"*) ok "a fresh reading over the threshold still warns" ;;
  *) bad "escape hatch" "no warning on a good reading: $(warn_row)" ;;
esac

# Age. The cache keeps its last good sample when a refresh fails, so a reading can
# outlive the window it measured.
wcache 99 40 "$(iso 3600)" "$(iso 500000)" 3600
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "warned from an hour-old reading: $(warn_row)" ;;
  *) ok "a reading too old to describe now does not raise the alarm" ;;
esac

# The window itself. 99% of a five-hour window that reset twenty minutes ago is not a
# claim about the window running now, however fresh the file is.
wcache 99 40 "$(iso -1200)" "$(iso 500000)"
case "$(warn_row)" in
  *"quota 99%"*) bad "escape hatch" "warned on a window that had already turned over: $(warn_row)" ;;
  *) ok "a window that has already reset is not counted against the user" ;;
esac
# ...while the OTHER window still counts. Same file, same age, weekly over the bound.
wcache 20 97 "$(iso -1200)" "$(iso 500000)"
case "$(warn_row)" in
  *"quota 97%"*) ok "...and a live window over the bound still warns" ;;
  *) bad "escape hatch" "dropped a live window with the dead one: $(warn_row)" ;;
esac

# Usable. The dashboard reports its own failures as valid JSON with error=true, and
# the arming path already refuses those. Each flag is checked on its own: set both at
# once and an `or` that should have been an `and` passes anyway.
wflags() { # $1=available $2=error
  printf '{"claude":{"available":%s,"error":%s,"fiveHourPercent":99,"sevenDayPercent":99,"fiveHourReset":"%s","sevenDayReset":"%s"}}\n' \
    "$1" "$2" "$(iso 3600)" "$(iso 500000)" > "$WDIR/quota-cache.json"
}
wflags false true
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "warned from a failed reading: $(warn_row)" ;;
  *) ok "a reading that reports itself unusable raises nothing" ;;
esac
wflags true true
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "error=true alone was not enough to silence it" ;;
  *) ok "...error=true alone is enough" ;;
esac
wflags false false
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "available=false alone was not enough to silence it" ;;
  *) ok "...and so is available=false" ;;
esac

# A reset we cannot read says nothing either way, so its percentage still counts.
# Silence there would be the worse failure: a user at 99% seeing nothing.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":99,"sevenDayPercent":40,"fiveHourReset":"R1","sevenDayReset":"D1"}}\n' \
  > "$WDIR/quota-cache.json"
case "$(warn_row)" in
  *"quota 99%"*) ok "an unreadable reset does not disqualify its window" ;;
  *) bad "escape hatch" "went silent on a window it could not time: $(warn_row)" ;;
esac

# A swap makes the cache about somebody else. Leaving it in place is what put a red
# 99% beside a dashboard row reading 3% on the reporter's screen.
rm -rf "$FAKE/.claude/ccd/accounts"; mkdir -p "$ADIR"
mk_sl_acct one; mk_sl_acct two
printf 'one' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
HOME="$FAKE" "$ACCT" --no-color use two --force >/dev/null 2>&1 \
  && ok "the swap itself succeeds" || bad "swap cache" "the swap failed, so absence proves nothing"
[ ! -f "$WDIR/quota-cache.json" ] \
  && ok "a swap drops the reading that was about the account it left" \
  || bad "swap cache" "kept a reading about the previous account"
rm -rf "$ADIR"


head_ "27c. the warning names the move that actually applies"
# §16, §17 and §19 left an OpenRouter key on file, and the cases below that expect
# `ccd -c` read it. The one case that must not see a key moves it aside itself.
mkdir -p "$FAKE/.claude/ccd/providers"
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"
# `ccd -c` is the paid last resort. Offering it while a registered subscription sits
# there with room gets the order backwards — the plugin's own description is "hop to
# your other Claude subscription first, OpenRouter as the last resort", and the
# handoff path already agrees ("Prefer another subscription over paying").
mkdir -p "$ADIR"
rm -rf "$RQD"
mk_sl_acct here; mk_sl_acct roomyspare
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
KEYF="$FAKE/.claude/ccd/providers/keys.env"
mkdir -p "$(dirname "$KEYF")"

# A spare with room: name it, and do not send anyone to a paid backbone.
seed_rows here:ok:99:40:18000:518400 roomyspare:ok:8:12:18000:518400
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → !ccd account use" ] \
  && ok "with a spare that has room, the warning is exactly the command to run" || bad "warning target" "got: $row"
# ...and the row still carries the two numbers that make it a decision (#16): how
# much of that spare is spent, and when its window turns over. The warning has its
# own line, so naming the account in both places costs nothing.
full=$(warn_row)
case "$full" in
  *"ccd -c"*) bad "warning target" "named the paid route anywhere on a row about a free hop: $full" ;;
  *"spare roomyspare "*%*\(*\)*) ok "...and the row keeps the spare's name, percentage and countdown" ;;
  *) bad "warning target" "dropped the numbers that make the row a decision: $full" ;;
esac

# Every subscription spent, key configured: the paid hop is the answer again.
seed_rows here:ok:99:40:18000:518400 roomyspare:ok:100:100:18000:518400
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → /exit then ccd -c" ] \
  && ok "...and with every subscription spent it is ccd -c again" || bad "warning target" "got: $row"

# Nothing registered at all is the same answer by a different route.
rm -rf "$ADIR" "$RQD"; mkdir -p "$ADIR"
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → /exit then ccd -c" ] \
  && ok "...as is having registered no spare in the first place" || bad "warning target" "got: $row"

# No spare with room AND no key: there is nowhere to go, and knowing that before the
# quota hits zero is the whole point of putting it on screen.
mv "$KEYF" "$KEYF.bak" 2>/dev/null || true
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → no spare with room, no OpenRouter key" ] \
  && ok "with no spare and no key it says so, and names nothing it cannot deliver" || bad "warning target" "got: $row"

# Measured-and-none is not the same as never-measured. The row says "spare ?" for the
# second, and the warning must not turn not knowing into a claim. Registered accounts
# with no rows at all is what "never measured" looks like — in a cache written just now,
# since a missing one sends the render off to measure them (#54).
mk_sl_acct here; mk_sl_acct unseen
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
printf '{}' | rq_put
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → no known spare, no OpenRouter key" ] \
  && ok "...and with nothing measured it says it does not know" || bad "warning target" "got: $row"
mv "$KEYF.bak" "$KEYF" 2>/dev/null || true

# The threshold is a floor, not a fence: exactly at it must warn. `>=` and `>` are
# one character apart and every other case in this section passes under either.
rm -rf "$ADIR"; mkdir -p "$ADIR"
wcache 95 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 95% → /exit then ccd -c" ] \
  && ok "a reading exactly at the threshold warns" || bad "warning target" "got: $row"
wcache 94 40 "$(iso 3600)" "$(iso 500000)"
[ -z "$(hatch)" ] \
  && ok "...and one below it does not" || bad "warning target" "warned under the bound: $(hatch)"

# The command carries no name, so no name can be clipped into a different account,
# whatever the account is called (#47). The row still names it, bounded as always.
LONGNAME=$(python3 -c "print('n' * 56)")
mk_sl_acct here; mk_sl_acct "$LONGNAME"
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows "here:ok:99:40:18000:518400" "$LONGNAME:ok:8:12:18000:518400"
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → !ccd account use" ] \
  && ok "a name too long for the row cannot reach the command at all" \
  || bad "warning target" "got: $row"
case "$(warn_row)" in
  *"spare nnn"*) ok "...and the row keeps naming it, bounded the way it always was" ;;
  *) bad "warning target" "dropped the row's own mention as well: $(warn_row)" ;;
esac
rm -rf "$ADIR"; mkdir -p "$ADIR"

# A spare that needs a re-login is not a spare with room.
mk_sl_acct here; mk_sl_acct broken
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows here:ok:99:40:18000:518400 broken:dead:-:-:-:-
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → /exit then ccd -c" ] \
  && ok "a spare that needs a re-login is not offered as the escape" || bad "warning target" "got: $row"
rm -rf "$ADIR"; mkdir -p "$ADIR"


head_ "44. a reading from the future is unusable everywhere"
# #98. After the clock steps backward the quota cache is dated ahead of now. The
# hook's quota_peak read that age as "-900, which is ≤ 1800" and armed a return
# from it, while the banner (#95) asks 0 ≤ age ≤ WARN_MAX_AGE and stayed silent:
# one reading, two verdicts, and they part exactly where the reading is least
# worth trusting. The same negative age was also "not older than the TTL", so the
# ordinary refresh never fired either and the reading nobody trusted was pinned
# there for good. One rule now — 0 ≤ age ≤ MAX_READING_AGE, in whole seconds
# wherever it is asked — so every case below asks the hook AND the row, and the
# two cannot drift apart again without a case going red.
S44D="$FAKE/.claude/ccd"
S44_HF="$S44D/handoff-00000000000000000000000000000002.json"
S44_FUT=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=2)).isoformat())")
S44_BANNER="✓ Claude recovered → 종료하면 구독으로 자동 복귀"
S44_DASH="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
# The reading a recovered subscription leaves, and the record beside it. Every
# case uses this one pair and changes nothing but the date on the file, so age is
# the only thing any of them can be deciding.
s44_reading() { # $1=five-hour percent
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"fiveHourReset":"%s","sevenDayPercent":31,"sevenDayReset":"%s"}}\n' \
    "$1" "$S44_FUT" "$S44_FUT"
}
s44_state() {
  printf '{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"recovery_notified_window":"five_hour","recovery_notified_reset":"%s","last_five_hour_percent":4,"last_five_hour_reset":"%s","last_seven_day_percent":31,"last_seven_day_reset":"%s"}\n' \
    "$S44_FUT" "$S44_FUT" "$S44_FUT"
}
# A pinned clock for the row, and only when a case asks for one. Whole seconds and
# fractional seconds can only disagree inside one second, which is far too narrow
# a window for a fixture to hold open by racing it — so (e) stops the row's clock
# instead and the case becomes a fact about the two rules.
mkdir -p "$FAKE/s44py"
cat > "$FAKE/s44py/sitecustomize.py" <<'S44PY'
import os, time
_n = os.environ.get("CCD_S44_NOW")
if _n:
    time.time = lambda _f=float(_n): _f
S44PY
# Each case seeds its whole world: the reading, the date on it, the record beside
# it, and whether anything here could replace it. Nothing is registered, so the
# escape-to-a-spare arm never runs; no dashboard and a probe already backing off,
# so a refresh cannot quietly rewrite the file the case is about — except in (b),
# where being rewritten IS the assertion.
S44_NOW=""
s44_fixture() { # $1=how to date the cache: seconds from now, or "sub"   $2=dash → a dashboard that can refresh it
  rm -rf "$S44D/accounts" "$S44D/readings" "$S44_HF" "$S44D/refresh-failed" \
         "$FAKE/.claude/plugins/cache/claude-dashboard" \
         "$FAKE/.claude/plugins/data/claude-dashboard-claude-dashboard" \
         "$S44D/.dashboard-row" "$S44D/.dashboard-row.lock"
  mkdir -p "$S44D"
  s44_reading 4 > "$S44D/quota-cache.json"
  s44_state > "$S44D/run-state.json"
  : > "$S44D/.usage-probe-backoff"
  if [ "${2:-}" = "dash" ]; then
    mkdir -p "$S44_DASH"; : > "$S44_DASH/check-usage.js"
    s44_reading 7 > "$FAKE/.stub-usage.json"
  fi
  S44_NOW=$(python3 - "$S44D/quota-cache.json" "$1" <<'S44SEED'
import os, sys, time
if sys.argv[2] == "sub":
    # Half a second into the second that is running now. Whole-second arithmetic
    # cannot see that half second — `date +%s` and `stat %m` both drop it — so the
    # hook reads this file as 0s old however long it takes to get here, while a
    # fractional reading of the same file calls it future-dated. The clock the row
    # is judged on is pinned a quarter second in, so what the two say about this
    # file is a fact about the two rules and not about which ran first.
    n = int(time.time())
    t, pinned = n + 0.5, n + 0.25
else:
    t, pinned = time.time() + float(sys.argv[2]), ""
os.utime(sys.argv[1], (t, t))
print(pinned)
S44SEED
)
}
# One prompt tick of a supervised ccd session — the tick that arms the way home.
s44_start() { "$FAKE/sigbin/claude" 8 2>/dev/null & S44_PID=$!; sleep 0.3; }
s44_run() { # $1=session id
  printf '{"session_id":"%s","cwd":"/tmp/w","hook_event_name":"UserPromptSubmit"}' "$1" \
    | CCD_ACTIVE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_AUTH_TOKEN=x \
      CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$S44_HF" \
      CLAUDE_PID=$S44_PID CCD_STANDIN_PID=$S44_PID \
      "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
  sleep 0.3
}
s44_done() { kill -9 "$S44_PID" 2>/dev/null; wait "$S44_PID" 2>/dev/null; }
# The row that same session renders. CCD_S44_NOW is empty unless the case pinned a
# clock, and the module above is inert without it.
s44_row() {
  printf '%s' '{}' \
    | env PYTHONPATH="$FAKE/s44py" CCD_S44_NOW="$S44_NOW" \
      CCD_ACTIVE=1 CCD_HANDOFF=00000000000000000000000000000002 HOME="$FAKE" \
      "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'
}
# What `ccd doctor` says about the same file. It is the third reader of this one
# rule, and the only place a user goes to ask why nothing is happening.
s44_doctor() {
  "$ROOT/bin/ccd" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | sed -n '/Quota readings/,/^$/p'
}

# (a) The bug. The clock stepped back a quarter of an hour, so the cache is dated
# ahead of now. Nothing may be armed off it, and nothing may be promised from it.
s44_fixture 900
s44_start
s44_run sess-s44a
[ -z "$(hf_get armed)" ] \
  && ok "a reading dated in the future arms no return" \
  || bad "armed off a reading from the future" "armed=$(hf_get armed) direction=$(hf_get direction)"
s44_done
s44_fixture 900
row=$(s44_row)
case "$row" in
  *"Claude recovered"*) bad "the row promised a return off a reading from the future" "got: $row" ;;
  *) ok "...and the row promises none from it either" ;;
esac
s44_fixture 900
s44_doc=$(s44_doctor)
case "$s44_doc" in
  *"✓ 5h"*) bad "doctor called a reading from the future healthy" \
                "got: $(printf '%s' "$s44_doc" | tr '\n' ' ' | head -c 140)" ;;
  *) ok "...and doctor does not report it as a working reading" ;;
esac

# (b) ...and it is replaced, not pinned. The same negative age read as "not older
# than the ten-minute TTL", so the ordinary refresh skipped it and the reading
# stayed there until the clock caught up — which for a backward step is exactly
# as long as the step itself.
s44_fixture 900 dash
s44_start
s44_run sess-s44b
s44_done
s44_after=$(python3 - "$S44D/quota-cache.json" <<'S44CHK'
import json, os, sys, time
p = sys.argv[1]
try:
    pct = json.load(open(p))["claude"]["fiveHourPercent"]
except Exception as e:
    pct = f"unreadable ({e})"
print(f"{pct} {'ahead' if os.path.getmtime(p) > time.time() else 'behind'}")
S44CHK
)
[ "$s44_after" = "7 behind" ] \
  && ok "...and a refresh replaces it instead of being blocked by it" \
  || bad "a reading from the future was pinned" "the cache still reads: $s44_after"

# (c) Too old is the other end of the same rule, and it was never in dispute.
# Both sides refuse, and this case is here so a change to either end shows up.
s44_fixture -7200
s44_start
s44_run sess-s44c
[ -z "$(hf_get armed)" ] \
  && ok "a reading older than the bound still arms nothing" \
  || bad "armed off a stale reading" "armed=$(hf_get armed) direction=$(hf_get direction)"
s44_done
s44_fixture -7200
row=$(s44_row)
case "$row" in
  *"Claude recovered"*) bad "the row promised a return off a stale reading" "got: $row" ;;
  *) ok "...and the row refuses it on the same bound" ;;
esac

# (d) Inside the bound, both still work. A rule that refuses everything is not the
# fix; it is the same outage with nothing left to end it.
s44_fixture -60
s44_start
s44_run sess-s44d
[ "$(hf_get direction)" = "to_subscription" ] \
  && ok "a reading inside the bound still arms the return" \
  || bad "the return stopped arming" "armed=$(hf_get armed) direction=$(hf_get direction)"
s44_done
s44_fixture -60
row=$(s44_row)
case "$row" in
  *"$S44_BANNER"*) ok "...and the row still shows the banner, word for word" ;;
  *) bad "the banner stopped appearing" "got: $row" ;;
esac

# (e) The sub-second half of the same disagreement. The hook measures age in whole
# seconds and the row measured it fractionally, so a file half a second into the
# current second was 0s old to one and future-dated to the other — one reading,
# two verdicts again, a second below the resolution either of them can act on.
# Whole seconds is the answer both give now.
s44_fixture sub
s44_start
s44_run sess-s44e
[ "$(hf_get direction)" = "to_subscription" ] \
  && ok "a reading dated inside the current second is usable to the hook" \
  || bad "the hook refused a reading from this second" "armed=$(hf_get armed) direction=$(hf_get direction)"
s44_done
s44_fixture sub
row=$(s44_row)
case "$row" in
  *"$S44_BANNER"*) ok "...and the row says the same, to the same whole second" ;;
  *) bad "whole seconds on one side, fractional on the other" "the row read the same file as future-dated: $row" ;;
esac

rm -rf "$FAKE/s44py" "$S44_HF" "$S44D/run-state.json" "$S44D/quota-cache.json" \
       "$S44D/.usage-probe-backoff" "$S44D/refresh-failed"
unset -f s44_reading s44_state s44_fixture s44_start s44_run s44_done s44_row s44_doctor
unset S44_NOW S44_BANNER S44_DASH S44_FUT s44_after s44_doc

finish
