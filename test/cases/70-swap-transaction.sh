#!/usr/bin/env bash
# 70-swap-transaction — the in-session swap, as one transaction.
# Sections: §29, §30
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "29. the swap that happens inside the session"
# Ending a session to change account was always the expensive half of the hop: the
# turn dies, a launcher relaunches it, and the user waits through a cold start. The
# measurements in #57 say none of that is needed — the credential ccd writes is the
# one Claude Code's very next request reads, and a swap held for 16.9 hours across
# two token refreshes in one live process. So the primary path swaps where the
# session already is, off the reading ccd was taking anyway, ten minutes before the
# wall; StopFailure stays as the backstop for what that reading cannot see, and
# wakes the parked session itself instead of asking the user to type.
SWD="$FAKE/.claude/ccd"
# Nothing in this section may reach Anthropic: a swap is a real side effect and the
# tokens here are fixtures. Both endpoints point at a closed port, so a call that
# escaped fails in milliseconds instead of spending a real account's quota.
export CCD_USAGE_URL="http://127.0.0.1:1/usage" CCD_TOKEN_URL="http://127.0.0.1:1/token"
# The free hop needs no opt-in; leaving the paid one armed would let a fallthrough
# end the stand-in and make these assertions about the wrong thing.
paid_optin_off
# The plugin root is passed explicitly. Without it the hook resolves ccd-account
# through the plugin cache, where an older copy is staged — and the section would
# test that copy instead of the tree.
# A run at the wall re-reads the account, so it always gets the stand-in endpoint;
# a tick gets whatever the section exported, as before.
sw_hook() {
  if [ "${1:-}" = StopFailure ]; then
    CLAUDE_PLUGIN_ROOT="${SW_ROOT:-$ROOT}" CCD_SWAP_SETTLE="${SW_SETTLE:-0}" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" "$@"
  else
    CLAUDE_PLUGIN_ROOT="${SW_ROOT:-$ROOT}" CCD_SWAP_SETTLE="${SW_SETTLE:-0}" "$ROOT/scripts/quota-guard.sh" "$@"
  fi
}
# Its own store, every time. Two accounts, the signed-in one spent and the other
# with room, plus the reading that corroborates it. Seeded per case rather than
# inherited: a case that ran on the previous one's leftovers would have nothing to
# distinguish a swap that happened from one that already had.
sw_fixture() { # $1=signed-in 5h  $2=signed-in 7d  [$3=spare 5h  $4=spare 7d]
  # No canned endpoint answer left over from the case before: each case stages its own.
  rm -f "${CCD_FAKE_USAGE:-/nonexistent}"
  rm -rf "$ADIR" "$RQD" "$SWD/swapped-windows" "$FAKE/.claude.json" \
         "$SWD/handoff-00000000000000000000000000000002.json"
  mkdir -p "$ADIR"
  write_creds spent; "$ACCT" --no-color add --name spent --label "spent@example.com" >/dev/null 2>&1
  write_creds spare; "$ACCT" --no-color add --name spare --label "spare@example.com" >/dev/null 2>&1
  "$ACCT" --no-color use spent --force >/dev/null 2>&1
  printf '{"spent":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":100,"seven_day_percent":100},"spare":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":%s,"seven_day_percent":%s}}' \
    "$(date +%s)" "$(cred_fp "$ADIR/spent.json")" \
    "$(date +%s)" "$(cred_fp "$ADIR/spare.json")" "${3:-10}" "${4:-20}" | rq_put
  # Nothing here may spend a one-time refresh token, so keepalive is not due.
  printf '{"fails":0}' > "$SWD/accounts-keepalive"
  quota "$1" "$2"          # written last: the swap above deletes this file
  rm -f "$SWD/last-warn" "$SWD/accounts-stale" "$SWD/last-stale-warn" "$SWD/refresh-failed"
}
sw_prompt() { # $1=event  $2=session id ; stdout is the hook's own
  printf '{"session_id":"%s","cwd":"/tmp/w"}' "$2" \
    | CCD_HANDOFF=00000000000000000000000000000002 \
      CCD_HANDOFF_STATE="$SWD/handoff-00000000000000000000000000000002.json" \
      CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID sw_hook "$1" 2>/dev/null
}

# ── Before the wall: the turn never has to end ──────────────────────────────
# The whole launcher contract is handed to the hook on purpose. A swap that needs
# none of it must be seen not to use it.
set +m 2>/dev/null
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
out=$(sw_prompt UserPromptSubmit sess-sw1)
grep -q 'AT-spare' "$CREDS" \
  && ok "a corroborated 96% with a spare in reach swaps the session in place" \
  || bad "in-session swap" "the credential never moved"
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  && ok "...and the active pointer follows it" \
  || bad "in-session swap" "pointer: $(cat "$ADIR/.active" 2>/dev/null)"
python3 - "$out" <<'PY' \
  && ok "...saying so in one line the user sees, and telling the model why" \
  || bad "swap message" "got: ${out:0:200}"
import json, sys
d = json.loads(sys.argv[1])
msg = d.get("systemMessage") or ""
ctx = (d.get("hookSpecificOutput") or {}).get("additionalContext") or ""
assert "spare" in msg, f"systemMessage does not name the account: {msg!r}"
assert "spare" in ctx, f"additionalContext does not name the account: {ctx!r}"
PY
if kill -0 "$SWPID" 2>/dev/null; then ok "...and the session is never signalled — the turn keeps going"
else bad "in-session swap" "ended the session it was supposed to keep"; fi
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and nothing is armed for a launcher to relaunch" \
  || bad "in-session swap" "armed a handoff for a swap that had already happened"

# An autonomous turn fires tool uses and never a prompt, and that is exactly the
# turn that burns the last of the quota.
sw_fixture 58 100
sw_prompt PostToolUse sess-sw2 >/dev/null
grep -q 'AT-spare' "$CREDS" \
  && ok "a tool-use tick swaps too, not only a typed prompt" \
  || bad "tool-use swap" "the credential never moved"

# ── ...but only when the reading actually says so ───────────────────────────
sw_fixture 58 90
sw_prompt UserPromptSubmit sess-sw3 >/dev/null
grep -q 'AT-spent' "$CREDS" \
  && ok "a reading below the arm threshold swaps nothing" \
  || bad "threshold" "swapped on a reading that corroborates nothing"

sw_fixture 58 100 100 100
out=$(sw_prompt UserPromptSubmit sess-sw4)
grep -q 'AT-spent' "$CREDS" \
  && ok "...and neither does a spare with no room left" \
  || bad "no room" "swapped onto an account that is spent too"
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "...while the warning that was always there still arrives" ;;
  *) bad "warning preempted" "got: ${out:0:140}" ;;
esac
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── The account a swap just left is not where the next one goes ─────────────
# The ordinary case cannot repeat, because the swap deletes the reading that
# caused it. What can is a cached row claiming room for an account that has none:
# the session would walk back and forth between two spent accounts. The rule that
# stops it cannot be "refuse to leave" — a stale row lands you back on a spent
# account, and refusing to leave it again strands you there while a healthy one is
# registered. So a swap records where it came FROM, and that account stops being a
# destination while the record is live. Leaving is never blocked.
sw_fixture3() { # three accounts; the signed-in one is the most attractive row of all
  sw_fixture 58 100
  write_creds spare2; "$ACCT" --no-color add --name spare2 --label "spare2@example.com" >/dev/null 2>&1
  "$ACCT" --no-color use spent --force >/dev/null 2>&1
  printf '{"spent":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":1,"seven_day_percent":1,"five_hour_reset":"R1","seven_day_reset":"D1"},"spare":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":10,"seven_day_percent":20,"five_hour_reset":"R1","seven_day_reset":"D1"},"spare2":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":30,"seven_day_percent":40,"five_hour_reset":"R1","seven_day_reset":"D1"}}' \
    "$(date +%s)" "$(cred_fp "$ADIR/spent.json")" \
    "$(date +%s)" "$(cred_fp "$ADIR/spare.json")" \
    "$(date +%s)" "$(cred_fp "$ADIR/spare2.json")" | rq_put
  quota "$1" "$2"
}
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture3 58 100
sw_prompt UserPromptSubmit sess-sw5 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "flap guard" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
quota 58 100                        # the account it landed on is spent too
sw_prompt UserPromptSubmit sess-sw6 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "the account a swap just left is not offered as the next destination" \
  || bad "flap guard" "went to $(cat "$ADIR/.active" 2>/dev/null) — back onto an account it had just left as spent"

# A reading that names no window at all is the same situation, not a hole in the
# rule: without a record there, one unreadable reading walks the session through
# every account it owns.
sw_fixture3 58 100
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"sevenDayPercent":100}}\n' \
  > "$SWD/quota-cache.json"
sw_prompt UserPromptSubmit sess-sw5b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "no-window guard" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"sevenDayPercent":100}}\n' \
  > "$SWD/quota-cache.json"
sw_prompt UserPromptSubmit sess-sw6b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "...and a reading with no reset timestamp records the departure all the same" \
  || bad "no-window guard" "went to $(cat "$ADIR/.active" 2>/dev/null) on a reading that names no window"

# Bounded by time, not by how many entries fit: an account left long enough ago is
# a destination again, whatever else has been recorded since.
sw_fixture3 58 100
export CCD_SWAP_GUARD_TTL=1
sw_prompt UserPromptSubmit sess-sw7 >/dev/null
quota 58 100
sw_prompt UserPromptSubmit sess-sw7b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  || bad "guard ttl" "the second hop went to $(cat "$ADIR/.active" 2>/dev/null)"
sleep 2
quota 58 100
sw_prompt UserPromptSubmit sess-sw7c >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spent" ] \
  && ok "...and a record that has aged out stops excluding anything" \
  || bad "guard ttl" "still excluded an account left longer ago than the bound: $(cat "$ADIR/.active" 2>/dev/null)"
unset CCD_SWAP_GUARD_TTL
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── After the wall: swap, then wake the session that parked ─────────────────
# Claude Code never resumes a parked session by itself — every recovery in the
# transcripts was a human typing. So the backstop does not just swap and fall
# silent: it confirms the credential landed and exits 2, which is the one thing an
# asyncRewake entry acts on.
sw_stopfail() { # $1=session id ; prints the hook's exit code
  printf '{"session_id":"%s","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"rate_limit"}' "$1" \
    | CCD_HANDOFF=00000000000000000000000000000002 \
      CCD_HANDOFF_STATE="$SWD/handoff-00000000000000000000000000000002.json" \
      CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID sw_hook StopFailure \
      >"$FAKE/.sw-out" 2>"$FAKE/.sw-err"
  printf '%s' "$?"
}
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rc=$(sw_stopfail sess-sw8)
grep -q 'AT-spare' "$CREDS" \
  && ok "a limit that arrived before the reading could see it still swaps in place" \
  || bad "backstop swap" "the credential never moved"
