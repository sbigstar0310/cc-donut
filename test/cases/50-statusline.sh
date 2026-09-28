#!/usr/bin/env bash
# 50-statusline — the statusline row.
# Sections: §17b, §27, §27d, §28, §40
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "17b. the statusline never waits on the dashboard"
# ccd renders the dashboard's rows above its own by running it as a child. That
# child is usually instant, but it refreshes its usage reading on its own schedule,
# and one reported host measured 11s for that refresh: naming the Codex model
# shells out to `codex exec` under a 10s timeout of its own. Waiting for that on
# the render path froze the whole statusline and — when the wait lost the race, as
# it always did at a 10s watchdog — blanked the dashboard's rows. Alternating
# between the two is the flicker in #9. So the render never runs the dashboard at
# all now: it reads the row it cached and hands the refresh to a background job.
# Nothing Claude Code waits on can be made slow by another plugin's provider call.
DASH_DIST="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
mkdir -p "$DASH_DIST"; : > "$DASH_DIST/index.js"
cp "$FAKE/fakebin/node" "$FAKE/node.real"
dash_node() { cat > "$FAKE/fakebin/node"; chmod +x "$FAKE/fakebin/node"; }
# Move the file into the past rather than the clock into the future: production
# only ever compares against a real now.
age_file() { python3 -c "import os,sys,time;t=time.time()-float(sys.argv[2]);os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
render() { printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | env CCD_ACTIVE=1 "$@" "$ROOT/bin/ccd-statusline" 2>/dev/null; }
dash_reap() { pkill -f "$FAKE/fakebin/node" 2>/dev/null; true; }
# Refreshers are backgrounded copies of ccd-statusline, and its path is shared with
# any real session rendering from this same checkout. Narrow to what appeared since
# a snapshot rather than signalling everything the pattern matches. That is not
# proof of ownership — a real refresher starting inside the same window would be
# caught too — but it keeps the blast radius to this checkout and this moment.
dash_refreshers() { pgrep -f "$ROOT/bin/ccd-statusline" 2>/dev/null | tr '\n' ' '; }
dash_started_since() { # $1 = a dash_refreshers snapshot taken before the render
  local pid
  for pid in $(dash_refreshers); do
    case " $1 " in *" $pid "*) ;; *) printf '%s ' "$pid" ;; esac
  done
}
# Fail closed. Where pgrep is missing every assertion that counts processes counts
# zero and passes on nothing — which is how debian:stable-slim ran this suite until
# test/docker.sh started installing procps.
for dash_tool in pgrep pkill; do
  command -v "$dash_tool" >/dev/null 2>&1 \
    || bad "test environment" "$dash_tool is missing: the process assertions below cannot run"
done
dash_wait() { # $1=needle — a background refresh is done when its row lands
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q "$1" "$FAKE/.claude/ccd/.dashboard-row" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

# The exact shape of #9: a row past its refresh age and a dashboard slower than any
# watchdog we would set. The render must neither wait for it nor drop its rows.
dash_node <<'EOF'
#!/bin/sh
sleep 30
echo "SLOW-ROW"
EOF
printf 'CACHED-DASHBOARD-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
sl_start=$(date +%s)
row=$(render)
sl_elapsed=$(( $(date +%s) - sl_start ))
[ "$sl_elapsed" -le 2 ] \
  && ok "a stalled dashboard does not hold up the statusline (${sl_elapsed}s)" \
  || bad "statusline latency" "waited ${sl_elapsed}s for the dashboard"
case "$row" in
  *"CACHED-DASHBOARD-ROW"*) ok "...and its rows stay on screen while it refreshes" ;;
  *) bad "statusline" "blanked the dashboard rows: $(printf '%s' "$row" | head -c 70)" ;;
esac
case "$row" in
  *"ccd"*) ok "and the ccd row is still rendered alongside them" ;;
  *) bad "statusline" "no ccd row" ;;
esac
# A statusline renders on every prompt and tool call. Without single-flight, a
# stalled dashboard would leave a new `node` behind on each render, and two that
# finished out of order would let the older row win.
for _ in 1 2 3 4 5 6 7 8 9; do render >/dev/null; done
sleep 1
children=$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null | wc -l | tr -d ' ')
[ "${children:-0}" -le 1 ] \
  && ok "ten renders against a stalled dashboard leave at most one child ($children)" \
  || bad "statusline fan-out" "$children dashboard children alive"
[ -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "the refresh holds a lock while it runs" || bad "single-flight" "no lock"

# A child that hangs must not outlive the row it was fetched for.
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_reap
render CCD_DASH_TIMEOUT=1 >/dev/null
sleep 3
[ "$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && ok "a hung dashboard child is killed by the watchdog" \
  || bad "watchdog" "child survived its timeout"
[ ! -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "...and the lock is released with it" || bad "watchdog" "lock leaked"
# The kill that leaks is not the watchdog's, though — it is the render's whole
# process group going away with the terminal, mid-refresh. A refresh that dies that
# way still has to clean up after itself.
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
dash_node <<'EOF'
#!/bin/sh
sleep 30
EOF
dash_before=$(dash_refreshers)
render >/dev/null
sleep 1
for dash_pid in $(dash_started_since "$dash_before"); do kill -TERM "$dash_pid" 2>/dev/null; done
sleep 1
[ -z "$(ls "$FAKE/.claude/ccd"/.dashboard-row.?????? 2>/dev/null)" ] \
  && ok "a refresher killed by a signal takes its temp file with it" \
  || bad "signal cleanup" "temp left behind"
[ ! -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "...and releases its lock on the way out" || bad "signal cleanup" "lock leaked"
[ -z "$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null)" ] \
  && ok "...and does not leave an unsupervised dashboard running behind it" \
  || bad "signal cleanup" "dashboard survived the refresher that owned it"
dash_reap
# Killed refreshers used to leave their half-written temp behind — one report had
# 203 of them, 194 empty. Whatever the kill, the next refresh sweeps the debris.
: > "$FAKE/.claude/ccd/.dashboard-row.ZZleak"
age_file "$FAKE/.claude/ccd/.dashboard-row.ZZleak" 300
[ -e "$FAKE/.claude/ccd/.dashboard-row.ZZleak" ] || bad "temp sweep" "fixture vanished early"

# The refresh the render declined to wait for still has to land, or the row would
# never change again.
dash_node <<'EOF'
#!/bin/sh
echo "REFRESHED-ROW"
EOF
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
render >/dev/null
dash_wait REFRESHED-ROW \
  && ok "the background refresh lands for the next render" \
  || bad "background refresh" "the row never changed"
case "$(render)" in
  *"REFRESHED-ROW"*) ok "...and that render serves it" ;;
  *) bad "background refresh" "the fresh row was not served" ;;
esac
[ ! -e "$FAKE/.claude/ccd/.dashboard-row.ZZleak" ] \
  && ok "a refresh sweeps temp files leaked by killed refreshers" \
  || bad "temp sweep" "leaked temp survived a refresh"

# Nothing cached yet: the render still costs nothing, and the row it could not
# show arrives for the render after it. One row of latency, once, beats a
# statusline that can be frozen by a plugin ccd does not control.
dash_reap
rm -rf "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
sleep 30
echo "NEVER-ARRIVES"
EOF
sl_start=$(date +%s)
row=$(render)
sl_elapsed=$(( $(date +%s) - sl_start ))
[ "$sl_elapsed" -le 2 ] \
  && ok "a hung dashboard with nothing cached costs the render nothing either (${sl_elapsed}s)" \
  || bad "cold path" "waited ${sl_elapsed}s"
case "$row" in
  *"NEVER-ARRIVES"*) bad "cold path" "served output from a child it killed" ;;
  *"ccd"*) ok "...and the ccd row is rendered without the dashboard rows" ;;
  *) bad "cold path" "no row at all: $(printf '%s' "$row" | head -c 60)" ;;
esac
dash_reap
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
echo "FIRST-DASHBOARD-ROW"
EOF
render >/dev/null
dash_wait FIRST-DASHBOARD-ROW \
  && ok "the first render's refresh still fills the cache, so nothing is missing" \
  || bad "cold path" "nothing cached"

# A lock left behind by a killed refresher must not freeze refreshes forever.
mkdir -p "$FAKE/.claude/ccd/.dashboard-row.lock"
python3 -c "import os,sys;os.utime(sys.argv[1], (0, 0))" "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
echo "RECLAIMED-ROW"
EOF
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
render >/dev/null
dash_wait RECLAIMED-ROW \
  && ok "a stale lock is reclaimed instead of blocking refreshes forever" \
  || bad "stale lock" "refresh never ran again"

