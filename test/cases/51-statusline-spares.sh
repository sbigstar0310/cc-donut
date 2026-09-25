#!/usr/bin/env bash
# 51-statusline-spares — the spare's reading, and the row that keeps pace with it.
# Sections: §27e
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "27e. the spare's reading keeps pace with the row"
# §21–§26 left a live login on file. account_refresh will not spend a refresh
# token while it cannot see one (live_creds -> "unsure"), which is what the
# single-flight case measures.
wall_login
# #54. The row is only as current as the readings on file, and only a typed prompt
# refreshed it: an autonomous turn fires tool uses and assistant messages, never a
# prompt, so a healthy spare aged into `spare ?` exactly while quota burned fastest.
# The reading has to move on the row's own cadence (prompt, tool use, render, and a
# timer for an idle session), a fresh one must cost no process, and no refresh may
# overlap another, because keepalive and a pick can both spend a one-time refresh token.
#
# Every trigger runs from a copy of the plugin whose ccd-account logs, then execs the
# real one. The log tells "nothing needed refreshing" apart from "nothing was started";
# the local endpoint (section 25) says whether a refresh landed, and how many overlapped.
SPD="$FAKE/.claude/ccd"
SPROOT="$FAKE/spareroot"; SPLOG="$FAKE/.spare-calls"; SPHITS="$FAKE/.spare-hits"
rm -rf "$SPROOT"; mkdir -p "$SPROOT"
cp -R "$ROOT/bin" "$ROOT/scripts" "$SPROOT/"
cat > "$SPROOT/bin/ccd-account" <<EOF
#!/bin/sh
echo "\$*" >> "$SPLOG"
exec "$ROOT/bin/ccd-account" "\$@"
EOF
chmod +x "$SPROOT/bin/ccd-account"
endpoint_up "$SPHITS" 3 || bad "spare refresh" "local endpoint never came up"

sp_env() { env CCD_USAGE_URL="$EP_URL/usage" CCD_TOKEN_URL="$EP_URL/token" CCD_HTTP_TIMEOUT=10 "$@"; }
sp_hook() { sp_env CLAUDE_PLUGIN_ROOT="$SPROOT" "$SPROOT/scripts/quota-guard.sh" "$1" </dev/null >/dev/null 2>&1; }
# Claude Code hands the statusline no plugin root, so neither does this.
sp_render() {
  printf '%s' '{"model":{"id":"claude-opus-5"}}' \
    | sp_env env -u CLAUDE_PLUGIN_ROOT "$SPROOT/bin/ccd-statusline" 2>/dev/null
}
spare_fixture() { # $1 = age of every reading on file, in seconds; $2 = "due" for a spare
                  # whose keepalive is due and whose access token has expired
  rm -rf "$ADIR" "$RQD" "$SPLOG" "$SPHITS" "$FAKE/.claude.json"; mkdir -p "$ADIR"
  RQT=$(rq_gather)
  python3 - "$ADIR" "$RQT" "$1" "${2:-}" <<'PY'
import datetime, hashlib, json, os, sys, time
adir, qfile, age, due = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "due"
now = time.time()
iso = lambda s: datetime.datetime.fromtimestamp(now + s, datetime.timezone.utc).isoformat()
rows = {}
for name in ("main", "backup"):
    at = "AT-" + name
    expires = now - 3600 if due and name == "backup" else now + 8 * 3600
    json.dump({"name": name, "label": name, "account_uuid": "uuid-" + name, "priority": 1,
               "claudeAiOauth": {"accessToken": at, "refreshToken": "RT-" + name,
                                 "expiresAt": int(expires * 1000)}},
              open(os.path.join(adir, name + ".json"), "w"))
    rows[name] = {"status": "ok", "checked_at": int(now - age), "uuid": "uuid-" + name,
                  "cred": hashlib.sha256(at.encode()).hexdigest()[:16],
                  "five_hour_percent": 50, "seven_day_percent": 50,
                  "five_hour_reset": iso(3600), "seven_day_reset": iso(3 * 86400)}
json.dump(rows, open(qfile, "w"))
os.utime(qfile, (now - age, now - age))
PY
  rq_scatter "$RQT"
  printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
  # The hook's own reading of the signed-in account is not what this section measures.
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
    > "$SPD/quota-cache.json"
  if [ "${2:-}" = "due" ]; then rm -f "$SPD/accounts-keepalive"; else printf '{"fails": 0}' > "$SPD/accounts-keepalive"; fi
}
sp_reading() {
  RQT=$(rq_gather)
  python3 - "$RQT" <<'PY'
import json, sys, time
try: r = json.load(open(sys.argv[1]))["backup"]
except Exception: print("unreadable"); raise SystemExit
t = r.get("checked_at")
fresh = isinstance(t, (int, float)) and time.time() - t < 60
print(f"{r.get('status')}:{'fresh' if fresh else 'stale'}:{r.get('five_hour_percent')}")
PY
  rm -f "$RQT"            # read only: nothing to publish
}
sp_landed() { # the endpoint's reading, on file
  n=0; while [ "$(sp_reading)" != "ok:fresh:12" ] && [ $n -lt 60 ]; do sleep 0.25; n=$((n+1)); done
  [ "$(sp_reading)" = "ok:fresh:12" ]
}