[ "$rc" = "2" ] \
  && ok "...and exits 2, the only code an asyncRewake hook wakes on" \
  || bad "wake" "exit code $rc"
grep -q 'spare' "$FAKE/.sw-err" \
  && ok "...naming the account in the text the wake carries" \
  || bad "wake text" "stderr: $(head -c 140 "$FAKE/.sw-err")"
grep -qi 'do not repeat work' "$FAKE/.sw-err" \
  && ok "...and telling the model to continue rather than start the task over" \
  || bad "wake text" "stderr: $(head -c 180 "$FAKE/.sw-err")"
if kill -0 "$SWPID" 2>/dev/null; then ok "...without signalling the session it just repaired"
else bad "backstop" "ended the session instead of waking it"; fi
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and without arming a relaunch it no longer needs" \
  || bad "backstop" "armed a launcher handoff for a swap it had performed itself"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# A wake that lands on the account we just left is a wasted turn: it fails the same
# way and parks again. The swap writes the live store, but a keychain that refused
# — or this session writing its own refreshed blob back over ours — leaves that
# store holding the credential we meant to leave. Only the credential's own
# identity can settle that: a plan is not an account, and two accounts on one plan
# (which is what this fixture is) agree about every plan field there is.
#
# The write-back has to land in one window: after the swap wrote the store, and
# before the confirmation read it. A background `sleep 0.7` guessed at that
# window off the clock and lost it twice in CI (#88) — the hook is three Python
# starts away from the swap, and on a runner that takes longer over them the
# revert lands INSIDE the swap and is overwritten, which confirms and wakes.
# So the revert is not timed at all: the ccd-account the hook resolves does it,
# at the one point in the sequence where it belongs. `swap` records that the
# credential moved; the `current --json` that confirms it puts the outgoing blob
# back first and then hands the read to the real ccd-account, which still
# decides the question on the store's actual contents. Ordering by construction,
# on any machine, at any speed.
mkdir -p "$FAKE/revertroot/bin"
cat > "$FAKE/revertroot/bin/ccd-account" <<'REOF'
#!/bin/sh
for a in "$@"; do
  [ "$a" = swap ] && { "$CCD_REAL_ACCOUNT" "$@"; rc=$?; : > "$HOME/.swap-done"; exit "$rc"; }
done
case " $* " in
  *" current --json "*)
    [ -e "$HOME/.swap-done" ] && cp "$HOME/.creds-before" "$SW_LIVE_CREDS" ;;
esac
exec "$CCD_REAL_ACCOUNT" "$@"
REOF
chmod +x "$FAKE/revertroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT" SW_LIVE_CREDS="$CREDS"
# Long-lived on purpose: `kill -0` below means "nothing signalled it", and only
# a stand-in that cannot age out mid-block says that rather than how long the
# block took. At `claude 8` the check ran with 2.1s to spare here and 1.1s under
# load — the second half of #88's CI failure.
"$FAKE/sigbin/claude" 60 2>/dev/null & SWPID=$!
sw_fixture 58 100
cp "$CREDS" "$FAKE/.creds-before"            # the outgoing account's live blob
rm -f "$FAKE/.swap-done"
rc=$(SW_ROOT="$FAKE/revertroot" sw_stopfail sess-sw9)
[ "$rc" != "2" ] \
  && ok "a live store that no longer holds the credential we installed wakes nothing" \
  || bad "unconfirmed wake" "woke the session into the account it had just left"

# ...and a swap it cannot confirm is not a reason to start spending money. The
# credential, the pointer and the guard record have all moved by then; arming the
# paid hop on top of that bills the user for a swap that may well have worked.
paid_optin_on
sw_fixture 58 100
cp "$CREDS" "$FAKE/.creds-before"
rm -f "$FAKE/.swap-done"
rc=$(SW_ROOT="$FAKE/revertroot" sw_stopfail sess-sw9b)
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and arms no paid hop off a confirmation that failed" \
  || bad "unconfirmed paid hop" "armed $(hf_get direction) after a swap it could not confirm"
if kill -0 "$SWPID" 2>/dev/null; then ok "...nor ends the session over one"
else bad "unconfirmed paid hop" "signalled a session whose swap had already happened"; fi
paid_optin_off
unset SW_LIVE_CREDS
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── The wake has to be registered, and has to read like something ccd said ──
python3 - "$ROOT/hooks/hooks.json" "$ROOT/scripts/quota-guard.sh" <<'PY' \
  && ok "the StopFailure entry is registered as an asyncRewake hook" \
  || bad "hooks.json" "the exit 2 above would wake nothing"
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["StopFailure"]
entry = [e for g in groups for e in g["hooks"]][0]
assert entry.get("asyncRewake") is True, "asyncRewake is not set on the command hook"
# Section 30 owns the arithmetic: a timeout that clears the settle alone says
# nothing about the pick that runs before it.
assert isinstance(entry.get("timeout"), int), f"timeout is {entry.get('timeout')!r}"
PY
python3 - "$ROOT/hooks/hooks.json" <<'PY' \
  && ok "...carrying wake text of its own, not the blocking-error default" \
  || bad "hooks.json" "the user would read 'Stop hook blocking error from command …'"
import json, sys
entry = [e for g in json.load(open(sys.argv[1]))["hooks"]["StopFailure"] for e in g["hooks"]][0]
msg = entry.get("rewakeMessage") or ""
summary = entry.get("rewakeSummary") or ""
assert "usage limit" in msg, f"rewakeMessage: {msg!r}"
assert "do not repeat work" in msg.lower(), f"rewakeMessage: {msg!r}"
assert summary, "rewakeSummary is unset, so the default stands in for it"
for s in (msg, summary):
    assert "blocking error" not in s.lower(), f"default phrasing left in: {s!r}"
PY

# ── Coming back off OpenRouter is the one hop that still ends a session ─────
# While the session runs on OpenRouter its backbone is an environment variable, so
# writing a credential reaches nothing — leaving really does take a relaunch, and
# that is what the launcher is still for. What changed is that it is no longer told
# WHICH account to install: the hook swaps to the spare in place first and arms the
# plain return, so the relaunch simply lands on whatever is live.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
printf '{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5}\n' > "$SWD/run-state.json"
hf_reset
out=$(printf '{"session_id":"sess-sw10","cwd":"/tmp/w"}' \
  | CCD_ACTIVE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_AUTH_TOKEN=x \
    CCD_HANDOFF=00000000000000000000000000000002 \
    CCD_HANDOFF_STATE="$SWD/handoff-00000000000000000000000000000002.json" \
    CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID sw_hook UserPromptSubmit 2>/dev/null)
grep -q 'AT-spare' "$CREDS" \
  && ok "a spare with room takes the session off the paid backbone, credential first" \
  || bad "return hop" "armed a relaunch onto an account it never installed"
[ "$(hf_get direction)" = "to_subscription" ] \
  && ok "...arming the plain return, not an account the launcher would have to install" \
  || bad "return direction" "got: $(hf_get direction)"
[ -z "$(hf_get account)" ] \
  && ok "...naming no account, because the live store already is one" \
  || bad "return state" "still carries an account field: $(hf_get account)"
case "$out" in
  *spare*) ok "...and says where the session is going, in the user's own screen" ;;
  *) bad "return message" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 140)" ;;
esac
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
rm -f "$SWD/run-state.json"


head_ "30. the swap is one transaction, under one lock"
# Deciding where to go and installing the credential were two processes and no
# lock: the account was read before anything was held, so the background keepalive
# could rotate that account's one-time token in between and the swap would install
# the copy it read — a dead spare, handed to a session that has just run out.

# ── The token that is installed is the token the store holds NOW ────────────
# Held against the STORE lock, which is what every writer of a credential takes.
# The swap takes no other lock: the single-flight one is for background passes,
# and waiting on it was how a prompt tick ended up waiting on somebody else's
# HTTP request.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
# The background job's own single-flight lock, held while it rotates the spare —
# exactly what `ccd-account keepalive` does behind REFRESH_LOCK.
python3 - "$ADIR/.lock" "$ADIR/spare.json" "$RQD/spare.json" <<'PY' &
import fcntl, hashlib, json, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
d = json.load(open(sys.argv[2]))
d["claudeAiOauth"]["accessToken"] = "AT-spare-rotated"
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
# The pass re-measures what it rotated, exactly as `keepalive --pick` does: a
# verdict that still named the retired token would be discarded as somebody
# else's, and this test would pass for the wrong reason.
q = json.load(open(sys.argv[3]))
q["cred"] = hashlib.sha256(b"AT-spare-rotated").hexdigest()[:16]
q["checked_at"] = int(time.time())
with open(sys.argv[3], "w") as f:
    json.dump(q, f)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
ROT=$!
sleep 0.4
sw_prompt UserPromptSubmit sess-tx1 >/dev/null
wait "$ROT" 2>/dev/null
grep -q 'AT-spare-rotated' "$CREDS" \
  && ok "a swap installs the credential the store holds when it takes the lock" \
  || bad "rotation race" "installed a snapshot read before the lock — a spent one-time token"

# The same race one lock deeper. `ccd account refresh` takes the store lock and
# not the single-flight, so holding the single-flight is not enough: the account
# has to be READ inside the store lock too, or the swap installs a copy that was
# already stale when it got there.
sw_fixture 58 100
python3 - "$ADIR/.lock" "$ADIR/spare.json" "$RQD/spare.json" <<'PY' &
import fcntl, hashlib, json, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
d = json.load(open(sys.argv[2]))
d["claudeAiOauth"]["accessToken"] = "AT-spare-rotated"
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
q = json.load(open(sys.argv[3]))
q["cred"] = hashlib.sha256(b"AT-spare-rotated").hexdigest()[:16]
q["checked_at"] = int(time.time())
with open(sys.argv[3], "w") as f:
    json.dump(q, f)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
ROT=$!
sleep 0.4
sw_prompt UserPromptSubmit sess-tx1b >/dev/null
wait "$ROT" 2>/dev/null
grep -q 'AT-spare-rotated' "$CREDS" \
  && ok "...read inside that lock too, so a refresh beside it cannot be lost" \
  || bad "rotation race" "installed the copy it read before the store lock"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── A decision about an account we are no longer on does nothing ────────────
# Two sessions can reach the same reading and both decide to leave the same
# account. The second one has to notice the store moved while it was deciding, or
# one reading walks the session through two accounts.
sw_fixture3 58 100
out=$("$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --no-probe 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | cut -f1)" = "spare" ]; } \
  && ok "a swap names where it went, and the credential it installed" \
  || bad "swap command" "rc=$rc out='$(printf '%s' "$out" | tr '\t' ' ')'"
