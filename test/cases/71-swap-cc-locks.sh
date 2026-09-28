#!/usr/bin/env bash
# 71-swap-cc-locks — a swap and Claude Code's own credential locks.
# Sections: §37, §42
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "37. a swap waits for Claude Code's own credential locks"
# Claude Code refreshes a token under locks of its own — directories, in this
# order: <cfg>/.oauth_refresh.lock, <realpath(cfg)>.lock, and <cfg>/.storage-write.lock
# around the save — and the save is a compare-and-swap: if the stored refresh token
# is no longer the one it spent, it writes nothing. A swap that banks the outgoing
# credential mid-refresh banks the token the server has just retired, installs the
# next account, and Claude Code then throws the rotated one away: the account comes
# back needing /login (#67). Every case has a HOME of its own, where a is signed in
# (by the pointer) and b is a spare with a fresh reading.
cl_home() { # $1=case -> its HOME
  local h="$FAKE/cl-$1"
  rm -rf "$h"; mkdir -p "$h/.claude/ccd/accounts" "$h/.claude/ccd/readings"
  python3 - "$h" <<'PY'
import json, os, sys, time
h = sys.argv[1]
cfg = os.path.join(h, ".claude")
ms = int(time.time() * 1000)
def put(p, obj):
    with open(p, "w") as f:
        f.write(obj if isinstance(obj, str) else json.dumps(obj))
    os.chmod(p, 0o600)
def oauth(tag):
    return {"accessToken": "AT-" + tag, "refreshToken": "RT-" + tag,
            "expiresAt": ms + 3600000, "subscriptionType": "max"}
for i, n in enumerate(("a", "b")):
    put(os.path.join(cfg, "ccd", "accounts", n + ".json"), {
        "name": n, "account_uuid": "uuid-" + n, "priority": i + 1, "storage": "file",
        "claudeAiOauth": oauth(n + "-stored"), "added_at": ms // 1000})
put(os.path.join(cfg, "ccd", "accounts", ".active"), "a\n")
put(os.path.join(cfg, "ccd", "accounts", ".active-at"), f"{ms}\n")
put(os.path.join(cfg, ".credentials.json"), {"claudeAiOauth": oauth("a-live")})
put(os.path.join(cfg, "ccd", "readings", "b.json"), {
    "status": "ok", "checked_at": ms // 1000, "uuid": "uuid-b",
    "five_hour_percent": 10, "seven_day_percent": 10})
PY
  printf '%s' "$h"
}
# Its three locks, placed as a stand-in would leave them: $2..$4 are the ages in
# seconds of refresh, legacy and write ("-" for none; negative is the future).
cl_locks() { # $1=HOME $2 $3 $4
  python3 - "$@" <<'PY'
import os, sys, time
cfg = os.path.join(sys.argv[1], ".claude")
paths = (os.path.join(cfg, ".oauth_refresh.lock"), os.path.realpath(cfg) + ".lock",
         os.path.join(cfg, ".storage-write.lock"))
now = time.time()
for p, age in zip(paths, sys.argv[2:]):
    if age != "-":
        os.mkdir(p)
        os.utime(p, (now - float(age), now - float(age)))
PY
}
# ccd-account with a HOME and a hard limit: prints "<exit code|timeout> <seconds>",
# and leaves its stderr in $HOME/.err.
cl_run() { # $1=HOME $2=seconds allowed, then the arguments
  python3 - "$ROOT/bin/ccd-account" "$@" <<'PY'
import os, subprocess, sys, time
acct, home, limit, args = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4:]
t = time.time()
with open(os.path.join(home, ".err"), "w") as err:
    try:
        rc = subprocess.run([acct, "--no-color"] + args, env=dict(os.environ, HOME=home),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=err, timeout=limit).returncode
    except subprocess.TimeoutExpired:
        rc = "timeout"
print(rc, round(time.time() - t, 1))
PY
}
# Assertions about a HOME's end state -> the one that failed, if any.
cl_py() { # $1=HOME $2=python; RC and SECS are cl_run's answer
  RC="${rc:-}" SECS="${secs:-0}" python3 -c '
import json, os, sys, time
H = sys.argv[1]
RC, SECS = os.environ["RC"], float(os.environ["SECS"])
cfg = os.path.join(H, ".claude")
REFRESH, LEGACY = os.path.join(cfg, ".oauth_refresh.lock"), os.path.realpath(cfg) + ".lock"
WRITE = os.path.join(cfg, ".storage-write.lock")
def rt(n):
    return json.load(open(os.path.join(cfg, "ccd", "accounts", n + ".json")))["claudeAiOauth"]["refreshToken"]
def live():
    return json.load(open(os.path.join(cfg, ".credentials.json")))["claudeAiOauth"]["accessToken"]
def err():
    return open(os.path.join(H, ".err")).read().replace("\n", " ")
def untouched():
    assert live() == "AT-a-live", f"the live store moved to {live()}"
    a = rt("a")
    assert a == "RT-a-stored", f"a was banked: {a}"
    assert not os.path.exists(os.path.join(cfg, "ccd", "store-split")), "a stop was recorded"
def age(p):
    return time.time() - os.lstat(p).st_mtime
'"$2" "$1" 2>&1 | tail -1
}
# In-process, for what only a spy can see: every mkdir of a lock, in order, with
# the locks that already existed at that moment.
CL_PRE='
import importlib.machinery, importlib.util, json, os, sys, threading, time
H = os.environ["HOME"] = sys.argv[2]
loader = importlib.machinery.SourceFileLoader("ccdcl", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
def canon(p):              # one spelling per place: the legacy lock is named by a realpath
    return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))
