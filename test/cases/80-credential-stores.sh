#!/usr/bin/env bash
# 80-credential-stores — where the credential lives while it moves.
# Sections: §32, §36
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "32. the exchange belongs under the lock"
shim_fixture
# A probe is a read: it measures somebody's quota and can wait outside any lock.
# A token exchange is a WRITE — it consumes a one-time credential — and it has to
# happen inside the store lock with the write it produces, as one step. Outside
# it, the store can be re-registered, re-swapped or replaced while the exchange
# is in flight, and the result then lands on whatever is sitting in that file.
TXD="$FAKE/.claude/ccd"
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
tx_fixture() {  # one registered account, its stored token expired and due a refresh
  rm -rf "$ADIR" "$RQD" "$FAKE/.claude.json"
  mkdir -p "$ADIR"
  write_creds tx_b; "$ACCT" --no-color add --name tx_b --label B-original >/dev/null 2>&1
  write_creds tx_c; "$ACCT" --no-color add --name tx_c --label C-other >/dev/null 2>&1
  python3 - "$ADIR/tx_b.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
PY
  printf '{"fails":0}' > "$TXD/accounts-keepalive"
}
tx_tok() { python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$1"; }
tx_uuid() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("account_uuid") or "")' "$1"; }

# ── A completed exchange never lands on another account's record ────────────
# `account add --name B --force` points that name at a different account. If the
# exchange is outside the lock, the merge writes B's brand-new refresh token into
# the record that now belongs to C — and the live write lands on top of it.
tx_fixture
stage_usage 5 5 200 2 AT-tx-rotated       # a two-second exchange
( sleep 0.6; write_creds tx_c_again
  "$ACCT" --no-color add --name tx_b --force --label C-registered >/dev/null 2>&1 ) &
RACE=$!
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh tx_b >/dev/null 2>&1
wait "$RACE" 2>/dev/null
python3 - "$ADIR/tx_b.json" <<'PY' \
  && ok "a record never ends up holding a credential minted for another account" \
  || bad "cross-contaminated record" "the exchange landed on a re-registered name"
import json, sys
d = json.load(open(sys.argv[1]))
tok = (d.get("claudeAiOauth") or {}).get("accessToken") or ""
# Either the refresh won the name and the record is still its own, or the
# re-registration won and the record is wholly the new account's. What must not
# exist is a record wearing one account's identity and another's credential.
assert not (tok == "AT-tx-rotated" and d.get("label") == "C-registered"), \
    f"label={d.get('label')!r} token={tok}"
PY

# ── An exchange that could not take the lock never happened ─────────────────
# Nothing to lose is the whole point: a completed exchange has spent a token that
# cannot be minted again, so the exchange must not START unless its result can be
# written the moment it lands. A store held past the wait is the case — the lock
# is worth a few seconds' patience and nothing beyond that.
tx_fixture
stage_usage 5 5 200 0 AT-tx-rotated
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(6)                       # longer than any caller will wait for it
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
: > "$CCD_FAKE_USAGE_LOG"
"$ACCT" --no-color refresh tx_b >/dev/null 2>&1
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
wait "$HOLD" 2>/dev/null
[ "${calls:-0}" -eq 0 ] \
  && ok "a store that cannot be locked means no token is spent at all" \
  || bad "spent under a held lock" "${calls:-0} exchanges ran with the store locked"
[ "$(tx_tok "$ADIR/tx_b.json")" = "AT-tx_b" ] \
  && ok "...and the stored credential is exactly the one nobody touched" \
  || bad "lost exchange" "store holds $(tx_tok "$ADIR/tx_b.json")"

# ── A half-written credential is not a written one ──────────────────────────
# Two backends, one refusal: the file takes the new blob and the keychain keeps
# the old. Reporting that as success is how a later bank copies the stale one
# back over the new — the successor destroyed by the very next swap.
rm -f "$FAKE/.claude/ccd/store-split"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE" <<'PY' \
  && ok "a write only one backend took is reported as the failure it is" \
  || bad "partial write" "live_write called a split-brain store a success"
import importlib.machinery, importlib.util, os, sys
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdacct", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

m.use_keychain = lambda: True
m._keychain_write = lambda blob: False          # the keychain refuses
ok, failed, written = m.live_write({"claudeAiOauth": {"accessToken": "AT-new"}},
                                   ["keychain", "file"])
assert ok is False, "a refused backend was reported as a successful write"
assert "keychain" in failed, f"the refusing backend is not named: {failed!r}"
assert written == ["file"], f"the backend that took it is not named: {written!r}"

m._keychain_write = lambda blob: True
ok, failed, written = m.live_write({"claudeAiOauth": {"accessToken": "AT-new"}},
                                   ["keychain", "file"])
assert ok is True and not failed, f"a complete write was reported as partial: {failed!r}"
assert set(written) == {"keychain", "file"}, f"written: {written!r}"
PY

# ...and the caller has to act on it rather than carry on.
rm -f "$FAKE/.claude/ccd/store-split"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE" <<'PY' \
  && ok "...and a swap that cannot write both stores fails instead of claiming a move" \
  || bad "partial write" "the swap reported a credential it had not installed"
import importlib.machinery, importlib.util, os, sys
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdacct2", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

m.use_keychain = lambda: True
m._keychain_write = lambda blob: False
m.live_read = lambda: ({"claudeAiOauth": {"accessToken": "AT-old", "refreshToken": "RT-old"}},
                       ["keychain", "file"])
m.active_name = lambda: "someone_else"
m.account_load = lambda n: ({"name": n, "claudeAiOauth":
                             {"accessToken": "AT-target", "refreshToken": "RT-target"}}
                            if n == "target" else None)
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
else:
    raise AssertionError("swap_to returned success on a half-written credential store")
PY

# ── An account that goes live while the refresh waits is left alone ─────────
# The pre-check says "not the live account" before the lock is taken, and cannot
# say anything about the world after it. Claude Code publishing its profile is
# enough to make that account live while we wait — and consuming its refresh
# token then leaves the running session holding one that can never be renewed.
r1_fixture() {
  rm -rf "$ADIR" "$RQD"; rm -rf "$FAKE/.claude.json"
  mkdir -p "$ADIR"
  write_creds r1_b; "$ACCT" --no-color add --name r1_b >/dev/null 2>&1
  write_creds r1_other; "$ACCT" --no-color add --name r1_other >/dev/null 2>&1
  "$ACCT" --no-color use r1_other --force >/dev/null 2>&1   # the pointer says r1_other
  python3 - "$ADIR/r1_b.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["account_uuid"] = "uuid-r1"                                     # who the profile names
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)  # and it is due a refresh
json.dump(d, open(sys.argv[1], "w"))
PY
  printf '{"fails":0}' > "$TXD/accounts-keepalive"
}
r1_go_live() {  # Claude Code signs in as r1_b: its credential, and its profile
  python3 - "$ADIR/r1_b.json" "$CREDS" "$FAKE/.claude.json" <<'PY'
import json, sys, time
acct = json.load(open(sys.argv[1]))
live = json.load(open(sys.argv[2]))
live["claudeAiOauth"] = acct["claudeAiOauth"]
json.dump(live, open(sys.argv[2], "w"))
json.dump({"oauthAccount": {"accountUuid": "uuid-r1", "emailAddress": "r1@example.com",
                            "profileFetchedAt": int((time.time() + 5) * 1000)}},
          open(sys.argv[3], "w"))
PY
}
r1_fixture
stage_usage 5 5 200 0 AT-r1-rotated
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.2
: > "$CCD_FAKE_USAGE_LOG"
start=$(date +%s)
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh r1_b > "$FAKE/.r1-out" 2>&1 &
REFPID=$!
sleep 0.5
r1_go_live                       # r1_b is the live account from here on
wait "$HOLD" 2>/dev/null
wait "$REFPID" 2>/dev/null; rc=$?
waited=$(( $(date +%s) - start ))
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
# The interleaving itself, asserted rather than assumed: a refresh that did not
# queue behind the lock never met the publication and would prove nothing.
[ "$waited" -ge 1 ] \
  && ok "the refresh queued behind the lock, so it met the account going live" \
  || bad "no interleaving" "the refresh finished in ${waited}s without waiting"
{ [ "${calls:-0}" -eq 0 ] && [ "$rc" -ne 0 ]; } \
  && ok "an account that went live while we waited is not refreshed behind its session" \
  || bad "refreshed the live account" "${calls:-0} exchanges, rc=$rc"
