#!/usr/bin/env bash
# Portable smoke test — runs the real scripts against a throwaway HOME.
# Intended to run on both macOS and Linux (see test/docker.sh for the Linux run).
# No network, no real key, no writes outside $HOME.
#
# Sourced first by every file under test/cases/ — before anything else, so a case
# run on its own cannot reach the real HOME, the real ~/.claude or the keychain.
# Below the `Shared machinery` rule are the helpers and fixtures one section built
# and another used; each names the case files that need it (#76).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE" 2>/dev/null || true' EXIT
export HOME="$FAKE"
# CLAUDE_CONFIG_DIR outranks HOME everywhere ccd looks, so an inherited one would
# send fixture writes to the developer's real configuration. Cases that test it
# set it themselves. CLAUDE_SECURESTORAGE_CONFIG_DIR outranks both for where
# Claude Code keeps its credential locks, which a swap takes. ZDOTDIR outranks it
# for the zsh startup file `ccd setup` edits: where a developer keeps zsh dotfiles
# outside $HOME, an inherited one sent the fixture's PATH line to their real
# ~/.zshrc (#100). §18d is the only case with any use for it, and sets it itself.
# CCD_PROVIDERS_DIR, and CLAUDE_PROVIDERS_DIR behind it, outrank HOME for the
# directory keys.env lives in, so on a machine that sets either one §7's `ccd key`
# overwrote the developer's REAL OpenRouter key — and every run bootstrapped config
# files into their directory (#109).
unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR ZDOTDIR \
      CCD_PROVIDERS_DIR CLAUDE_PROVIDERS_DIR
# The suite imports bin/ccd-account as a module; Python would otherwise leave its
# bytecode in bin/, and one such file shipped in v0.8.0 (#77).
export PYTHONDONTWRITEBYTECODE=1

# One reading per account, one file each — the layout bin/ccd-account's reading_save
# writes. Fixtures still think of "the readings" as one dict, so these carry a dict
# to and from that layout; nothing in the product reads one.
RQD="$HOME/.claude/ccd/readings"
rq_put() { # stdin: {"<account>": {row}, ...} — REPLACES every reading on file
  rm -rf "$RQD"; mkdir -p "$RQD"; chmod 700 "$RQD"
  python3 -c '
import json, os, sys
for name, row in json.load(sys.stdin).items():
    p = os.path.join(sys.argv[1], name + ".json")
    with open(p, "w") as f:
        json.dump(row, f)
    os.chmod(p, 0o600)
    # A reading is written when it is taken, so its file is as old as it is. Fixtures
    # that seed an OLD reading would otherwise seed a file that looks brand new.
    ts = row.get("checked_at") if isinstance(row, dict) else None
    if isinstance(ts, (int, float)):
        os.utime(p, (ts, ts))' "$RQD"
}
rq_gather() { # every reading as one dict, in a temp file; prints its path
  python3 -c '
import glob, json, os, sys, tempfile
d = {}
for p in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try: d[os.path.basename(p)[:-5]] = json.load(open(p))
    except Exception: pass
fd, t = tempfile.mkstemp(prefix="rq.", suffix=".json", dir=os.environ["HOME"])
with os.fdopen(fd, "w") as f:
    json.dump(d, f)
print(t)' "$RQD"
}
rq_scatter() { # $1=that file, possibly edited → back to one file per account
  [ -f "$1" ] || return 0
  rq_put < "$1"; rm -f "$1"
}
# The suite must behave identically when launched from inside a ccd session:
# CCD_ACTIVE would suppress quota-guard warnings and flip the statusline branch.
# CCD_HANDOFF_STATE is worse than a flipped branch — it names the file quota-guard
# arms and deletes, and a supervised session exports one under the REAL
# ~/.claude/ccd, so a fixture hook run could consume the handoff of the session
# running the tests. CCD_HANDOFF is the token that unlocks that path.
unset CCD_ACTIVE CCD_HANDOFF CCD_HANDOFF_STATE \
      ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL \
      ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL \
      ANTHROPIC_CUSTOM_MODEL_OPTION ANTHROPIC_CUSTOM_MODEL_OPTION_NAME \
      CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL \
      CLAUDE_CODE_AUTO_COMPACT_WINDOW 2>/dev/null || true