def cc_locks(cfg):
    return [canon(os.path.join(cfg, ".oauth_refresh.lock")), canon(os.path.realpath(cfg) + ".lock"),
            canon(os.path.join(cfg, ".storage-write.lock"))]
DEFAULT = cc_locks(os.path.join(H, ".claude"))
TOOK, TRIED = [], []
real_mkdir = os.mkdir
def spy(p, *a, **k):
    c = canon(os.fspath(p))
    lock = c.endswith(".lock")
    if lock:
        TRIED.append((c, [q for q in DEFAULT if os.path.isdir(q)]))
    real_mkdir(p, *a, **k)
    if lock:
        TOOK.append(c)
os.mkdir = spy
def live():
    return json.load(open(m.credentials_file()))["claudeAiOauth"]["accessToken"]
'

# The regression. A stand-in Claude Code is mid-refresh of a: it holds the refresh
# locks, and when its request answers it saves a′ under the write lock — only if the
# store still holds the token it spent, as Claude Code does. `use b` arrives while it
# waits on the server.
H=$(cl_home race)
cat > "$H/.standin.py" <<'PY'
import json, os, sys, time
h = sys.argv[1]
cfg = os.path.join(h, ".claude")
refresh, legacy = os.path.join(cfg, ".oauth_refresh.lock"), os.path.realpath(cfg) + ".lock"
write, creds = os.path.join(cfg, ".storage-write.lock"), os.path.join(cfg, ".credentials.json")
os.mkdir(refresh); os.mkdir(legacy)
open(os.path.join(h, ".cc-holds"), "w").close()
time.sleep(1.5)                                  # the server rotates a's refresh token
end = time.time() + 10
while True:
    try:
        os.mkdir(write); break
    except FileExistsError:
        if time.time() > end:
            sys.exit("the write lock never came free")
        time.sleep(0.05)
blob = json.load(open(creds))
if blob["claudeAiOauth"]["refreshToken"] == "RT-a-live":
    blob["claudeAiOauth"] = {"accessToken": "AT-a-rotated", "refreshToken": "RT-a-rotated",
                             "expiresAt": int(time.time() * 1000) + 3600000}
    with open(creds + ".tmp", "w") as f:
        json.dump(blob, f)
    os.replace(creds + ".tmp", creds)
    print("saved")
else:
    print("adopted")                             # somebody else's login is there: keep it