# ── A tool use refreshes, not only a typed prompt ───────────────────────────
spare_fixture 600
sp_hook PostToolUse
sp_landed \
  && ok "a tool-use tick brings a stale spare reading current" \
  || bad "tool-use refresh" "only a typed prompt refreshes the spare: $(sp_reading)"
sleep 1

# ── A fresh reading costs no process ────────────────────────────────────────
# Judged before anything is spawned. A pick that starts only to find the cache warm is
# exactly the process ruled out: the hook fires on every tool use. The bare keepalive
# every tick already ran is the one call allowed.
spare_fixture 10
sp_hook UserPromptSubmit; sp_hook PostToolUse
sleep 2
started=$(grep -vxF -- '--no-color keepalive --detach' "$SPLOG" 2>/dev/null)
[ -z "$started" ] \
  && ok "a fresh reading starts no refresh, on a prompt or a tool use" \
  || bad "fresh reading" "started for a reading seconds old: $(printf '%s' "$started" | tr '\n' '/')"

# ── An idle session still ticks ─────────────────────────────────────────────
# Event triggers go quiet while the session idles, so the row needs a timer of its own.
# Seeded with today's wiring, which is what a re-run of setup meets.
SPH="$FAKE/home54"; rm -rf "$SPH"; mkdir -p "$SPH/.claude"
printf '{"statusLine":{"type":"command","command":"bash ~/.claude/ccd/statusline-launcher.sh"}}\n' \
  > "$SPH/.claude/settings.json"
HOME="$SPH" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
sl=$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get('statusLine'),sort_keys=True))" \
       "$SPH/.claude/settings.json" 2>/dev/null)
[ "$sl" = '{"command": "bash ~/.claude/ccd/statusline-launcher.sh", "refreshInterval": 60, "type": "command"}' ] \
  && ok "setup gives the statusline a 60s tick, beside the command it already wires" \
  || bad "refreshInterval" "statusLine: $sl"

# Nothing reruns setup after an update, so an install wired before the tick existed gets
# it at session start, through the hook as hooks.json registers it. Only ccd's own
# statusline, exactly as setup writes it: never a wrapper around it, never one whose
# interval the user already chose, never a statusline where there was none. The last
# three pass against a hook that does nothing, so they ride with the first.
ss_out=$(HOME="$SPH" CLAUDE_PLUGIN_ROOT="$ROOT" python3 - "$SPH/.claude/settings.json" "$ROOT/hooks/hooks.json" 2>&1 <<'PY'
import json, subprocess, sys
settings, hooks = sys.argv[1], sys.argv[2]
ours = json.load(open(settings))["statusLine"]
ours.pop("refreshInterval", None)                      # what an older setup wrote
cmds = [h["command"] for g in json.load(open(hooks))["hooks"].get("SessionStart", [])
        for h in g.get("hooks", [])]
if not cmds:
    print("no SessionStart hook is registered")
for seed, want in ((ours, dict(ours, refreshInterval=60)),
                   (dict(ours, command=ours["command"] + " --wrapped"), None),
                   (dict(ours, refreshInterval=5), None),
                   ("absent", None)):
    with open(settings, "w") as f:
        json.dump({} if seed == "absent" else {"statusLine": seed}, f)
    before = open(settings).read()
    out = "".join(subprocess.run(["bash", "-c", c], stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True).stdout for c in cmds)
    got = json.load(open(settings)).get("statusLine", "absent")
    if (got != want if want else open(settings).read() != before) or out:
        print(f"{seed} became {got}" + (f", printing {out.strip()}" if out else ""))
print("checked")                                       # reached only if nothing above threw
PY
)
[ "$ss_out" = "checked" ] \
  && ok "...and a session start gives it to an older install's statusline, and to nothing else" \
  || bad "statusline upgrade" "$(printf '%s' "$ss_out" | tr '\n' '/')"