grep -q "signed in here" "$FAKE/.r1-out" \
  && ok "...and says why, rather than reporting an unreachable account" \
  || bad "wrong refusal" "got: $(tr '\n' ' ' < "$FAKE/.r1-out" | head -c 100)"
[ "$(tx_tok "$ADIR/r1_b.json")" = "AT-r1_b" ] \
  && ok "...with its stored credential still the one that session is holding" \
  || bad "refreshed the live account" "store holds $(tx_tok "$ADIR/r1_b.json")"
rm -f "$FAKE/.claude.json" "$FAKE/.r1-out"

# ── An account removed while we waited is not brought back ──────────────────
r1_fixture
stage_usage 5 5 200 0 AT-r1-rotated
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.2
: > "$CCD_FAKE_USAGE_LOG"
start=$(date +%s)
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh r1_b > "$FAKE/.r5-out" 2>&1 &
REFPID=$!
sleep 0.5
rm -f "$ADIR/r1_b.json"          # `ccd account rm` landing while we wait
wait "$HOLD" 2>/dev/null
wait "$REFPID" 2>/dev/null; rc=$?
waited=$(( $(date +%s) - start ))
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "$waited" -ge 1 ] \
  && ok "the refresh queued behind the lock, so it met the removal" \
  || bad "no interleaving" "the refresh finished in ${waited}s without waiting"
{ [ ! -e "$ADIR/r1_b.json" ] && [ "${calls:-0}" -eq 0 ] && [ "$rc" -ne 0 ]; } \
  && ok "a refresh does not re-register an account somebody removed" \
  || bad "resurrected account" "exists=$([ -e "$ADIR/r1_b.json" ] && echo yes || echo no) calls=${calls:-0} rc=$rc"
grep -q "no longer registered" "$FAKE/.r5-out" \
  && ok "...and says so, rather than reporting it unreachable" \
  || bad "wrong refusal" "got: $(tr '\n' ' ' < "$FAKE/.r5-out" | head -c 100)"
rm -f "$FAKE/.claude.json" "$FAKE/.r5-out"

# ── A partial install puts back what it managed to write ────────────────────
# The rollback has to be about what was actually WRITTEN, not about how many
# sources happened to be readable: a keychain that cannot be read still gets
# written, so counting readable sources skips the restore exactly when both
# stores have been left disagreeing.
rm -f "$FAKE/.claude/ccd/store-split"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE" <<'PY' \
  && ok "a half-installed credential is rolled back to what the session still holds" \
  || bad "no rollback" "the stores were left disagreeing about who is signed in"
import importlib.machinery, importlib.util, json, os, sys
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdacct3", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

OLD = {"claudeAiOauth": {"accessToken": "AT-old", "refreshToken": "RT-old"}}
writes = []
m.use_keychain = lambda: True
m._keychain_write = lambda blob: False          # the keychain refuses every write
# A keychain that could not be READ: the source list names the file alone, while
# the write still has to reach both.
m.live_read = lambda: (OLD, ["file"])
m.write_json = lambda p, obj, mode=0o600: writes.append((str(p), obj))
m.active_name = lambda: "someone_else"
m.account_load = lambda n: ({"name": n, "claudeAiOauth":
                             {"accessToken": "AT-target", "refreshToken": "RT-target"}}
                            if n == "target" else None)
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
else:
    raise AssertionError("swap_to reported success on a half-written store")
creds = [obj for path, obj in writes if path.endswith(".credentials.json")]
assert creds, "the credential file was never written, so this proved nothing"
last = (creds[-1].get("claudeAiOauth") or {}).get("accessToken")
assert last == "AT-old", f"the file was left holding {last!r} while the keychain kept AT-old"
PY

# ── A batch job is never ended for a return it cannot make ─────────────────
# The launcher is the only one that knows there is no terminal to come back to.
# Discovering it after the session has been signalled means the work was killed
# for a relaunch that then does not happen.
"$FAKE/sigbin/claude" 8 2>/dev/null & BPID=$!
sleep 0.3
cat > "$TXD/run-state.json" <<'RSEOF'
{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"last_seven_day_percent":97,"last_seven_day_reset":"D1"}
RSEOF
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"fiveHourReset":"R1","sevenDayPercent":3,"sevenDayReset":"D2"}}\n' \
  > "$TXD/quota-cache.json"
rm -f "$TXD/handoff-00000000000000000000000000000002.json"
printf '{"session_id":"sess-batch","cwd":"/tmp/w","hook_event_name":"UserPromptSubmit"}' \
  | CCD_ACTIVE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_AUTH_TOKEN=x \
    CCD_HANDOFF=00000000000000000000000000000002 \
    CCD_HANDOFF_STATE="$TXD/handoff-00000000000000000000000000000002.json" \
    CCD_HANDOFF_HEADLESS=1 CLAUDE_PID=$BPID CCD_STANDIN_PID=$BPID \
    "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