# Half of what the dashboard draws it computes from the payload of the render that
# ran it: the context bar, the session cost, the burn rate. Refreshing only once a
# row has aged out would freeze those at whatever the last refresh saw, so every
# render kicks one — including a render whose row is seconds old.
printf 'FRESH-ENOUGH-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
echo "TRACKS-THE-PAYLOAD"
EOF
render >/dev/null
dash_wait TRACKS-THE-PAYLOAD \
  && ok "a row seconds old is refreshed anyway, so payload cells keep moving" \
  || bad "refresh cadence" "a fresh row was left alone until it aged out"

# Staleness has a ceiling. Serving a row beats blanking it at almost any age — but
# ccd exists to catch a quota running out, and an hour-old percentage is not a
# stale reading, it is a wrong one.
printf 'ANCIENT-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
python3 -c "import os,sys;os.utime(sys.argv[1], (0, 0))" "$FAKE/.claude/ccd/.dashboard-row"
dash_node <<'EOF'
#!/bin/sh
sleep 30
echo "NEVER-ARRIVES"
EOF
row=$(render)
case "$row" in
  *"ANCIENT-ROW"*) bad "staleness" "served a row with no upper bound on its age" ;;
  *"ccd"*) ok "a row too old to be a reading is dropped rather than shown" ;;
  *) bad "staleness" "got: $(printf '%s' "$row" | head -c 60)" ;;
esac
# A row inside the ceiling but past its refresh age is the opposite call: show it.
printf 'STALE-BUT-USABLE' > "$FAKE/.claude/ccd/.dashboard-row"
age_file "$FAKE/.claude/ccd/.dashboard-row" 900
case "$(render)" in
  *"STALE-BUT-USABLE"*) ok "...while one inside the ceiling is still served" ;;
  *) bad "staleness" "dropped a row it should have served" ;;
esac
dash_reap

# A row dated into the future is a clock skew or a poisoned file, never a fresh
# reading. Trusting the arithmetic would pin the row until wall time caught up.
dash_node <<'EOF'
#!/bin/sh
sleep 30
EOF
printf 'FUTURE-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
age_file "$FAKE/.claude/ccd/.dashboard-row" -86400
row=$(render)
case "$row" in
  *"FUTURE-ROW"*) bad "future mtime" "served a row dated a day ahead" ;;
  *"ccd"*) ok "a row dated into the future is not treated as fresh" ;;
  *) bad "future mtime" "got: $(printf '%s' "$row" | head -c 60)" ;;
esac
# The same arithmetic gates the lock, and a future-dated one would never be reclaimed.
# Let the refresh above finish releasing first: its EXIT trap removes the lock, and
# would remove the one staged here instead.
dash_reap; sleep 1
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
mkdir -p "$FAKE/.claude/ccd/.dashboard-row.lock"
age_file "$FAKE/.claude/ccd/.dashboard-row.lock" -86400
dash_node <<'EOF'
#!/bin/sh
echo "UNSTUCK-ROW"
EOF
render >/dev/null
dash_wait UNSTUCK-ROW \
  && ok "...and a lock dated into the future is reclaimed, not honoured forever" \
  || bad "future mtime" "refreshes stayed blocked behind it"

# WHICH build gets run. Claude Code never prunes old versions, so the newest
# directory in the cache is not necessarily the one it loaded: an interrupted
# update leaves a version there that was never installed. Resolving it costs a
# python3, which is why only the background refresh may ask.
dash_node <<'EOF'
#!/bin/sh
echo "RAN:$1"
EOF
DASH_CACHE_ROOT="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard"
mkdir -p "$DASH_CACHE_ROOT/9.9.9/dist"; : > "$DASH_CACHE_ROOT/9.9.9/dist/index.js"
ran() { cat "$FAKE/.claude/ccd/.dashboard-row" 2>/dev/null; }
resolve_render() {
  rm -f "$FAKE/.claude/ccd/.dashboard-row"; rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
  render >/dev/null
  dash_wait "RAN:" || bad "build resolution" "no refresh landed at all"
}
# Claude Code never prunes, so 9.9.9 can sit in the cache without ever having been
# installed. Only the registry knows which build actually was.
cat > "$FAKE/.claude/plugins/installed_plugins.json" <<EOF
{"version":2,"plugins":{"claude-dashboard@claude-dashboard":[
 {"scope":"user","installPath":"$DASH_CACHE_ROOT/1.0.0","version":"1.0.0"}]}}
EOF
resolve_render
case "$(ran)" in
  *"/1.0.0/dist/index.js") ok "the installed build is run, not merely the newest in the cache" ;;
  *"/9.9.9/"*) bad "build resolution" "ran a build that was never installed" ;;
  *) bad "build resolution" "ran: $(ran)" ;;
esac
# From 1.32.0 the plugin ships a shim that makes this choice itself. Where one
# exists, running it is running exactly what the plugin's own statusline would.
DASH_SHIM_DIR="$FAKE/.claude/plugins/data/claude-dashboard-claude-dashboard"
mkdir -p "$DASH_SHIM_DIR"; : > "$DASH_SHIM_DIR/statusline.mjs"
resolve_render
case "$(ran)" in
  *"/statusline.mjs") ok "...and the plugin's own shim outranks every record when it is there" ;;
  *) bad "build resolution" "ran: $(ran)" ;;
esac
rm -rf "$DASH_SHIM_DIR" "$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/9.9.9" \
       "$FAKE/.claude/plugins/installed_plugins.json"

# The EXIT trap deletes "$tmp" and signals "$watchdog"/"$node_pid". On a refresh that
# fails before it owns any of them, those names must be empty rather than whatever
# the environment happened to export — otherwise the trap reaches for a stranger's
# file and a stranger's process group. Only meaningful as a non-root user, since the
# containers can write through anything; they skip this one.
if [ "$(id -u)" -ne 0 ]; then
  # dash_present sees a build, dash_resolve finds no version it can name: the
  # refresher exits between the lock and its first resource.
  rm -rf "$DASH_CACHE_ROOT/1.0.0" "$DASH_CACHE_ROOT/9.9.9" \
         "$FAKE/.claude/plugins/installed_plugins.json"
  mkdir -p "$DASH_CACHE_ROOT/not-a-version/dist"; : > "$DASH_CACHE_ROOT/not-a-version/dist/index.js"
  sentinel="$FAKE/not-my-temp"; : > "$sentinel"
  set -m; sleep 3002 & victim=$!; set +m
  rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
  printf '%s' '{"model":{"id":"m"}}' \
    | env CCD_ACTIVE=1 tmp="$sentinel" watchdog="$victim" node_pid="$victim" \
          "$ROOT/bin/ccd-statusline" >/dev/null 2>&1
  sleep 1
  [ -e "$sentinel" ] \
    && ok "a refresh that owns no temp file deletes nobody else's" \
    || bad "trap state" "deleted a file named by an inherited \$tmp"
  kill -0 "$victim" 2>/dev/null \
    && ok "...and signals no process group it never started" \
    || bad "trap state" "killed a process named by an inherited \$watchdog/\$node_pid"
  kill -9 "$victim" 2>/dev/null
  rm -rf "$DASH_CACHE_ROOT/not-a-version"
  mkdir -p "$DASH_DIST"; : > "$DASH_DIST/index.js"
fi

cp "$FAKE/node.real" "$FAKE/fakebin/node"; chmod +x "$FAKE/fakebin/node"
rm -rf "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock" "$FAKE/node.real"
unset -f dash_node age_file render dash_wait


head_ "27. multi-account: the statusline's spare row"
# The row that answers "do I have a net?". Its states have to stay distinguishable
# from each other, and none of them may read as "no spare" while one is registered
# — that was the bug: an account merely out of room for the next few minutes was
# reported as an account the user had never set up.
rm -rf "$ADIR" "$RQD" "$FAKE/.claude.json"
mkdir -p "$ADIR"
mk_sl_acct main; mk_sl_acct backup
printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"

# Just the account segment, without the colours the assertions do not care about.
sl_spare() {
  printf '%s' '{"model":{"id":"claude-opus-5"}}' \
    | "$ROOT/bin/ccd-statusline" 2>/dev/null \
    | grep 'claude:' | sed $'s/\x1b\\[[0-9;]*m//g'
}