[ -n "$(printf '%s' "$out" | cut -f2)" ] \
  && ok "...as an identity the confirmation can check later" \
  || bad "swap command" "named no credential: '$(printf '%s' "$out" | tr '\t' ' ')'"
out2=$("$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --no-probe 2>/dev/null); rc2=$?
{ [ "$rc2" -ne 0 ] && [ "$(cat "$ADIR/.active")" = "spare" ]; } \
  && ok "...and a second decision about the account we already left does nothing" \
  || bad "stale decision" "rc=$rc2, now on $(cat "$ADIR/.active")"

# Both departures stay on the record. Count-based eviction threw away entries that
# were still current; time is the only bound now.
"$ACCT" --no-color swap --from spare --window "5h=R1;7d=D1" --no-probe >/dev/null 2>&1
recs=$(python3 - "$SWD/swapped-windows" <<'PY'
import sys
try:
    lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
except OSError:
    lines = []
print(" ".join(sorted(l.split("\t")[1] for l in lines if len(l.split("\t")) >= 2)))
PY
)
[ "$recs" = "spare spent" ] \
  && ok "every account a swap left stays on the record while it is current" \
  || bad "guard record" "recorded: '$recs'"

# ── The pick gets a deadline, and the hook's budget covers what follows it ──
# best_target() probes candidates one after another and a refresh tries two
# endpoints; nine expired spares ahead of a usable one can eat the whole hook
# timeout, and a hook killed there wakes nobody.
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
sw_fixture3 58 100
stage_usage 5 5          # after the fixture: it clears the canned answer of the case before
rm -rf "$RQD"        # nothing measured: every candidate needs a probe
: > "$CCD_FAKE_USAGE_LOG"
"$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --deadline 0 >/dev/null 2>&1; rc=$?
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
{ [ "$rc" -ne 0 ] && [ "${calls:-0}" -eq 0 ]; } \
  && ok "a pick with no budget left probes nothing rather than overrunning the hook" \
  || bad "pick deadline" "rc=$rc after ${calls:-0} probes"
: > "$CCD_FAKE_USAGE_LOG"
"$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --deadline 30 >/dev/null 2>&1
[ "$(cat "$ADIR/.active")" != "spent" ] \
  && ok "...while a budget that allows one measures and moves" \
  || bad "pick deadline" "measured nothing with 30s of budget ($(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ') probes)"
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

python3 - "$ROOT/hooks/hooks.json" "$ROOT/scripts/quota-guard.sh" <<'PY' \
  && ok "the hook's timeout covers the pick's budget, the settle and the wake" \
  || bad "hook budget" "the backstop can be killed before it wakes anything"
import json, re, sys
src = open(sys.argv[2]).read()
def env_default(name):
    m = re.search(rf"{name}:-(\d+)", src)
    assert m, f"{name} has no default in quota-guard.sh"
    return int(m.group(1))
settle = env_default("CCD_SWAP_SETTLE")
budget = env_default("CCD_SWAP_PICK_BUDGET")
entry = [e for g in json.load(open(sys.argv[1]))["hooks"]["StopFailure"] for e in g["hooks"]][0]
t = entry.get("timeout")
assert isinstance(t, int), f"timeout is {t!r}"
# The pick may spend its whole budget, the settle runs after it, and the swap,
# the confirm and the wake all have to fit in what is left.
assert t >= budget + settle + 30, \
    f"timeout {t} leaves {t - budget - settle}s for a swap, a confirm and a wake"
PY

# ── Nothing rotates a stored credential outside the store lock ─────────────
# Reading inside a lock only protects against writers that take it. `ccd account
# pick` refreshes an expired token on its way to a reading, and it used to do that
# holding neither lock: a swap could read an account, the pick could rotate it,
# and the swap would install the copy it had — a one-time token the server had
# already retired, which is a dead spare handed to a session that has just run out.
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
sw_fixture 58 100
stage_usage 5 5 200 0 AT-spare-rotated
# Expire the spare's stored token and age its verdict, so the pick has to rotate
# before it can measure.
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
# Another writer owns the store for the next second and a half, and changes a
# field of the very account the pick is about to rotate before it lets go.
python3 - "$ADIR/.lock" "$ADIR/spare.json" <<'PY' &
import fcntl, json, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(1.5)
d = json.load(open(sys.argv[2]))
d["label"] = "relabelled-under-the-lock"
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
time.sleep(0.3)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
"$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 1
mid=$(python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$ADIR/spare.json")
wait "$PICKPID" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$mid" = "AT-spare" ] \
  && ok "a rotation waits for the store lock instead of writing beside it" \
  || bad "unlocked rotation" "rotated to '$mid' while another writer held the lock"
python3 - "$ADIR/spare.json" <<'PY' \
  && ok "...and re-reads there, so the change made while it waited is not lost" \
  || bad "unlocked rotation" "wrote a copy read before the lock"
import json, sys
d = json.load(open(sys.argv[1]))
assert (d.get("claudeAiOauth") or {}).get("accessToken") == "AT-spare-rotated", \
    "the fixture never rotated, so this proved nothing"
assert d.get("label") == "relabelled-under-the-lock", f"label: {d.get('label')!r}"
PY

# ── Operational failure is not "every subscription is spent" ────────────────
# Only the second answer may reach a backbone that bills. A tool that cannot
# answer at all is the first, and buying OpenRouter on it is the one mistake here
# that costs money.
mkdir -p "$FAKE/brokenroot/bin"
printf '#!/bin/sh\nexit 3\n' > "$FAKE/brokenroot/bin/ccd-account"
chmod +x "$FAKE/brokenroot/bin/ccd-account"
paid_optin_on
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rc=$(SW_ROOT="$FAKE/brokenroot" sw_stopfail sess-f2)
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "an account tool that cannot answer never reaches the paid hop" \
  || bad "paid gate" "armed $(hf_get direction) on a tool failure"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
paid_optin_off

# ── The decision is checked against the account the READING was about ───────
# The hook reads a quota, and only then asks which account it is on. Between the
# two another session can swap; the stale verdict then reads as if it were about
# the account we are now on, and moves the session a second time.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture3 58 100
f3_reading() {  # the shape ccd's own probe writes: the reading names its account
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"fiveHourReset":"R1","sevenDayPercent":100,"sevenDayReset":"D1"},"account":"%s"}\n' "$1" \
    > "$SWD/quota-cache.json"
}
"$ACCT" --no-color use spare --force >/dev/null 2>&1   # another session got there first
f3_reading spent                                        # ...and this reading predates it
sw_prompt UserPromptSubmit sess-f3 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  && ok "a reading about an account we have already left moves nothing" \
  || bad "stale reading" "swapped again, onto $(cat "$ADIR/.active" 2>/dev/null)"
# ...and the refusal is about staleness, not about refusing: the same tick on a
# reading that does name the account we are on moves the session.
f3_reading spare
sw_prompt UserPromptSubmit sess-f3b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" != "spare" ] \
  && ok "...while a reading about the account we are on still moves it" \
  || bad "stale reading" "refused a current reading too"

# ── A window that has turned over is a new situation ────────────────────────
# The record carries the windows it was written in. An account whose own reading
# now names different resets has had a reset since; keeping it excluded on the
# name alone strands a two-account install for the rest of the TTL.
sw_fixture3 58 100
sw_prompt UserPromptSubmit sess-f4 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "window release" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1]))
q["spent"]["five_hour_reset"] = "R2"      # the window we left it in has turned over
q["spent"]["seven_day_reset"] = "D2"
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
quota 58 100
sw_prompt UserPromptSubmit sess-f4b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spent" ] \
  && ok "an account whose windows have turned over is a destination again" \
  || bad "window release" "still excluded on the name alone: $(cat "$ADIR/.active" 2>/dev/null)"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── One registered account beside an unregistered login ─────────────────────
# A supported install (#41): the one registered account IS the spare. Refusing
# because ccd cannot name the account we are on makes the escape unreachable for
# exactly the people who need it most.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rm -f "$ADIR/spent.json" "$ADIR/.active" "$ADIR/.active-at"
sw_prompt UserPromptSubmit sess-f7 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  && ok "an unregistered login can still reach the one account that is registered" \
  || bad "solo spare" "went nowhere: $(cat "$ADIR/.active" 2>/dev/null)"

# ── A rotation during the settle is not a failed swap ───────────────────────
# Twelve seconds is long enough for Claude Code to renew the credential ccd just
# installed. ccd never rotates a live account itself, but the next ccd-account
# command banks what Claude Code rotated into that account's own file — so both
# halves end up holding it, the credential is still provably the target's, and
# byte equality would be the only thing calling that a failure.
sw_fixture 58 100
( sleep 0.7; python3 - "$CREDS" "$ADIR/spare.json" <<'PY'
import json, sys
for path in sys.argv[1:3]:
    d = json.load(open(path))
    d["claudeAiOauth"]["accessToken"] = "AT-spare-refreshed"
    json.dump(d, open(path, "w"))
PY
) &
ROT=$!
rc=$(SW_SETTLE=2 sw_stopfail sess-f6)
wait "$ROT" 2>/dev/null
[ "$rc" = "2" ] \
  && ok "a rotation of the installed credential during the settle still wakes the turn" \
  || bad "settle rotation" "exit $rc — a legitimate refresh read as a failed swap"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── The budget reaches the socket, and the prompt path never waits on it ────
sw_fixture3 58 100
rm -rf "$RQD"
stage_usage 5 5
: > "$CCD_FAKE_USAGE_LOG"
# A ten-second per-request bound against a three-second budget: the bound that
# reaches the socket has to be the budget, or the hook is killed mid-probe.
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" \
  --deadline 3 >/dev/null 2>&1
worst_timeout=$(awk -F'\t' '{if ($2+0 > m) m=$2+0} END {print m+0}' "$CCD_FAKE_USAGE_LOG")
python3 -c "import sys; sys.exit(0 if 0 < float(sys.argv[1]) <= 3 else 1)" "${worst_timeout:-0}" \
  && ok "the decision's remaining budget is what bounds each request" \
  || bad "request budget" "a request was given ${worst_timeout}s of a 3s budget"

# A prompt tick fires several times a minute. Waiting on a background pass there
# is a frozen prompt, and the next tick can decide just as well.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
python3 - "$ADIR/.refresh.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(8)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
start=$(date +%s)
sw_prompt UserPromptSubmit sess-f5b >/dev/null
waited=$(( $(date +%s) - start ))
kill -9 "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$waited" -le 5 ] \
  && ok "...and a prompt tick gives up on a busy background pass rather than blocking" \
  || bad "prompt wait" "the tick held the prompt for ${waited}s"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