sleep 0.4
if kill -0 "$BPID" 2>/dev/null; then ok "a run that cannot be relaunched is never signalled"
else bad "killed a batch job" "the hook ended a session the launcher would refuse to bring back"; fi
[ ! -f "$TXD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and nothing is armed for a relaunch that would be refused" \
  || bad "armed for a batch job" "armed a return a headless run cannot take"
kill -9 "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
rm -f "$TXD/run-state.json"

# ── The token decides, not the name ─────────────────────────────────────────
# What an exchange can hurt is the CREDENTIAL a session is holding, and a name is
# only a guess at that. Here the pointer names another account entirely, while the
# live blob is carrying r1_b's refresh token — spend it and the running session is
# left with one it can never renew.
r1_fixture
stage_usage 5 5 200 0 AT-r1-rotated
python3 - "$ADIR/r1_b.json" "$CREDS" <<'PY'
import json, sys
acct = json.load(open(sys.argv[1]))
live = json.load(open(sys.argv[2]))
live["claudeAiOauth"] = dict(acct["claudeAiOauth"])   # the session holds r1_b's token
json.dump(live, open(sys.argv[2], "w"))
PY
: > "$CCD_FAKE_USAGE_LOG"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh r1_b > "$FAKE/.rtok-out" 2>&1; rc=$?
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
{ [ "${calls:-0}" -eq 0 ] && [ "$rc" -ne 0 ]; } \
  && ok "a token the live session is holding is never spent, whatever the pointer says" \
  || bad "spent the live token" "${calls:-0} exchanges, rc=$rc"
[ "$(tx_tok "$ADIR/r1_b.json")" = "AT-r1_b" ] \
  && ok "...and the stored copy still matches what that session has" \
  || bad "spent the live token" "store holds $(tx_tok "$ADIR/r1_b.json")"

# ── A store that disagrees with itself stops everything, and ccd never repairs it ─
# One backend took the new credential and the other kept the old, and putting it
# back failed too. The next swap's outgoing backup would read the half the
# keychain answers with and file it under the registration the pointer names —
# one account's credential saved as another's. Nothing may move until the stores
# agree again, and the only thing that can put them back in step is /login:
# Claude Code writes every backend itself, which is more authoritative than
# anything ccd could reconstruct from what it happens to have on file.
split_home() { # $1=case name -> a HOME of this case's own
  rm -rf "$FAKE/split-$1"; mkdir -p "$FAKE/split-$1/.claude"; printf '%s' "$FAKE/split-$1"
}
SPLIT_PRE='
import importlib.machinery, importlib.util, json, os, sys, time
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdsplit", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.ensure_dirs()
# The fake sits at the subprocess boundary, not on ccd functions: whatever a
# revision calls its keychain reader, it ends in `security`, and that is where a
# test has to stand to be about behaviour. Anything not staged ends the test —
# and as a BaseException, because the code under test swallows Exception.
import types
class Unstaged(BaseException):
    pass
class Ran:
    def __init__(self, rc, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""
STAGED = {}
def fake_run(argv, *a, **k):
    if list(argv[:2]) == ["security", "find-generic-password"] and "find" in STAGED:
        return STAGED["find"]()
    raise Unstaged("unstaged external call: " + " ".join(argv[:2]))
m.subprocess = types.SimpleNamespace(run=fake_run)
def kc(fn=None, rc=0):                    # what `security find-generic-password` answers
    STAGED["find"] = lambda: Ran(rc, json.dumps(fn()) if rc == 0 else "")
OLD = {"claudeAiOauth": {"accessToken": "AT-old", "refreshToken": "RT-old"}}
TARGET = {"name": "target", "claudeAiOauth":
          {"accessToken": "AT-target", "refreshToken": "RT-target"}}
def only_target(n):
    return dict(TARGET) if n == "target" else None
'

PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
try:
    os.unlink(m.STORE_SPLIT)
except OSError:
    pass
# The keychain takes the install and then refuses the rollback; the file refuses
# throughout. That is the state with no good half left to copy from.
calls = {"n": 0}
def keychain_write(blob):
    calls["n"] += 1
    return calls["n"] == 1
m.use_keychain = lambda: True
m._keychain_write = keychain_write
m.live_read = lambda: (OLD, ["keychain", "file"])
real_write = m.write_json
def selective(p, obj, mode=0o600):
    if str(p).endswith(".credentials.json"):
        raise OSError("read-only")          # the file backend, and only it
    return real_write(p, obj, mode)
m.write_json = selective
m.active_name = lambda: "someone_else"
m.account_load = only_target
m.account_save = lambda n, o: None
err = None
try:
    m.swap_to("target", force=True)
except SystemExit as e:
    err = str(e)
assert err is not None, "swap_to reported success on a store it could not repair"
rec = json.load(open(m.STORE_SPLIT))
# The record has to say what each half is holding — it is what doctor prints —
# and which stores the stop is about, which is what lets it be re-tested later.
note = rec.get("detail") or ""
assert "keychain" in note and "file" in note, f"the record says too little: {note!r}"
assert rec.get("stores") == ["file", "keychain"], f"the stop names no stores: {rec!r}"
' "$ROOT/bin/ccd-account" "$(split_home rollback)" \
  && ok "a rollback that fails too is recorded as a store that cannot be trusted" \
  || bad "unrecorded split" "the swap left the stores disagreeing and said nothing"

# A rollback that PUT EVERYTHING BACK is not a split, however loudly the install
# failed. The backend that refused the new credential refuses the redundant
# restore too, and it never moved: recording that as a split stops a machine that
# is perfectly consistent.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
m._keychain_write = lambda blob: False   # refuses the install AND the restore
m.live_read = lambda: (OLD, ["keychain", "file"])
m.active_name = lambda: "someone_else"
m.account_load = only_target
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
assert not os.path.exists(m.STORE_SPLIT), \
    "a store that ends up consistent was stopped anyway: " + open(m.STORE_SPLIT).read()
live = json.load(open(m.credentials_file()))
assert live["claudeAiOauth"]["accessToken"] == "AT-old", \
    "the rollback did not put the file back: " + json.dumps(live["claudeAiOauth"])
' "$ROOT/bin/ccd-account" "$(split_home consistent)" \
  && ok "a rollback that put every backend back is not recorded as a split" \
  || bad "false split" "a consistent store was stopped over a refused redundant write"

# Write-ahead, not best-effort. If the intent cannot be recorded, the credential
# is not written at all: an unwritable state directory would otherwise disable
# the protection silently, and the next command banks one account's credential
# under another's name with nothing left to stop it.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
touched = []
m.use_keychain = lambda: True
m._keychain_write = lambda blob: (touched.append("keychain"), True)[1]
m.live_read = lambda: (OLD, ["keychain", "file"])
real_write = m.write_json
def selective(p, obj, mode=0o600):
    if os.path.basename(str(p)) == "store-split":
        raise OSError("read-only state directory")
    touched.append(os.path.basename(str(p)))
    return real_write(p, obj, mode)
m.write_json = selective
m.active_name = lambda: "someone_else"
m.account_load = only_target
m.account_save = lambda n, o: None
err = None
try:
    m.swap_to("target", force=True)
except SystemExit as e:
    err = str(e)
assert err is not None, "the swap went ahead with no way to record what it was doing"
assert touched == [], f"a credential backend was written anyway: {touched!r}"
' "$ROOT/bin/ccd-account" "$(split_home noroom)" \
  && ok "a state directory that cannot hold the record means no credential is written" \
  || bad "unrecorded write" "the swap wrote credentials it could not record"

# The stop is re-tested, never repaired. /login makes Claude Code write every
# backend itself, and the moment they agree again there is nothing left to stop.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
held = {"kc": {"accessToken": "AT-old", "refreshToken": "RT-old"}}
m.use_keychain = lambda: True
kc(lambda: {"claudeAiOauth": held["kc"]})
m.write_json(m.credentials_file(),
             {"claudeAiOauth": {"accessToken": "AT-new", "refreshToken": "RT-new"}})
m.write_json(m.STORE_SPLIT, {"detail": "keychain kept the old credential",
                             "stores": ["file", "keychain"]})
assert m.store_split_now() is not None, "the stop lifted while the stores disagreed"
held["kc"] = {"accessToken": "AT-new", "refreshToken": "RT-new"}   # signed in again
assert m.store_split_now() is None, "the stop stood after the stores were put back in step"
assert not os.path.exists(m.STORE_SPLIT), "the record outlived the disagreement"
' "$ROOT/bin/ccd-account" "$(split_home login)" \
  && ok "the stop lifts by itself once every store it names agrees again" \
  || bad "no way out" "/login put the stores back in step and ccd stayed stopped"

# Banking re-checks the record under the lock. The pre-check describes the world
# we saw; the record can land while we queue, and copying between stores that
# disagree is exactly how one account's credential gets filed under another's.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
saved = []
m.use_keychain = lambda: False
m.account_save = lambda n, o: saved.append(n)
m.account_load = lambda n: {"name": n}
m._bank_target = lambda: ("acct", {"accessToken": "AT-live", "refreshToken": "RT-live"})
RealLock = m.Lock
class MarkingLock(RealLock):
    def __enter__(self):
        got = RealLock.__enter__(self)
        m.write_json(m.STORE_SPLIT, {"detail": "another ccd stopped mid-write",
                                     "stores": ["file", "keychain"]})
        return got
m.Lock = MarkingLock
m.bank_live_oauth()
assert saved == [], f"banked across a store that started disagreeing while it waited: {saved!r}"
' "$ROOT/bin/ccd-account" "$(split_home banklock)" \
  && ok "banking re-reads the stop under the lock, not only before it" \
  || bad "banked on a split" "the record landed while banking waited and it copied anyway"

# The gate that decides whether a stored token is safe to spend has to look at
# EVERY backend. Preferring one drops the other's credential from the comparison,
# and a running session may well be carrying the one that was dropped.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
spent = []
m.use_keychain = lambda: True
kc(lambda: {"claudeAiOauth": {"accessToken": "AT-a", "refreshToken": "RT-a"}})
m.write_json(m.credentials_file(),
             {"claudeAiOauth": {"accessToken": "AT-b", "refreshToken": "RT-b"}})
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [], f"spent a token the other backend is holding: {spent!r}"
assert okd is False and st == "stale", f"got {okd!r}/{st!r}"
' "$ROOT/bin/ccd-account" "$(split_home bothbackends)" \
  && ok "a token any readable backend is holding is never spent" \
  || bad "spent a live token" "the gate looked at one backend and missed the other"

# And a backend it cannot read is unknown, not absent. An empty answer is what
# let the exchange proceed when nothing could be read at all.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
spent = []
m.use_keychain = lambda: True
kc(rc=1)                                # the keychain will not answer
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [], f"spent a token with no idea what the session is holding: {spent!r}"
assert okd is False, f"got {okd!r}/{st!r}"
' "$ROOT/bin/ccd-account" "$(split_home blind)" \
  && ok "a credential store that cannot be read refuses the exchange, it does not permit it" \
  || bad "spent a token blind" "an unreadable backend was treated as an empty one"

# Absence of evidence is not agreement. A credential only has to carry an access
# token for ccd to register and install it, so two backends can hold DIFFERENT
# logins that both lack a refresh token — and a stop lifted on that pair hands the
# next swap a live blob belonging to the other account.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kcb = {"blob": {"claudeAiOauth": {"accessToken": "AT-b"}}}         # B, no refresh token
kc(lambda: kcb["blob"])
m.write_json(m.credentials_file(), {"claudeAiOauth": {"accessToken": "AT-a"}})
m.write_json(m.STORE_SPLIT, {"detail": "keychain took b, file kept a",
                             "stores": ["file", "keychain"]})
assert m.store_split_now() is not None, \
    "two different logins compared equal because neither had a refresh token"
# ...and a store where nothing can be identified at all is not an agreeing store.
kcb["blob"] = {"claudeAiOauth": {}}
m.write_json(m.credentials_file(), {"claudeAiOauth": {}})
assert m.store_split_now() is not None, "a store with no identity anywhere lifted the stop"
' "$ROOT/bin/ccd-account" "$(split_home noident)" \
  && ok "two credentials that cannot be told apart are not the same credential" \
  || bad "absence read as agreement" "the stop lifted on a store that is still divided"

# Codex's scenario end to end: the install takes the keychain and the rollback
# cannot put it back, so keychain=B, file=A, pointer=A — every credential carrying
# an access token and nothing else. The retry must find the stop, and must not
# bank the keychain half into A on its way past.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
store = {"a": {"name": "a", "claudeAiOauth": {"accessToken": "AT-a"}},
         "b": {"name": "b", "claudeAiOauth": {"accessToken": "AT-b"}}}
m.account_load = lambda n: json.loads(json.dumps(store[n])) if n in store else None
m.account_save = lambda n, o: store.__setitem__(n, json.loads(json.dumps(o)))
m.active_name = lambda: "a"
m.active_set = lambda n, stamp=True: None
m.drop_account_scoped_config = lambda: None
back = {"keychain": {"claudeAiOauth": {"accessToken": "AT-a"}},
        "file": {"claudeAiOauth": {"accessToken": "AT-a"}}}
m.use_keychain = lambda: True
kcalls = {"n": 0}
def kwrite(blob):
    kcalls["n"] += 1
    if kcalls["n"] == 1:
        back["keychain"] = json.loads(json.dumps(blob))
        return True
    return False                      # refuses the rollback
m._keychain_write = kwrite
kc(lambda: back["keychain"])
m.live_read = lambda: (json.loads(json.dumps(back["keychain"])), ["keychain", "file"])
m.write_json(m.credentials_file(), {"claudeAiOauth": {"accessToken": "AT-a"}})
real_write = m.write_json
def selective(p, obj, mode=0o600):
    if str(p).endswith(".credentials.json"):
        raise OSError("read-only")     # the file backend keeps A throughout
    return real_write(p, obj, mode)
m.write_json = selective
first = None
try:
    m.swap_to("b", force=True)
except SystemExit as e:
    first = str(e)
assert first is not None, "the divided write reported success"
assert os.path.exists(m.STORE_SPLIT), "nothing recorded the divided store"
try:
    m.swap_to("b", force=True)         # the retry
except SystemExit as e:
    second = str(e)
else:
    raise AssertionError("the retry ran on a store that is still divided")
assert store["a"]["claudeAiOauth"]["accessToken"] == "AT-a", \
    "a retry filed b credential under a: " + json.dumps(store["a"]["claudeAiOauth"])
' "$ROOT/bin/ccd-account" "$(split_home retry)" \
  && ok "a retry over a divided store neither swaps nor rewrites the outgoing account" \
  || bad "retry corrupts the store" "the second swap moved something it should not have"

# ccd does not infer absence. The stop lifts only when every store the record names
# ANSWERS, with a credential, and they all carry the same identity. Each of the
# three below once counted as "that backend is gone", and each was a way to lift
# the stop on a store nobody had actually seen agree.
HEALTHY='{"claudeAiOauth": {"accessToken": "AT-new", "refreshToken": "RT-new"}}'
RECORD='m.write_json(m.STORE_SPLIT, {"detail": "keychain took b, file kept a", "stores": ["file", "keychain"]})'

# A file that is not there. It may have been removed for good — and the user has
# an explicit exit for that — but ccd cannot tell that from a file it cannot reach.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
exec(sys.argv[4])
assert m.store_split_now() is not None, "a missing file was read as a store that agrees"
' "$ROOT/bin/ccd-account" "$(split_home nofile)" "$HEALTHY" "$RECORD" \
  && ok "a named store that does not answer keeps the stop, even when the file is simply missing" \
  || bad "absence inferred" "a store that did not answer was counted as agreeing"

# A file that is there and cannot be reached. os.path.exists() answers False for a
# permission error as readily as for a missing file, which is how an unreadable
# credential was classed as no credential at all.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
exec(sys.argv[4])
creds = m.credentials_file()
real_open, real_exists = open, os.path.exists
def denied(p, *a, **k):
    if str(p) == creds:
        raise PermissionError(13, "Permission denied", creds)
    return real_open(p, *a, **k)
m.open = denied
m.os.path.exists = lambda p: False if str(p) == creds else real_exists(p)
assert m.store_split_now() is not None, "a file ccd was refused was read as a file that is gone"
' "$ROOT/bin/ccd-account" "$(split_home denied)" "$HEALTHY" "$RECORD" \
  && ok "a credentials file ccd is refused is unknown, not absent" \
  || bad "absence inferred" "a permission error lifted the stop"

# A keychain that says it found nothing. `security` exits 44 out of failed searches
# too, so it cannot prove the item is absent.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(rc=44)                               # exit 44, staged as itself
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
exec(sys.argv[4])
assert m.store_split_now() is not None, "a keychain that found nothing was read as an empty one"
' "$ROOT/bin/ccd-account" "$(split_home kc44)" "$HEALTHY" "$RECORD" \
  && ok "a keychain search that comes back empty does not prove the keychain is" \
  || bad "absence inferred" "exit 44 lifted the stop"

# A keychain holding no Claude login at all. Lifting the stop here is what let the
# same-account branch copy that blob over the healthy file login and erase it.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: {"mcpOAuth": {"notion|abc": {"accessToken": "MCP"}}})
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
exec(sys.argv[4])
assert m.store_split_now() is not None, "a store holding no login was read as one that agrees"
' "$ROOT/bin/ccd-account" "$(split_home nologin)" "$HEALTHY" "$RECORD" \
  && ok "a named store holding no Claude login keeps the stop" \
  || bad "absence inferred" "a credential-free backend lifted the stop"

# ...and that branch does not need a lifted stop to do the damage: with no record
# at all it still copies whatever live_read() prefers over every backend. A blob
# with no login in it is not something to even the stores WITH.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
wrote = []
m.use_keychain = lambda: True
m.live_read = lambda: ({"mcpOAuth": {"notion|abc": {"accessToken": "MCP"}}}, ["keychain", "file"])
m.live_write = lambda blob, sources: (wrote.append(blob), (True, [], []))[1]
m.active_name = lambda: "target"
m.account_load = only_target
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
assert wrote == [], "a blob holding no login was copied over every backend: " + json.dumps(wrote)
' "$ROOT/bin/ccd-account" "$(split_home sameacct)" \
  && ok "evening the stores never copies a blob that holds no login" \
  || bad "login erased" "the same-account branch overwrote the stores with a credential-free blob"

# The gate that protects a live token looks at every refresh token any backend
# holds — identifiable or not. A blob with a refresh token and no access token is
# nothing ccd would install, and it is still something a session may be carrying.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
spent = []
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
m.write_json(m.credentials_file(), {"claudeAiOauth": {"refreshToken": "RT-b"}})
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [], f"spent a token a backend is holding: {spent!r}"
' "$ROOT/bin/ccd-account" "$(split_home unidentified)" "$HEALTHY" \
  && ok "a refresh token is protected even in a credential ccd cannot identify" \
  || bad "spent a live token" "a backend with no access token was dropped from the gate"

# For the gate the two kinds of silence are NOT the same as an empty store: a
# backend that gave no answer may be holding the very token about to be spent,
# however healthy the other one looks.
GATE='
spent = []
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [] and okd is False, f"exchanged with a backend unaccounted for: {spent!r} {st!r}"
'
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
creds = m.credentials_file()
real_open = open
def denied(p, *a, **k):
    if str(p) == creds:
        raise PermissionError(13, "Permission denied", creds)
    return real_open(p, *a, **k)
m.open = denied
'"$GATE" "$ROOT/bin/ccd-account" "$(split_home gatedenied)" "$HEALTHY" \
  && ok "a credentials file ccd is refused stops the exchange, healthy keychain or not" \
  || bad "spent a token blind" "an unreadable file was treated as holding nothing"

PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(rc=1)
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
'"$GATE" "$ROOT/bin/ccd-account" "$(split_home gatesilent)" "$HEALTHY" \
  && ok "a keychain that gives no answer stops the exchange, healthy file or not" \
  || bad "spent a token blind" "a silent keychain was treated as an empty one"

# Two writes that both succeed prove only that ccd wrote twice. Claude Code shares
# no lock with ccd, and a refresh of the outgoing account can land on one backend
# between them. So the record goes away on what the stores are SEEN to hold, not
# on what the writes returned. (This narrows that race; it cannot close it.)
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
A = {"claudeAiOauth": {"accessToken": "AT-a", "refreshToken": "RT-a"}}
back = {"kc": json.loads(json.dumps(A))}
m.write_json(m.credentials_file(), A)
m.use_keychain = lambda: True
kc(lambda: back["kc"])
def kwrite(blob):
    # ccd write lands, and then the refresh Claude Code had in flight for the
    # outgoing account lands on top of it — before ccd reaches the file.
    back["kc"] = {"claudeAiOauth": {"accessToken": "AT-a2", "refreshToken": "RT-a2"}}
    return True
m._keychain_write = kwrite
moved = []
m.active_set = lambda n, stamp=True: moved.append(n)
m.active_name = lambda: "a"
m.account_load = lambda n: only_target(n) or ({"name": "a", **A} if n == "a" else None)
m.account_save = lambda n, o: None
m.drop_account_scoped_config = lambda: None
m.swap_to("target", force=True)
assert os.path.exists(m.STORE_SPLIT), "two successful writes cleared the stop on stores that disagree"
rec = json.load(open(m.STORE_SPLIT))
# Ownership follows the writes, as it always did: both succeeded, and that is the
# best knowledge there is of whose credential is live. Only the RECORD waits.
assert moved == ["target"], f"the pointer did not follow the install: {moved!r}"
assert "interrupted" not in rec["detail"], "the record still tells the write-ahead story: " + rec["detail"]
' "$ROOT/bin/ccd-account" "$(split_home foreign)" 2> "$FAKE/.foreign-err" \
  && ok "two successful writes do not clear the stop when the stores are seen to disagree" \
  || bad "cleared on write success" "$(tail -1 "$FAKE/.foreign-err")"
grep -q 'ccd/store-split' "$FAKE/.foreign-err" \
  && ok "...and the refusal names the record, as every other one does" \
  || bad "no way out" "got: $(tr '\n' ' ' < "$FAKE/.foreign-err" | head -c 160)"

# The verify decides about the RECORD and about nothing else. When it also gated
# the pointer, one failed read left B installed under a pointer still saying A —
# and once reads recovered, the next command lifted the stop and the retry banked
# live B into A. No foreign writer needed; the hook's own retry did it. So: real
# files, real account_save, and the whole sequence.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
A = {"accessToken": "AT-a", "refreshToken": "RT-a"}
B = {"accessToken": "AT-b", "refreshToken": "RT-b"}
m.use_keychain = lambda: False
m.account_save("a", {"name": "a", "claudeAiOauth": A})
m.account_save("b", {"name": "b", "claudeAiOauth": B})
m.active_set("a", stamp=False)
m.write_json(m.credentials_file(), {"claudeAiOauth": A})
creds, real_open, real_live_write = m.credentials_file(), open, m.live_write
state = {"blind": False}
def flaky(p, *a, **k):
    if state["blind"] and str(p) == creds:
        raise PermissionError(13, "Permission denied", creds)
    return real_open(p, *a, **k)
m.open = flaky
def then_blind(blob, sources):
    got = real_live_write(blob, sources)
    state["blind"] = True             # every write landed; the read after it does not
    return got
m.live_write = then_blind
said = []
m.warn = lambda msg: said.append(msg)
try:
    installed = m.swap_to("b", force=True)[1]
except SystemExit:
    installed = None                  # judged last: what it corrupts comes first
assert os.path.exists(m.STORE_SPLIT), "an unverified install cleared its own record"
state["blind"] = False                # reads recover
m.live_write = real_live_write
m.bank_live_oauth()                   # what every next command starts with
m.swap_to("b", force=True)            # and the retry the hook would make
stored = json.load(real_open(m.account_path("a")))["claudeAiOauth"]
assert stored["accessToken"] == "AT-a", "the outgoing account now holds: " + json.dumps(stored)
assert m._pointer_name() == "b", "the pointer says " + repr(m._pointer_name())
assert not os.path.exists(m.STORE_SPLIT), "the stop outlived stores that agree"
assert installed, "a swap that happened was reported as one that did not"
assert said and "store-split" in " ".join(said), f"the standing stop went unmentioned: {said!r}"
' "$ROOT/bin/ccd-account" "$(split_home sequence)" \
  && ok "a verify that cannot see leaves the pointer right, and the retry banks nothing into the wrong account" \
  || bad "outgoing snapshot corrupted" "a transient read failure ended with one account filed under another"

# A record ccd cannot make sense of is still a record. Each of these used to fail
# open: no stores named meant nothing had to answer, and an empty one read as
# "no stop" to every caller that tested it for truth.
for bad_rec in '{}' '{"detail":"x"}' '{"detail":"x","stores":[]}' '{"detail":"x","stores":["floppy"]}' 'not json at all'; do
  BAD_REC="$bad_rec" PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: False
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
open(m.STORE_SPLIT, "w").write(os.environ["BAD_REC"])
assert m.store_split(), "the record reads as no stop at all"
assert m.store_split_now(), "one healthy backend lifted a stop that names nothing it can check"
assert os.path.exists(m.STORE_SPLIT), "the record was deleted"
' "$ROOT/bin/ccd-account" "$(split_home malformed)" "$HEALTHY" 2>/dev/null \
    && ok "a malformed stop still stops: $bad_rec" \
    || bad "malformed record fails open" "$bad_rec"
done

# The outgoing backup and the evening of the stores ask the same question — does
# the blob live_read() prefers hold a login at all — and must get the same answer.
# Banking a refresh-only blob overwrites a healthy snapshot with something ccd
# itself would refuse to install.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: False
m.write_json(m.credentials_file(), {"claudeAiOauth": {"refreshToken": "RT-only"}})
saved, warned = [], []
m.account_save = lambda n, o: saved.append((n, o.get("claudeAiOauth")))
m.warn = lambda msg: warned.append(msg)
m.active_name = lambda: "target"
m.account_load = only_target
m.swap_to("target", force=True)
assert saved == [], "a blob holding no login was banked over the snapshot: " + json.dumps(saved)
assert warned, "nothing was done and nothing was said"
' "$ROOT/bin/ccd-account" "$(split_home nobank)" \
  && ok "a live blob holding no login is neither banked nor copied, and ccd says so" \
  || bad "snapshot overwritten" "the outgoing backup banked a credential-free blob"

PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: False
m.write_json(m.credentials_file(), {"claudeAiOauth": {"refreshToken": "RT-only"}})
saved = []
m.account_save = lambda n, o: saved.append(n)
m.active_name = lambda: "a"
m.account_load = lambda n: only_target(n) or ({"name": "a", "claudeAiOauth": {"accessToken": "AT-a"}} if n == "a" else None)
m.active_set = lambda n, stamp=True: None
m.drop_account_scoped_config = lambda: None
m.swap_to("target", force=True)
assert "a" not in saved, "the outgoing account was overwritten with a blob holding no login"
assert not os.path.exists(m.STORE_SPLIT), "a clean single-store install left its record behind"
' "$ROOT/bin/ccd-account" "$(split_home nobank2)" \
  && ok "...nor banked on the way out to another account, and a one-store install still clears its record" \
  || bad "snapshot overwritten" "a swap away banked a credential-free blob"

# ...and while the stop stands, nothing else may touch the credential stores. The
# record names both backends; this suite can only see the file one, so it cannot
# be re-tested here — which is exactly the shape of "ccd cannot see that they
# agree", and the stop has to hold.
mkdir -p "$ADIR"
printf '{"detail":"keychain kept AT-old, file holds AT-new","stores":["file","keychain"]}' \
  > "$TXD/store-split"
write_creds split_b; "$ACCT" --no-color add --name split_b >/dev/null 2>&1
write_creds split_a; "$ACCT" --no-color add --name split_a >/dev/null 2>&1
out=$("$ACCT" --no-color use split_b --force 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q 'AT-split_b' "$CREDS"; } \
  && ok "a swap refuses to run on a store that is known to disagree with itself" \
  || bad "swapped on a split store" "rc=$rc, credential $(tx_tok "$CREDS")"
: > "$CCD_FAKE_USAGE_LOG"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh split_b >/dev/null 2>&1; rrc=$?
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
{ [ "${calls:-0}" -eq 0 ] && [ "$rrc" -ne 0 ]; } \
  && ok "...and no stored token is spent while a store the stop names cannot be seen" \
  || bad "spent a token on a split store" "${calls:-0} exchanges, rc=$rrc"
case "$out" in
  *"/login"*) ok "...and sends the user to /login, which replaces the credential in use" ;;
  *) bad "no way out" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