# ── The bug: registered, alive, and out of room is its own state ─────────────
seed_rows main:ok:0:22:18000:600000 backup:ok:98:12:780:518400
row=$(sl_spare)
case "$row" in
  *"spare none"*) bad "spare row" "called a registered account absent: $row" ;;
  *"spare backup 98%"*) ok "a spare with no room is named, not reported as absent" ;;
  *) bad "spare row" "got: $row" ;;
esac
# 98% came from the 5-hour window, so the countdown must be that window's 13
# minutes — not the weekly reset six days out, which would send the user away for
# a week over a wait shorter than a coffee.
case "$row" in
  *"(13m)"*) ok "...counting down the window that is actually spent" ;;
  *) bad "countdown" "wrong window or none: $row" ;;
esac

# The mirror image: when the weekly is the spent one, it is the weekly that gets
# reported. Same code path, opposite answer.
seed_rows main:ok:0:22:18000:600000 backup:ok:10:95:3600:172800
row=$(sl_spare)
case "$row" in
  *"95%"*"(2d0h)"*) ok "the binding window flips to the weekly when that is the spent one" ;;
  *) bad "binding window" "got: $row" ;;
esac

# ── With no room, the countdown is time-to-usable, not time-to-anything ──────
# Both windows spent: the 5-hour turns over in 13 minutes, the weekly in six days,
# and the account is unusable until the LATER one does (has_headroom needs every
# window under the bound). Printing the 13 minutes here promises relief that does
# not arrive — the same lie as reporting the wrong window, pointed the other way.
seed_rows main:ok:0:22:18000:600000 backup:ok:100:100:780:518400
row=$(sl_spare)
case "$row" in
  *"(13m)"*) bad "time to usable" "counted down a window that does not free the account: $row" ;;
  *"backup 100% (6d0h)"*) ok "a spare blocked on both windows is timed by the later one" ;;
  *) bad "time to usable" "got: $row" ;;
esac
# And the ordering follows the same number, or the row names a spare that is six
# days away over one that is back in two hours.
mk_sl_acct sooner
seed_rows main:ok:0:22:18000:600000 backup:ok:100:100:780:518400 sooner:ok:100:12:7200:518400
row=$(sl_spare)
case "$row" in
  *"sooner 100% (2h0m)"*"+1"*) ok "...and outranked by a spare that is actually usable sooner" ;;
  *) bad "time to usable" "got: $row" ;;
esac
rm -f "$ADIR/sooner.json"

# ── Somebody has to keep the file current ───────────────────────────────────
# The checks above make a stale row read as unknown, which is honest and useless on
# its own: before this, nothing refreshed the readings except a user-typed
# `ccd account` command, so the row would simply go quiet instead of going wrong.
# A prompt tick warms it in the background.
# The file appearing is not the point — a failed probe writes one too, and `dead` is
# the silent-failure state #27 is about. What the row needs is a reading it can use,
# so stand up a local usage endpoint and check the verdict, not the filename.
cat > "$FAKE/usageserver.py" <<'USRV'
import http.server, json, os, socketserver, sys
port_file = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({
            "five_hour": {"utilization": 12, "resets_at": "2099-01-01T00:00:00Z"},
            "seven_day": {"utilization": 30, "resets_at": "2099-01-01T00:00:00Z"},
        }).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
class S(http.server.ThreadingHTTPServer):
    def server_bind(self):                      # skip getfqdn(), see the token server
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]
srv = S(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.replace(port_file + ".tmp", port_file)
srv.serve_forever()
USRV
rm -f "$FAKE/.uport"
python3 "$FAKE/usageserver.py" "$FAKE/.uport" </dev/null >/dev/null 2>&1 &
usrv_pid=$!
n=0; while [ ! -s "$FAKE/.uport" ] && [ $n -lt 75 ]; do sleep 0.2; n=$((n+1)); done
if [ -s "$FAKE/.uport" ]; then
  # A live access token, so probe_account goes straight to the usage endpoint instead
  # of trying to refresh a fixture that has no refresh token — `dead` is what that
  # produces, and `dead` is the silent-failure state this assertion must not accept.
  python3 - "$ADIR/backup.json" <<'LIVEPY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["claudeAiOauth"]["expiresAt"] = int((time.time() + 8 * 3600) * 1000)
json.dump(d, open(p, "w"))
LIVEPY
  rm -rf "$RQD"
  # Its OWN live reading. `use --force` a few cases up deletes the cache, so this run
  # used to go and fetch one — from a stand-in that a later edit of mine had left
  # saying 100% — and then moved the session to the spare it had just warmed,
  # whenever the background pick won the race (Linux always, macOS never).
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
    > "$FAKE/.claude/ccd/quota-cache.json"
  printf '{"session_id":"sess-warm","cwd":"/tmp"}' \
    | CCD_USAGE_URL="http://127.0.0.1:$(cat "$FAKE/.uport")/usage" \
      CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(ls "$RQD" 2>/dev/null)" ] && break; sleep 0.3; done
  verdict=$(python3 -c "
import json, sys, time
try: d = json.load(open('$(rq_gather)'))
except Exception: print('unreadable'); raise SystemExit
rows = [r for r in d.values() if isinstance(r, dict)]
if not rows: print('empty'); raise SystemExit
r = rows[0]
fresh = isinstance(r.get('checked_at'), (int, float)) and time.time() - r['checked_at'] < 60
print(f\"{r.get('status')}:{'fresh' if fresh else 'stale'}:{r.get('five_hour_percent')}\")")
  case "$verdict" in
    ok:fresh:12) ok "a prompt warms the cache with a reading the row can actually use" ;;
    *) bad "quota warm" "wrote something, but not a usable reading: $verdict" ;;
  esac
else
  bad "quota warm" "local usage endpoint never came up"
fi
kill "$usrv_pid" 2>/dev/null; wait "$usrv_pid" 2>/dev/null

# ── A window that has turned over is not a reading about now ─────────────────
# A reset in the past means the cache predates it. The row used to print the
# percentage anyway and merely withhold the countdown, which is the half-measure
# this fixes: 98% of a window that no longer exists is not a smaller claim than
# 98% with a clock beside it, it is the same wrong claim with less to argue with.
# The OTHER window is still a reading, so the row shows that one.
seed_rows main:ok:0:22:18000:600000 backup:ok:98:12:-60:518400
row=$(sl_spare)
case "$row" in
  *"backup 98%"*) bad "expired window" "served a percentage whose window had turned over: $row" ;;
  *"backup 12%"*) ok "a window that has already reset is dropped, not shown without its clock" ;;
  *) bad "expired window" "got: $row" ;;
esac

# With every window turned over there is nothing left to report. That is "?", the
# state the row already has for an account it has never measured — not a number,
# and not "none", which would deny the account exists.
seed_rows main:ok:0:22:18000:600000 backup:ok:98:95:-60:-120
row=$(sl_spare)
case "$row" in
  *"backup"*%*) bad "expired window" "invented a number from two dead windows: $row" ;;
  *"spare ?"*) ok "...and an account with no live window reads as unknown" ;;
  *) bad "expired window" "got: $row" ;;
esac

# Staleness has a ceiling of its own. The reset check above is the sharp instrument;
# this is the backstop for a row whose resets cannot be parsed, or that predates a
# reset it never recorded. The reporter's machine served a four-day-old row as
# current for exactly this reason.
seed_rows main:ok:0:22:18000:600000 backup:ok:8:12:18000:518400
RQT=$(rq_gather)
python3 - "$RQT" <<'AGEPY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["backup"]["checked_at"] = int(time.time()) - 4 * 86400
json.dump(d, open(p, "w"))
AGEPY
rq_scatter "$RQT"
row=$(sl_spare)
case "$row" in
  *"backup 12%"*) bad "stale row" "served a four-day-old reading as current: $row" ;;
  *"spare ?"*) ok "a row too old to be a reading is not shown as one" ;;
  *) bad "stale row" "got: $row" ;;
esac
seed_rows main:ok:0:22:18000:600000 backup:ok:98:12:-:-
row=$(sl_spare)
case "$row" in
  *"backup 98%"*"("*) bad "absent reset" "invented a countdown: $row" ;;
  *"backup 98%"*) ok "...and a missing reset leaves the percentage to stand alone" ;;
  *) bad "absent reset" "got: $row" ;;
esac
# Both windows over the bound, only one of them timed. The untimed one still has
# to turn over, so there is no honest number for when the account comes back —
# and the other window's 13 minutes is not it. (Without the guard this is also
# where `max()` meets a None and takes the whole row down with it.)
seed_rows main:ok:0:22:18000:600000 backup:ok:100:100:780:-
row=$(sl_spare)
case "$row" in
  *"backup 100%"*"("*) bad "half-timed spare" "timed the account by a window that does not free it: $row" ;;
  *"backup 100%"*) ok "...and one blocked window we cannot time leaves the whole account untimed" ;;
  *) bad "half-timed spare" "got: $row" ;;