# ── Paying is proved, never inferred ────────────────────────────────────────
# Every way a swap can fail that is not "there is measurably nowhere free to go"
# used to end at the same fork, and one branch of that fork spends the user's
# money. The paid arm asks its own question now, and only a fresh successful
# measurement of every registered account can answer it yes.
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
paid_optin_on
# Each case seeds its own store, stand-in, consent and key: a case that ran on the
# last one's leftovers could not tell a hop that was refused from one that had
# already been made.
PROOF="every-subscription-measured-spent"
pay_case() { # $1=spare 5h  $2=spare 7d
  kill -9 "${SWPID:-0}" 2>/dev/null; wait "${SWPID:-0}" 2>/dev/null
  "$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
  sleep 0.3
  rm -f "$SWD/store-split" "$SWD/swap-note"
  sw_fixture 58 100 "$1" "$2"
  RQT=$(rq_gather)
  python3 - "$RQT" <<'PY'
import datetime, json, sys
ahead = lambda h: (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=h)).isoformat()
q = json.load(open(sys.argv[1]))
for row in q.values():
    row["five_hour_reset"], row["seven_day_reset"] = ahead(2), ahead(72)
json.dump(q, open(sys.argv[1], "w"))
PY
  rq_scatter "$RQT"
  hf_reset
  paid_optin_on
  mkdir -p "$SWD/providers"
  printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$SWD/providers/keys.env"
}
age_spare_row() { age_row spare; }
age_row() { RQT=$(rq_gather); python3 - "$RQT" "$1" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1])); q[sys.argv[2]]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
}
note_text() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["message"])' "$SWD/swap-note" 2>/dev/null; }
unpaid() { # $1=what was missing  [$2=nonote]
  if [ -n "$(hf_get direction)" ]; then bad "paid without proof: $1" "armed $(hf_get direction)"
  elif ! kill -0 "$SWPID" 2>/dev/null; then bad "paid without proof: $1" "ended the session"
  elif [ "${2:-}" != nonote ] && [ ! -f "$SWD/swap-note" ]; then bad "paid without proof: $1" "stopped and said nothing"
  else ok "no paid hop: $1"; fi
}

# The two proofs.
pay_case 100 100
sw_stopfail sess-p1 >/dev/null
{ [ "$(hf_get direction)" = "to_fallback" ] && died_within "$SWPID" 5; } \
  && ok "every spare freshly measured and spent, a key, the opt-in and a launcher: the paid hop fires" \
  || bad "paid proof" "direction=$(hf_get direction), note: $(note_text | head -c 120)"
pay_case 100 100
"$ACCT" --no-color rm spare >/dev/null 2>&1
sw_stopfail sess-p2 >/dev/null
{ [ "$(hf_get direction)" = "to_fallback" ] && died_within "$SWPID" 5; } \
  && ok "...and so does no spare registered at all" \
  || bad "paid proof" "direction=$(hf_get direction), note: $(note_text | head -c 120)"

# EVERY registered account has to prove itself — the one the store is on included.
# Excluding "the active account" made the proof depend on who is active, and that
# is not this session's to decide: another session swaps the store onto B, this
# session's proof then skips B as "active", finds A's fresh 99%, and pays past a
# subscription with room. Codex's interleaving, as it happens:
pay_case 10 20                          # B (spare) has room
"$ACCT" --no-color use spare --force >/dev/null 2>&1   # ...and another session moved the store onto it
quota 58 100                             # this session's cached reading still says: spent
stage_usage 10 20                        # ...but the wall measures the account the store is on NOW
hf_reset; rm -f "$SWD/swap-note" "$SWD"/wake-*
sw_stopfail sess-p2b >/dev/null
[ -z "$(hf_get direction)" ] \
  && ok "no paid hop: the store moved onto an account with room while this session hit the wall" \
  || bad "paid without proof: the store moved" "armed $(hf_get direction)"
rm -f "$SWD"/wake-*

# The wall's re-read IS the active account's measurement, so with one account
# registered it is the whole proof — and it never touches the token Claude Code owns.
pay_case 100 100; "$ACCT" --no-color rm spare >/dev/null 2>&1
age_row spent; stage_usage 100 100
: > "$CCD_FAKE_USAGE_LOG"
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p2c >/dev/null
{ [ "$(hf_get direction)" = "to_fallback" ] && [ -s "$CCD_FAKE_USAGE_LOG" ]; } \
  && ok "one registered account, measured spent at the wall, is proof" \
  || bad "paid proof" "direction=$(hf_get direction), measured $(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ') times"
pay_case 100 100; "$ACCT" --no-color rm spare >/dev/null 2>&1
stage_usage 5 5 503
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p2d >/dev/null
unpaid "the re-read at the wall failed, with a fresh 100% reading on file for every account" nonote
[ ! -f "$SWD/swap-note" ] && ok "...and nothing else fires either: no swap, no wake, no note" \
  || bad "acted on a failed re-read" "left a note: $(note_text | head -c 100)"
# The live token is the SESSION'S. An expired one is simply not measured — there is
# no refresh path in the wall's measurement at all — and an unmeasured wall fires nothing.
pay_case 100 100; "$ACCT" --no-color rm spare >/dev/null 2>&1
python3 - "$CREDS" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
PY
stage_usage 100 100 200 0 AT-spent-rotated               # an exchange WOULD rotate, and would show
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p2e >/dev/null
unpaid "the live token has expired, so the wall could not be measured" nonote
{ grep -q '"AT-spent"' "$CREDS" && ! grep -q 'rotated' "$ADIR/spent.json" "$CREDS"; } \
  && ok "...and nothing is exchanged to find out: that token belongs to the running session" \
  || bad "spent the live token" "a token was rotated from the wall's measurement"

# ONE meaning of "spent", and it is 100%. The 90% reserve used to decide two things
# at once — "not worth hopping to" and "spent enough to pay" — so a spare at 90%
# was skipped by the swap AND proved spent, and ccd paid with a tenth of a
# subscription left. A spare is a destination while it is under 100; ccd pays only
# when every registered account is AT 100; and a session moves when its own
# account gets there, not before.
moved_to_spare() { grep -q 'AT-spare' "$CREDS" && [ -z "$(hf_get direction)" ]; }
pay_case 90 90
sw_stopfail sess-s1 >/dev/null
moved_to_spare && ok "a spare at 90% is a destination: the session moves there and nothing is billed" \
  || bad "paid past a spare with room" "direction=$(hf_get direction), credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1)"
pay_case 99 99
sw_stopfail sess-s2 >/dev/null
moved_to_spare && ok "...and so is a spare at 99%" \
  || bad "paid past a spare with room" "direction=$(hf_get direction), credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1)"
pay_case 100 100
sw_stopfail sess-s3 >/dev/null
[ "$(hf_get direction)" = "to_fallback" ] && ok "...while every registered account at 100% is what paying takes" \
  || bad "paid proof" "direction=$(hf_get direction), note: $(note_text | head -c 120)"
pay_case 10 20; quota 58 97
sw_prompt UserPromptSubmit sess-s4 >/dev/null
grep -q 'AT-spent' "$CREDS" && ok "a tick at 97% moves nothing: the account still answers" \
  || bad "moved before the wall" "the session left an account with quota still on it"
pay_case 10 20; quota 58 100
sw_prompt UserPromptSubmit sess-s5 >/dev/null
grep -q 'AT-spare' "$CREDS" && ok "...and a tick at 100% moves it" \
  || bad "did not move at the wall" "credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1)"

# "Spent" is written down once. Every program that decides on it reads that file;
# none carries a number of its own, and the two knobs that used to disagree are gone.
{ [ "$(cat "$ROOT/bin/spent-at")" = "100" ] \
  && grep -q 'spent-at' "$ROOT/bin/ccd-account" && grep -q 'spent-at' "$ROOT/scripts/quota-guard.sh" \
  && grep -q 'spent-at' "$ROOT/bin/ccd-statusline" \
  && ! grep -qE 'HEADROOM|ARM_THRESHOLD' "$ROOT/bin/ccd-account" "$ROOT/bin/ccd-statusline" "$ROOT/bin/ccd" \
         "$ROOT/bin/ccd-handoff" "$ROOT/scripts/quota-guard.sh"; } \
  && ok "one definition of spent, read by the hook, the account tool and the statusline alike" \
  || bad "spent is defined twice" "a program carries its own threshold again"
# ...and nothing in somebody's shell moves it for the swap, as nothing moves it for the row.
pay_case 95 95
CCD_HEADROOM=50 "$ACCT" --no-color pick >/dev/null 2>&1 \
  && ok "...and the retired CCD_HEADROOM cannot make a spare with room look spent" \
  || bad "spent is a knob again" "an environment variable took a destination away"
# The hook fails closed without it: a hook that cannot tell "spent" moves nothing.
rm -rf "$FAKE/nospent"; mkdir -p "$FAKE/nospent"; cp -R "$ROOT/bin" "$ROOT/scripts" "$FAKE/nospent/"; rm -f "$FAKE/nospent/bin/spent-at"
pay_case 10 20
printf '{"session_id":"sess-ns","cwd":"/tmp/w"}' \
  | CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID CLAUDE_PLUGIN_ROOT="$ROOT" CCD_SWAP_SETTLE=0 \
    "$FAKE/nospent/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
grep -q 'AT-spent' "$CREDS" && ok "...and a hook that cannot read it acts on no guess of its own" \
  || bad "guessed at spent" "the hook moved a session without knowing what spent means"
rm -rf "$FAKE/nospent"

# A reading belongs to its account for as long as the account is registered.
pay_case 10 20
{ [ -f "$RQD/spare.json" ] && "$ACCT" --no-color rm spare >/dev/null 2>&1 && [ ! -e "$RQD/spare.json" ] && [ -f "$RQD/spent.json" ]; } \
  && ok "removing an account removes its reading, and only its reading" \
  || bad "orphaned reading" "readings on file: $(ls "$RQD" 2>/dev/null | tr '\n' ' ')"
# The shared cache is gone for good: no reader, no migration, and the file itself
# goes the first time a command sets up the store.
printf '{"spare":{"status":"ok","five_hour_percent":1}}' > "$SWD/accounts-quota.json"
"$ACCT" --no-color current >/dev/null 2>&1
[ ! -e "$SWD/accounts-quota.json" ] && ok "the old shared cache is deleted where it is found, not read" \
  || bad "old cache survives" "accounts-quota.json is still on disk"

# At the wall the reading is taken AGAIN. It is cached for ten minutes, so the one on
# file can say 96 while the account is at 100 — and with spent meaning 100, a
# backstop that trusted it would sit beside a spare with room and do nothing, on
# exactly the turn it exists for.
pay_case 10 20
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"fiveHourReset":"R1","sevenDayPercent":96,"sevenDayReset":"D1"}}\n' \
  > "$SWD/quota-cache.json"            # what the cache still says (not staged behind it)