case "$out" in
  *"writes every credential store"*)
    bad "overclaims" "ccd promises Claude Code writes both stores; it writes one and falls back" ;;
  *"stale"*|*"other half"*)
    bad "overclaims" "ccd says which half is stale; it does not know" ;;
  *".claude/ccd/store-split"*)
    ok "...and names the record to delete once the user is satisfied the login works" ;;
  *) bad "no second exit" "nothing says what to do when signing in does not lift it" ;;
esac
case "$out" in
  *reconcile*) bad "still offering a repair" "ccd offered to rebuild the store itself" ;;
  *) ok "...and never offers to rebuild the store itself" ;;
esac
out=$(HOME="$FAKE" CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/bin/ccd" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' \
      | sed -n '/Credential stores/,/^$/p')
case "$out" in
  *"stale"*|*"other half"*) bad "doctor overclaims" "doctor says which half is stale; ccd does not know" ;;
  *"disagree"*"/login"*"ccd/store-split"*) ok "...and doctor says it, exit included, where somebody would go looking" ;;
  *) bad "doctor blind" "doctor never sends the user to /login over the split store" ;;
esac
"$ACCT" --no-color reconcile split_a >/dev/null 2>&1 \
  && bad "repair command survives" "ccd account reconcile still runs" \
  || ok "...and there is no ccd command that claims to repair a credential store"