# Several sessions start at once and Claude Code writes settings.json itself, so a write
# that lands between our read and our replace must not be discarded — including one that
# stops the statusline being ours. The interleave is staged from outside the hook: a
# sitecustomize makes the foreign write happen as the hook opens its temp file.
mkdir -p "$FAKE/pysite54"
cat > "$FAKE/pysite54/sitecustomize.py" <<'SCEOF'
import json, os, tempfile
_target = os.environ.get("CCD_TEST_INTERLEAVE")
if _target:
    _mkstemp = tempfile.mkstemp

    def mkstemp(*a, **k):                    # after the hook's read, before its replace
        d = json.load(open(_target))
        d["theirs"] = "kept"
        with open(_target, "w") as f:
            json.dump(d, f)
        tempfile.mkstemp = _mkstemp          # once is enough to open the window
        return _mkstemp(*a, **k)

    tempfile.mkstemp = mkstemp
SCEOF
cas_state() {
  python3 -c "import json,sys
d = json.load(open(sys.argv[1]))
print(d.get('theirs'), (d.get('statusLine') or {}).get('refreshInterval'))" "$SPH/.claude/settings.json" 2>&1
}
printf '{"statusLine":{"type":"command","command":"bash ~/.claude/ccd/statusline-launcher.sh"}}\n' \
  > "$SPH/.claude/settings.json"
HOME="$SPH" CLAUDE_PLUGIN_ROOT="$ROOT" CCD_TEST_INTERLEAVE="$SPH/.claude/settings.json" \
  PYTHONPATH="$FAKE/pysite54${PYTHONPATH:+:$PYTHONPATH}" \
  "$ROOT/scripts/quota-guard.sh" SessionStart </dev/null >/dev/null 2>&1
raced=$(cas_state)
# Standing down is only safe because the next session start tries again.
HOME="$SPH" CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/scripts/quota-guard.sh" SessionStart </dev/null >/dev/null 2>&1
retried=$(cas_state)
[ "$raced" = "kept None" ] && [ "$retried" = "kept 60" ] \
  && ok "...and stands down on a settings write that lands mid-flight, then retries" \
  || bad "settings race" "during: $raced · after: $retried"
rm -rf "$SPH" "$FAKE/pysite54"

# ── A render refreshes too, and waits for none of it ────────────────────────
# The statusline re-runs on each assistant message and on that timer, which makes it the
# trigger an idle session still has. Claude Code cancels a run still in flight, so the
# refresh must leave the render behind. Paired with the fresh case: on its own that
# half passes against a statusline that never refreshes anything.
spare_fixture 10
sp_render >/dev/null; sleep 2
fresh_started=$(cat "$SPLOG" 2>/dev/null)
spare_fixture 600
sl_start=$(date +%s)
row=$(sp_render)
sl_elapsed=$(( $(date +%s) - sl_start ))
# Waited for whatever the verdict, or a refresh still in flight lands in the next case.
sp_landed && landed=1 || landed=0
if [ -n "$fresh_started" ]; then
  bad "render refresh" "a render started ccd-account for a reading seconds old: $fresh_started"
elif [ "$landed" -eq 0 ]; then
  bad "render refresh" "a render left a stale spare reading stale: $(sp_reading)"
elif [ "$sl_elapsed" -gt 2 ]; then
  bad "render refresh" "the render waited ${sl_elapsed}s for the refresh"
else
  ok "a render refreshes a stale reading behind itself, and leaves a fresh one alone"
fi
sleep 1

# ── ...and outlives the trigger being cancelled ─────────────────────────────
# Claude Code cancels a render that is still running when the next update arrives, and
# kills a hook that outruns its timeout — both by process group. A refresh caught there
# mid token-exchange loses a refresh token the server has already rotated: the spare
# dies, which is the failure ccd exists to prevent.
sp_cancelled() { # run a trigger in a session of its own, then kill that session
  sp_env python3 - "$@" >/dev/null 2>&1 <<'PY'
import os, signal, subprocess, sys, time
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
p.communicate(b'{"model":{"id":"claude-opus-5"}}')
time.sleep(0.5)                              # the refresh is at the endpoint by now
os.killpg(p.pid, signal.SIGKILL)
PY
}
spare_fixture 600
sp_cancelled env -u CLAUDE_PLUGIN_ROOT "$SPROOT/bin/ccd-statusline"
sp_landed && cancel_render=yes || cancel_render="no ($(sp_reading))"
sleep 1
spare_fixture 600
sp_cancelled env CLAUDE_PLUGIN_ROOT="$SPROOT" "$SPROOT/scripts/quota-guard.sh" PostToolUse
sp_landed && cancel_tick=yes || cancel_tick="no ($(sp_reading))"
[ "$cancel_render" = yes ] && [ "$cancel_tick" = yes ] \
  && ok "...and a refresh outlives the render or the tick that started it being killed" \
  || bad "detached refresh" "render: $cancel_render · tick: $cancel_tick"