stage_usage 100 100                     # what the account says now
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-s6)
{ [ "$rc" = "2" ] && grep -q 'AT-spare' "$CREDS"; } \
  && ok "a turn that dies on rate_limit re-reads the account rather than trust a reading that lags it" \
  || bad "stale reading at the wall" "rc=$rc, credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1): the backstop believed a cached 96%"

# A reading is published by whoever measured it, and by nobody else. The active
# account's measurement used to load every account's row, wait on the network, and
# write every row back — putting a spare's stale 503 back over the healthy reading a
# background prober had recorded in the meantime, and stranding the turn beside a
# subscription that had just been measured free. One file per account: a prober can
# only ever publish the account it measured.
pay_case 10 20
python3 - "$RQD" <<'PY'
import json, os, sys, time
d = sys.argv[1]
sp = json.load(open(os.path.join(d, "spare.json")))
json.dump({"status": "error", "http_status": 503, "checked_at": int(time.time()),
           "cred": sp["cred"], "uuid": sp.get("uuid")}, open(os.path.join(d, "spare.json"), "w"))
me = json.load(open(os.path.join(d, "spent.json")))
me["checked_at"] = int(time.time()) - 99999          # so the active account IS measured
json.dump(me, open(os.path.join(d, "spent.json"), "w"))
PY
stage_usage 100 100 200 3
( sleep 1.2
  python3 - "$RQD/spare.json" "$ADIR/spare.json" <<'PY'
import datetime, hashlib, json, os, sys, time
ahead = lambda h: (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=h)).isoformat()
at = json.load(open(sys.argv[2]))["claudeAiOauth"]["accessToken"]
row = {"status": "ok", "checked_at": int(time.time()), "cred": hashlib.sha256(at.encode()).hexdigest()[:16],
       "uuid": None, "five_hour_percent": 10, "seven_day_percent": 20,
       "five_hour_reset": ahead(2), "seven_day_reset": ahead(72)}
tmp = sys.argv[1] + ".bg"
json.dump(row, open(tmp, "w")); os.replace(tmp, sys.argv[1])
PY
) & BGP=$!
# The measurement in flight is the wall's own: three seconds on the wire for the
# active account, while a background prober records the spare.
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color usage --json --deadline 30 >/dev/null 2>&1
wait "$BGP" 2>/dev/null
spare_row() { python3 -c 'import json,sys
try: r = json.load(open(sys.argv[1]))
except Exception: r = {}
print(str(r.get("status")) + ":" + str(r.get("five_hour_percent")))' "$RQD/spare.json"; }
[ "$(spare_row)" = "ok:10" ] \
  && ok "a measurement in flight does not write back over another account's newer reading" \
  || bad "lost update" "the spare's reading is now $(spare_row)"
stage_token AT-spare 10 20
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window none --deadline 30 >/dev/null 2>&1
grep -q 'AT-spare' "$CREDS" && ok "...so the next attempt finds the spare and moves there" \
  || bad "lost update" "the healthy spare was never reached"
# ...and "check, then replace" has to be ONE step. Writer A passes the check with
# 99%@T and is descheduled before its rename; writer B publishes 100%@T+10; A
# resumes and puts 99% back. Nothing bounds that pause, so it is closed with a lock
# per account — two processes, because the lock is reentrant inside one.
cat > "$FAKE/.lockrace.py" <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("ccdrace", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
who, t = sys.argv[2], int(sys.argv[3])
if who == "A":
    real = m.write_json
    def slow(p, obj, mode=0o600):
        if str(p).endswith("race2.json"):
            time.sleep(2.0)             # past the check, not yet renamed
        return real(p, obj, mode)
    m.write_json = slow
    m.reading_save("race2", {"status": "ok", "checked_at": t, "five_hour_percent": 99})
else:
    time.sleep(0.7)                     # A is inside its pause by now
    m.reading_save("race2", {"status": "ok", "checked_at": t + 10, "five_hour_percent": 100})
PY
rm -f "$RQD/race2.json"; mkdir -p "$RQD"
T0=$(date +%s)
PYTHONDONTWRITEBYTECODE=1 HOME="$FAKE" python3 "$FAKE/.lockrace.py" "$ROOT/bin/ccd-account" A "$T0" & RA=$!
PYTHONDONTWRITEBYTECODE=1 HOME="$FAKE" python3 "$FAKE/.lockrace.py" "$ROOT/bin/ccd-account" B "$T0" & RB=$!
wait "$RA" "$RB" 2>/dev/null
got=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("five_hour_percent"))' "$RQD/race2.json" 2>/dev/null)
[ "$got" = "100" ] \
  && ok "a writer paused between its check and its rename cannot put an older reading back" \
  || bad "lost update" "the account's reading ended at ${got:-nothing}% — the older writer won"
ls "$RQD" | grep -v '\.json$' | grep -q . \
  && { ls -A "$RQD" | grep -q '^\.' || bad "lock in the way" "a non-dot file sits beside the readings: $(ls "$RQD" | tr '\n' ' ')"; } || true
rm -f "$RQD/race2.json" "$RQD"/.race2.* "$FAKE/.lockrace.py"

# Two probers of the SAME account can finish out of order. The later look wins.
PYTHONDONTWRITEBYTECODE=1 HOME="$FAKE" python3 - "$ROOT/bin/ccd-account" <<'PY' \
  && ok "an older measurement of an account never replaces a newer one" \
  || bad "stale reading published" "a slow probe overwrote the reading a faster one had already recorded"
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("ccdread", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
t = int(time.time())
m.reading_save("race", {"status": "ok", "checked_at": t, "five_hour_percent": 10})
m.reading_save("race", {"status": "error", "checked_at": t - 5})          # asked earlier, answered later
assert m.reading_load("race")["status"] == "ok", m.reading_load("race")
m.reading_save("race", {"status": "ok", "checked_at": t + 1, "five_hour_percent": 11})
assert m.reading_load("race")["five_hour_percent"] == 11, "a newer reading was refused"
m.reading_save("race", {"status": "ok", "checked_at": t + 99999, "five_hour_percent": 12})   # a wrong clock
m.reading_save("race", {"status": "ok", "checked_at": t + 2, "five_hour_percent": 13})
assert m.reading_load("race")["five_hour_percent"] == 13, "a reading from the future blocked every later one"
# "Later stamp wins" only means "later look wins" if the stamp is when the ANSWER
# arrived. A probe stamps itself when it starts; quota_for re-stamps on the way out.
m.probe_account = lambda n, a, allow_refresh=True: {"status": "ok", "checked_at": t - 50, "five_hour_percent": 1}
rec = m.quota_for("stamp", {"claudeAiOauth": {"accessToken": "AT-stamp"}})
assert rec["checked_at"] >= t, "stamped when the question was asked, not when it was answered"
assert m.reading_load("stamp")["checked_at"] >= t, "the reading on file carries the asking time"
m.reading_drop("stamp")
import os, stat
assert stat.S_IMODE(os.stat(m.reading_path("race")).st_mode) == 0o600
assert stat.S_IMODE(os.stat(m.READINGS_DIR).st_mode) == 0o700
# One freshness rule for every reader: a reading from the FUTURE is a wrong clock,
# not a fresh reading. After a backward clock step it would otherwise pin a spent
# verdict in place and keep a usable account from being measured again.
probed = []
m.probe_account = lambda n, a, allow_refresh=True: (probed.append(n), {"status": "ok", "checked_at": t, "five_hour_percent": 1})[1]
acct = {"claudeAiOauth": {"accessToken": "AT-fut"}}
m.write_json(m.reading_path("fut"), {"status": "ok", "checked_at": t + 9999, "cred": m._cred_fingerprint(acct), "five_hour_percent": 100}, 0o600)
m.quota_for("fut", acct)
assert probed == ["fut"], "a future-dated reading was served as fresh instead of being re-measured"
m.reading_drop("fut")
# ...and a readings directory that already existed with loose permissions is put right.
os.chmod(m.READINGS_DIR, 0o755)
m.reading_save("perm", {"status": "ok", "checked_at": t})
assert stat.S_IMODE(os.stat(m.READINGS_DIR).st_mode) == 0o700, oct(stat.S_IMODE(os.stat(m.READINGS_DIR).st_mode))
m.reading_drop("perm")
m.reading_drop("race")
assert not [f for f in os.listdir(m.READINGS_DIR) if "race" in f or "perm" in f or "fut" in f], os.listdir(m.READINGS_DIR)
PY

# What the wall just measured is what the proof sees. The re-read used to land only
# in the hook's own cache, so an account reading taken 30 seconds earlier at 99%
# went on speaking for an account the wall had just measured at 100 — and the turn
# stayed parked with every condition for paying met.
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1]))
q["spent"].update({"five_hour_percent": 99, "seven_day_percent": 99, "checked_at": int(time.time()) - 30})
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
stage_usage 100 100
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-w1 >/dev/null
[ "$(hf_get direction)" = "to_fallback" ] \
  && ok "the wall's own measurement of the active account is the one the proof reads" \
  || bad "wall reading lost" "direction=$(hf_get direction), spent's reading: $(head -c 140 "$RQD/spent.json" 2>/dev/null)"

# ...but only under a name ccd can PROVE. The pointer says `spent`; the login in the
# store is somebody ccd never registered (a /login it has had no chance to bank, and
# no profile to bank it by). Those numbers are about a stranger, and filing them as
# spent's reading would let a stranger's quota speak in the proof for spent's.
pay_case 100 100
rm -f "$RQD/spent.json"
write_creds stranger
stage_usage 100 100
CCD_HTTP_TIMEOUT=5 "$ACCT" --no-color usage --json >/dev/null 2>&1
[ ! -e "$RQD/spent.json" ] \
  && ok "...and a measurement of a login ccd cannot tie to the account is filed under nobody's name" \
  || bad "reading filed under the wrong account" "spent's reading now says: $(head -c 120 "$RQD/spent.json")"

# A turn can die on rate_limit while the account the store is ON has room: the tick
# installed a spare a second ago and the request still went out on the old
# credential; another session moved the store; the throttle was transient. There is
# nothing to swap and nothing to pay for — and a turn left parked. It is woken, once.
pay_case 10 20
"$ACCT" --no-color use spare --force >/dev/null 2>&1      # the store is on the healthy account
stage_usage 10 20                                        # ...and the wall measures exactly that
rm -f "$SWD"/wake-* "$SWD/swap-note"; hf_reset
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-k1)
{ [ "$rc" = "2" ] && [ -z "$(hf_get direction)" ] && grep -q 'AT-spare' "$CREDS"; } \
  && ok "a turn that died on rate_limit beside an account with room is woken to retry" \
  || bad "left parked" "rc=$rc, direction=$(hf_get direction)"
