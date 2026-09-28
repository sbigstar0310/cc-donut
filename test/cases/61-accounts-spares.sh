#!/usr/bin/env bash
# 61-accounts-spares — a spare must not die in silence.
# Sections: §25
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "25. multi-account: a spare must not die in silence"
# §21–§24 left a live login on file. account_refresh will not spend a refresh
# token while it cannot see one (live_creds -> "unsure"), and the two refreshers
# this section times both go through it.
wall_login
# §23/§24 also left one reading per account on file, all of them ok, and this
# section never clears the readings directory: the isolation case at the end
# asserts that nothing overwrote them. It cannot seed them itself — `ka warm`
# below calls quota_cache_save(), which no longer exists (it raises, in this
# suite and on main alike).
printf '{"one":{"status":"ok","checked_at":%s,"five_hour_percent":100,"seven_day_percent":100},"two":{"status":"ok","checked_at":%s,"five_hour_percent":10,"seven_day_percent":20}}' \
  "$(date +%s)" "$(date +%s)" | rq_put
# The failure this covers happened in production: every keepalive pass failed for
# sixteen days with a 429, the code only reported "dead", and the user met the
# re-login at the moment of the handoff. Nothing here touches the network — the
# refresh endpoint has no shim, and these are the decisions around it.
#
# Nor does anything from here on: a test that wants an endpoint stands one up locally
# and names it, and everything else points at a dead port rather than at Anthropic.
# Relying on a neighbour's probe-backoff marker for that is how a real request slipped
# through before.
export CCD_USAGE_URL="http://127.0.0.1:1/usage" CCD_TOKEN_URL="http://127.0.0.1:1/token"
rm -rf "$ADIR"; mkdir -p "$ADIR"
ka() { HOME="$FAKE" python3 - "$@" <<'PY'
import json, os, sys, time, types
# Grab the arguments before clearing sys.argv: ccd-account parses it at import.
argv = sys.argv[1:]
m = types.ModuleType("m"); sys.argv = ["x"]
# A module loaded from text has no __file__, and the program finds bin/spent-at
# beside itself. Give it the path it would have had.
m.__file__ = os.environ["ROOT"] + "/bin/ccd-account"
src = open(m.__file__).read()
exec(compile(src.replace('if __name__ == "__main__":', 'if False:'), "x", "exec"), m.__dict__)
cmd = argv[0] if argv else ""
if cmd == "mk":                       # mk <name> <days since refresh> <rt days left>
    name, ago, left = argv[1], int(argv[2]), int(argv[3])
    n = m.now()
    m.account_save(name, {
        "name": name, "label": name, "priority": 1, "storage": "file",
        "refreshed_at": n - ago * 86400, "added_at": n - ago * 86400,
        "claudeAiOauth": {"accessToken": "a", "refreshToken": "r",
                          "expiresAt": (n - 3600) * 1000,
                          "refreshTokenExpiresAt": int((n + left * 86400) * 1000)}})
elif cmd == "gate":                   # gate <mark content|-> <age seconds>
    content, age = argv[1], int(argv[2])
    if content == "-":
        os.path.exists(m.KEEPALIVE_MARK) and os.unlink(m.KEEPALIVE_MARK)
    else:
        m.write_atomic(m.KEEPALIVE_MARK, content, 0o600)
        t = time.time() - age; os.utime(m.KEEPALIVE_MARK, (t, t))
    due, fails = m.keepalive_due()
    print("due" if due else "wait", fails)
elif cmd == "stale":
    print(json.dumps([s["name"] for s in m.stale_spares()]))
elif cmd == "msg":
    s = m.stale_spares(); print(m.stale_message(s) if s else "")
elif cmd == "breadcrumb":
    m.stale_breadcrumb(m.stale_spares()); print("yes" if os.path.exists(m.STALE_FILE) else "no")
elif cmd == "refresh-ok":             # run the real account_refresh, stubbing only HTTP
    # The fixtures carry the refresh token "r", so the exchange cannot succeed
    # against anything real — and a test that reaches the network is a bug in the
    # test. Everything account_refresh does with the result is the code under test.
    name = argv[1]
    m.token_refresh = lambda rt: ({"accessToken": "A2", "refreshToken": "R2",
                                   "expiresAt": int((time.time() + 8 * 3600) * 1000)}, 200)
    acct = m.account_load(name)
    print("ok" if m.account_refresh(name, acct)[0] else "failed")
elif cmd == "quiet":                  # park keepalive so hook runs make no network call
    m.write_json(m.KEEPALIVE_MARK, {"fails": 0}, 0o600)
elif cmd == "warm":                   # ...and park the picker, for the same reason
    # quota_for() serves any row that is valid for the account and inside the TTL
    # without touching the network, so a fresh row per account is what silences the
    # backgrounded `pick` the prompt hook now runs. These accounts carry no uuid, so
    # _cache_row_valid falls back to the credential fingerprint.
    rows = {}
    for name in m.account_names():
        acct = m.account_load(name)
        rows[name] = {"status": "ok", "checked_at": m.now(),
                      "uuid": acct.get("account_uuid"),
                      "cred": m._cred_fingerprint(acct),
                      "five_hour_percent": 5, "seven_day_percent": 5}
    m.quota_cache_save(rows)
elif cmd == "ua":
    print(m.claude_ua())
elif cmd == "refresh-ua":             # what UA does a token refresh present?
    seen = []
    m._http_json = lambda url, data=None, headers=None, timeout=None: (
        seen.append((headers or {}).get("User-Agent")), (0, None))[1]
    m.token_refresh("tok")
    print(seen[0] if seen else "")
PY
}
export ROOT
ka mk active-acct 0 8; ka mk fresh-spare 1 8; ka mk stale-spare 16 -3
printf 'active-acct\n' > "$ADIR/.active"