sleep 1

# ── The only registered account is a spare too ──────────────────────────────
# An unregistered login beside one registered account: that account IS the spare (#41),
# so its reading has to keep moving like any other — on a tick and on a render.
solo_fixture() {
  spare_fixture 600
  rm -f "$ADIR/main.json" "$ADIR/.active"
  printf '{"oauthAccount":{"accountUuid":"uuid-nobody","emailAddress":"nobody@example.com","profileFetchedAt":%s}}\n' \
    "$(( $(date +%s) * 1000 ))" > "$FAKE/.claude.json"
}
solo_fixture
sp_hook PostToolUse
sp_landed && solo_hook=yes || solo_hook="no ($(sp_reading))"
sleep 1
solo_fixture
sp_render >/dev/null
sp_landed && solo_render=yes || solo_render="no ($(sp_reading))"
[ "$solo_hook" = yes ] && [ "$solo_render" = yes ] \
  && ok "the only registered account is measured too, by a tick and by a render" \
  || bad "single spare" "tick: $solo_hook · render: $solo_render"
sleep 1

# ── ...and an exclusion list nothing writes any more excludes nothing ───────
# The row used to drop the launcher's per-burst visited set before deciding whether
# a refresh was worth starting. That set left with the account ladder, so a stale
# `CCD_BURST_VISITED` in some long-lived shell must not be able to silence the one
# spare there is — a reading that stops moving is exactly how a spare dies unseen.
solo_fixture
CCD_BURST_VISITED=earlier-hop,backup sp_render >/dev/null
sp_landed && stale_env=yes || stale_env="no ($(sp_reading))"
[ "$stale_env" = yes ] \
  && ok "...and a leftover burst variable no longer stops the only spare being measured" \
  || bad "stale exclusion" "an unwritten variable still excluded the spare: $stale_env"
rm -f "$FAKE/.claude.json"
sleep 1

# ── However many triggers, one refresh at a time ────────────────────────────
# Three sessions' prompts, tool uses and renders landing together, which the new
# triggers make routine, against a spare with a keepalive due and an expired token: every
# job would spend a refresh token. Whatever the lock, the endpoint sees any overlap.
spare_fixture 600 due
sp_pids=""
for _ in 1 2 3; do
  sp_hook UserPromptSubmit & sp_pids="$sp_pids $!"
  sp_hook PostToolUse & sp_pids="$sp_pids $!"
  sp_render >/dev/null & sp_pids="$sp_pids $!"
done
wait $sp_pids
# A refresh queued behind the first arrives within one more hold of the endpoint.
sp_landed && landed=1 || landed=0
sleep 4
peak=$(grep '^start' "$SPHITS" 2>/dev/null | cut -d' ' -f3 | sort -n | tail -n 1)
kinds=$(grep '^start' "$SPHITS" 2>/dev/null | cut -d' ' -f2 | sort -u | tr '\n' ' ')
# Both halves have to have run, or "one at a time" is satisfied by doing almost nothing.
if [ "$landed" -eq 0 ]; then
  bad "single-flight" "no refresh landed at all: $(sp_reading)"
elif [ "$kinds" != "token usage " ]; then
  bad "single-flight" "the job did not both refresh and measure: ${kinds:-nothing ran}"
elif [ "${peak:-0}" != "1" ]; then
  bad "single-flight" "peak refreshes in flight at the endpoint: $peak"
else
  ok "prompts, tool uses and renders at once never run two refreshes together"
fi

kill "$EP_PID" 2>/dev/null; wait "$EP_PID" 2>/dev/null
rm -rf "$SPROOT" "$ADIR" "$RQD" "$SPLOG" "$SPHITS" "$SPD/accounts-keepalive"
mkdir -p "$ADIR"
unset -f sp_env sp_hook sp_render sp_cancelled solo_fixture spare_fixture sp_reading sp_landed cas_state

finish