esac

# ── Where the ready/full line falls, and what it costs to be on each side ────
# A dead spare needs the user to do something and this row is the only place it
# says so, so it outranks a spare that is merely full. That makes precedence the
# test for which side of the bound an account landed on — no colour matching.
mk_sl_acct broken
seed_rows main:ok:0:22:18000:600000 backup:ok:99:12:780:518400 broken:dead:-:-:-:-
# The countdown belongs on this side of the bound too: a spare at 99% with
# thirteen minutes left is a net that is about to have a hole in it. And it IS
# this side: there is no reserve under "spent" — 99% is somewhere to go.
case "$(sl_spare)" in
  *"backup 99% (13m)"*) ok "one point under spent still counts as a spare with room, timed" ;;
  *) bad "spent bound" "99% did not read as ready, or lost its countdown: $(sl_spare)" ;;
esac
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:780:518400 broken:dead:-:-:-:-
case "$(sl_spare)" in
  *"needs re-login"*) ok "...and at 100% the row goes to the spare needing a re-login" ;;
  *) bad "spent bound" "100% still read as ready: $(sl_spare)" ;;
esac
# The bound has to mean the same thing to both halves of the row: an account AT
# the bound is classified as having no room, so the window holding it there is
# what has to turn over before it is usable.
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:780:518400
case "$(sl_spare)" in
  *"backup 100% (13m)"*) ok "...and a spare exactly at the bound is timed by the window holding it there" ;;
  *) bad "spent bound" "the bound means two different things: $(sl_spare)" ;;
esac
# "Spent" is not a knob any more. The old one, set in somebody's shell, must not
# move this row away from where the swap and the proof draw the same line.
seed_rows main:ok:0:22:18000:600000 backup:ok:60:12:780:518400 broken:dead:-:-:-:-
case "$(CCD_HEADROOM=50 sl_spare)" in
  *"backup 60%"*) ok "...and the retired CCD_HEADROOM moves nothing: there is one meaning of spent" ;;
  *) bad "spent bound" "an environment variable redrew the line: $(CCD_HEADROOM=50 sl_spare)" ;;
esac
rm -f "$ADIR/broken.json"

# ── Among spares with no room, the one that comes back first ─────────────────
# Not by percentage — every one of them is at 100 — but by the clock: resetting in
# two hours is no use to someone whose next command is now, and in three minutes is.
mk_sl_acct later
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:180:518400 later:ok:100:12:7200:518400
row=$(sl_spare)
case "$row" in
  *"backup 100% (3m)"*"+1"*) ok "the full spare named is the soonest to reset, with the rest as +N" ;;
  *) bad "full ordering" "got: $row" ;;
esac
# A spare we cannot time loses to one we can, whatever their percentages: an
# unknown wait is not a shorter wait.
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:180:518400 later:ok:100:12:-:-
row=$(sl_spare)
case "$row" in
  *"backup 100% (3m)"*"+1"*) ok "...and a full spare with no timing sorts behind one with it" ;;
  *) bad "full ordering" "got: $row" ;;
esac
rm -f "$ADIR/later.json"

# ── Never probed is not the same as never registered ────────────────────────
seed_rows main:ok:0:22:18000:600000 backup:stale:-:-:-:-
row=$(sl_spare)
case "$row" in
  *"spare none"*) bad "unprobed spare" "called an unmeasured account absent: $row" ;;
  *"spare ?"*) ok "an unprobed spare is a question mark, never a denial" ;;
  *) bad "unprobed spare" "got: $row" ;;
esac

# The claim itself must be unsayable, not merely unsaid: every arrangement of
# registered accounts above reaches a state, so the string has no branch left to
# live in. If it comes back, so does the bug.
if [ ! -r "$ROOT/bin/ccd-statusline" ]; then
  bad "no-spare claim" "could not read the statusline to check"   # absent must not pass
elif grep -q 'spare none' "$ROOT/bin/ccd-statusline"; then
  bad "no-spare claim" "the statusline can still say a registered spare is absent"
else
  ok "...and the row has no way left to answer \"no spare\" at a registered one"
fi

rm -rf "$ADIR" "$RQD"


head_ "27d. a session that cannot hand off says so where you are looking"
WDIR="$FAKE/.claude/ccd"   # §27b named the same directory
# The whole of #21 was an install that sat inert for four days while every surface
# except `ccd doctor` reported success. doctor is the command nobody runs BEFORE the
# thing they installed fails to happen; this row is the one people actually read, and
# it already carries "needs re-login" for the same reason.
rm -rf "$ADIR" "$RQD"; mkdir -p "$ADIR"
mk_sl_acct main; mk_sl_acct backup
printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows main:ok:0:22:18000:600000 backup:ok:20:30:18000:600000
# Below the threshold: this section is about supervision, not about the warning.
# (CCDD is not defined until section 28; WDIR from 27b names the same directory.)
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20,"fiveHourReset":"R1","sevenDayReset":"D1"}}\n' \
  > "$WDIR/quota-cache.json"
SHIMD="$FAKE/.claude/ccd/bin"
sl_env() { env -u CCD_HANDOFF "$@" HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null \
             | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:'; }
# A launcher is only needed by the hop that is authorised here. With the paid hop
# on, an unsupervised session cannot take it — which is what these cases are about.
paid_optin_on
mkdir -p "$FAKE/.claude/ccd/providers"
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"

# Nothing installed: there is no launcher, so no session can hand off.
rm -rf "$SHIMD"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "with no launcher the row says the handoff cannot fire" ;;
  *) bad "supervision" "said nothing about it: $row" ;;
esac

# Installed but unreachable — the exact state that stranded the reporter.
mkdir -p "$SHIMD"; printf '#!/bin/sh\n' > "$SHIMD/claude"; chmod +x "$SHIMD/claude"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "...and an installed launcher that is not on PATH is the same answer" ;;
  *) bad "supervision" "counted an unreachable launcher as working: $row" ;;
esac

# On PATH but with no token: this session started before the launcher did, and
# nothing here can hand off either.
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | PATH="$SHIMD:$PATH" sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "a session that predates the launcher is not called supervised" ;;
  *) bad "supervision" "got: $row" ;;
esac

# A token the hook would refuse must not read as supervision here. launcher_present()
# wants 32 lowercase hex and the state path that token implies; anything weaker calls
# a session supervised that the hook will then decline to signal.
HST="$FAKE/.claude/ccd/handoff-00000000000000000000000000000001.json"
for bad_tok in "x" "0000000000000000000000000000000" "0000000000000000000000000000000G"; do
  row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' \
          | CCD_HANDOFF="$bad_tok" CCD_HANDOFF_STATE="$HST" HOME="$FAKE" \
            "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:')
  case "$row" in
    *"OpenRouter handoff will not happen"*) : ;;
    *) bad "supervision" "a token the hook rejects read as supervised: '$bad_tok' -> $row" ;;
  esac
done
ok "a malformed token is not supervision"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' \
        | CCD_HANDOFF=00000000000000000000000000000001 CCD_HANDOFF_STATE="$FAKE/elsewhere.json" \
          HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:')
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "...and neither is a good token with the wrong state path" ;;
  *) bad "supervision" "accepted a mismatched state path: $row" ;;
esac

# Supervised: say nothing. A row that warns when everything is fine is a row people
# learn not to read.
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' \
        | CCD_HANDOFF=00000000000000000000000000000001 CCD_HANDOFF_STATE="$HST" \
          PATH="$SHIMD:$PATH" HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null \
        | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:')
case "$row" in
  *"OpenRouter handoff will not happen"*) bad "supervision" "warned a supervised session: $row" ;;
  *"spare backup"*) ok "a session holding the hook's own contract is told nothing" ;;
  *) bad "supervision" "got: $row" ;;
esac

# Neither is a session that needs no launcher at all. Without the paid opt-in the
# only hop this install can make happens inside the session, and warning about
# supervision there marks a correct, complete install as broken.
paid_optin_off
rm -rf "$SHIMD"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) bad "supervision" "warned an install whose only hop needs no launcher: $row" ;;
  *"spare backup"*) ok "...and an install with no paid hop is not warned about a launcher it does not need" ;;
  *) bad "supervision" "got: $row" ;;
esac
paid_optin_on
mkdir -p "$SHIMD"; printf '#!/bin/sh\n' > "$SHIMD/claude"; chmod +x "$SHIMD/claude"