case "$(cat "$FAKE/.sw-err")" in
  *"switched this session to"*) bad "wake message" "claimed a swap that did not happen: $(head -c 140 "$FAKE/.sw-err")" ;;
  *"has quota"*|*"has room"*) ok "...in words that are true: the account has quota and the turn is retried, no swap claimed" ;;
  *) bad "wake message" "got: $(head -c 140 "$FAKE/.sw-err")" ;;
esac
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-k1)
{ [ "$rc" != "2" ] && [ -f "$SWD/swap-note" ]; } \
  && ok "...once: a second failure inside the interval wakes nothing and leaves a note instead" \
  || bad "wake loop" "rc=$rc on the second failure, note: $(note_text | head -c 100)"
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-k2)
[ "$rc" = "2" ] && ok "...and the bound is per session, not a gag on every other one" \
  || bad "wake bound" "a different session was refused its one retry (rc=$rc)"
rm -f "$SWD"/wake-* "$SWD/swap-note"

# The user's three conditions, one missing at a time.
pay_case 100 100; rm -f "$SWD/providers/keys.env"
sw_stopfail sess-p3 >/dev/null; unpaid "no key stored"
pay_case 100 100; paid_optin_off
sw_stopfail sess-p4 >/dev/null; unpaid "no opt-in"
case "$(note_text)" in
  *"ccd -c"*) ok "...and the note still names the way there by hand" ;;
  *) bad "stop note" "got: $(note_text | head -c 140)" ;;
esac

# The mechanical one: the hop is a relaunch, and only a launcher can relaunch.
pay_case 100 100
printf '{"session_id":"sess-p5","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"rate_limit"}' \
  | env -u CCD_HANDOFF -u CCD_HANDOFF_STATE CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID \
      CLAUDE_PLUGIN_ROOT="$ROOT" CCD_SWAP_SETTLE=0 env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
unpaid "no launcher supervising the session"
case "$(note_text)" in
  *"launcher"*"claude"*) ok "...and the note says the opt-in is on but this session cannot take it, and what fixes that" ;;
  *) bad "launcher note" "got: $(note_text | head -c 160)" ;;
esac
pay_case 100 100
CCD_HANDOFF_HEADLESS=1 sw_stopfail sess-p6 >/dev/null; unpaid "a headless run"

# What is NOT proof. Each of these once reached the paying branch, or could have.
pay_case 10 20                          # the spare HAS room; the store is just busy
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(6)
PY
HOLD=$!; sleep 0.4
CCD_SWAP_PICK_BUDGET=3 sw_stopfail sess-p7 >/dev/null
kill -9 "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
unpaid "a store lock that timed out"

pay_case 100 100; age_spare_row; stage_usage 100 100; stage_token AT-spare 5 5 503
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p8 >/dev/null; unpaid "a spare that answered 503"

pay_case 100 100; age_spare_row
CCD_SWAP_PICK_BUDGET=0 sw_stopfail sess-p9 >/dev/null; unpaid "a deadline that expired before anything was measured" nonote

pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1])); q["spare"] = {"status": "unknown", "checked_at": int(time.time())}
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
stage_token AT-spare 5 5 500            # ...and it cannot be measured now either
sw_stopfail sess-p10 >/dev/null; unpaid "a spare whose reading is not a measurement"

pay_case 100 100
printf '{"detail":"x","stores":["file","keychain"]}' > "$SWD/store-split"
sw_stopfail sess-p11 >/dev/null; unpaid "credential stores that disagree"
rm -f "$SWD/store-split"

pay_case 10 20                          # room to go to, and a swap that cannot get there
mkdir -p "$FAKE/failroot/bin"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = swap ] && { echo "could not act" >&2; exit 4; }; done\nexec "$CCD_REAL_ACCOUNT" "$@"\n' \
  > "$FAKE/failroot/bin/ccd-account"
chmod +x "$FAKE/failroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
SW_ROOT="$FAKE/failroot" sw_stopfail sess-p12 >/dev/null; unpaid "a swap that was attempted and failed"

mkdir -p "$FAKE/unconfroot/bin"
cat > "$FAKE/unconfroot/bin/ccd-account" <<'UEOF'
#!/bin/sh
case " $* " in *" current --json "*) [ -e "$HOME/.unconf-swapped" ] && { echo '{}'; exit 0; } ;; esac
for a in "$@"; do
  [ "$a" = swap ] && { "$CCD_REAL_ACCOUNT" "$@"; rc=$?; : > "$HOME/.unconf-swapped"; exit "$rc"; }
done
exec "$CCD_REAL_ACCOUNT" "$@"
UEOF
chmod +x "$FAKE/unconfroot/bin/ccd-account"
pay_case 10 20; rm -f "$FAKE/.unconf-swapped"
SW_ROOT="$FAKE/unconfroot" sw_stopfail sess-p13 >/dev/null; unpaid "a swap that landed but could not be confirmed"
rm -f "$FAKE/.unconf-swapped"

# chmod cannot stage this: every ccd-account command re-asserts 0700 on its own
# directory, which heals it. A store that cannot be listed is staged where the
# listing happens, and as a path that is not a directory at all.
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE/proof-unlistable" <<'PY' \
  && ok "no paid hop: an accounts directory that could not be read" \
  || bad "paid without proof: unreadable accounts directory" "a listing that failed read as no spare registered"
import importlib.machinery, importlib.util, os, sys
os.makedirs(sys.argv[2] + "/.claude", exist_ok=True)
os.environ["HOME"] = sys.argv[2]; os.environ["CCD_CREDENTIALS_BACKEND"] = "file"
loader = importlib.machinery.SourceFileLoader("ccdproof", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m); m.ensure_dirs()
real = os.listdir
def denied(p):
    if str(p) == m.ACCOUNTS_DIR:
        raise PermissionError(13, "Permission denied", p)
    return real(p)
m.os.listdir = denied
try:
    verdict = m.subscriptions_proved_spent()
except OSError:
    verdict = "raised"
finally:
    m.os.listdir = real
assert verdict is not True, "an unlistable store was proof that nothing is registered"
PY
pay_case 100 100; mv "$ADIR" "$ADIR.real"; : > "$ADIR"
sw_stopfail sess-p14 >/dev/null
rm -f "$ADIR"; mv "$ADIR.real" "$ADIR"
unpaid "an accounts path that is not a directory" nonote

# ccd does not start billing while the subscription still answers.
pay_case 100 100
sw_prompt UserPromptSubmit sess-p15 >/dev/null
unpaid "the tick before the wall, with everything else in place" nonote

# The verdict is one positive answer. A caller that inferred it from an exit code,
# or from there being no output, is how an operational failure used to pay.
for shape in silent-success wrong-word right-word-but-failed crashed; do
  mkdir -p "$FAKE/proofroot-$shape/bin"
  case "$shape" in
    silent-success)        body='exit 0' ;;
    wrong-word)            body='echo yes; exit 0' ;;
    right-word-but-failed) body="echo $PROOF; exit 1" ;;
    crashed)               body='echo "Traceback (most recent call last):" >&2; exit 1' ;;
  esac
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = exhausted ] && { %s; }; done\nexec "$CCD_REAL_ACCOUNT" "$@"\n' "$body" \
    > "$FAKE/proofroot-$shape/bin/ccd-account"
  chmod +x "$FAKE/proofroot-$shape/bin/ccd-account"
  pay_case 100 100
  SW_ROOT="$FAKE/proofroot-$shape" sw_stopfail "sess-p16-$shape" >/dev/null
  unpaid "an answer that is not the proof ($shape)"
done
{ [ "$(grep -c "\"$PROOF\"" "$ROOT/bin/ccd-account")" = "1" ] \
  && [ "$(grep -c 'print(EXHAUSTED_PROOF)' "$ROOT/bin/ccd-account")" = "1" ] \
  && grep -q "= \"$PROOF\" \]" "$ROOT/scripts/quota-guard.sh"; } \
  && ok "the proof is one word, printed in one place, and compared for equality" \
  || bad "proof mechanism" "the verdict can be produced or accepted some other way"

# The question itself, asked directly. It reads what the measurement left behind
# and opens no socket of its own, so nothing in it can time out into a yes.
proves() { [ "$("$ACCT" --no-color exhausted 2>/dev/null)" = "$PROOF" ]; }
pay_case 100 100
: > "$CCD_FAKE_USAGE_LOG"
{ proves && [ ! -s "$CCD_FAKE_USAGE_LOG" ]; } \
  && ok "every spare measured, fresh and spent is proof, read without a network call" \
  || bad "proof" "refused proof in hand, or went to the network for it"
pay_case 10 100
proves && ok "...one window spent is an account spent" || bad "proof" "a spare at 99% weekly was called free"
pay_case 10 20
proves && bad "proof" "a spare with room was called spent" || ok "...and a spare with room is not"
# The same line the swap draws, from the other side: whatever is still a destination
# is not spent. Through the hook this cannot be seen — a spare under 100 is swapped
# TO and the proof is never asked — so it is asked here.
for pct in 90 99; do
  pay_case "$pct" "$pct"
  proves && bad "proof" "a spare at ${pct}% counted as spent" || ok "...nor is a spare at ${pct}%: only 100 is spent"
done
pay_case 100 100; age_spare_row
proves && bad "proof" "a reading past its TTL was proof" || ok "...nor is a reading too old to describe now"
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1])); q["spare"]["status"] = "error"
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "a failed measurement was proof" || ok "...nor a measurement that failed"
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1])); del q["spare"]
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "an unmeasured spare was proof" || ok "...nor a spare nobody measured"
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import datetime, json, sys
past = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1)).isoformat()
q = json.load(open(sys.argv[1])); q["spare"]["five_hour_reset"] = past; q["spare"]["seven_day_reset"] = past
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "a window that has since reset was proof" || ok "...nor a window that has reset since it was read"
set_resets() { # $1=account  $2=python expression for the value
  RQT=$(rq_gather)
  python3 - "$RQT" "$1" "$2" <<'PY'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
q = json.load(open(sys.argv[1])); v = eval(sys.argv[3])
for k in ("five_hour_reset", "seven_day_reset"):
    if v is None: q[sys.argv[2]].pop(k, None)
    else: q[sys.argv[2]][k] = v
json.dump(q, open(sys.argv[1], "w"))
PY
  rq_scatter "$RQT"
}
# A window is spent only while it is KNOWN to still be open. 99% with no usable
# reset can have reset a second later, and the row stays "fresh" for five minutes.
for shape in 'missing:None' 'malformed:"soon"' 'naive:(now + datetime.timedelta(hours=48)).replace(tzinfo=None).isoformat()'; do
  pay_case 100 100; set_resets spare "${shape#*:}"
  proves && bad "proof" "a ${shape%%:*} reset time was proof" \
    || ok "...nor a spent window whose reset time is ${shape%%:*}"