rm -f "$TXD/store-split"

# Write-ahead, on the real filesystem and not a stubbed one: the state directory
# stops taking new files while everything the swap reads stays readable. A
# protection that cannot be recorded is none at all, so the credential must not
# move either. Root writes through a read-only directory, so containers skip it.
if [ "$(id -u)" -ne 0 ]; then
  write_creds split_a
  chmod 500 "$TXD"
  out=$("$ACCT" --no-color use split_b --force 2>&1); rc=$?
  chmod 700 "$TXD"
  { [ "$rc" -ne 0 ] && [ "$(tx_tok "$CREDS")" = "AT-split_a" ]; } \
    && ok "a record ccd cannot write means the credential is not written either" \
    || bad "wrote what it could not record" "rc=$rc, credential $(tx_tok "$CREDS")"
  case "$out" in
    *"refusing to touch the credential stores"*) ok "...and says so instead of swapping quietly" ;;
    *) bad "silent unrecorded write" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
  esac
fi

write_creds split_a
"$ACCT" --no-color use split_b --force >/dev/null 2>&1 \
  && grep -q 'AT-split_b' "$CREDS" \
  && [ ! -e "$TXD/store-split" ] \
  && ok "...after which a swap works again, and clears its own record on a one-store machine" \
  || bad "still blocked" "the store stayed unusable once the stop was gone"