# The note and the warning no longer compete: the warning takes its own line, so both
# can say their piece without either being truncated away.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":99,"sevenDayPercent":40,"fiveHourReset":"%s","sevenDayReset":"%s"}}\n' \
  "$(iso 3600)" "$(iso 500000)" > "$WDIR/quota-cache.json"
both=$(printf '%s' '{"model":{"id":"claude-fable-5"}}' \
         | env -u CCD_HANDOFF HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null \
         | sed $'s/\\x1b\\[[0-9;]*m//g')
case "$both" in
  *"OpenRouter handoff will not happen"*"quota 99%"*) ok "the note and the warning both survive, on their own lines" ;;
  *) bad "supervision" "one crowded the other out: $(printf '%s' "$both" | tr '\n' '/')" ;;
esac
[ "$(printf '%s' "$both" | grep -c 'quota 99%')" = "1" ] \
  && ok "...and the warning is on a line of its own" \
  || bad "supervision" "the warning did not get its own line"

# The opt-in alone is not paid auto mode: without a key the hop cannot happen for a
# reason no launcher fixes, and the row is not where that is said.
mv "$FAKE/.claude/ccd/providers/keys.env" "$FAKE/.claude/ccd/providers/keys.env.off"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) bad "supervision" "warned an install with no key: $row" ;;
  *) ok "an opt-in with no key stored is not warned about supervision" ;;
esac
mv "$FAKE/.claude/ccd/providers/keys.env.off" "$FAKE/.claude/ccd/providers/keys.env"

# One account is where the paid hop matters MOST — no spare is itself the proof —
# so it is warned exactly like the rest, and names the fix.
rm -f "$ADIR/backup.json"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*"claude"*) ok "with one account the warning still shows, and says what to do" ;;
  *) bad "supervision" "one account, paid auto on, unsupervised, and the row said: '$row'" ;;
esac
rm -f "$FAKE/.claude/ccd/providers/keys.env"
paid_optin_off
rm -rf "$ADIR" "$SHIMD"; mkdir -p "$ADIR"


head_ "28. no claude-dashboard installed"
# ccd reads Claude quota to do three things: warn before exhaustion, notice a
# reset, and corroborate a rate_limit before arming a handoff. claude-dashboard
# is one source for that reading, not the only one there could be, and an install
# without it used to lose all three in silence: the statusline said nothing, the
# handoff never fired, and nothing anywhere said why. ccd already talks to the
# same Anthropic usage endpoint for its spare accounts, so it can measure the
# account this session is signed in as and answer for itself.
#
# Every assertion below runs with no dashboard anywhere on disk.
rm -rf "$FAKE/.claude/plugins/cache/claude-dashboard" \
       "$FAKE/.claude/plugins/data/claude-dashboard-claude-dashboard" \
       "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock"

export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json"
export CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
# Reset timestamps are generated relative to now. Hardcoded dates would quietly
# expire: once they pass, the reading is correctly rejected as belonging to a
# window that already turned over, and every positive assertion here starts
# failing on a calendar date rather than on a code change. Expired timestamps
# belong only in the reset-crossing test, which builds its own.
# The hook as the plugin runs it, with the dashboard gone.
nd_hook() { CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/scripts/quota-guard.sh" "$@"; }
# Move the file into the past rather than the clock into the future: production
# only ever compares against a real now. (Section 17b's age_file is unset by the
# time this section runs.)
nd_age() { python3 -c "import os,sys,time;t=time.time()-float(sys.argv[2]);os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
CCDD="$FAKE/.claude/ccd"

# ── The reading ─────────────────────────────────────────────────────────────
write_creds nodash
stage_usage 58 96
usage_out=$("$ACCT" --no-color usage --json 2>/dev/null)
case "$usage_out" in
  *'"fiveHourPercent": 58'*|*'"fiveHourPercent":58'*)
    ok "ccd measures the signed-in account with no dashboard installed" ;;
  *) bad "self-measured quota" "got: ${usage_out:0:120}" ;;
esac
case "$usage_out" in
  *'"sevenDayPercent": 96'*|*'"sevenDayPercent":96'*) ok "...both windows, in the shape the cache already speaks" ;;
  *) bad "self-measured 7d window" "got: ${usage_out:0:120}" ;;
esac

# ── What the user sees ──────────────────────────────────────────────────────
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
nd_hook UserPromptSubmit >/dev/null 2>&1
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "96" ] && ok "the hook fills the quota cache from ccd's own reading" \
  || bad "cache without a dashboard" "got: $got"

rm -f "$CCDD/last-warn" "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
out=$(nd_hook UserPromptSubmit 2>/dev/null)
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "...so the near-exhaustion warning still reaches the user" ;;
  *) bad "warning without a dashboard" "got: ${out:0:120}" ;;
esac

# ── The statusline ──────────────────────────────────────────────────────────
rm -rf "$ADIR" "$RQD"; mkdir -p "$ADIR"
mk_sl_acct main; mk_sl_acct backup
printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows main:ok:0:22:18000:600000 backup:ok:20:30:18000:600000
# Below the warning threshold on purpose: this section is about the row surviving a
# missing dashboard, and above it the row hands its spare to the warning instead of
# naming it twice (27c), which would be a different thing being tested.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20,"fiveHourReset":"R1","sevenDayReset":"D1"}}\n' \
  > "$CCDD/quota-cache.json"
row=$(sl_spare)
case "$row" in
  *"spare backup"*) ok "the spare row still names the account to hop to" ;;
  *) bad "spare row without a dashboard" "got: $row" ;;
esac
ccdrow=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$ccdrow" in
  *ccd*luna*) ok "...and the ccd row renders with no dashboard to render above" ;;
  *) bad "ccd row without a dashboard" "got: ${ccdrow:0:80}" ;;
esac

# ── The handoff ─────────────────────────────────────────────────────────────
# The whole point of the reading. Without one, arming is impossible by design
# (see quota_peak), so this is what an install with no dashboard used to lose.
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$CCDD/providers/keys.env"
paid_optin_on
set +m 2>/dev/null
# A fresh stand-in per arm. Arming signals the claude process, so the one that
# armed is gone by the next call — and a dead pid fails the readiness check for
# a reason that has nothing to do with what these assertions are about.
nd_arm() { # $1=session id ; leaves the hook's exit code in $ND_RC
  "$FAKE/sigbin/claude" 8 2>/dev/null & NDPID=$!
  sleep 0.3
  stopfail "$1" rate_limit \
    | CCD_HANDOFF=00000000000000000000000000000002 \
      CCD_HANDOFF_STATE="$CCDD/handoff-00000000000000000000000000000002.json" \
      CLAUDE_PID=$NDPID CCD_STANDIN_PID=$NDPID CLAUDE_PLUGIN_ROOT="$ROOT" \
      CCD_SWAP_SETTLE=0 env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
  ND_RC=$?
  sleep 0.3
  kill -9 $NDPID 2>/dev/null; wait $NDPID 2>/dev/null
}

# Nothing registered: the only place left to go is OpenRouter.
rm -rf "$ADIR" "$RQD"
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_arm sess-nd1
[ "$(hf_get armed)" = "True" ] && ok "rate_limit + a self-measured 100% arms the handoff" \
  || bad "arming without a dashboard" "armed=$(hf_get armed)"
[ "$(hf_get direction)" = "to_fallback" ] && ok "...toward OpenRouter when no subscription is registered" \
  || bad "direction" "got: $(hf_get direction)"

# Without the opt-in the same situation arms nothing. A key configured at some point
# in the past says the paid backbone is reachable; it does not say the user agreed
# that quota exhaustion may start billing while they are not at the keyboard.
paid_optin_off
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_arm sess-nd1b
[ -z "$(hf_get armed)" ] \
  && ok "...and not at all when the paid hop was never opted into" \
  || bad "paid opt-in" "armed $(hf_get direction) on a configured key alone"