os.rmdir(write); os.rmdir(legacy); os.rmdir(refresh)
PY
python3 "$H/.standin.py" "$H" > "$H/.cc-out" 2>&1 & CC=$!
n=0; while [ ! -e "$H/.cc-holds" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
read -r rc secs <<< "$(cl_run "$H" 15 use b --force)"
wait "$CC" 2>/dev/null
out=$(cl_py "$H" '
assert live() == "AT-b-stored", f"the swap did not happen: {err()[:160]}"
a = rt("a")
assert a == "RT-a-rotated", f"a was banked as {a}; the rotated token was thrown away"
left = [p for p in (REFRESH, LEGACY, WRITE) if os.path.lexists(p)]
assert not left, f"left behind: {left}"
') && ok "a refresh in flight finishes first, and the swap banks the token it produced" \
  || bad "banked a spent token" "$out (stand-in: $(cat "$H/.cc-out"))"

# The order is Claude Code's, and nothing is held while the refresh lock is awaited:
# a write lock held there would make Claude Code's own save fail, and lose a′.
H=$(cl_home order)
out=$(python3 -c "$CL_PRE"'
R, L, W = DEFAULT
real_mkdir(R)                                    # Claude Code is mid-refresh
def done():
    time.sleep(0.5)
    os.rmdir(R)
threading.Thread(target=done).start()
m.swap_to("b", force=True)
assert live() == "AT-b-stored", "the swap did not happen"
names = {R: "refresh", L: "legacy", W: "write"}
assert [names.get(c, c) for c in TOOK] == ["refresh", "legacy", "write"], \
    f"took {[names.get(c, c) for c in TOOK]}"
waits = [held for c, held in TRIED if c == R]
assert len(waits) > 1, f"never waited on the refresh lock: {TRIED}"
assert not [h for h in waits if L in h or W in h], "held a lock while waiting on the refresh lock"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "the locks are taken in Claude Code's order, none held while the refresh lock is awaited" \
  || bad "lock order" "$out"

# A lock is abandoned once older than its window: 60s for the refresh pair, 15s for
# the write lock. One taken over is released like any other.
H=$(cl_home stale)
cl_locks "$H" 90 90 20
read -r rc secs <<< "$(cl_run "$H" 15 use b --force)"
out=$(cl_py "$H" '
assert live() == "AT-b-stored", f"the swap did not happen: {err()[:160]}"
left = [p for p in (REFRESH, LEGACY, WRITE) if os.path.lexists(p)]
assert not left, f"left behind: {left}"
') && ok "stale locks are taken over, by each one's own window, and the swap proceeds" \
  || bad "stale locks" "$out"

# Held past the caller's deadline: nothing is written and the attempt fails, in time
# for the hook's retry. A 20s-old refresh lock is fresh by its own 60s window.
H=$(cl_home held)
cl_locks "$H" 20 - -
read -r rc secs <<< "$(cl_run "$H" 10 swap --from a --window x --no-probe --deadline 1)"
out=$(cl_py "$H" '
assert RC == "4", f"exit {RC} after {SECS}s: {err()[:160]}"
assert SECS <= 4, f"took {SECS}s on a 1s deadline"
untouched()
assert os.path.isdir(REFRESH) and age(REFRESH) > 15, "the held lock was removed or touched"
assert not os.path.lexists(LEGACY) and not os.path.lexists(WRITE), "a lock was left behind"
assert ".oauth_refresh.lock" in err(), f"the reason names no lock: {err()[:160]}"
') && ok "a lock held past the deadline fails the attempt in time, having written nothing" \
  || bad "deadline" "$out"

# A failure after the locks were taken still releases every one of them, and the
# write it failed was made under all three.
H=$(cl_home fail)
out=$(python3 -c "$CL_PRE"'
under = []
real_write = m.write_json
def failing(p, obj, mode=0o600):
    if str(p) == m.credentials_file():
        under.append([os.path.isdir(q) for q in DEFAULT])
        raise OSError("disk full")
    return real_write(p, obj, mode)
m.write_json = failing
try:
    m.swap_to("b", force=True)
    raise AssertionError("a failed write reported success")
except SystemExit:
    pass
assert under == [[True, True, True]], f"the write was made under {under}"
left = [q for q in DEFAULT if os.path.lexists(q)]
assert not left, f"left behind: {left}"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "the live store is written under all three, and they are released when it fails" \
  || bad "locks after a failure" "$out"

# Claude Code's own lock bugs are not ccd's to repair. A lock dated in the future
# never goes stale for Claude Code (anthropics/claude-code#95739), so it is held
# here too; a lock left as a FILE (#95425) is nobody's lock, and the swap refuses at
# once rather than wait out a lock that cannot be taken. Neither is deleted.
H=$(cl_home future)
cl_locks "$H" -3600 - -
read -r rc secs <<< "$(cl_run "$H" 10 swap --from a --window x --no-probe --deadline 1)"
out=$(cl_py "$H" '
assert RC == "4", f"exit {RC} after {SECS}s: {err()[:160]}"
untouched()
assert os.path.isdir(REFRESH) and age(REFRESH) < -3000, "the future-dated lock was removed or touched"
assert ".oauth_refresh.lock" in err() and "future" in err(), f"the reason: {err()[:200]}"
') && ok "a lock dated in the future is held, not deleted, and the reason says so" \
  || bad "future-dated lock" "$out"

H=$(cl_home file)
printf 'not a lock' > "$H/.claude/.storage-write.lock"
read -r rc secs <<< "$(cl_run "$H" 15 use b --force)"
out=$(cl_py "$H" '
assert RC not in ("0", "timeout"), f"exit {RC}"
assert SECS < 4, f"waited {SECS}s on a lock that can never be taken"
untouched()
assert open(WRITE).read() == "not a lock", "the file was changed or removed"
assert not os.path.lexists(REFRESH) and not os.path.lexists(LEGACY), "a lock was left behind"
assert ".storage-write.lock" in err(), f"the reason names no path: {err()[:160]}"
') && ok "a lock left as a file refuses the swap at once, naming it, and stays as it was" \
  || bad "lock left as a file" "$out"

# The locks live where Claude Code keeps its credentials:
# CLAUDE_SECURESTORAGE_CONFIG_DIR, then CLAUDE_CONFIG_DIR, then ~/.claude — and the
# legacy one is named after the realpath. A directory that does not exist holds no
# store to guard, and ccd does not create it.
H=$(cl_home dirs)
mkdir -p "$H/real" "$H/sec"; ln -s "$H/real" "$H/link"
out=$(python3 -c "$CL_PRE"'
def case(env, want):
    for k in ("CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"):
        os.environ.pop(k, None)
    os.environ.update(env)
    with open(m.credentials_file(), "w") as f:
        json.dump({"claudeAiOauth": {"accessToken": "AT-a-live", "refreshToken": "RT-a-live"}}, f)
    with open(os.path.join(m.ACCOUNTS_DIR, ".active"), "w") as f:
        f.write("a\n")
    del TOOK[:]
    m.swap_to("b", force=True)
    assert live() == "AT-b-stored", f"{env}: the swap did not happen"
    if want is not None:
        assert TOOK == want, f"{env}: took {TOOK}, not {want}"
    left = [q for q in set(TOOK) | set(want or []) if os.path.lexists(q)]
    assert not left, f"{env}: left behind {left}"
case({"CLAUDE_CONFIG_DIR": H + "/link"}, cc_locks(H + "/link"))
assert canon(os.path.realpath(H + "/link") + ".lock") in TOOK, "the legacy lock ignored the realpath"
case({"CLAUDE_CONFIG_DIR": H + "/real", "CLAUDE_SECURESTORAGE_CONFIG_DIR": H + "/sec"}, cc_locks(H + "/sec"))
case({"CLAUDE_CONFIG_DIR": H + "/real", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""}, DEFAULT)
case({"CLAUDE_CONFIG_DIR": H + "/real", "CLAUDE_SECURESTORAGE_CONFIG_DIR": H + "/nowhere"}, None)
assert not os.path.lexists(H + "/nowhere"), "created a config directory"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "the locks follow CLAUDE_SECURESTORAGE_CONFIG_DIR, then CLAUDE_CONFIG_DIR, as Claude Code's do" \
  || bad "lock location" "$out"
rm -rf "$FAKE"/cl-*
# cl_home, cl_locks, cl_run, cl_py and CL_PRE stay defined: §42 asks the other
# half of the same question — not whether the locks are taken, but whether they
# are still held when the writing starts — and it stages it from here.

# ── setup reports what it verified, not what it attempted ───────────────────

head_ "42. a swap stops when its hold on Claude Code's locks lapses"
# Taking Claude Code's locks (§37) is not keeping them. A process that stalls past
# a stale window — a sleeping laptop, a suspended hook, a keychain call that takes
# its full 15s — is overtaken: Claude Code makes the lock its own and starts
# refreshing the account the swap has already read. Installing from that read is
# #67 again through the narrow door (#96): Claude Code's compare-and-swap discards
# the token it just minted, and the bank keeps the retired one. Acquiring was
# checked; KEEPING it was not, and only the writer can act on the answer — so it
# asks before it banks and before every live-store write, and the deadline bounds
# every acquisition, not only the ones that had to wait.
#
# §37's fixtures, and three shared helpers: what die() said, how a stand-in takes a
# lock over, and the end state of a HOME where a swap must have written nothing.
CL_LEASE="$CL_PRE"'
import contextlib, io
def dies(fn):                    # what die() said, or an assertion when it did not
    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            fn()
    except SystemExit:
        return buf.getvalue().replace("\n", " ")
    raise AssertionError("the swap wrote with a lock it had lost: "
                         + buf.getvalue().replace("\n", " ")[:160])
def taken(p):                    # a stand-in Claude Code takes this lock over
    os.rmdir(p); real_mkdir(p)
    # Dated as its own holder dates it — proper-lockfile writes an mtime about a
    # second ahead — and a real takeover only happens once the lock has gone stale,
    # so the new one is at least a window newer than the mtime ccd recorded.
    # Without that the staging is invisible on a filesystem whose directory
    # timestamps are coarse and whose inodes are reused: on the container overlay
    # an instant rmdir+mkdir comes back byte-identical, and no holder anywhere
    # could tell the difference.
    t = time.time() + 1
    os.utime(p, (t, t))
def banked(n):
    p = os.path.join(m.ACCOUNTS_DIR, n + ".json")
    return json.load(open(p))["claudeAiOauth"]["refreshToken"]
def untouched():
    assert live() == "AT-a-live", f"the live store moved to {live()}"
    a = banked("a")
    assert a == "RT-a-stored", f"a was banked as {a}"
    assert not os.path.exists(m.STORE_SPLIT), "a stop was recorded"
'

# The lease lapses between the read and the bank: a stand-in Claude Code takes the
# write lock over, as it may once this process has stalled past the 15s window.
# What ccd read while the lock was its own is now a snapshot of a credential
# somebody else is rotating — banking it retires the spare.
H=$(cl_home lease)
out=$(python3 -c "$CL_LEASE"'
R, L, W = DEFAULT
real_read = m.live_read
def read_then_taken():
    got = real_read()
    taken(W)                         # Claude Code takes the write lock over
    return got
m.live_read = read_then_taken
msg = dies(lambda: m.swap_to("b", force=True))
untouched()
assert ".storage-write.lock" in msg and "took it over" in msg, f"the reason: {msg[:200]}"
assert not os.path.lexists(R) and not os.path.lexists(L), "a lock of ours was left behind"
assert os.path.isdir(W), "removed a lock that was no longer ours"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "a lease lost before the bank writes nothing, and the reason names the lock" \
  || bad "lost lease before the bank" "$out"

# And asked again after it, because the install is a write of its own and the
# window is still open. Here the lock goes as the bank lands: the new credential
# must not be installed — and the stop the swap wrote ahead of itself must come
# back down, because nothing was touched, the stores still agree, and a stop
# standing over them would block every bank and swap after this one.
H=$(cl_home after)
out=$(python3 -c "$CL_LEASE"'
R, L, W = DEFAULT
real_save = m.account_save
def save_then_taken(name, obj):
    real_save(name, obj)
    taken(W)                         # the bank landed, and the lock is no longer ours
m.account_save = save_then_taken
msg = dies(lambda: m.swap_to("b", force=True))
assert live() == "AT-a-live", f"the live store moved to {live()}"
a = banked("a")
assert a == "RT-a-live", f"the bank never happened, so this proves nothing: {a}"
who = open(m.ACTIVE_FILE).read().strip()
assert who == "a", f"the pointer moved to {who}"
assert not os.path.exists(m.STORE_SPLIT), "a stop was left over stores nothing touched"
assert ".storage-write.lock" in msg and "took it over" in msg, f"the reason: {msg[:200]}"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "a lease lost between the bank and the install installs nothing, and leaves no stop" \
  || bad "lost lease before the install" "$out"

# A refresh that FAILS ends the lease as surely as a takeover: a lock whose mtime
# we cannot keep current goes stale under us and is taken over at somebody else's
# leisure. Swallowing the error left the writer the only one not told.
H=$(cl_home touch)
out=$(python3 -c "$CL_LEASE"'
m.LOCK_TOUCH = 0.05                  # the heartbeat, dialled down for the test
def refused(*a, **k):
    raise OSError(1, "Operation not permitted")
os.utime = refused
real_read = m.live_read
def slow_read():
    got = real_read()
    time.sleep(0.4)                  # a stall, long enough for several refreshes
    return got
m.live_read = slow_read
msg = dies(lambda: m.swap_to("b", force=True))
untouched()
assert ".lock" in msg and "keep it fresh" in msg, f"the reason: {msg[:200]}"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "a lock the heartbeat cannot refresh is a lock the writer stops for" \
  || bad "a swallowed utime failure" "$out"

# Every live-store write is asked, not only the install. `use a` while a is signed
# in installs nothing — it puts the two stores back in step — and that write lands
# on the same store Claude Code refreshes. Here the lock goes after the bank, so
# the evening write is the first thing the check has to stop.
H=$(cl_home even)
out=$(python3 -c "$CL_LEASE"'
R, L, W = DEFAULT
wrote = []
real_live_write = m.live_write
def spy(blob, sources):
    wrote.append(sorted(sources))
    return real_live_write(blob, sources)
m.live_write = spy
real_save = m.account_save
def save_then_taken(name, obj):
    real_save(name, obj)
    taken(W)                         # the bank landed, and the lock is no longer ours
m.account_save = save_then_taken
msg = dies(lambda: m.swap_to("a", force=True))
assert not wrote, f"evened the stores without the lock: {wrote}"
assert ".storage-write.lock" in msg and "took it over" in msg, f"the reason: {msg[:200]}"
assert not os.path.exists(m.STORE_SPLIT), "a stop was recorded"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "the same-account evening write stops on a lapsed lease too" \
  || bad "evening write without the lock" "$out"

# The rollback is a write as well. An install that lands on one store and not the
# other is put back — but only while the lock that makes putting it back safe is
# still ours. Once it is not, the backend that took the new credential keeps it and
# the write-ahead stop stands over it: a restore made without the lock is the #67
# write over again, in the other direction.
H=$(cl_home undo)
out=$(python3 -c "$CL_LEASE"'
R, L, W = DEFAULT
chain = {"claudeAiOauth": {"accessToken": "AT-a-live", "refreshToken": "RT-a-live",
                           "expiresAt": int(time.time() * 1000) + 3600000}}
m.use_keychain = lambda: True
m._keychain_read = lambda: json.loads(json.dumps(chain))
def kwrite(blob):
    chain.clear(); chain.update(json.loads(json.dumps(blob))); return True
m._keychain_write = kwrite
real_write_json = m.write_json
def failing(p, obj, mode=0o600):
    if str(p) == m.credentials_file():
        taken(W)                     # half installed, and the lock goes right there
        raise OSError("disk full")
    return real_write_json(p, obj, mode)
m.write_json = failing
msg = dies(lambda: m.swap_to("b", force=True))
at = chain["claudeAiOauth"]["accessToken"]
assert at == "AT-b-stored", f"the keychain was written back without the lock: {at}"
rec = json.load(open(m.STORE_SPLIT))
assert "keychain" in str(rec.get("detail")), f"the stop does not name what is stuck: {rec}"
assert "did not restore" in msg and "took it over" in msg, f"the reason: {msg[:200]}"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "a rollback is not written without the lock, and the stop stands over what is stuck" \
  || bad "rollback without the lock" "$out"

# The deadline bounds every acquisition path, not only the ones that had to wait.
# A lock standing free — or released a moment after the budget ran out — is still
# one this swap has no time left to use, and mkdir succeeding was never checked
# against the clock, so the write started anyway.
H=$(cl_home late)
read -r rc secs <<< "$(cl_run "$H" 10 swap --from a --window x --no-probe --deadline 0)"
out=$(cl_py "$H" '
assert RC == "4", f"exit {RC} after {SECS}s: {err()[:200]}"
untouched()
assert ".oauth_refresh.lock" in err(), f"the reason names no lock: {err()[:200]}"
left = [p for p in (REFRESH, LEGACY, WRITE) if os.path.lexists(p)]
assert not left, f"took a lock with no budget left: {left}"
') && ok "no budget left takes no lock, free or not, and writes nothing" \
  || bad "deadline on a free lock" "$out"

# And where the lock was there to be taken OVER. A stale lock is Claude Code's
# abandoned one, but removing it and taking its place is still a write beginning
# after the caller stopped waiting — that branch looped straight past the check.
H=$(cl_home stalelate)
cl_locks "$H" 90 90 20
read -r rc secs <<< "$(cl_run "$H" 10 swap --from a --window x --no-probe --deadline 0)"
out=$(cl_py "$H" '
assert RC == "4", f"exit {RC} after {SECS}s: {err()[:200]}"
untouched()
assert os.path.isdir(REFRESH), "took over a stale lock with no budget left"
') && ok "the stale-takeover path respects the deadline as well" \
  || bad "deadline on a stale takeover" "$out"

# ccd's own store lock got a floor of its own on top: half a second in which a
# swap whose budget was already spent could still start writing.
H=$(cl_home floor)
out=$(python3 -c "$CL_LEASE"'
given = []
real_lock = m.Lock
class Spy(real_lock):
    def __init__(self, path, timeout=m.LOCK_TIMEOUT, *a, **k):
        if path == m.LOCK_FILE:
            given.append(timeout)
        real_lock.__init__(self, path, timeout, *a, **k)
m.Lock = Spy
dies(lambda: m.swap_to("b", force=True, deadline=time.time() - 1))
untouched()
assert given and given[0] <= 0, f"the store lock was given {given[0]}s past the deadline"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "an expired budget buys the store lock no extra half second" \
  || bad "store lock floor" "$out"

# The guard: locks free, budget intact, and the swap still does all of its work.
H=$(cl_home whole)
read -r rc secs <<< "$(cl_run "$H" 15 use b --force)"
out=$(cl_py "$H" '
assert RC == "0", f"exit {RC}: {err()[:200]}"
assert live() == "AT-b-stored", f"the swap did not happen: {err()[:200]}"
a = rt("a")
assert a == "RT-a-live", f"the outgoing credential was not banked: {a}"
who = open(os.path.join(cfg, "ccd", "accounts", ".active")).read().strip()
assert who == "b", f"the pointer says {who}"
assert not os.path.exists(os.path.join(cfg, "ccd", "store-split")), "a stop was recorded"
left = [p for p in (REFRESH, LEGACY, WRITE) if os.path.lexists(p)]
assert not left, f"left behind: {left}"
') && ok "a swap that keeps its lease banks, installs, moves the pointer and lets go" \
  || bad "a whole swap" "$out"
rm -rf "$FAKE"/cl-*
unset -f cl_home cl_locks cl_run cl_py
unset CL_PRE CL_LEASE

# ── a launcher is installed whole, or not at all ───────────────────────────

finish