rm -rf "$FAKE"/split-*

# ── The launcher is the one that knows a run is headless ────────────────────
# A test that sets the flag itself proves only that the hook reads it. What has
# to be true is that the launcher publishes it, because it is the only party that
# can see there is no terminal to come back to.
mkdir -p "$FAKE/hlbin"
printf '#!/bin/sh\nprintf "HEADLESS=[%%s]\\n" "${CCD_HANDOFF_HEADLESS:-}"\n' > "$FAKE/hlbin/claude"
chmod +x "$FAKE/hlbin/claude"
out=$(PATH="$FAKE/hlbin:$PATH" "$ROOT/bin/ccd-handoff" -p hi 2>&1)
case "$out" in
  *"HEADLESS=[1]"*) ok "the launcher tells the hook when a run cannot be relaunched" ;;
  *) bad "no headless flag" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 100)" ;;
esac
out=$(PATH="$FAKE/hlbin:$PATH" shim_run "$ROOT/bin/ccd-handoff" 2>&1)
case "$out" in
  *"HEADLESS=[]"*) ok "...and says nothing of the sort about an interactive one" ;;
  *) bad "headless flag leaked" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 100)" ;;
esac

# ── A leftover shim that cannot run is not a route ──────────────────────────
# is_ccd_shim() answers "ours", not "runnable". Committing to an unexecutable one
# breaks every ccd launch on a machine with a perfectly good claude on PATH.
rm -rf "$FAKE/.claude/ccd/bin"
mkdir -p "$FAKE/.claude/ccd/bin"
{ printf '#!/usr/bin/env bash\n'; printf '# ccd-auto-handoff-shim v1 (managed by: ccd setup --auto)\n'; } \
  > "$FAKE/.claude/ccd/bin/claude"