# Two subscriptions: the spare wins, and nothing is billed. The opt-in stays OFF
# through this one, because that is the whole point — the free hop is the product
# and it must not need a flag. Section 29 owns what the hop now looks like; what
# is being checked here is that a self-measured reading is enough to reach it.
rm -rf "$ADIR"
for n in nd_one nd_two; do write_creds "$n"; "$ACCT" --no-color add --name "$n" >/dev/null 2>&1; done
"$ACCT" --no-color use nd_one --force >/dev/null 2>&1
# Rows the picker will accept whichever way these accounts registered:
# _cache_row_valid asks for the uuid when an account has one and for the
# credential when it does not, so carry both. A row it retires sends pick to the
# network, and there it would read the signed-in account's numbers for every
# account, which is a fixture bug that looks exactly like a product bug.
nd_seed_rows() { # name:5h:7d ...
  RQT=$(rq_gather)
  python3 - "$ADIR" "$RQT" "$@" <<'NDEOF'
import hashlib, json, os, sys, time
adir, out, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
rows = {}
for spec in specs:
    name, fh, sd = spec.split(":")
    acct = json.load(open(os.path.join(adir, name + ".json")))
    token = (acct.get("claudeAiOauth") or {}).get("accessToken") or ""
    rows[name] = {
        "status": "ok",
        "checked_at": int(time.time()),
        "uuid": acct.get("account_uuid"),
        "cred": hashlib.sha256(token.encode()).hexdigest()[:16],
        "five_hour_percent": int(fh),
        "seven_day_percent": int(sd),
    }
json.dump(rows, open(out, "w"))
NDEOF
  rq_scatter "$RQT"
}
nd_seed_rows nd_one:100:100 nd_two:10:20
paid_optin_off
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
nd_arm sess-nd2
grep -q 'AT-nd_two' "$CREDS" && ok "...and onto the other subscription when one has room" \
  || bad "backstop swap" "the credential never moved"
[ "$ND_RC" = "2" ] && ok "...waking the parked session rather than arming a relaunch" \
  || bad "wake" "exit code $ND_RC, and a handoff of $(hf_get direction)"
[ ! -f "$CCDD/paid-handoff" ] \
  && ok "...and it needed no paid opt-in to get there" \
  || bad "free hop" "the fixture left an opt-in behind, so this proved nothing"
paid_optin_on

# ── Fails closed ────────────────────────────────────────────────────────────
# No dashboard AND no reading is the same as no reading: a bare rate_limit can be
# transient throttling, and arming on one would end a session on a guess.
rm -rf "$ADIR" "$RQD"
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100 500
nd_arm sess-nd3
[ -z "$(hf_get armed)" ] && ok "an unmeasurable account still refuses to arm" \
  || bad "armed on no reading" "armed=$(hf_get armed)"
[ ! -f "$CCDD/quota-cache.json" ] && ok "...and no unusable reading is cached as if it were one" \
  || bad "cached a failed probe" "cache: $(cat "$CCDD/quota-cache.json" 2>/dev/null | head -c 80)"

# The hook fires on every prompt and every tool use, and a failed probe leaves the
# cache exactly as stale as it found it. Without a backoff that is a python3 spawn
# and a socket several times a minute for an account that is offline or signed out.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
: > "$CCD_FAKE_USAGE_LOG"
nd_hook UserPromptSubmit >/dev/null 2>&1
n1=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
nd_hook UserPromptSubmit >/dev/null 2>&1
n2=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "${n1:-0}" -ge 1 ] && ok "a missing cache is probed once" \
  || bad "probe never ran" "calls: ${n1:-0}"
[ "${n2:-0}" = "${n1:-0}" ] && ok "...and a failed probe backs off instead of running on every tick" \
  || bad "no backoff" "calls went $n1 → $n2"

# ── A reading can be too old to mean anything ───────────────────────────────
# The cache keeps its last good sample when a refresh fails, so a 96% reading
# survives the reset it was taken before. Arming on that hands off a session
# whose quota is fine, on a rate_limit that was only ever transient.
"$FAKE/sigbin/claude" 8 2>/dev/null & NDPID=$!
sleep 0.3
kill -9 $NDPID 2>/dev/null; wait $NDPID 2>/dev/null
rm -rf "$ADIR" "$RQD"
hf_reset; rm -f "$CCDD/.usage-probe-backoff"
quota 58 100                      # a good reading...
nd_age "$CCDD/quota-cache.json" 5400     # ...taken an hour and a half ago
stage_usage 58 100 500            # and every refresh since has failed
nd_arm sess-nd4
[ -z "$(hf_get armed)" ] && ok "a reading too old to describe now does not arm" \
  || bad "armed on a stale reading" "armed=$(hf_get armed)"
# ...and so does a YOUNG one, when the re-read at the wall fails. The last good
# reading stays on file for the row to show; it has no authority here. Letting it
# corroborate is how a quota that had since reset, plus one transient rate_limit,
# plus one 429 on the re-read, added up to a paid hop.
hf_reset; quota 58 100
nd_age "$CCDD/quota-cache.json" 240
stage_usage 58 100 429
nd_arm sess-nd5
[ -z "$(hf_get armed)" ] && ok "a re-read that fails at the wall fires nothing, whatever the cache still says" \
  || bad "armed on a failed re-read" "armed=$(hf_get armed)"
# Codex's case exactly: nothing registered, a cached 100% whose reset is unknown.
hf_reset
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"sevenDayPercent":40}}\n' > "$CCDD/quota-cache.json"
stage_usage 58 100 429
nd_arm sess-nd5b
[ -z "$(hf_get armed)" ] && ok "...including a cached 100% with no reset time and nobody registered" \
  || bad "armed on a failed re-read" "armed=$(hf_get armed)"
# A re-read that SUCCEEDS is what a working install has, and it is what arms.
hf_reset; quota 58 40
stage_usage 58 100
nd_arm sess-nd5c
[ "$(hf_get armed)" = "True" ] && ok "...while a re-read that succeeds and says spent still arms" \
  || bad "rejected a fresh reading" "armed=$(hf_get armed)"

# A reading can be young and still describe a window that no longer exists. Four
# minutes old passes every age bound, and if its 5-hour window reset three minutes
# ago then 96% is a fact about quota the user no longer has.
hf_reset; rm -f "$CCDD/.usage-probe-backoff"
past=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=3)).isoformat())")
future=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2)).isoformat())")
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"fiveHourReset":"%s","sevenDayPercent":40,"sevenDayReset":"%s"}}\n' \
  "$past" "$future" > "$CCDD/quota-cache.json"
nd_age "$CCDD/quota-cache.json" 240
stage_usage 58 100 500
nd_arm sess-nd6
[ -z "$(hf_get armed)" ] && ok "a window that has already reset does not corroborate" \
  || bad "armed across a reset" "armed=$(hf_get armed)"
# The same reading before its reset is exactly what a real handoff runs on.
hf_reset
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"fiveHourReset":"%s","sevenDayPercent":40,"sevenDayReset":"%s"}}\n' \
  "$future" "$future" > "$CCDD/quota-cache.json"
nd_age "$CCDD/quota-cache.json" 240
stage_usage 100 40
nd_arm sess-nd7
[ "$(hf_get armed)" = "True" ] && ok "...while one whose window is still open, re-read at the wall, does" \
  || bad "rejected a live window" "armed=$(hf_get armed)"

# ── One probe, not one per hook ─────────────────────────────────────────────
# UserPromptSubmit and PostToolUse overlap constantly. Recording the attempt only
# after a failure let every sibling pass the backoff check and open its own
# socket, which is the shape that turns one slow endpoint into a stalled session.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
: > "$CCD_FAKE_USAGE_LOG"
stage_usage 58 100 500
for _ in 1 2 3 4 5 6; do nd_hook PostToolUse >/dev/null 2>&1 & done; wait
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "${calls:-0}" -eq 1 ] && ok "six concurrent hooks make exactly one request" \
  || bad "probe stampede" "6 concurrent hooks made $calls requests, expected 1"

# The same contention on the path that succeeds. A failed probe leaves a backoff
# marker behind, which would hide a lease released too early; a successful one
# leaves nothing until the cache is installed, so only the lease can hold the
# gap between the request returning and the reading being published.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
rm -rf "$CCDD/.usage-probe.lock"
: > "$CCD_FAKE_USAGE_LOG"
stage_usage 58 100
for _ in 1 2 3 4 5 6; do nd_hook PostToolUse >/dev/null 2>&1 & done; wait
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "${calls:-0}" -eq 1 ] && ok "...and exactly one when the request succeeds" \
  || bad "probe stampede on success" "6 concurrent hooks made $calls requests, expected 1"
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "100" ] && ok "...with the reading published exactly once" \
  || bad "publication" "cache holds: $got"
[ ! -d "$CCDD/.usage-probe.lock" ] && ok "...and the lease released after publication" \
  || bad "lease leak" "the lock outlived the probe"