done
pay_case 100 100; set_resets spare '(now + datetime.timedelta(hours=2)).isoformat().replace("+00:00", "Z")'
proves && ok "...while a reset written with Z is as good as one written with an offset" \
  || bad "proof" "a valid future reset in Z form was refused"
# The active account is a registered account. Its row counts like any other.
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1])); q["spent"]["five_hour_percent"] = 10; q["spent"]["seven_day_percent"] = 20
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "the account the store is on was left out of the proof" \
  || ok "...nor anything while the account the store is on shows room"
# Asking is not acting: no directory made, no credential banked, no pointer moved.
rm -rf "$FAKE/proof-ro"; mkdir -p "$FAKE/proof-ro/.claude"
out=$(HOME="$FAKE/proof-ro" "$ACCT" --no-color exhausted 2>/dev/null); rc=$?
{ [ "$out" = "$PROOF" ] && [ "$rc" -eq 0 ] && [ ! -e "$FAKE/proof-ro/.claude/ccd" ]; } \
  && ok "a store that was never created is an honest zero, and asking does not create it" \
  || bad "proof is not read-only" "out=$out rc=$rc, made: $(ls -A "$FAKE/proof-ro/.claude")"
pay_case 100 100; printf 'not json' > "$ADIR/spare.json"
proves && bad "proof" "an account that cannot be read was skipped" || ok "...nor a store with an account file it cannot read"
# Naming a store this suite cannot see, so the stop cannot lift itself first.
pay_case 100 100; printf '{"detail":"x","stores":["file","keychain"]}' > "$SWD/store-split"
proves && bad "proof" "proved over a standing stop" || ok "...nor anything at all while the credential stores disagree"
rm -f "$SWD/store-split"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
rm -f "$SWD/providers/keys.env" "$SWD/swap-note"
paid_optin_off

# ── stdout is the protocol; stderr is not ───────────────────────────────────
# A swap can succeed and still have something to say — the cached account config
# it could not drop, for one. Folding that into the result made the warning the
# account name and left no fingerprint, so the parked turn was never woken.
mkdir -p "$FAKE/warnroot/bin"
cat > "$FAKE/warnroot/bin/ccd-account" <<'WEOF'
#!/bin/sh
for a in "$@"; do
  [ "$a" = swap ] && echo "ccd account: warning: could not drop the cached account config" >&2
done
exec "$CCD_REAL_ACCOUNT" "$@"
WEOF
chmod +x "$FAKE/warnroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rc=$(SW_ROOT="$FAKE/warnroot" sw_stopfail sess-w1)
{ [ "$rc" = "2" ] && grep -q 'switched this session to spare,' "$FAKE/.sw-err"; } \
  && ok "a swap that warned still wakes the turn, naming the account it moved to" \
  || bad "warning read as the result" "rc=$rc: $(tr '\n' ' ' < "$FAKE/.sw-err" | head -c 160)"
sw_fixture 58 100
out=$(SW_ROOT="$FAKE/warnroot" sw_prompt UserPromptSubmit sess-w2)
case "$out" in
  *warning*) bad "warning read as the result" "the tick announced: ${out:0:160}" ;;
  *spare*) ok "...and the tick before the wall announces the account, not the warning" ;;
  *) bad "warning read as the result" "nothing announced: ${out:0:160}" ;;
esac

# A swap refused by a standing stop has a remedy, and 120 characters of stderr do
# not reach it. One fixed line that points at doctor, which carries all of it.
sw_fixture 58 100
printf '{"detail":"keychain took b, file kept a","stores":["file","keychain"]}' > "$SWD/store-split"
rm -f "$SWD/swap-note"
sw_stopfail sess-w3 >/dev/null
grep -q 'stores disagree.*ccd doctor' "$SWD/swap-note" 2>/dev/null \
  && ok "a backstop stopped by disagreeing stores sends the user to ccd doctor" \
  || bad "remedy cut off" "note: $(head -c 200 "$SWD/swap-note" 2>/dev/null)"
rm -f "$SWD/swap-note"
# The same tick that writes the note may be the one that shows it, so look at both.
out=$(sw_prompt UserPromptSubmit sess-w4)
# "ccd doctor" alone proves nothing here — the quota warning says it too.
{ case "$out" in *"stores disagree"*"ccd doctor"*) true ;; *) false ;; esac \
  || grep -q 'stores disagree.*ccd doctor' "$SWD/swap-note" 2>/dev/null; } \
  && ok "...and so does the tick before the wall, which used to say nothing" \
  || bad "remedy cut off" "the proactive path said: ${out:0:120} / left: $(head -c 80 "$SWD/swap-note" 2>/dev/null)"
rm -f "$SWD/store-split" "$SWD/swap-note"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── A swap that happened, over stores not yet seen to agree ─────────────────
# The swap is a success and stays one — it wakes, it announces — but the stop it
# left standing has a remedy, and the hook threw the only mention of it away.
mkdir -p "$FAKE/splitroot/bin"
cat > "$FAKE/splitroot/bin/ccd-account" <<'SEOF'
#!/bin/sh
# The real swap, followed by what a verify that could not see leaves behind. With
# SPLIT_UNCONFIRMED set, the confirmation read AFTER the swap finds nothing to
# confirm either — only after: the same command feeds the decision to swap at all.
case " $* " in
  *" current --json "*)
    [ -n "${SPLIT_UNCONFIRMED:-}" ] && [ -e "$HOME/.split-swapped" ] && { echo '{}'; exit 0; } ;;
esac
for a in "$@"; do
  if [ "$a" = swap ]; then
    "$CCD_REAL_ACCOUNT" "$@"; rc=$?
    [ "$rc" -eq 0 ] && { printf '{"detail":"x","stores":["file","keychain"]}' > "$HOME/.claude/ccd/store-split"
                         : > "$HOME/.split-swapped"; }
    exit "$rc"
  fi
done
exec "$CCD_REAL_ACCOUNT" "$@"
SEOF
chmod +x "$FAKE/splitroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
for shape in wakes unconfirmed tick; do
  # Before the fixture, not after: the stop the last shape left standing would
  # refuse the fixture's own `use`, and this shape would start on the wrong account.
  rm -f "$SWD/swap-note" "$SWD/store-split" "$FAKE/.split-swapped"
  sw_fixture 58 100
  case "$shape" in
    wakes)       rc=$(SW_ROOT="$FAKE/splitroot" sw_stopfail sess-s1); want=2 ;;
    unconfirmed) rc=$(SPLIT_UNCONFIRMED=1 SW_ROOT="$FAKE/splitroot" sw_stopfail sess-s2); want=0 ;;
    tick)        out=$(SW_ROOT="$FAKE/splitroot" sw_prompt UserPromptSubmit sess-s3)
                 case "$out" in *"spare 계정으로 갈아탔습니다"*) rc=0 ;; *) rc=1 ;; esac; want=0 ;;
  esac
  { [ "$rc" = "$want" ] && grep -q 'AT-spare' "$CREDS" \
      && grep -q 'spare.*stores disagree.*ccd doctor' "$SWD/swap-note" 2>/dev/null; } \
    && ok "a swap over a standing stop still succeeds ($shape), and says where the remedy is" \
    || bad "advisory lost ($shape)" "rc=$rc want=$want, note: $(head -c 140 "$SWD/swap-note" 2>/dev/null)"
done
rm -f "$SWD/store-split" "$SWD/swap-note"

# A hook killed mid-swap must not strand its stderr capture. bash defers a trap
# until the child returns, so the fake swap is short; without a trap the TERM
# kills the hook on the spot and the file stays for ever.
mkdir -p "$FAKE/slowroot/bin"
cat > "$FAKE/slowroot/bin/ccd-account" <<'LEOF'
#!/bin/sh
for a in "$@"; do [ "$a" = swap ] && { : > "$HOME/.swap-started"; sleep 2; echo "too slow" >&2; exit 4; }; done
exec "$CCD_REAL_ACCOUNT" "$@"
LEOF
chmod +x "$FAKE/slowroot/bin/ccd-account"
sw_fixture 58 100
rm -f "$FAKE/.swap-started" "$SWD"/.swap-err.*
printf '{"session_id":"sess-k1","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"rate_limit"}' > "$FAKE/.k1-in"
# exec, so that $! is the hook itself: a signal sent to a wrapping subshell kills
# the wrapper and proves nothing about the script inside it.
( exec env CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID CLAUDE_PLUGIN_ROOT="$FAKE/slowroot" \
    env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure < "$FAKE/.k1-in" >/dev/null 2>&1 ) & HKPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$FAKE/.swap-started" ] && break; sleep 0.25; done
started=$(ls "$SWD"/.swap-err.* 2>/dev/null | wc -l | tr -d ' ')
kill -TERM "$HKPID" 2>/dev/null; wait "$HKPID" 2>/dev/null
left=$(ls "$SWD"/.swap-err.* 2>/dev/null | wc -l | tr -d ' ')
{ [ "${started:-0}" -ge 1 ] && [ "${left:-1}" -eq 0 ]; } \
  && ok "a hook killed mid-swap takes its stderr capture with it" \
  || bad "stranded capture" "in flight: $started, left behind: $left"
rm -f "$SWD"/.swap-err.* "$FAKE/.swap-started"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── Three attempts, then stop ───────────────────────────────────────────────
# An operational failure is worth retrying briefly — a store that moved, a lock
# someone else held — and worth nothing after that.
mkdir -p "$FAKE/countroot/bin"
cat > "$FAKE/countroot/bin/ccd-account" <<'CEOF'
#!/bin/sh
# Counts swap attempts and refuses each one the way an operational failure does;
# everything else is the real tool.
for a in "$@"; do
  [ "$a" = swap ] && { echo x >> "$HOME/.swap-tries"; echo "could not act" >&2; exit 4; }
done
exec "$CCD_REAL_ACCOUNT" "$@"
CEOF
chmod +x "$FAKE/countroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rm -f "$FAKE/.swap-tries"
SW_ROOT="$FAKE/countroot" sw_prompt UserPromptSubmit sess-r1 >/dev/null
tries=$(grep -c . "$FAKE/.swap-tries" 2>/dev/null || echo 0)
[ "${tries:-0}" -eq 3 ] \
  && ok "an operational failure is retried three times and then let go" \
  || bad "retries" "the swap was attempted ${tries:-0} times"