[ "$(ka stale)" = '["stale-spare"]' ] \
  && ok "a spare that stopped refreshing is spotted by age, not by error class" \
  || bad "stale detection" "got: $(ka stale)"
ka mk stale-spare 1 8
[ "$(ka stale)" = "[]" ] \
  && ok "...and a spare refreshed yesterday is left alone" \
  || bad "stale detection" "flagged a fresh spare: $(ka stale)"
ka mk active-acct 30 -3
[ "$(ka stale)" = "[]" ] \
  && ok "...and the active account is never reported as a stale spare" \
  || bad "stale detection" "reported the active account: $(ka stale)"
ka mk active-acct 0 8

# The message has to carry urgency, not just a name: how long is left before the
# account needs a human at a browser is the whole basis for acting today or not.
ka mk stale-spare 16 11
# Matched by shape, not by an exact count: the remaining days are floored so the
# warning never overstates the time left, and the boundary is a second wide.
case "$(ka msg)" in
  *[0-9]"d before it needs a re-login"*) ok "the warning says how long is left to recover without a re-login" ;;
  *) bad "stale message" "no deadline: $(ka msg)" ;;
esac
ka mk stale-spare 16 -3
case "$(ka msg)" in
  *"already past re-login"*) ok "...and says plainly when that window has closed" ;;
  *) bad "stale message" "no closed-window wording: $(ka msg)" ;;
esac

# The endpoint's front door throttles unrecognized clients to a trickle — the
# refreshes that starved the reporter's spare for 16 days all died there as 429s.
# These tokens are Claude Code logins on Claude Code's client_id, so the refresh
# must present as that client, at a version, whatever machine it runs on.
case "$(ka refresh-ua)" in
  "claude-cli/"*[0-9].[0-9]*" (external, cli)") ok "a token refresh presents as the client the tokens belong to" ;;
  *) bad "refresh UA" "got: $(ka refresh-ua)" ;;
esac

# A failed pass used to stamp the mark before trying, so one bad window per day
# was the account's entire budget: ~8 all-or-nothing tries in a token's lifetime.
[ "$(ka gate '{"fails":0}' 3600)" = "wait 0" ] \
  && ok "a clean pass holds off for the full day" \
  || bad "keepalive gate" "ran early after success"
[ "$(ka gate '{"fails":1}' 1200)" = "due 1" ] \
  && ok "...but a failed pass is retried in minutes, not tomorrow" \
  || bad "keepalive gate" "a failure still burned the whole interval"