# An installed dashboard that cannot reach Anthropic reports that as valid JSON
# and exits 0. Treating the exit code as the answer published its error payload
# over the last good reading and skipped the fallback, so a machine that could
# measure itself perfectly well lost its handoffs to a broken neighbour.
DASHD="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
mkdir -p "$DASHD"
cat > "$DASHD/check-usage.js" <<'DJS'
// contents are irrelevant; the stub node below decides what it prints
DJS
cp "$FAKE/fakebin/node" "$FAKE/node.before-nodash"
cat > "$FAKE/fakebin/node" <<'NEOF'
#!/bin/sh
echo '{"claude":{"available":false,"error":true}}'
exit 0
NEOF
chmod +x "$FAKE/fakebin/node"
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"; rm -rf "$CCDD/.usage-probe.lock"
: > "$CCD_FAKE_USAGE_LOG"
stage_usage 58 100
nd_hook UserPromptSubmit >/dev/null 2>&1
[ "$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')" -ge 1 ] \
  && ok "a dashboard that answers with an error still falls through to ccd" \
  || bad "fallback suppressed" "the dashboard's error payload was taken as an answer"
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "100" ] && ok "...and the reading that lands is the usable one" \
  || bad "unusable publication" "cache holds: $got"
# ...and when neither producer can answer, the last good reading is left alone.
quota 58 91
stage_usage 58 100 500
nd_age "$CCDD/quota-cache.json" 900
rm -f "$CCDD/.usage-probe-backoff"; rm -rf "$CCDD/.usage-probe.lock"
nd_hook UserPromptSubmit >/dev/null 2>&1
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "91" ] && ok "...and neither producer answering leaves the last good one in place" \
  || bad "clobbered a good reading" "cache holds: $got"
cp "$FAKE/node.before-nodash" "$FAKE/fakebin/node"; chmod +x "$FAKE/fakebin/node"
rm -rf "$FAKE/.claude/plugins/cache/claude-dashboard"

# ── What doctor says about it ───────────────────────────────────────────────
# A reading that stops coming is invisible everywhere else: the warnings simply
# never appear again and the handoff quietly stops arming. doctor is the one view
# whose job is to answer "is this working?", so it has to name the state.
doctor_out() {
  OPENROUTER_API_KEY=sk-or-v1-smoketest CLAUDE_PLUGIN_ROOT="$ROOT" \
    "$ROOT/bin/ccd" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
}
rm -f "$CCDD/quota-cache.json" "$CCDD/refresh-failed" "$CCDD/.usage-probe-backoff"
stage_usage 58 100 500
nd_hook UserPromptSubmit >/dev/null 2>&1      # probe fails, leaves the breadcrumb
out=$(doctor_out)
case "$out" in
  *"Quota readings"*) ok "doctor reports the quota reading as its own state" ;;
  *) bad "doctor quota section" "no Quota readings section in doctor output" ;;
esac
case "$out" in
  *"✗ none"*) ok "...and says so plainly when there is no reading to arm on" ;;
  *) bad "doctor with no reading" "got: $(printf '%s' "$out" | grep -A2 'Quota readings' | head -3)" ;;
esac
case "$out" in
  *"could not be measured"*) ok "...carrying the reason the hook already recorded" ;;
  *) bad "doctor breadcrumb" "the recorded reason never reached the user" ;;
esac

rm -f "$CCDD/quota-cache.json" "$CCDD/refresh-failed" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_hook UserPromptSubmit >/dev/null 2>&1
out=$(doctor_out)
case "$out" in
  *"5h 58%"*"7d 100%"*) ok "...and reports the numbers once a reading lands" ;;
  *) bad "doctor with a reading" "got: $(printf '%s' "$out" | grep -A2 'Quota readings' | head -3)" ;;
esac

# doctor and the arming gate must draw the line in the same place. A green check
# on a reading the handoff has already stopped trusting is the exact failure this
# section exists to end.
nd_age "$CCDD/quota-cache.json" 1799
inside=$(doctor_out)
case "$inside" in
  # Absence of the warning is not evidence on its own: doctor failing outright
  # would also lack the string. Require the row it is supposed to print.
  *"Too old to arm"*) bad "doctor freshness" "called a 1799s reading too old" ;;
  *"✓ 5h 58%"*) ok "doctor still trusts a reading one second inside the arming bound" ;;
  *) bad "doctor freshness" "no healthy quota row: ${inside:0:120}" ;;
esac
nd_age "$CCDD/quota-cache.json" 1801
case "$(doctor_out)" in
  *"Too old to arm"*) ok "...and says so the second it falls outside" ;;
  *) bad "doctor freshness" "a 1801s reading still read as healthy" ;;
esac

# doctor and the gate must also agree about a window that has already reset. A
# young sample whose window turned over is evidence about quota nobody has any
# more, and a green check on it is exactly the false healthy this section exists
# to end.
gone=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=3)).isoformat())")
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"fiveHourReset":"%s"}}\n' \
  "$gone" > "$CCDD/quota-cache.json"
nd_age "$CCDD/quota-cache.json" 240
case "$(doctor_out)" in
  *"none usable"*) ok "...and calls a reading whose windows have all reset unusable" ;;
  *) bad "doctor expiry" "reported an expired window as a reading: $(doctor_out | grep -A1 'Quota readings' | tail -1)" ;;
esac
# The same shape with a recorded failure behind it is not the benign case. A
# reading whose windows reset two days ago is not waiting for the next prompt.
printf 'the signed-in Claude account could not be measured (login, token, or network)\n' \
  > "$CCDD/refresh-failed"
nd_age "$CCDD/quota-cache.json" 172800
case "$(doctor_out)" in
  *"Refreshes have stopped"*) ok "...and names the cause when one was recorded" ;;
  *) bad "doctor expiry" "offered reassurance over a recorded failure" ;;
esac
case "$(doctor_out)" in
  *"could not be measured"*) ok "...carrying the recorded reason through" ;;
  *) bad "doctor expiry" "the reason never reached the user" ;;
esac
rm -f "$CCDD/refresh-failed"

# Termination while the lease is held must not strand it. A hook killed during
# validation used to leave the lock behind, and every later hook then had to wait
# out the stale-lock reaper before it could refresh at all.
rm -rf "$CCDD/.usage-probe.lock"; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_hook UserPromptSubmit >/dev/null 2>&1
[ ! -d "$CCDD/.usage-probe.lock" ] && ok "a completed refresh leaves no lease behind" \
  || bad "lease leak" "the lock outlived a normal refresh"
# Termination while the lease is held must not strand it: the EXIT/INT/TERM traps
# release it, and a hook killed mid-refresh would otherwise make every later one
# wait out the reaper before it could refresh at all.
rm -rf "$CCDD/.usage-probe.lock"; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
# Signal the hook itself, not a wrapper subshell around it: TERM on a wrapper
# kills the wrapper while the hook runs to completion, and the assertion then
# passes without the trap ever firing. And hold the probe open, so the kill
# lands while the lease is actually held rather than before or after it.
mkdir -p "$FAKE/slowplug/bin"
printf '#!/bin/sh\nsleep 5\n' > "$FAKE/slowplug/bin/ccd-account"
chmod +x "$FAKE/slowplug/bin/ccd-account"
CLAUDE_PLUGIN_ROOT="$FAKE/slowplug" "$ROOT/scripts/quota-guard.sh" UserPromptSubmit \
  >/dev/null 2>&1 < /dev/null & HKPID=$!
held=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -d "$CCDD/.usage-probe.lock" ] && { held=1; break; }
  sleep 0.1
done
[ "$held" -eq 1 ] && ok "the lease is held for the length of the request" \
  || bad "lease never taken" "nothing to clean up, so the next assertion proves nothing"
kill -TERM $HKPID 2>/dev/null; wait $HKPID 2>/dev/null
[ ! -d "$CCDD/.usage-probe.lock" ] && ok "...and a hook killed mid-request releases it" \
  || bad "lease leak" "a TERMed hook stranded the lock"
rm -rf "$FAKE/slowplug"

# And if one survives anyway, it still cannot block the event that matters:
# StopFailure takes no lease, so an armed handoff fires straight through it.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
mkdir -p "$CCDD/.usage-probe.lock"          # as a killed hook would leave it
stage_usage 58 100
hf_reset
nd_arm sess-nd8
[ "$(hf_get armed)" = "True" ] && ok "...and a stranded lease never blocks a handoff" \
  || bad "lease blocks arming" "armed=$(hf_get armed)"
rm -rf "$CCDD/.usage-probe.lock"