# ── A failure the user hears about once, without a doomed wake ──────────────
# The spare is spent as well, so the ticks that follow have nothing to swap to
# and the note is the only thing they can have to say.
sw_fixture 58 100 100 100
rm -f "$SWD/swap-note" "$FAKE/.swap-tries"
SW_ROOT="$FAKE/countroot" sw_stopfail sess-r2 >/dev/null
[ -f "$SWD/swap-note" ] \
  && ok "a backstop that could not swap leaves the reason behind" \
  || bad "breadcrumb" "the turn died with nothing to say for it"
note=$(SW_ROOT="$FAKE/countroot" sw_prompt UserPromptSubmit sess-r3)
case "$note" in
  *"Nothing was billed"*) ok "...and the next prompt says it once, naming the cost that was not paid" ;;
  *) bad "breadcrumb" "got: $(printf '%s' "$note" | tr '\n' ' ' | head -c 160)" ;;
esac
again=$(SW_ROOT="$FAKE/countroot" sw_prompt UserPromptSubmit sess-r4)
case "$again" in
  *"Nothing was billed"*) bad "breadcrumb" "said it twice" ;;
  *) ok "...and only once" ;;
esac
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset CCD_REAL_ACCOUNT
rm -f "$SWD/providers/keys.env"

# ── The exchange holds the lock; a probe does not ───────────────────────────
# A probe is a read: it measures somebody's quota and can wait outside any lock.
# An exchange is a write — it consumes a one-time credential — so it holds the
# store lock across the request and the write it produces, as one step. Anything
# else can land on a record that was re-registered while it was in flight.
sw_fixture 58 100
stage_usage 5 5 200 2 AT-spare-rotated
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)   # needs a rotation
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999                # and a measurement
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
lock_free() {  # is the store lock takeable right now?
  python3 - "$ADIR/.lock" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("free")
except OSError:
    print("held")
PY
}
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.8
[ "$(lock_free)" = "held" ] \
  && ok "a token exchange holds the store lock for as long as it takes" \
  || bad "exchange outside the lock" "the store was writable mid-exchange"
wait "$PICKPID" 2>/dev/null

# ...and the read-only half takes nothing: a spare whose token is fine is simply
# measured, and every other writer carries on while that request is open.
sw_fixture 58 100
stage_usage 5 5 200 2
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.8
[ "$(lock_free)" = "free" ] \
  && ok "...while a measurement that rotates nothing blocks nobody" \
  || bad "probe under the lock" "a read-only probe held the store lock"
wait "$PICKPID" 2>/dev/null
unset -f lock_free

# ── The confirmation proves ownership, not change ───────────────────────────
# "different from what we replaced" is satisfied by a third account's token, by
# the outgoing account's next rotation, by anything at all that moved.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
# A token belonging to neither account: not the one the swap installs, not the
# one it replaces. "Different from what we replaced" says yes to this.
python3 - "$CREDS" "$FAKE/.creds-third" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["accessToken"] = "AT-interloper"
json.dump(d, open(sys.argv[2], "w"))
PY
( sleep 0.7; cp "$FAKE/.creds-third" "$CREDS" ) &
ROT=$!
rc=$(SW_SETTLE=2 sw_stopfail sess-c1)
wait "$ROT" 2>/dev/null
[ "$rc" != "2" ] \
  && ok "a credential that is nobody's in particular does not confirm a swap" \
  || bad "confirmation" "woke on a token belonging to neither account"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── A probe never rotates the credential Claude Code is holding ─────────────
# The live token belongs to the running session. An account can BECOME the live
# one while a probe is mid-exchange, and finishing that rotation consumes a
# one-time token the session is still carrying — with the replacement landing in
# the account file and nowhere else.
sw_fixture 58 100
stage_usage 5 5 200 2 AT-spare-rotated
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.5
"$ACCT" --no-color use spare --force >/dev/null 2>&1    # it is the live one now
wait "$PICKPID" 2>/dev/null
tok() { python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$1"; }
[ "$(tok "$CREDS")" = "$(tok "$ADIR/spare.json")" ] \
  && ok "a probe leaves the signed-in account's credential to Claude Code" \
  || bad "live rotation" "live $(tok "$CREDS") vs stored $(tok "$ADIR/spare.json")"

# ── A decision installed only where it was still true ───────────────────────
# Measuring takes time, and a person can run `ccd account use` inside it. The
# check that the store has not moved belongs with the install, under the lock.
sw_fixture3 58 100
rm -rf "$RQD"
stage_usage 5 5 200 2
( sleep 0.7; "$ACCT" --no-color use spare2 --force >/dev/null 2>&1 ) &
RACE=$!
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" \
  --deadline 30 >/dev/null 2>&1
wait "$RACE" 2>/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "a swap whose ground moved while it measured installs nothing" \
  || bad "install cas" "overwrote a swap made while it was measuring: $(cat "$ADIR/.active" 2>/dev/null)"

# ── A reading is labelled with the account it measured ──────────────────────
sw_fixture 58 100
stage_usage 5 5 200 2
( CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color usage --json > "$FAKE/.usage-out" 2>/dev/null ) &
USAGEPID=$!
sleep 0.7
"$ACCT" --no-color use spare --force >/dev/null 2>&1
wait "$USAGEPID" 2>/dev/null
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("account") == "spent" else 1)' "$FAKE/.usage-out" \
  && ok "a reading names the account whose credential it measured" \
  || bad "reading label" "named $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("account"))' "$FAKE/.usage-out" 2>/dev/null)"

# ── Partial information holds the exclusion ─────────────────────────────────
# One window in common and one missing is not a reset; it is half an answer.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture3 58 100
sw_prompt UserPromptSubmit sess-w1 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "partial window" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1]))
q["spent"].pop("five_hour_reset", None)     # only half the windows can be named
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
quota 58 100
sw_prompt UserPromptSubmit sess-w2 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "half a window is not a reset, and the exclusion holds" \
  || bad "partial window" "released on partial information: $(cat "$ADIR/.active" 2>/dev/null)"

# ── One budget, end to end, on the prompt path ──────────────────────────────
sw_fixture 58 100
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(8)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
start=$(date +%s)
sw_prompt UserPromptSubmit sess-b1 >/dev/null
waited=$(( $(date +%s) - start ))
kill -9 "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$waited" -le 4 ] \
  && ok "a prompt tick is bounded by its own budget, whoever holds the store lock" \
  || bad "tick budget" "the tick held the prompt for ${waited}s"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"

# ── A swap queues behind an exchange, and installs what it produced ─────────
# The old refresh token is spent the moment the server answers, so the exchange
# holds the store lock across it. A `use` arriving mid-exchange therefore waits,
# and what it then installs is the credential the exchange wrote — not the one it
# read before.
sw_fixture 58 100
stage_usage 5 5 200 2 AT-spare-rotated
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.5
"$ACCT" --no-color use spare --force >/dev/null 2>&1    # queues behind the exchange
wait "$PICKPID" 2>/dev/null
tok() { python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$1"; }
[ "$(tok "$ADIR/spare.json")" = "AT-spare-rotated" ] \
  && ok "a refresh that succeeded is written down, whatever was waiting behind it" \
  || bad "lost refresh" "the exchange was discarded: store holds $(tok "$ADIR/spare.json")"
[ "$(tok "$CREDS")" = "$(tok "$ADIR/spare.json")" ] \
  && ok "...and the swap that waited installs that credential, not the one it read" \
  || bad "stale install" "live $(tok "$CREDS") vs stored $(tok "$ADIR/spare.json")"

# ── The departure record is read where the install happens ──────────────────
# Measuring takes time; another swap can record a departure inside it, and a
# target that was free when we looked may be the account somebody just left.
sw_fixture3 58 100
rm -rf "$RQD" "$SWD/swapped-windows"
stage_usage 5 5 200 2
# Recorded with no window of its own, which is the case that holds whatever the
# candidate's own reading says: this is about WHEN the record is read, not about
# which windows it names.
( sleep 0.7; printf '%s\tspare\tnone\n' "$(date +%s)" > "$SWD/swapped-windows" ) &
RACE=$!
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" \
  --deadline 30 >/dev/null 2>&1
wait "$RACE" 2>/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" != "spare" ] \
  && ok "a target recorded as just-left while we measured is not installed" \
  || bad "guard revalidation" "installed the account another swap had just left"

# ── Two writers, one note, and it still parses ──────────────────────────────
# A fixed temp path is a second writer's truncation, and the consumer drops a
# note it cannot read — the explanation disappearing exactly when there is one.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100 100 100
rm -f "$SWD/swap-note"
mkdir -p "$SWD/swap-note.tmp"          # the one name a careless writer would take
# The stand-in forwards everything but `swap` to the real tool, and says where that
# is through this variable — which an earlier section unsets on its way out. Without
# it the wall's re-read goes nowhere, nothing fires, and there is no note to parse.
CCD_REAL_ACCOUNT="$ACCT" SW_ROOT="$FAKE/countroot" sw_stopfail sess-n5 >/dev/null
rmdir "$SWD/swap-note.tmp" 2>/dev/null
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$SWD/swap-note" 2>/dev/null \
  && ok "the note is published through a name of its own, so it always parses" \
  || bad "note temp" "no readable note was left: $(head -c 80 "$SWD/swap-note" 2>/dev/null)"

# ── The note says what actually went wrong ──────────────────────────────────
note=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["message"])' "$SWD/swap-note" 2>/dev/null)
case "$note" in
  *"reason unknown"*) bad "note reason" "the reason was lost on the way out of the subshell" ;;
  *"could not act"*) ok "...and carries the reason the swap itself gave" ;;
  *) bad "note reason" "got: $(printf '%s' "$note" | head -c 140)" ;;
esac
rm -f "$SWD/swap-note"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

# ── The status screen promises only what this path does ─────────────────────
# The subscription hop fires when the reading says the account is spent. It does
# not come back on its own — nothing measures the account you left while you are
# not on it — and a promise of a return is a promise the user would wait for.
out=$(HOME="$FAKE" "$ROOT/bin/ccd" 2>&1 | sed -n '/When quota runs out/,/Other commands/p')
case "$out" in
  *"back when the window resets"*)
    bad "status promise" "promised a return the subscription path does not make" ;;
  *"registered account has room"*)
    ok "the status screen promises the hop it makes, and no return it does not" ;;
  *) bad "status promise" "said neither: $(printf '%s' "$out" | tr '\n' ' ' | head -c 140)" ;;
esac

rm -rf "$ADIR" "$RQD" "$SWD/swapped-windows" "$SWD/accounts-keepalive" \
       "$FAKE/.sw-out" "$FAKE/.sw-err" "$FAKE/.creds-before" "$FAKE/.swap-done"
hf_reset
unset CCD_USAGE_URL CCD_TOKEN_URL
unset -f sw_hook sw_fixture sw_fixture3 sw_prompt sw_stopfail

finish