chmod -x "$FAKE/.claude/ccd/bin/claude"
fake_real '#!/bin/sh
printf "REAL reached=%s\n" "$*"'
out=$(PATH="$SHIMPATH" HOME="$FAKE" shim_run "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"REAL reached="*) ok "a shim that cannot be executed is stepped over, not exec'd" ;;
  *) bad "unrunnable shim" "ccd could not start claude at all: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
rm -rf "$FAKE/.claude/ccd/bin"

# ── The return has an entrance ──────────────────────────────────────────────
# `--auto` installs a launcher whose only job is bringing a ccd run back to the
# subscription. A ccd run that does not START under it can never come back, so
# ccd itself has to go through it when one is installed.
rm -rf "$FAKE/.claude/ccd/bin"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
fake_real '#!/bin/sh
printf "REAL supervised=[%s]\n" "${CCD_HANDOFF:+yes}"'
out=$(PATH="$SHIMPATH" HOME="$FAKE" shim_run "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"supervised=[yes]"*) ok "an interactive ccd run starts under the launcher that can bring it back" ;;
  *) bad "no entrance" "the launcher installed by --auto never sees the session: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
# ...and a redirected one does not: no terminal, nothing to return to.
out=$(PATH="$SHIMPATH" HOME="$FAKE" "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"supervised=[]"*) ok "...while a run with nowhere to come back to is left alone" ;;
  *"supervised=[yes]"*) bad "no entrance" "a redirected run was put under a launcher" ;;
  *) bad "no entrance" "never reached the real claude: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac

# ── A batch job never inherits somebody else's supervision ──────────────────
# `ccd -p` run from inside a supervised session inherits CCD_HANDOFF and the
# state path that goes with it. Declining the launcher is only half the job: the
# child still claims to be watched, so the hook arms and signals it on the
# parent's contract — and the work dies for a relaunch nobody will make.
out=$(PATH="$SHIMPATH" HOME="$FAKE" OPENROUTER_API_KEY=sk-or-v1-smoketest \
      CCD_HANDOFF=00000000000000000000000000000001 \
      CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000001.json" \
      "$ROOT/bin/ccd" -p hi 2>&1)
case "$out" in
  *"supervised=[]"*) ok "a batch run started inside a supervised session claims no supervision" ;;
  *"supervised=[yes]"*) bad "inherited supervision" "the batch child carried its parent's launcher contract" ;;
  *) bad "inherited supervision" "never reached the real claude: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
# ...but never two of them: a session already supervised must not gain a second
# launcher underneath the first.
# A second launcher would mint a token of its own, so the one that arrives is the
# proof: the same token means nothing was nested underneath it.
fake_real '#!/bin/sh
printf "REAL token=%s\n" "${CCD_HANDOFF:-none}"'
out=$(PATH="$SHIMPATH" HOME="$FAKE" CCD_HANDOFF=00000000000000000000000000000001 \
      shim_run "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"token=00000000000000000000000000000001"*)
    bad "inherited supervision" "the child kept a contract minted for its parent" ;;
  *"token=none"*) ok "...and a session that inherits a contract does not keep it" ;;
  *) bad "nested launcher" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac

rm -rf "$ADIR" "$TXD/accounts-keepalive"
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG
unset -f tx_fixture tx_tok tx_uuid

# Reported, not yet asserted. The rejecting stub is what guarantees nothing leaves
# the machine; making this a failure means staging an answer in every section
# that probes OpenRouter, which is its own piece of work. Until then the number
# stays in plain sight instead of being a request nobody knew the suite made.
if [ -s "$FAKE/.unstaged-curl" ]; then
  printf '\n  note: %s curl calls had no staged answer and were REJECTED by the default stub:\n' \
    "$(wc -l < "$FAKE/.unstaged-curl" | tr -d ' ')"
  sed -E 's#.*(https?://[^ ]+).*#\1#; s#/models/[^ ]*/endpoints#/models/<slug>/endpoints#' "$FAKE/.unstaged-curl" \
    | sort | uniq -c | sort -rn | sed 's/^/    /'
fi