[ "$(ka gate '{"fails":1}' 300)" = "wait 1" ] \
  && ok "...though not so fast that it hammers a refusing endpoint" \
  || bad "keepalive gate" "retried before the backoff elapsed"
[ "$(ka gate '{"fails":5}' 3600)" = "wait 5" ] \
  && ok "...and the backoff widens as failures pile up" \
  || bad "keepalive gate" "no backoff growth"
[ "$(ka gate '{"fails":8}' 90000)" = "due 8" ] \
  && ok "...capped at the daily cadence, never longer" \
  || bad "keepalive gate" "backed off past a day"
# Upgrading installs inherit an empty mark file written by the old code.
[ "$(ka gate '' 3600)" = "wait 0" ] && [ "$(ka gate '' 90000)" = "due 0" ] \
  && ok "an empty mark left by an older ccd still gates correctly" \
  || bad "keepalive gate" "upgrade path misread the old mark"
[ "$(ka gate - 0)" = "due 0" ] \
  && ok "...and a missing mark runs immediately" \
  || bad "keepalive gate" "did not run on first use"

# keepalive is backgrounded with its output discarded, so the warning can only
# reach the user as a breadcrumb the next hook tick picks up.
[ "$(ka breadcrumb)" = "yes" ] \
  && ok "the verdict is left where the hook can find it" \
  || bad "breadcrumb" "keepalive left nothing behind"
# ── A refresh that never succeeded is not a refresh ─────────────────────────
# stale_spares() keys on refreshed_at, and bank_live_oauth() and swap_to() both write
# that field on a successful COPY. So every hop reset the staleness clock while the
# refresh path kept failing: on the reporting machine the spare's refreshed_at was
# the exact second of a manual swap, six consecutive keepalive failures were on disk,
# and the warning never fired.
ka mk banked-spare 20 8
python3 - "$ADIR/banked-spare.json" <<'BANKPY'
import json, sys, time
# What banking leaves behind: a fresh refreshed_at against a token nothing has ever
# managed to refresh.
p = sys.argv[1]
d = json.load(open(p))
d["refreshed_at"] = int(time.time())
json.dump(d, open(p, "w"))
BANKPY
case "$(ka stale)" in
  *'"banked-spare"'*) ok "a spare whose token was copied but never refreshed is still stale" ;;
  *) bad "stale detection" "a copy reset the clock: $(ka stale)" ;;
esac

# ...and a refresh that really happened clears it.
ka refresh-ok banked-spare >/dev/null
case "$(ka stale)" in
  *'"banked-spare"'*) bad "stale detection" "a real refresh did not count: $(ka stale)" ;;
  *) ok "...and a refresh that actually succeeded clears it" ;;
esac

# The failure counter is evidence nobody was reading. A manual repair must clear it,
# or the account just proven healthy stays in the backoff keepalive computes from it.
ka_fails() { python3 -c "
import json
try: print((json.load(open('$FAKE/.claude/ccd/accounts-keepalive')) or {}).get('fails'))
except Exception: print('unreadable')"; }

# One account refreshing is not the pass succeeding. The marker carries the SCHEDULE
# as well as the count, so a per-account write postpones the next pass — and with the
# quota warm probing every few minutes, postpones it forever. That silences the
# warning a different, failing spare is waiting for, which is the bug this issue is
# about rather than a new one to introduce.
ka mk lone-success 1 8
printf '{"fails": 6}' > "$FAKE/.claude/ccd/accounts-keepalive"
[ "$(ka refresh-ok lone-success)" = "ok" ] || bad "keepalive counter" "the fixture refresh failed"
[ "$(ka_fails)" = "6" ] \
  && ok "one account's refresh does not reset the whole pass's record" \
  || bad "keepalive counter" "a single success claimed the pass: $(ka_fails)"

# A clean sweep of every spare is a repair, and that is where the counter clears.
printf '{"fails": 6}' > "$FAKE/.claude/ccd/accounts-keepalive"
CCD_TOKEN_URL="http://127.0.0.1:1/x" "$ACCT" --no-color refresh >/dev/null 2>&1
[ "$(ka_fails)" = "6" ] \
  && ok "...and a sweep with a failure in it does not clear it either" \
  || bad "keepalive counter" "cleared on a failed sweep: $(ka_fails)"

# Park keepalive AND the picker: hook runs below must not fire a background token
# refresh or a quota probe. These fixtures carry the refresh token "r" and an
# expired access token, so anything that reaches the network here is a test
# reaching Anthropic for real — a bug in the test, not a slow one.
ka quiet
ka warm
# The signed-in account's reading is parked too: without it the hook goes to measure it.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
  > "$FAKE/.claude/ccd/quota-cache.json"
# Its own clean state, once, before the first tick of this block: an earlier
# backstop may have left a note, a tick shows it, and every assertion below is
# about what a tick says.
rm -f "$FAKE/.claude/ccd/last-stale-warn" "$FAKE/.claude/ccd/swap-note"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
case "$out" in
  *stale-spare*"account refresh"*) ok "...and the prompt hook delivers it, with the recovery command" ;;
  *) bad "stale warning" "got: ${out:-<nothing>}" ;;