# The handoff tests exercise code whose whole job is to SIGHUP a claude process.
# Run from inside a real Claude Code session — which is exactly how a developer
# runs this suite — an unset or stale CLAUDE_PID lets the ancestor walk find the
# SESSION RUNNING THE TESTS and kill it. Sever the link to any real session:
# the tests always pass an explicit CLAUDE_PID for their own stand-in process.
unset CLAUDE_PID CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# Every credential operation stays inside $HOME. The keychain is the one thing
# ccd touches outside it, so without this the suite reads (and could overwrite)
# the developer's real Claude login on macOS. It belongs at the top: `ccd doctor`
# lists accounts long before the multi-account sections start.
export CCD_CREDENTIALS_BACKEND=file

# A key exported in the developer's own shell is not this suite's key. It reaches
# have_key() ahead of the throwaway HOME, and the assertions that a missing key
# must stop a handoff then measure the developer's environment instead of the
# code. Those passed in CI and failed only on the machine of whoever set a key.
unset OPENROUTER_API_KEY 2>/dev/null || true

# §41 re-runs THIS file with the environment a developer's shell can carry — a
# ZDOTDIR and XDG_* naming directories outside $HOME — and reports where a
# `setup --yes` landed. It has to be this file and not a copy of the unsets above:
# a copy would go on passing after one of them was deleted. Any line printed here
# is a stray; the only expected one is `wrote .zshrc`.
if [ "${1:-}" = "--setup-canary" ]; then
  # A foreign `claude` first on PATH, so the run reaches the startup file instead
  # of reporting that a shim already leads — which it would if the developer has
  # one installed, leaving the canary clean and proving nothing.
  mkdir -p "$FAKE/bin"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE/bin/claude"; chmod +x "$FAKE/bin/claude"
  SHELL=/bin/zsh PATH="$FAKE/bin:$PATH" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
  # setup's own record of every startup file it edited — the receipt that this run
  # really wrote a PATH line, and the only place the path it chose survives.
  if [ -f "$HOME/.claude/ccd/auto-path" ]; then
    while read -r t; do
      case "$t" in "$HOME"/*) printf 'wrote %s\n' "${t#"$HOME"/}" ;;
                   *)         printf 'OUTSIDE %s\n' "$t" ;; esac
    done < "$HOME/.claude/ccd/auto-path"
  fi
  ls -A "${2:?canary directory}" 2>/dev/null | sed 's/^/CANARY /'
  # Every variable the preamble severs because it outranks these fixtures. The
  # canary catches the ones `setup` itself resolves; this catches the rest, so
  # deleting any one of those unsets cannot go unnoticed.
  for v in ZDOTDIR CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR \
           CCD_PROVIDERS_DIR CLAUDE_PROVIDERS_DIR \
           CCD_HANDOFF CCD_HANDOFF_STATE; do
    [ -z "${!v-}" ] || printf 'SURVIVED %s\n' "$v"
  done
  exit 0
fi

pass=0 fail=0

ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
head_() { printf '\n%s\n' "$1"; }

# The paid hop bills, so it is gated on an opt-in that `ccd setup --auto` records,
# while the free hop between subscriptions is not gated at all. Most sections here
# are about thresholds, corroboration and signalling rather than about consent, so
# they run on a machine where that question is already settled. The sections that
# ARE about the gate turn it off explicitly and say so.
paid_optin_on()  { : > "$HOME/.claude/ccd/paid-handoff"; }
paid_optin_off() { rm -f "$HOME/.claude/ccd/paid-handoff"; }

# A fake `node` so we don't need a real one: it prints the JSON we stage.
mkdir -p "$FAKE/fakebin"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
cat "$HOME/.stub-usage.json"
EOF
chmod +x "$FAKE/fakebin/node"
export PATH="$FAKE/fakebin:$PATH"
# No case may reach the network, and "there is no fake on PATH" is how one does:
# the real curl is right behind it. So a REJECTING curl is always there, and a
# section that needs an answer stages its own over it and puts this one back.
curl_reject() {
  printf '#!/bin/sh\necho "$*" >> "$HOME/.unstaged-curl"\necho "curl: unstaged network call in the test suite" >&2\nexit 7\n' \
    > "$FAKE/fakebin/curl"
  chmod +x "$FAKE/fakebin/curl"
}
curl_reject
# A stand-in for the Anthropic usage endpoint. ccd-account reaches it with urllib
# rather than curl, so the double goes in as a sitecustomize module on PYTHONPATH.
# It is inert unless CCD_FAKE_USAGE names a staged response, which is what keeps
# it out of the way of every other python3 in this suite and keeps production
# free of any test-only branch.
mkdir -p "$FAKE/pysite"
cat > "$FAKE/pysite/sitecustomize.py" <<'SCEOF'
import json, os
_stage = os.environ.get("CCD_FAKE_USAGE")
if _stage:
    import urllib.error, urllib.request

    def _urlopen(req, timeout=None, *a, **k):
        # Count attempts, not successes: the backoff assertion needs to see the
        # call that failed. The timeout each call was given rides along: a budget
        # that never reaches the socket is a budget that bounds nothing.
        log = os.environ.get("CCD_FAKE_USAGE_LOG")
        if log:
            with open(log, "a") as f:
                f.write(f"call\t{timeout}\n")
        with open(_stage) as f:
            staged = json.load(f)
        # One answer for everybody is not enough any more: the wall re-reads the
        # live account and then the swap probes a spare, in the same run. An answer
        # staged for a bearer token wins over the default one.
        _auth = ""
        try:
            _auth = (req.get_header("Authorization") or "").replace("Bearer ", "")
        except Exception:
            pass
        staged = dict(staged, **(staged.get("by_token") or {}).get(_auth, {}))
        # A slow endpoint, and one that honours the caller's bound the way a
        # socket would: past it the call fails rather than running on.
        delay = staged.get("delay") or 0
        if delay:
            import time as _t
            if timeout is not None and delay > timeout:
                _t.sleep(timeout)
                raise urllib.error.URLError("timed out")
            _t.sleep(delay)
        url = getattr(req, "full_url", "") or str(req)
        if "/token" in url and staged.get("token_body") is not None:
            status = staged.get("token_status", 200)
            body = json.dumps(staged["token_body"]).encode()
            if status != 200:
                raise urllib.error.HTTPError(url, status, "staged", {}, None)

            class _T:
                def __init__(self):
                    self.status = status

                def read(self):
                    return body

                def __enter__(self):
                    return self

                def __exit__(self, *e):
                    return False

            return _T()
        status = staged.get("status", 200)
        body = json.dumps(staged.get("body", {})).encode()
        if status != 200:
            raise urllib.error.HTTPError(
                getattr(req, "full_url", ""), status, "staged", {}, None)

        class _R:
            def __init__(self):
                self.status = status

            def read(self):
                return body

            def __enter__(self):
                return self

            def __exit__(self, *e):
                return False

        return _R()

    urllib.request.urlopen = _urlopen
SCEOF
stage_usage() { # $1=5h utilization  $2=7d utilization  [$3=http status] [$4=delay s] [$5=rotated access token]
  python3 - "$STAGE" "$1" "$2" "${3:-200}" "${4:-0}" "${5:-}" <<'SUEOF'
import datetime, json, sys
out, fh, sd, status, delay, rotated = sys.argv[1:7]
fh, sd, status, delay = int(fh), int(sd), int(status), float(delay)
now = datetime.datetime.now(datetime.timezone.utc)
ahead = lambda h: (now + datetime.timedelta(hours=h)).isoformat()
staged = {"status": status, "delay": delay,
          "body": {"five_hour": {"utilization": fh, "resets_at": ahead(2)},
                   "seven_day": {"utilization": sd, "resets_at": ahead(72)}}}
if rotated:
    # A token exchange answers on the same double; a rotation is the one thing
    # that must be seen to happen under a lock rather than beside one.
    staged["token_body"] = {"access_token": rotated, "refresh_token": "RT-" + rotated,
                            "expires_in": 3600}
with open(out, "w") as f:
    json.dump(staged, f)
SUEOF
}
stage_token() { # $1=access token  $2=5h  $3=7d  [$4=http status] — an answer for ONE bearer token
  python3 - "$STAGE" "$1" "$2" "$3" "${4:-200}" <<'STEOF'
import datetime, json, os, sys
out, tok, fh, sd, status = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
now = datetime.datetime.now(datetime.timezone.utc)
ahead = lambda h: (now + datetime.timedelta(hours=h)).isoformat()
d = json.load(open(out)) if os.path.exists(out) else {"status": 500, "body": {}}
d.setdefault("by_token", {})[tok] = {"status": status, "body": {
    "five_hour": {"utilization": fh, "resets_at": ahead(2)}, "seven_day": {"utilization": sd, "resets_at": ahead(72)}}}
json.dump(d, open(out, "w"))
STEOF
}
# What a hook run AT THE WALL needs. It re-reads the account through ccd-account, so
# it needs the real tool and the stand-in endpoint; without them the re-read fails,
# nothing fires, and a case about anything else would pass for that reason alone.
STAGE="$FAKE/.stage-usage.json"
WALLENV=(PYTHONPATH="$FAKE/pysite" CCD_FAKE_USAGE="$STAGE")
# ...and somebody signed in, because the wall measures the LIVE login. Sections that
# are about accounts write their own; this is for the ones that never needed one.
wall_login() { # [$1=home]
  local h="${1:-$FAKE}"; mkdir -p "$h/.claude"
  [ -f "$h/.claude/.credentials.json" ] || printf '{"claudeAiOauth":{"accessToken":"AT-wall","refreshToken":"RT-wall","expiresAt":%s}}\n' \
    "$(( ($(date +%s) + 99999) * 1000 ))" > "$h/.claude/.credentials.json"
}
stub_usage() { # $1=5h $2=7d
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"fiveHourReset":"R1","sevenDayPercent":%s,"sevenDayReset":"D1"}}\n' "$1" "$2" > "$FAKE/.stub-usage.json"
}
DASH="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
mkdir -p "$DASH"; : > "$DASH/check-usage.js"


# ccd's own directory under the fixture HOME. §2 created it and every section after
# it simply had one; a file whose first section is not §2 needs it just as much, and
# a seeded cache written into a directory that is not there is a silent no-op.
mkdir -p "$FAKE/.claude/ccd"

# ── Shared machinery ────────────────────────────────────────────────────────

# The runner needs each case file's counts, and ok/bad mutate pass/fail in the
# shell that runs them: wrapping a file in a subshell would report 0 passed, 0
# failed and exit 0 (#65's correction). So each file ends with `finish`, which
# prints the tally a human reads and — only when the runner asked for one — leaves
# the two numbers where it can be picked up.
finish() {
  printf '\n──────────\n%s passed, %s failed\n' "$pass" "$fail"
  [ -n "${CCD_TALLY_OUT:-}" ] && printf '%s %s\n' "$pass" "$fail" > "$CCD_TALLY_OUT"
  [ "$fail" -eq 0 ]
}

# The handoff state a hook arms, and the stand-in process it signals.
# needed by: 10-hook-readings 31-setup-path 40-handoff-arming 50-statusline
#            70-swap-transaction 80-credential-stores
hf_reset() { rm -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json"; }
# Did a signalled stand-in exit within the ceiling? A single sleep turns "was it
# signalled?" into "was it signalled fast enough?", and the answer to the second
# depends on how busy the machine is.
died_within() { # $1=pid  $2=seconds
  local waited=0 ceiling
  ceiling=$(( ${2%%.*} * 10 ))
  while [ "$waited" -lt "$ceiling" ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}
hf_get() { python3 -c "
import json,os,sys
p='$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json'
print(json.load(open(p)).get(sys.argv[1],'') if os.path.exists(p) else '')" "$1" 2>/dev/null; }
# Quota cache the hook reads to corroborate a rate_limit error.
# The reading is staged in the cache AND at the endpoint the wall re-reads. A turn
# that dies on rate_limit decides on a measurement taken then and there, so a case
# that staged only the cache would have its wall re-measured away.
quota() { printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"fiveHourReset":"R1","sevenDayPercent":%s,"sevenDayReset":"D1"}}\n' "$1" "$2" \
            > "$FAKE/.claude/ccd/quota-cache.json"; stage_usage "$1" "$2"; }
# StopFailure payload as Claude Code delivers it.
stopfail() { printf '{"session_id":"%s","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"%s"}' "$1" "$2"; }

# needed by: 10-hook-readings 40-handoff-arming 50-statusline 70-swap-transaction
#            80-credential-stores  (§17 still stages its own copy, as it always did)
# Stand-in for the claude process. Nothing resolves as "claude" on every
# platform at once — a symlink shows the target on Linux, a script shows the
# interpreter on macOS, and copied system binaries fail code-signing there. On
# Linux /proc names the script correctly; on macOS the harness puts a fake `ps`
# on PATH that reports this pid as claude. Production has neither, so the code
# under test carries no test-only branch.
mkdir -p "$FAKE/sigbin"
printf '#!/bin/sh\nsleep "${1:-60}"\n' > "$FAKE/sigbin/claude"
chmod +x "$FAKE/sigbin/claude"
# macOS path: ps must answer "claude" for the stand-in and the truth otherwise.
if [ ! -d /proc ]; then
  cat > "$FAKE/fakebin/ps" <<'PSEOF'
#!/bin/sh
# Test double: name $CCD_STANDIN_PID "claude"; defer everything else to real ps.
for a in "$@"; do case "$a" in -p) next=1 ;; *) [ "${next:-}" = 1 ] && { want=$a; next=0; } ;; esac; done
if [ -n "${CCD_STANDIN_PID:-}" ] && [ "${want:-}" = "$CCD_STANDIN_PID" ]; then
  case "$*" in *comm=*) echo claude; exit 0 ;; esac
fi
exec /bin/ps "$@"
PSEOF
  chmod +x "$FAKE/fakebin/ps"
fi

# The plugin cache a hook with no CLAUDE_PLUGIN_ROOT falls back to. shim_fixture
# fills it with stand-ins; §21 and §24 put the real ccd-account in it.
# needed by: 30-setup-install 31-setup-path 40-handoff-arming 60-accounts
HB="$FAKE/.claude/plugins/cache/cc-donut/ccd/0.2.0/bin"

# The launcher shim, and the pty that has to drive it because the launcher reads
# its own terminal state.
# needed by: 30-setup-install 31-setup-path 40-handoff-arming 80-credential-stores
shim_run() { python3 "$FAKE/ptyrun.py" "$@"; }
fake_real() { printf '%s\n' "$1" > "$FAKE/realbin/claude"; chmod +x "$FAKE/realbin/claude"; }

pty_fixture() {   # $FAKE/ptyrun.py, the real claude beside it, and the PATH that finds both
  mkdir -p "$FAKE/realbin"
  # The launcher decides whether a relaunch is possible from its terminal state:
  # production always has one, and a session with no terminal must not be relaunched
  # into ccd's "exit Claude Code first" refusal. Command substitution takes that
  # terminal away, so drive the shim through a pty and capture what it wrote.
  # Exit status is forwarded exactly — several tests assert on it. Reading stops as
  # soon as the child is reaped, so a detached grandchild holding the pty open (real
  # ccd warms its price cache in the background) cannot wedge the suite.
  cat > "$FAKE/ptyrun.py" <<'PYRUN'
import os, pty, select, sys

# Give the child a terminal without losing a byte of what it writes.
#
# pty.fork() is the obvious tool and the wrong one here: on Linux, once the last
# slave fd closes, output the master has not read yet is discarded, so a launcher
# that relaunches and exits quickly loses everything after the first leg. That is
# a property of the harness, not of the code under test, and it made the suite
# fail on Alpine for reasons that had nothing to do with the handoff.
#
# So the parent holds a slave fd open for the whole run: the stream cannot end
# early, and draining continuously also keeps a chatty child from filling the
# buffer and blocking. Only once the child is reaped and the pty has gone quiet
# do we close our slave and finish.
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    # A session of its own with the slave as controlling terminal, so /dev/tty and
    # job control behave as they would in a real terminal — openpty alone would
    # only hand over tty-shaped file descriptors.
    os.setsid()
    try:
        import fcntl, termios
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    except Exception:
        pass
    for target in (0, 1, 2):
        os.dup2(slave, target)
    if slave > 2:
        os.close(slave)
    try:
        os.execvp(sys.argv[1], sys.argv[1:])
    except OSError:
        os._exit(127)

def drain(timeout):
    """Copy one readable chunk. False when there was nothing to read."""
    r, _, _ = select.select([master], [], [], timeout)
    if not r:
        return False
    try:
        chunk = os.read(master, 65536)
    except OSError:
        return False
    if not chunk:
        return False
    # A pty turns every \n into \r\n; assertions compare against plain text.
    sys.stdout.buffer.write(chunk.replace(b"\r\n", b"\n"))
    return True

status = None
while status is None:
    if drain(0.05):
        continue
    done, st = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        status = st
while drain(0.2):                # whatever the child wrote on its way out
    pass
os.close(slave)
os.close(master)
sys.stdout.buffer.flush()
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PYRUN
  SHIMPATH="$FAKE/.claude/ccd/bin:$FAKE/realbin:$PATH"
}

shim_fixture() {  # the installed launcher §18 built, and §18c, §19 and §32 went on using
  SHIM="$FAKE/.claude/ccd/bin/claude"
  # The shim must be invisible until a handoff happens: every exit code other
  # than 129 passes through untouched.
  mkdir -p "$HB" "$FAKE/realbin"
  cp "$ROOT/bin/ccd-handoff" "$HB/ccd-handoff"; chmod +x "$HB/ccd-handoff"
  cat > "$HB/ccd" <<'EOF'
#!/bin/sh
echo "CCD-RESUMED:$*"
EOF
  chmod +x "$HB/ccd"
  # The launcher asks the proof again before it relaunches onto the paid backbone.
  # This stand-in answers NO unless the launcher cases have switched it on: it sits
  # in the plugin cache, which is also where an unrooted hook run looks for
  # ccd-account, and a stand-in that vouches for whoever asks hands "proof" to
  # sections that never staged any. Switched off again where those cases end.
  cat > "$HB/ccd-account" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = exhausted ] && { [ -e "$HOME/.launcher-proof" ] || exit 1; echo every-subscription-measured-spent; exit 0; }; done
exit 0
EOF
  chmod +x "$HB/ccd-account"
  : > "$FAKE/.launcher-proof"
  pty_fixture
  # Pin the launcher token so these tests know where its state file lives; a real
  # launch mints a random one. HSTATE is that path.
  export CCD_HANDOFF_TOKEN=00000000000000000000000000000001
  HSTATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000001.json"
}

# The consent prompt reaches a person through the controlling terminal, so a case
# about consent has to stage one.
# needed by: 30-setup-install 31-setup-path
# Claude Code runs shell commands with stdin and stdout as PIPES while the
# controlling terminal is still there. That is neither "interactive" nor
# "scripted", and getting it wrong means the consent prompt silently never
# appears — which is exactly what happened in the first user test. This helper
# reproduces that shape, and `bare` drops the controlling terminal too, for the
# genuinely scripted case.
ttyask_fixture() {
  cat > "$FAKE/ttyask.py" <<'TTYASK'
import os, pty, select, sys, time

mode, answer, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
argv = sys.argv[4:]
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    if mode == "ctty":                      # a terminal exists, just not on 0/1
        import fcntl, termios
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    r, w = os.pipe()
    os.dup2(r, 0)                           # stdin: a pipe nobody writes to
    os.close(w)
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    if slave > 2:
        os.close(slave)
    try:
        os.execvp(argv[0], argv)
    except OSError:
        os._exit(127)

seen = b""
status = None
deadline = time.time() + 25
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if chunk:
            seen += chunk
            if b"[Y/n]" in seen and answer != "none":
                os.write(master, answer.encode() + b"\n")
                answer = "none"
            continue
    done, st = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        status = st
        break
if status is None:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)
os.close(slave)
os.close(master)
sys.stdout.buffer.write(seen.replace(b"\r\n", b"\n"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
TTYASK
}

# The account store.
# needed by: 10-hook-readings 40-handoff-arming 50-statusline 51-statusline-spares
#            60-accounts 61-accounts-spares 70-swap-transaction 80-credential-stores
ACCT="$ROOT/bin/ccd-account"
ADIR="$FAKE/.claude/ccd/accounts"
CREDS="$FAKE/.claude/.credentials.json"

# A live blob carrying BOTH an account login and account-independent MCP logins.
write_creds() { # $1=token marker
  cat > "$CREDS" <<EOF
{"mcpOAuth":{"notion|abc":{"serverName":"notion","accessToken":"MCP-NOTION"},
 "slack|def":{"serverName":"slack","accessToken":"MCP-SLACK"}},
 "claudeAiOauth":{"accessToken":"AT-$1","refreshToken":"RT-$1",
 "expiresAt":$(( ($(date +%s) + 99999) * 1000 )),"subscriptionType":"max"}}
EOF
}

# needed by: 60-accounts 70-swap-transaction
cred_fp() {
  python3 -c 'import hashlib,json,sys
at = (json.load(open(sys.argv[1])).get("claudeAiOauth") or {}).get("accessToken") or ""
print(hashlib.sha256(at.encode()).hexdigest()[:16])' "$1"
}

# needed by: 40-handoff-arming 60-accounts
seed_quota() { printf '%s' "$1" | rq_put; }
NOW=$(date +%s)
# These accounts are registered without an identity, so a cached row is bound to
# the credential alone. Omitting `cred` would retire every row and send `pick`
# to Anthropic with fake tokens.
q() { printf '"%s":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":%s,"seven_day_percent":%s}' \
        "$1" "$NOW" "$(cred_fp "$ADIR/$1.json")" "$2" "$3"; }

# A local stand-in for both endpoints a refresh reaches.
# needed by: 51-statusline-spares 61-accounts-spares
# Ordering is the property, so measure it where the token is spent. A stand-in for
# both endpoints a refresh reaches logs when each request starts, with how many were in
# flight, and when it ends, holding long enough between for a sibling to overlap.
endpoint_up() { # $1=log $2=seconds each request holds; sets EP_URL and EP_PID
  cat > "$FAKE/endpoint.py" <<'EPY'
import http.server, json, os, socketserver, sys, threading, time
port_file, log, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
lock, live = threading.Lock(), [0]
def note(line):
    with open(log, "a") as f: f.write(line + "\n")
class H(http.server.BaseHTTPRequestHandler):
    def answer(self, kind, reply):
        with lock:
            live[0] += 1; note(f"start {kind} {live[0]}")
        time.sleep(hold)
        with lock:
            live[0] -= 1; note(f"end {kind}")
        body = json.dumps(reply).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_POST(self):                          # a token refresh
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        t = str(time.time())
        self.answer("token", {"access_token": "A" + t, "refresh_token": "R" + t, "expires_in": 28800})
    def do_GET(self):                           # a usage probe
        w = {"utilization": 12, "resets_at": "2099-01-01T00:00:00Z"}
        self.answer("usage", {"five_hour": w, "seven_day": dict(w, utilization=30)})
    def log_message(self, *a): pass
class S(http.server.ThreadingHTTPServer):
    def server_bind(self):                      # skip getfqdn(), see the token server below
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]
srv = S(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.replace(port_file + ".tmp", port_file)
srv.serve_forever()
EPY
  rm -f "$FAKE/.ep-port"
  python3 "$FAKE/endpoint.py" "$FAKE/.ep-port" "$1" "$2" </dev/null >/dev/null 2>&1 &
  EP_PID=$!
  local n=0
  while [ ! -s "$FAKE/.ep-port" ] && [ $n -lt 75 ]; do sleep 0.2; n=$((n+1)); done
  EP_URL="http://127.0.0.1:$(cat "$FAKE/.ep-port" 2>/dev/null)"
  [ -s "$FAKE/.ep-port" ]
}

# needed by: 10-hook-readings 50-statusline
mk_sl_acct() { # $1=name
  printf '{"name":"%s","label":"%s@example.com","account_uuid":"uuid-%s","priority":1,"claudeAiOauth":{"accessToken":"AT-%s"}}\n' \
    "$1" "$1" "$1" "$1" > "$ADIR/$1.json"
}

# Cache rows the statusline will actually accept: row_valid() binds an `ok` row to
# the account's uuid and a failure row to its credential too, so both are written.
# Offsets are seconds from now, which is how a reset time is really read — as a
# distance, not a date. "-" leaves a field out entirely.
seed_rows() { # name:status:5h:7d:5h_offset:7d_offset ...
  RQT=$(rq_gather)
  python3 - "$ADIR" "$RQT" "$@" <<'PY'
import datetime, hashlib, json, os, sys
adir, out, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
now = datetime.datetime.now(datetime.timezone.utc)
rows = {}
for s in specs:
    name, status, fh, sd, fr, sr = s.split(":")
    acct = json.load(open(os.path.join(adir, name + ".json")))
    rec = {"status": status, "checked_at": int(now.timestamp()),
           "uuid": acct["account_uuid"],
           "cred": hashlib.sha256(
               acct["claudeAiOauth"]["accessToken"].encode()).hexdigest()[:16]}
    for key, val in (("five_hour_percent", fh), ("seven_day_percent", sd)):
        if val != "-":
            rec[key] = int(val)
    for key, val in (("five_hour_reset", fr), ("seven_day_reset", sr)):
        if val != "-":
            rec[key] = (now + datetime.timedelta(seconds=float(val))).isoformat()
    rows[name] = rec
json.dump(rows, open(out, "w"))
PY
  rq_scatter "$RQT"
}

# needed by: 10-hook-readings 50-statusline 51-statusline-spares
iso() { python3 -c "
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc)
       + datetime.timedelta(seconds=float(sys.argv[1]))).isoformat())" "$1"; }