# Publication that fails must not look like one that succeeded: clearing the
# markers there would advertise a fresh reading the cache never received.
rm -rf "$CCDD/.usage-probe.lock"; rm -f "$CCDD/quota-cache.json" "$CCDD/refresh-failed"
: > "$CCDD/.usage-probe-backoff"; nd_age "$CCDD/.usage-probe-backoff" 400
stage_usage 58 100
# Fail the move itself. A directory at the cache path does not do it: `mv file
# dir` moves the file into the directory and reports success.
cat > "$FAKE/fakebin/mv" <<'MVEOF'
#!/bin/sh
exit 1
MVEOF
chmod +x "$FAKE/fakebin/mv"
nd_hook UserPromptSubmit >/dev/null 2>&1
rm -f "$FAKE/fakebin/mv"
grep -q "could not be written" "$CCDD/refresh-failed" 2>/dev/null \
  && ok "a reading that cannot be written is recorded as a publication failure" \
  || bad "silent publication failure" "got: $(cat "$CCDD/refresh-failed" 2>&1 | head -1)"
[ -f "$CCDD/.usage-probe-backoff" ] && ok "...and the retry protection is left in place" \
  || bad "backoff cleared" "a failed publication cleared the marker"
[ ! -f "$CCDD/quota-cache.json" ] && ok "...and no half-written reading is left at the cache path" \
  || bad "publication" "a failed move still produced a cache file"

# Subscription-only users are the ones this whole path is for, and they have no
# OpenRouter key. doctor used to exit at the top without one, which put the
# accounts, handoff and quota sections behind a paid fallback nobody needs yet.
mv "$CCDD/providers/keys.env" "$CCDD/providers/keys.env.bak"
nokey_out=$(env -u OPENROUTER_API_KEY CLAUDE_PLUGIN_ROOT="$ROOT" \
  "$ROOT/bin/ccd" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')
mv "$CCDD/providers/keys.env.bak" "$CCDD/providers/keys.env"
case "$nokey_out" in
  *"Quota readings"*) ok "doctor diagnoses the subscription path with no OpenRouter key" ;;
  *) bad "doctor without a key" "got: ${nokey_out:0:160}" ;;
esac
case "$nokey_out" in
  *"Automatic handoff"*) ok "...including the handoff section it used to exit before" ;;
  *) bad "doctor without a key" "no handoff section" ;;
esac
case "$nokey_out" in
  *"no key configured"*) ok "...and names the fallback as the one thing missing" ;;
  *) bad "doctor without a key" "never mentioned the missing key" ;;
esac

unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG
rm -rf "$ADIR" "$RQD"


head_ "40. the recovery banner reads every window"
# #94. The banner is a promise — end this session and ccd takes you back — and it
# was decided from recovery_notified_window alone: one window that had turned
# over, with no reference to bin/spent-at and no look at the other window. Since
# #93 the hook returns only when EVERY reported, unexpired window is below that
# number, so a 5-hour reset beside a weekly window still at 100% had the row
# promising a return the hook correctly declines — and the user ending a session
# for nothing. The banner asks the hook's question, of the hook's own reading.
S40D="$FAKE/.claude/ccd"
S40_FUT=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=2)).isoformat())")
S40_PAST=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=3)).isoformat())")
S40_BANNER="✓ Claude recovered → 종료하면 구독으로 자동 복귀"
# Each case seeds the whole world its row is drawn from: the reading, the record
# beside it, and no dashboard at all — the dashboard's row is printed above ours,
# and one left on disk by an earlier section would be read as this one's output.
s40_fixture() { # $1=reading (empty: none on disk)  $2=run-state  [$3=age the reading by]
  rm -rf "$FAKE/.claude/plugins/cache/claude-dashboard" \
         "$FAKE/.claude/plugins/data/claude-dashboard-claude-dashboard" \
         "$S40D/.dashboard-row" "$S40D/.dashboard-row.lock"
  mkdir -p "$S40D"
  rm -f "$S40D/quota-cache.json"
  [ -n "$1" ] && printf '%s\n' "$1" > "$S40D/quota-cache.json"
  printf '%s\n' "$2" > "$S40D/run-state.json"
  [ -n "${3:-}" ] && python3 -c '
import os, sys, time
t = time.time() - int(sys.argv[2])
os.utime(sys.argv[1], (t, t))' "$S40D/quota-cache.json" "$3"
  return 0
}
# The row a ccd session renders. No model id in the payload: nothing here is about
# the price half of the row, and naming a slug sends a price fetch out. CCD_HANDOFF
# selects the supervised wording, the one that promises the return outright; the
# unsupervised wording is checked once, in (a).
s40_row() {
  printf '%s' '{}' \
    | CCD_ACTIVE=1 CCD_HANDOFF=00000000000000000000000000000002 HOME="$FAKE" \
      "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'
}
# The run-state of a recovered 5-hour window, as update_ccd_state leaves it. Only
# the seven-day number differs between the cases below, and the reading beside it
# is what the row must actually decide on.
s40_state() { # $1=seven-day percent
  printf '{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"recovery_notified_window":"five_hour","recovery_notified_reset":"%s","last_five_hour_percent":4,"last_five_hour_reset":"%s","last_seven_day_percent":%s,"last_seven_day_reset":"%s"}' \
    "$S40_FUT" "$S40_FUT" "$1" "$S40_FUT"
}

# (a) The bug. The 5-hour window reset; the weekly one is still spent, so there is
# nothing to go back to and the hook will not take this session back.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":100,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 100)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) bad "promised a return the hook declines" "5-hour reset, weekly at 100%, row: $row" ;;
  *"Claude recovered"*) bad "promised a return the hook declines" "in some other wording: $row" ;;
  *) ok "a 5-hour reset beside a weekly window still at 100% promises no return" ;;
esac
# Withholding the promise is not blanking the row: everything else it carries is
# still the only thing on screen during an outage.
case "$row" in
  *"run \$0.5000"*) ok "...and the rest of the row is untouched" ;;
  *) bad "the row went with it" "got: $row" ;;
esac
row=$(printf '%s' '{}' | env -u CCD_HANDOFF CCD_ACTIVE=1 HOME="$FAKE" \
        "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')
case "$row" in
  *"Claude recovered"*) bad "promised a return the hook declines" "unsupervised wording: $row" ;;
  *) ok "...and neither does the wording that tells an unsupervised user to walk back by hand" ;;
esac

# (b) Every window below spent-at: this is the state the banner exists for.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 31)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) ok "every window below spent-at still shows the banner, word for word" ;;
  *) bad "the banner stopped appearing" "got: $row" ;;
esac
# ...and the reading is a second condition, not a replacement for the first: room
# with no reset recorded is not a recovery, and saying so would announce one on
# every tick of an outage the subscription simply had headroom during.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"last_five_hour_percent\":4,\"last_five_hour_reset\":\"$S40_FUT\",\"last_seven_day_percent\":31,\"last_seven_day_reset\":\"$S40_FUT\"}"
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "a reading with room is not a reset" "announced one with nothing recorded: $row" ;;
  *) ok "...and room with no reset recorded still announces nothing" ;;
esac

# (c) The bar is spent-at, not a reserve below it (#57). 99% is still somewhere to
# come back to, and a banner that waited for more would keep the user paying
# beside a subscription they could be using.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":99,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 99)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) ok "one point short of spent is still a place to come back to" ;;
  *) bad "a reserve crept in below spent-at" "got: $row" ;;
esac

# (d) A window whose reset has passed says nothing about the quota that replaced
# it — the same call expired() already makes everywhere else. 100% under a reset
# in the past must not hold the promise back.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":100,\"sevenDayReset\":\"$S40_PAST\"}}" \
  "$(s40_state 100)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) ok "...and a window that has already turned over is not counted against it" ;;
  *) bad "held back by an expired window" "got: $row" ;;
esac

# (e) A promise needs a reading that is there, usable, and young enough to
# describe now. The record beside it outlives the reading it came from, and the
# last_*_percent written next to it carries no age bound at all (#94) — so a
# memory of room is exactly what must not be enough. Each of these seeds one.
s40_fixture "" "$(s40_state 31)"
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "promised a return on no reading" "got: $row" ;;
  *) ok "with no reading on disk the row promises nothing" ;;
esac
s40_fixture '{"claude":{"available":false,"error":true}}' "$(s40_state 31)"
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "promised a return on an unusable reading" "got: $row" ;;
  *) ok "...nor on one that could not be taken" ;;
esac
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 31)" 7200
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "promised a return on a stale reading" "got: $row" ;;
  *) ok "...nor on one too old to describe the quota now" ;;
esac

rm -f "$S40D/run-state.json" "$S40D/quota-cache.json"
unset -f s40_fixture s40_row s40_state

finish