esac
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
[ -z "$out" ] \
  && ok "...once, not on every prompt" \
  || bad "stale warning" "repeated inside its cooldown"
rm -f "$FAKE/.claude/ccd/last-stale-warn"
out=$("$ROOT/scripts/quota-guard.sh" PostToolUse < /dev/null 2>/dev/null)
case "$out" in
  *stale-spare*) bad "stale warning" "fired on a tool-use tick" ;;
  *) ok "...and never on a tool-use tick" ;;
esac
ka mk stale-spare 1 8
[ "$(ka breadcrumb)" = "no" ] \
  && ok "recovering the account clears the warning by itself" \
  || bad "breadcrumb" "warning outlived the problem"
# A half-written breadcrumb must not become a hook that emits malformed JSON.
printf '{}' > "$FAKE/.claude/ccd/accounts-stale"
rm -f "$FAKE/.claude/ccd/last-stale-warn"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
[ -z "$out" ] \
  && ok "a breadcrumb with no message says nothing rather than something broken" \
  || bad "stale warning" "emitted from a malformed breadcrumb: $out"
rm -f "$FAKE/.claude/ccd/accounts-stale"

# Nothing above may have gone to the network. These fixtures hold the refresh token
# "r" against a real Anthropic endpoint, so a probe that got through would come back
# an error or dead and overwrite the rows `ka warm` seeded. Their survival is the
# assertion: the prompt hook's backgrounded picker stayed home.
for _ in 1 2 3 4 5 6; do sleep 0.3; done
RQT=$(rq_gather)
left=$(python3 -c "
import json
d = json.load(open('$RQT'))
print(sorted({r.get('status') for r in d.values()}))" 2>/dev/null)
[ "$left" = "['ok']" ] \
  && ok "the prompt hook's quota warm stays off the network in a parked fixture" \
  || bad "test isolation" "a background probe reached out: $left"

# The hook is killed whenever it outruns its timeout, which used to strand its
# tmp file; eight had accumulated in the reporter's CCD_DIR over four weeks.
QDIR="$FAKE/.claude/ccd"
rm -f "$QDIR/quota-cache.json"
: > "$QDIR/quota-cache.json.tmp.999001"; touch -t 202001010000 "$QDIR/quota-cache.json.tmp.999001"
: > "$QDIR/quota-cache.json.tmp.999002"
# The sweep lives on the cache-refresh path, so the cache has to be missing — which
# sends the hook off to measure the signed-in account, at the dead port above.
"$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null >/dev/null 2>&1
[ ! -e "$QDIR/quota-cache.json.tmp.999001" ] \
  && ok "a tmp file stranded by an earlier hard kill is swept" \
  || bad "tmp sweep" "orphan survived"
[ -e "$QDIR/quota-cache.json.tmp.999002" ] \
  && ok "...while a live sibling's in-flight tmp is left alone" \
  || bad "tmp sweep" "deleted a concurrent instance's tmp"
rm -f "$QDIR"/quota-cache.json.tmp.*
# The trap is what stops the hook from creating new orphans in the first place.
( trap 'rm -f "$QDIR/t.$$"; exit 143' TERM; : > "$QDIR/t.$$"; sleep 5 ) & tp=$!
sleep 1; kill -TERM $tp 2>/dev/null; wait $tp 2>/dev/null
[ -z "$(ls "$QDIR"/t.* 2>/dev/null)" ] \
  && ok "...and a killed hook removes its own tmp on the way out" \
  || bad "tmp trap" "a terminated hook still left its tmp behind"

# The version presented must be the one in use. The native installer leaves old
# and newer directories in its store across up- and downgrades, so the store is
# only a fallback for when no `claude` is on the hook's PATH.
VS="$FAKE/.local/share/claude/versions"; mkdir -p "$VS/9.9.9" "$FAKE/clbin"
: > "$VS/1.2.3"; chmod +x "$VS/1.2.3"; ln -sf "$VS/1.2.3" "$FAKE/clbin/claude"
[ "$(PATH="$FAKE/clbin:$PATH" ka ua)" = "claude-cli/1.2.3 (external, cli)" ] \
  && ok "the UA names the version the claude on PATH actually is" \
  || bad "claude_ua" "got: $(PATH="$FAKE/clbin:$PATH" ka ua)"
# A PATH with python3 and nothing else, so the helper itself still runs.
mkdir -p "$FAKE/pybin"; ln -sf "$(command -v python3)" "$FAKE/pybin/python3"
[ "$(PATH="$FAKE/pybin" ka ua)" = "claude-cli/9.9.9 (external, cli)" ] \
  && ok "...and falls back to the newest in the store only when PATH has none" \
  || bad "claude_ua" "got: $(PATH="$FAKE/pybin" ka ua)"
rm -rf "$VS" "$FAKE/clbin" "$FAKE/pybin"

# ── One refresher at a time ─────────────────────────────────────────────────
# keepalive rotates tokens; the quota warm probes, and quota_for() refreshes a token
# on the way when the stored one has expired. Both therefore spend the same one-time
# refresh token. Run as siblings they raced, the loser got `dead`, and the account read
# as logged out — which is the failure this release is about, arriving by a route we
# opened.
#
# A spare due for a keepalive, holding an expired token, behind a stale reading: a
# prompt has both refreshers to run. The signed-in account's reading is current, so
# the hook measures nothing else.
rm -rf "$ADIR"; mkdir -p "$ADIR"
ka mk active-acct 0 8; ka mk race-spare 0 8
printf 'active-acct\n' > "$ADIR/.active"
rm -rf "$FAKE/.claude/ccd/accounts-keepalive" "$RQD" "$FAKE/.race"
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
  > "$FAKE/.claude/ccd/quota-cache.json"
endpoint_up "$FAKE/.race" 0.4 || bad "refresher race" "local endpoint never came up"
CLAUDE_PLUGIN_ROOT="$ROOT" CCD_TOKEN_URL="$EP_URL/token" CCD_USAGE_URL="$EP_URL/usage" \
  CCD_HTTP_TIMEOUT=10 "$ROOT/scripts/quota-guard.sh" UserPromptSubmit </dev/null >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c '^end' "$FAKE/.race" 2>/dev/null)" = "2" ] && break; sleep 0.3