head_ "36. the keychain write keeps the credential off the command line"
# `security add-generic-password -w <blob>` put both tokens in argv, readable by any
# process on the machine for as long as it ran (#78). `security -i` reads the same
# command from stdin, which is how Claude Code writes this item itself. The fake
# stands where the others do, at subprocess.run, and reads a command the way the
# real tool does (Apple's SecurityTool/macOS: readline.c, security.c,
# keychain_add.c), so a line that would break there breaks here too.
cat > "$FAKE/kcw-fake.py" <<'PYEOF'
import importlib.machinery, importlib.util, json, os, sys, types
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
os.environ["USER"] = "ccd-test"
loader = importlib.machinery.SourceFileLoader("ccdkcw", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.use_keychain = lambda: True
SVC, ME = m.KEYCHAIN_SERVICE, "ccd-test"
OLD = b'{"claudeAiOauth": {"accessToken": "AT-old"}}'
ITEMS = {(SVC, ME): OLD}   # the login this write replaces
CALLS = []                 # (argv, stdin) of every exec
REFUSE = []                # a status staged here refuses the next add
BLOB = {"claudeAiOauth": {"accessToken": "AT-kcw-secret", "refreshToken": "RT-kcw-secret"},
        "mcpOAuth": {"notion|x": {"accessToken": "MCP-kcw-secret",
                                  "note": 'a "quoted" \\ \u00fcn\u00ef value'}}}
class Unstaged(BaseException):
    pass
class Ran:
    def __init__(self, rc, err):
        self.returncode, self.stdout, self.stderr = rc, "", err
def lines(text):
    # readline(buffer, 4096): a line ends at a newline or after 4095 bytes, the rest
    # is read as the next line, and a last line with no newline is never run.
    out, cur = [], b""
    for b in text.encode():
        if len(cur) == 4095:
            out.append(cur); cur = b""
        if b == 10:
            out.append(cur); cur = b""
        else:
            cur += bytes([b])
    if len(cur) == 4095:
        out.append(cur)
    return [l.decode("utf-8", "replace") for l in out]
def split_line(s):
    # Words split on whitespace; one that opens with " or ' runs to the same quote;
    # a backslash takes the next character as it is, inside quotes or not.
    words, cur, state, q = [], "", "ws", ""
    for ch in s:
        if state == "ws":
            if ch.isspace():
                continue
            cur, state = "", "w"
            if ch in "\"'":
                q, state = ch, "q"
                continue
        if state.endswith("\\"):
            cur, state = cur + ch, state[0]
        elif ch == "\\":
            state += "\\"
        elif ch.isspace() if state == "w" else ch == q:
            words.append(cur); state = "ws"
        else:
            cur += ch
    if state != "ws":
        words.append(cur)
    return words
def add(args, err):
    # getopt stops at the first word that is not an option; a word left over is a
    # keychain name to the real tool, and ccd never names one.
    o, i = {}, 0
    while i < len(args) and args[i].startswith("-"):
        if args[i] == "-U":
            o["U"], i = True, i + 1
        elif args[i][1:] in ("a", "s", "w", "X") and i + 1 < len(args):
            o[args[i][1:]], i = args[i + 1], i + 2
        else:
            break
    if i < len(args):
        err.append("Usage: add-generic-password ...")
        return 2
    try:
        data = bytes.fromhex(o["X"]) if "X" in o else o.get("w", "").encode()
    except ValueError:
        err.append("security: Unable to convert password data (-X must specify valid hex digits)")
        return 2
    if REFUSE:
        status = REFUSE.pop(0)
        err.append("security: SecKeychainItemCreateFromContent (<default>): %d" % status)
        return status
    key = (o.get("s"), o.get("a"))
    if key in ITEMS and "U" not in o:
        err.append("security: The specified item already exists in the keychain.")
        return -25299
    ITEMS[key] = data
    return 0
def execute(words, err):
    if not words:
        return 0
    if words[0] != "add-generic-password":
        err.append('security: unknown command "%s"' % words[0])
        return 1
    return add(words[1:], err)
def fake_run(argv, *a, input=None, **k):
    argv = list(argv)
    CALLS.append((argv, input))
    if argv[:1] != ["security"]:
        raise Unstaged("unstaged external call: " + " ".join(argv[:2]))
    err = []
    if argv[1:] == ["-i"]:
        # The exit status is the LAST line's, cut to one byte; every line that
        # failed says so on stderr, whole.
        rc = 0
        for line in lines(input or ""):
            words = split_line(line)
            rc = execute(words, err)
            if rc:
                err.append("%s: returned %d" % (words[0], rc))
    else:
        rc = execute(argv[1:], err)
    return Ran(rc & 0xFF, "".join(e + "\n" for e in err))
m.subprocess = types.SimpleNamespace(run=fake_run)
PYEOF
kcw() { # $1=the case -> the assertion it failed, if any
  rm -rf "$FAKE/kcw"; mkdir -p "$FAKE/kcw/.claude"
  python3 -c "$(cat "$FAKE/kcw-fake.py")$1" "$ROOT/bin/ccd-account" "$FAKE/kcw" 2>&1 | tail -1
}

out=$(kcw '
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert ok and written == ["keychain"], f"the write did not land: failed={failed}"
seen = " ".join(" ".join(argv) for argv, _ in CALLS)
for s in ("AT-kcw-secret", "RT-kcw-secret", "MCP-kcw-secret"):
    for form in (s, s.encode().hex()):
        assert form not in seen, f"{s} is on the command line: {seen[:100]}"
') && ok "no token from the credential reaches argv, as itself or as hex" \
  || bad "the credential is on the command line" "$out"

out=$(kcw '
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert any(stdin for _, stdin in CALLS), f"nothing came in on stdin: {[a[:2] for a, _ in CALLS]}"
got = json.loads(ITEMS[(SVC, ME)].decode("utf-8"))
assert got == BLOB, f"the item holds something else: {got!r}"
') && ok "the write goes in on stdin, and the item decodes to exactly the blob written" \
  || bad "the stdin write" "$out"

out=$(kcw '
REFUSE.append(-25308)      # errSecInteractionNotAllowed: a locked keychain
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert not ok and failed == ["keychain"] and written == [], f"reported {ok, failed, written}"
') && ok "a keychain that refuses the write inside security -i is a failed write" \
  || bad "refused write" "$out"

# The exit status carries the status modulo 256, and -67072 (errSecCSUnimplemented)
# is a multiple of it: a refusal that exits 0. Only the "returned" line says so.
out=$(kcw '
REFUSE.append(-67072)
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert not ok and failed == ["keychain"] and written == [], f"reported {ok, failed, written}"
') && ok "...even when the refusal's status comes out as exit 0" \
  || bad "a refusal that exits 0" "$out"

# Past what one interactive line holds, argv is the only way left, as it is for
# Claude Code. An mcpOAuth with enough servers is all it takes.
out=$(kcw '
BLOB["mcpOAuth"] = {"s%d" % i: {"accessToken": "x" * 40} for i in range(50)}
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert ok, f"the write failed: {failed}"
assert [a[1] for a, _ in CALLS] == ["add-generic-password"], f"calls: {[a[:2] for a, _ in CALLS]}"
got = json.loads(ITEMS[(SVC, ME)].decode("utf-8"))
assert got == BLOB, "the item holds something else"
') && ok "a credential too long for one line falls back to argv, and still lands whole" \
  || bad "oversized write" "$out"

# A quote, backslash or newline in the account would change the -a word or cut the
# command short, writing another account's item or one with no password.
out=$(kcw '
for name in ("ccd\"test", "ccd\\test", "ccd\ntest"):
    os.environ["USER"] = name
    ok, failed, written = m.live_write(BLOB, ["keychain"])
    assert not ok and failed == ["keychain"], f"reported {ok, failed} for {name!r}"
assert CALLS == [] and ITEMS == {(SVC, ME): OLD}, f"security ran: {[a[:2] for a, _ in CALLS]}"
') && ok "an account name the line cannot carry is refused before security runs" \
  || bad "unsafe account name" "$out"
rm -rf "$FAKE/kcw" "$FAKE/kcw-fake.py"
unset -f kcw

finish