done
sleep 0.5    # long enough for a straggler to show
[ "$(cut -d' ' -f1-2 "$FAKE/.race" 2>/dev/null | tr '\n' ' ')" = "start token end token start usage end usage " ] \
  && ok "a prompt runs the two refreshers in sequence, never at once" \
  || bad "refresher race" "interleaved: $(tr '\n' ' ' < "$FAKE/.race" 2>/dev/null)"
kill "$EP_PID" 2>/dev/null; wait "$EP_PID" 2>/dev/null
rm -f "$FAKE/.race"

# The hook fires on each prompt and each tool use, so keepalive passes start
# within the same second. Each must not read a refresh token another is about
# to rotate: a local token endpoint counts what actually arrives.
rm -rf "$ADIR"; mkdir -p "$ADIR"
ka mk active-acct 0 8; ka mk lone-spare 0 8
printf 'active-acct\n' > "$ADIR/.active"
rm -f "$FAKE/.claude/ccd/accounts-keepalive" "$FAKE/.port" "$FAKE/.hits"
# The server is a file, not a heredoc on a backgrounded command: bash 3.2 (the
# macOS CI runner) never started the latter, and its stderr is kept so a CI
# failure says why instead of "never came up".
cat > "$FAKE/tokserver.py" <<'PY'
import http.server, json, os, socketserver, sys, time
port_file, hits = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        time.sleep(1)                      # hold the window open for the race
        with open(hits, "a") as f: f.write("x\n")
        body = json.dumps({"access_token": "a" + str(time.time()),
                           "refresh_token": "r" + str(time.time()),
                           "expires_in": 28800}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
class S(http.server.ThreadingHTTPServer):
    # HTTPServer.server_bind calls socket.getfqdn(), a reverse-DNS lookup that
    # stalls for tens of seconds on the macOS CI runner; the port file then
    # never appears and the test reads as "endpoint never came up".
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]
srv = S(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.replace(port_file + ".tmp", port_file)
srv.serve_forever()
PY
python3 "$FAKE/tokserver.py" "$FAKE/.port" "$FAKE/.hits" </dev/null >/dev/null 2>"$FAKE/tokserver.err" &
srv_pid=$!
# Measured, not assumed: this is the reverse-DNS lookup HTTPServer.server_bind
# performs by default, and the reason the server above skips it. Printed on
# every platform so a CI log shows the number, not a guess.
printf '  · getfqdn(127.0.0.1) on this runner: %s\n' \
  "$(python3 -c 'import socket,time;t=time.time();socket.getfqdn("127.0.0.1");print(f"{time.time()-t:.2f}s")' 2>&1)"
n=0; while [ ! -s "$FAKE/.port" ] && [ $n -lt 75 ]; do sleep 0.2; n=$((n+1)); done
[ -s "$FAKE/.port" ] || bad "keepalive race" "local token endpoint never came up after ${n}00ms; server: $(ps -o stat=,etime= -p "$srv_pid" 2>/dev/null | tr -s ' '); stderr: $(head -c 300 "$FAKE/tokserver.err" 2>/dev/null)"
TOK="http://127.0.0.1:$(cat "$FAKE/.port" 2>/dev/null)/token"
# The suite shortens CCD_HTTP_TIMEOUT elsewhere; the endpoint's deliberate delay
# must not read as a client-side timeout here.
for _ in 1 2 3 4 5; do
  CCD_TOKEN_URL="$TOK" CCD_HTTP_TIMEOUT=10 HOME="$FAKE" "$ACCT" --no-color keepalive >/dev/null 2>&1 &
done; wait $(jobs -p | grep -v "^$srv_pid$") 2>/dev/null
hits=$(grep -c x "$FAKE/.hits" 2>/dev/null || echo 0)
[ "$hits" -eq 1 ] \
  && ok "five keepalive passes at once refresh the spare exactly once (sent $hits)" \
  || bad "keepalive race" "the endpoint saw $hits refreshes for one spare"
python3 - "$FAKE/.claude/ccd/accounts-keepalive" <<'PY' \
  && ok "...and the pass is recorded as clean, not as four rotated-token failures" \
  || bad "keepalive race" "mark: $(cat "$FAKE/.claude/ccd/accounts-keepalive")"
import json, sys; assert json.load(open(sys.argv[1]))["fails"] == 0
PY
kill $srv_pid 2>/dev/null; wait $srv_pid 2>/dev/null; rm -f "$FAKE/.port" "$FAKE/.hits"

# Prompts from several sessions can land together; "at most every four hours"
# has to hold across them, not per process.
ka mk lone-spare 16 -3; ka breadcrumb >/dev/null; ka quiet
rm -f "$FAKE/.claude/ccd/last-stale-warn" "$FAKE"/hook.*
for i in 1 2 3 4 5; do
  "$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null > "$FAKE/hook.$i" 2>/dev/null &
done; wait
emitted=$(cat "$FAKE"/hook.* | grep -c "lone-spare")
[ "$emitted" -eq 1 ] \
  && ok "five simultaneous prompt hooks deliver the warning exactly once" \
  || bad "stale warning race" "$emitted hooks emitted at once"
rm -f "$FAKE"/hook.*

rm -rf "$ADIR" "$FAKE/.claude/ccd/accounts-stale" "$FAKE/.claude/ccd/last-stale-warn" \
       "$FAKE/.claude/ccd/accounts-keepalive"

finish
