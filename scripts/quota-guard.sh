#!/bin/bash
# Claude Code hook shared by SessionStart, UserPromptSubmit, PostToolUse, StopFailure, and SessionEnd.
# Checks claude-dashboard usage through a ten-minute cache. In normal sessions it recommends
# Codex delegation at 85%; in ccd sessions it tracks cost and Claude quota resets only.
# StopFailure/SessionEnd additionally record automatic-handoff state (see arm_handoff).
EVENT="${1:-UserPromptSubmit}"
CCD_DIR="$HOME/.claude/ccd"
CACHE="$CCD_DIR/quota-cache.json"
WARN_MARK="$CCD_DIR/last-warn"
# keepalive leaves its verdict here; the next prompt tick forwards it.
STALE_FILE="$CCD_DIR/accounts-stale"
STALE_MARK="$CCD_DIR/last-stale-warn"
RUN_STATE="$CCD_DIR/run-state.json"
OUTAGE_STATE="$CCD_DIR/outage-state.json"
# The launcher names its own state file and passes the path down; a fixed name
# would be shared by every concurrent session (see write_handoff).
HANDOFF="${CCD_HANDOFF_STATE:-$CCD_DIR/handoff.json}"
mkdir -p "$CCD_DIR"
TTL=600
# Staleness moves in days, so this warning repeats far more slowly than the quota one.
STALE_TTL=14400
THRESHOLD=85
# Arming needs the quota reading to corroborate the API error: a bare rate_limit
# can be transient throttling, and a handoff on that would be a false alarm. The
# same reading, at the same threshold, is what moves the session BEFORE the wall
# (see "Swap before the wall") — one corroboration, two moments.
ARM_THRESHOLD=95
# Measured credential pickup after a swap is 1-11s. The backstop waits that out
# before it wakes the session, so the woken turn does not retry on the account we
# just left. The StopFailure hook's timeout is set well past it (hooks/hooks.json).
SWAP_SETTLE="${CCD_SWAP_SETTLE:-12}"
# What the decision itself may spend: the wait for the background job's lock, and
# any probing. It has to be bounded and it has to be stated — the hook is killed on
# its timeout, and one usable spare behind nine expired ones would otherwise eat
# the whole of it and wake nobody. hooks.json budgets for this plus the settle.
SWAP_PICK_BUDGET="${CCD_SWAP_PICK_BUDGET:-60}"
# What a PROMPT tick may spend on the same decision. This fires several times a
# minute, so waiting on a background pass here is a frozen prompt — and the next
# tick decides just as well. Only the backstop, where the turn has already died
# and nothing else is coming, gets the long budget above.
SWAP_TICK_BUDGET="${CCD_SWAP_TICK_BUDGET:-3}"
# Where a backstop that could not move the session leaves its one line. The next
# prompt claims it, says it once, and removes it — the same shape the keepalive's
# verdict uses, and for the same reason: the path that learns the fact has no
# screen to say it on.
SWAP_NOTE="$CCD_DIR/swap-note"

# Hook payloads arrive on stdin as one JSON object. Read it with pure bash: the
# obvious `timeout 0.5 cat` is not portable — macOS has no timeout(1), and under
# `set -e` its absence silently killed every hook, taking the quota warnings with
# it. Claude Code closes stdin after the payload, so a plain read terminates.
# `-t 0` means "is stdin a terminal": when run by hand there is no payload to wait for.
HOOK_INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' HOOK_INPUT || true
fi

# `ccd setup` gives its statusline a 60s tick, so an idle session still redraws — and
# re-measures — the spare row (#54). Nothing reruns setup after an update, so an install
# wired before the tick existed gets it here: on ccd's own statusline exactly as setup
# writes it, and only where no interval is set. Anything else on that key is the user's.
if [ "$EVENT" = "SessionStart" ]; then
  python3 - "$HOME/.claude/settings.json" >/dev/null 2>&1 <<'PY'
import json, os, sys, tempfile
p = os.path.realpath(sys.argv[1])          # a dotfiles symlink stays a symlink
with open(p, encoding="utf-8") as f:
    before = f.read()
data = json.loads(before)
s = data.get("statusLine")
if (not isinstance(s, dict) or "refreshInterval" in s
        or s.get("command") != "bash ~/.claude/ccd/statusline-launcher.sh"):
    raise SystemExit(0)
s["refreshInterval"] = 60
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".settings.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2); f.write("\n")
    os.chmod(tmp, os.stat(p).st_mode & 0o777)
    # Compare and swap. This rewrites the whole file, so a write that landed while we
    # worked — Claude Code's own, another session's, or one that made the statusline
    # somebody else's — would be dropped by replacing it. Sessions start in bunches, so
    # stand down and let the next one try; a lock Claude Code does not take would not
    # help anyway.
    with open(p, encoding="utf-8") as f:
        if f.read() == before:
            os.replace(tmp, p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
  exit 0
fi

# Extract the fields this script uses. Absent/malformed input leaves them empty,
# which every caller below treats as "not applicable" rather than an error.
SESSION_ID=""; HOOK_CWD=""; HOOK_ERROR=""
if [ -n "$HOOK_INPUT" ]; then
  # Tab-separated so a value containing spaces survives; newlines are impossible
  # in these fields (they are ids, paths, and enum tags).
  # StopFailure names the error in `error` — the key this whole arm hangs on.
  IFS=$'\t' read -r SESSION_ID HOOK_CWD HOOK_ERROR <<EOF
$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    print("\t\t"); raise SystemExit(0)
def s(k):
    v = d.get(k)
    return v if isinstance(v, str) else ""
print("\t".join((s("session_id"), s("cwd"), s("error"))))
' 2>/dev/null)
EOF
fi

# A session id becomes part of a filename and a --resume argument, so accept only
# the shape Claude Code actually emits (uuid-ish) and reject anything else.
valid_session_id() {
  case "$1" in
    ''|*[!a-zA-Z0-9-]*) return 1 ;;
    *) [ "${#1}" -le 64 ] ;;
  esac
}

file_age() {
  local f="$1" now mtime
  now=$(date +%s)
  [ -f "$f" ] || { echo 999999; return; }
  # GNU first, BSD second, and the fallback MUST be outside the command
  # substitution: `$(stat -f %m || stat -c %Y)` captures both commands' stdout,
  # and GNU `stat -f` prints a filesystem dump while failing — that poisoned
  # mtime, made the arithmetic die, and silently froze the cache on Linux.
  mtime=$(stat -c %Y "$f" 2>/dev/null) || mtime=$(stat -f %m "$f" 2>/dev/null)
  case "$mtime" in
    ''|*[!0-9]*) echo 999999; return ;;   # unusable → treat as ancient, never as fresh
  esac
  echo $((now - mtime))
}

# Refresh the dashboard's Claude quota cache regardless of ccd state,
# so Claude resets are visible even while the external backbone is active.
# Hooks run non-interactively, so a version-manager node (nvm/volta/fnm) is often
# absent from PATH even though it works in the user's shell — that made the cache
# refresh fail silently. Fall back to the usual install locations.
find_node() {
  command -v node 2>/dev/null && return 0
  local c
  for c in "$HOME/.volta/bin/node" "$HOME/.local/share/fnm/aliases/default/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node /snap/bin/node; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  c=$(ls -d "$HOME/.nvm/versions/node"/*/bin/node 2>/dev/null | sort -V | tail -1)
  [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  return 1
}

# Locate ccd-account. The hook runs from the plugin, so a sibling lookup off
# CLAUDE_PLUGIN_ROOT is the direct answer; the glob covers a hook invoked by hand.
ccd_account_bin() {
  local t
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/bin/ccd-account" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT/bin/ccd-account"; return 0
  fi
  t=$(ls -d "$HOME/.claude/plugins/cache"/*/ccd/*/bin/ccd-account 2>/dev/null | sort -V | tail -1)
  [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  return 1
}

# The reading does not have to come from claude-dashboard. ccd already talks to
# the same Anthropic usage endpoint for its spare accounts, so it can measure the
# account this session is signed in as. That keeps quota warnings, reset
# detection, and the automatic handoff working on an install that has no
# dashboard: without a reading none of them can fire at all (see quota_peak).
#
# A failed probe backs off. This runs on a stale cache, and a stale cache is what
# a failure leaves behind, so without the marker every prompt and every tool use
# would spawn python3 and open a socket for an account that is offline or signed
# out.
PROBE_BACKOFF="$CCD_DIR/.usage-probe-backoff"
PROBE_BACKOFF_TTL=300
# mkdir, not a marker file: it either creates the directory or fails, and exactly
# one caller can win. A `: >` claim cannot single-flight anything, because every
# sibling's write succeeds — six overlapping hooks still opened three sockets.
PROBE_LOCK="$CCD_DIR/.usage-probe.lock"
# Held across the caller's validate-and-install step, so probe_release is what
# ends the lease, never usage_probe's own success path.
PROBE_LEASED=0

probe_release() {
  [ "$PROBE_LEASED" -eq 1 ] || return 0
  rmdir "$PROBE_LOCK" 2>/dev/null
  PROBE_LEASED=0
}

# Is this file a reading, or just well-formed JSON? Everything downstream treats
# a percentage as proof the quota really is spent, so "parses" is not the bar.
usable_reading() {  # $1=file
  python3 - "$1" 2>/dev/null <<'PY'
import json, sys
try:
    c = (json.load(open(sys.argv[1])).get("claude") or {})
except Exception:
    raise SystemExit(1)
if c.get("available") is not True or c.get("error") is not False:
    raise SystemExit(1)
raise SystemExit(0 if any(
    isinstance(p, (int, float)) and not isinstance(p, bool)
    for p in (c.get("fiveHourPercent"), c.get("sevenDayPercent"))) else 1)
PY
}

usage_probe() {  # $1=destination file
  local ab leased=0
  # The backoff and the lease both protect the prompt path, where this hook fires
  # several times a minute. StopFailure is the opposite: it fires once, on the
  # turn that actually failed, and the reading decides whether the conversation
  # survives. Nothing may stand between that event and its answer.
  if [ "$EVENT" != "StopFailure" ]; then
    [ "$(file_age "$PROBE_BACKOFF")" -gt "$PROBE_BACKOFF_TTL" ] || return 1
    if mkdir "$PROBE_LOCK" 2>/dev/null; then
      leased=1
      # Re-check under the lease. The check above and this claim are two steps,
      # so a sibling can pass the first, wait, and arrive here after the winner
      # has already probed, failed and released. Asking again is what makes the
      # marker it left mean something. The cache is re-checked for the same
      # reason: a winner that succeeded has made this probe pointless.
      if [ "$(file_age "$PROBE_BACKOFF")" -le "$PROBE_BACKOFF_TTL" ] \
         || [ "$(file_age "$CACHE")" -le "$TTL" ]; then
        rmdir "$PROBE_LOCK" 2>/dev/null
        return 1
      fi
    else
      # A lease left behind by a killed probe must not block refreshes forever.
      # The age floor is what keeps this from reaping a live sibling's lease.
      find "$CCD_DIR" -maxdepth 1 -name "$(basename "$PROBE_LOCK")" -mmin +1 -delete 2>/dev/null
      return 1
    fi
  fi
  PROBE_LEASED=$leased
  if ! ab=$(ccd_account_bin); then
    probe_release
    return 1
  fi
  # Record the attempt BEFORE the request, so being killed mid-flight backs off
  # the same way a refusal does. Recording it only on failure meant a hard kill
  # left nothing behind and the next tick tried again immediately.
  : > "$PROBE_BACKOFF" 2>/dev/null
  # Bound the wait. A hook that blocks is a prompt that hangs, and the default is
  # ten seconds per socket operation. Not a hard deadline (urllib budgets each
  # operation, not the whole request), but it keeps the common slow case off the
  # prompt path.
  # A win keeps the lease and keeps the backoff marker. Both are cleared by the
  # caller, once the reading is validated and installed: until then this probe
  # has produced nothing a sibling could use.
  if CCD_HTTP_TIMEOUT="${CCD_PROBE_TIMEOUT:-5}" "$ab" --no-color usage --json > "$1" 2>/dev/null; then
    return 0
  fi
  probe_release
  return 1
}

if [ "$(file_age "$CACHE")" -gt "$TTL" ]; then
  script=$(ls -d "$HOME/.claude"/plugins/cache/claude-dashboard/claude-dashboard/*/dist/check-usage.js 2>/dev/null | sort -V | tail -1)
  node_bin=$(find_node) || node_bin=""
  # This hook fires on both UserPromptSubmit and PostToolUse, so instances run
  # concurrently. A shared tmp name lets one instance truncate/delete another's
  # in-flight write and the refresh silently fails forever under load — use a
  # per-process tmp and install it only when it parses as JSON.
  tmp="$CACHE.tmp.$$"
  # Claude Code kills a hook that outruns its timeout, and the kill lands between
  # the redirect that creates $tmp and the branch below that removes it. Without
  # this trap every such kill strands a 0-byte file in CCD_DIR permanently.
  # The signal handlers must exit, not just clean up: bash resumes the script
  # after a handler returns, and the resumed `mv` would chase a file the handler
  # just deleted.
  trap 'rm -f "$tmp"; probe_release' EXIT
  trap 'rm -f "$tmp"; probe_release; exit 130' INT
  trap 'rm -f "$tmp"; probe_release; exit 143' TERM
  # SIGKILL cannot be trapped, so sweep what an earlier hard kill already left.
  # The age floor is what keeps this from deleting a live sibling's in-flight tmp.
  find "$CCD_DIR" -maxdepth 1 -name "$(basename "$CACHE").tmp.*" -mmin +60 -delete 2>/dev/null || true
  # Either producer writes the same shape, so everything downstream reads one
  # format and never learns where the numbers came from. Exiting 0 is not the
  # same as answering: the dashboard reports its own failures as valid JSON with
  # error=true, and taking that as success published an unusable payload over the
  # last good reading AND skipped the fallback entirely. An installed dashboard
  # that cannot reach Anthropic would then disable handoffs on a machine that can
  # measure itself perfectly well, which is the exact failure this change exists
  # to remove. So each producer is judged on what it produced.
  got=0
  if [ -n "$script" ] && [ -n "$node_bin" ] \
     && "$node_bin" "$script" --json > "$tmp" 2>/dev/null && usable_reading "$tmp"; then
    got=1
  elif usage_probe "$tmp" && usable_reading "$tmp"; then
    got=1
  fi
  if [ "$got" -eq 1 ]; then
    # Only a reading that actually landed may clear the markers. Publication can
    # fail (a full or read-only $HOME), and clearing them on the way past would
    # advertise a fresh reading that is not there.
    if mv "$tmp" "$CACHE" 2>/dev/null; then
      rm -f "$CCD_DIR/refresh-failed" "$PROBE_BACKOFF"
    else
      rm -f "$tmp"
      echo "the quota reading could not be written to $CACHE" \
        > "$CCD_DIR/refresh-failed" 2>/dev/null
    fi
  else
    rm -f "$tmp"
    # Leave a breadcrumb, because `ccd doctor` is the only place this surfaces.
    # A reading that stops coming is invisible otherwise: the warnings just never
    # appear again. Which producer failed does not matter to the user, only that
    # the account could not be measured, so say that and nothing else.
    { echo "the signed-in Claude account could not be measured (login, token, or network)"
      [ -f "$PROBE_BACKOFF" ] && echo "backing off; the next attempt is a few minutes away"
    } > "$CCD_DIR/refresh-failed" 2>/dev/null
  fi
  probe_release
  trap - EXIT INT TERM
fi

# ── Automatic handoff ────────────────────────────────────────────────────────
# Records whether the launcher should relaunch this conversation on the other
# backbone. Writing the file is always safe; only the launcher acts on it, and
# only when it installed itself (see the CCD_HANDOFF interlock below).

# Highest observed quota percentage and the reset window it came from, tab
# separated, or empty when the data is unusable.
# Unusable is deliberately NOT zero: a missing reading must never arm a handoff.
# The window id rides along because every caller that acts on the peak also has
# to say WHICH window it acted on, and re-reading the cache to ask again would be
# a second answer that could differ from the first.
#
# Age is part of usable. The cache keeps its last good sample when a refresh
# fails, so a reading can outlive the window it measured: a 96% sample taken
# before a reset still reads 96% afterwards, and a transient rate_limit on the
# fresh quota would then look corroborated. Three consecutive failed refreshes
# (the refresh runs on a ten-minute timer) is the point where the sample stops
# being evidence about now.
MAX_READING_AGE=1800
quota_peak() {
  [ -f "$CACHE" ] || return 0
  [ "$(file_age "$CACHE")" -le "$MAX_READING_AGE" ] || return 0
  python3 - "$CACHE" 2>/dev/null <<'PY'
import datetime, json, sys
try:
    d = json.load(open(sys.argv[1]))
    c = (d.get("claude") or {})
except Exception:
    raise SystemExit(0)
if c.get("available") is not True or c.get("error") is not False:
    raise SystemExit(0)


def expired(reset):
    """Has the window this percentage belongs to already turned over?

    Age alone cannot answer it. A reading taken four minutes ago is fresh by any
    clock and still describes a window that reset three minutes ago, and 96% of a
    window that no longer exists is not evidence about the one that replaced it.
    An unparseable value (the dashboard does not promise a timestamp) means we
    cannot tell, and not being able to tell is not a reason to discard a reading:
    the age bound above still governs it."""
    if not isinstance(reset, str) or not reset:
        return False
    try:
        t = datetime.datetime.fromisoformat(reset.replace("Z", "+00:00"))
    except ValueError:
        return False
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t <= datetime.datetime.now(datetime.timezone.utc)


vals = [(label, int(p), reset)
        for label, p, reset in (("5h", c.get("fiveHourPercent"), c.get("fiveHourReset")),
                                ("7d", c.get("sevenDayPercent"), c.get("sevenDayReset")))
        if isinstance(p, (int, float)) and not isinstance(p, bool)
        and not expired(reset)]
if vals:
    peak = max(p for _, p, _ in vals)
    # Whose reading this is, when the producer said so. ccd's own probe does;
    # claude-dashboard has no idea, and then the caller has to ask.
    acct = d.get("account")
    acct = acct if isinstance(acct, str) else ""
    # Named by BOTH windows the reading carries, not by whichever happens to be
    # higher: a key that changes when the peak moves from one window to the other
    # describes a different situation every time the two numbers cross.
    key = ";".join(f"{label}={reset}" for label, _, reset in vals
                   if isinstance(reset, str) and reset)
    print(f"{peak}\t{key or 'none'}\t{acct}")
PY
}

# The peak and the key naming the windows it came from, as two shell variables.
# Every caller needs both, and a second call would read a cache that may have been
# replaced in between.
read_peak() {  # sets $peak, $wkey and $racct (the account the reading measured)
  IFS=$'\t' read -r peak wkey racct <<EOF
$(quota_peak)
EOF
}

# Write handoff state atomically, mode 600 — same discipline as run-state.json.
# The file is per-launcher, keyed by the token that launcher exported: with one
# shared file, a second session exiting 129 for any reason would consume the
# first session's handoff, resume the WRONG conversation, and leave the session
# that was actually signalled with nothing to bring it back.
write_handoff() {  # $1=armed(true|false) $2=direction $3=session_id $4=cwd
  CCD_ARMED="$1" CCD_DIR_TO="$2" CCD_SID="$3" CCD_CWD="$4" CCD_HF="$HANDOFF" \
  CCD_TOKEN="${CCD_HANDOFF:-}" \
    python3 - <<'PY'
import json, os, tempfile, time
p = os.environ["CCD_HF"]
state = {
    "armed": os.environ["CCD_ARMED"] == "true",
    "token": os.environ.get("CCD_TOKEN", ""),
    # to_fallback | to_subscription — the paid hop and the way back from it.
    # Which account the way back lands on is whatever the live store holds by
    # then, so nothing here has to name one.
    "direction": os.environ["CCD_DIR_TO"],
    "session_id": os.environ["CCD_SID"],
    "cwd": os.environ["CCD_CWD"],
    "armed_at": int(time.time()),
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".handoff.")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, p)
    os.chmod(p, 0o600)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

# Process name for a pid, or empty. /proc is authoritative on Linux and is the
# only option in minimal images, which often ship no ps at all (debian-slim) or a
# BusyBox ps that rejects -p and would answer about the WRONG process (Alpine).
# ps is the macOS path, where /proc does not exist.
proc_name() {
  local pid="$1" n=""
  [ -n "$pid" ] || return 1
  # Branch on the PLATFORM, not on whether one /proc entry happens to be
  # readable. A vanished or unreadable entry on Linux must fail closed: falling
  # through to `ps -p` there lands on BusyBox, which ignores -p and would name
  # some other process entirely — that is how a wrong pid gets signalled.
  if [ -d /proc ]; then
    [ -r "/proc/$pid/comm" ] || return 1
    read -r n < "/proc/$pid/comm" 2>/dev/null || return 1
  else
    n=$(ps -o comm= -p "$pid" 2>/dev/null | head -1) || return 1
    [ -n "$n" ] || return 1
  fi
  n=${n##*/}
  printf '%s' "$n"
}

proc_parent() {
  local pid="$1" ppid=""
  [ -n "$pid" ] || return 1
  if [ -d /proc ]; then
    [ -r "/proc/$pid/stat" ] || return 1
    # Field 4 is ppid, but field 2 (comm) can contain spaces or parens — cut past
    # the last ')' so the remaining offsets are stable: state, then ppid.
    ppid=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f2)
  else
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  fi
  case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$ppid"
}

# Resolve the claude process to signal. $CLAUDE_PID is exported to every child and
# is the reliable answer; the ancestor walk is a fallback for versions that don't
# set it. Never signal $PPID blindly — it is sometimes an intermediate shell, and
# never signal a pid whose name we could not confirm.
claude_pid() {
  local p c
  if [ -n "${CLAUDE_PID:-}" ]; then
    c=$(proc_name "$CLAUDE_PID") || c=""
    [ "$c" = "claude" ] && { printf '%s' "$CLAUDE_PID"; return 0; }
    # CLAUDE_PID was set but no longer names a claude — the process it referred
    # to is gone. Walking up from here would find whatever claude happens to be
    # further up the tree (a parent session running tests, say) and kill THAT.
    return 1
  fi
  # Only walk when Claude Code never told us, which is the older-version case.
  # Stop at the first claude: it is the session this hook belongs to.
  p=$PPID
  for _ in 1 2 3 4 5; do
    { [ -n "$p" ] && [ "$p" != "1" ]; } || break
    c=$(proc_name "$p") || c=""
    [ "$c" = "claude" ] && { printf '%s' "$p"; return 0; }
    p=$(proc_parent "$p") || break
  done
  return 1
}

# End the session so the launcher can relaunch it on the other backbone.
# SIGHUP is the one signal interactive Claude Code acts on: it runs SessionEnd
# hooks, flushes, and exits 129 — the code the launcher watches for.
#
# Is a relaunch loop actually supervising us? Presence of CCD_HANDOFF alone is
# not enough: `CCD_HANDOFF=x claude` would then end a session with nothing
# waiting to bring it back — the exact failure the interlock exists to prevent.
# Require the whole launcher contract: a token of the generated shape AND a
# state path that is exactly the one that token implies.
launcher_present() {
  local tok="${CCD_HANDOFF:-}"
  # Exactly the shape the launcher generates: 32 lowercase hex. A longer value
  # would name a file the write cannot create, and signalling against state that
  # was never written is precisely how a session ends with nothing to catch it.
  case "$tok" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#tok}" -eq 32 ] || return 1
  [ "${CCD_HANDOFF_STATE:-}" = "$CCD_DIR/handoff-$tok.json" ] || return 1
}

# THE INTERLOCK: only ever signal when the launcher is supervising this process.
# Without a relaunch loop to catch the exit, this would just kill the user's
# session with nothing bringing it back — strictly worse than doing nothing.
request_handoff() {
  launcher_present || return 1
  local pid
  pid=$(claude_pid) || return 1
  # Never signal ourselves or our own process group leader — that would be a
  # loop, not a handoff.
  [ "$pid" = "$$" ] && return 1
  kill -HUP "$pid" 2>/dev/null || return 1
}

# Is a usable OpenRouter key configured? Deliberately strict: a key that ccd will
# later reject is the same as no key, and signalling on one would end the session
# with nowhere to go. Mirrors the parser `ccd setup` uses to report readiness.
have_key() {
  # An exported key gets the same scrutiny as the file: a whitespace-only value
  # is not a key, and accepting one would end a session with nowhere to go.
  case "${OPENROUTER_API_KEY:-}" in
    '') : ;;
    *[![:space:]]*) return 0 ;;
    *) : ;;
  esac
  [ -f "$CCD_DIR/providers/keys.env" ] || return 1
  python3 - "$CCD_DIR/providers/keys.env" 2>/dev/null <<'PY'
import re, sys
try:
    s = open(sys.argv[1]).read()
except Exception:
    raise SystemExit(1)
for line in s.splitlines():
    line = line.strip()
    if line.startswith("#"):
        continue
    m = re.match(r'^(?:export\s+)?OPENROUTER_API_KEY=(.*)$', line)
    if not m:
        continue
    v = m.group(1).strip().strip('"').strip("'").strip()
    if v:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# May quota exhaustion move this session onto the paid backbone unattended?
# Separate from have_key on purpose: a key says OpenRouter is REACHABLE, this says
# the user agreed it may be USED. Written by `ccd setup --auto`.
paid_optin() { [ -f "$CCD_DIR/paid-handoff" ]; }

# The only thing that may authorise spending money: PROOF that no subscription can
# take this session. It is one word on stdout AND a zero exit — never an exit code
# alone, never silence, never "the swap did not happen". Five review passes each
# found an operational failure (a lock timeout, a 503, an unreadable directory, a
# die()) reaching the paying branch through an inference like those; a positive
# answer that only one line of ccd-account can print cannot be reached that way.
# What the proof consists of is ccd-account's business (cmd_exhausted).
subscriptions_proved_spent() {
  local ab out
  ab=$(ccd_account_bin) || return 1
  out=$("$ab" --no-color exhausted 2>/dev/null) || return 1
  [ "$out" = "every-subscription-measured-spent" ]
}

# Everything that must hold before a session may be ended. Checked BEFORE arming,
# not after: an armed file left behind by an unsupervised or unready session
# would be consumed by a later launcher and resume the wrong conversation.
#
# Both relaunches need exactly this — the paid hop out and the return from it.
# The key is NOT part of it: coming back needs none, and requiring one would
# strand a session on the paid backbone over a credential it is about to stop
# using. The hop out asks for the key separately (have_key).
launcher_ready() {
  # A run the launcher cannot relaunch must not be ended for one: signalling a
  # batch job kills the work and nothing brings it back.
  [ -z "${CCD_HANDOFF_HEADLESS:-}" ] || return 1
  launcher_present || return 1
  valid_session_id "$SESSION_ID" || return 1
  claude_pid >/dev/null || return 1
}

# Is the multi-account feature in use at all? This hook fires on every prompt AND
# every tool use, so the paths below must cost nothing for the many users who
# never register an account. A shell glob forks nothing; asking ccd-account would
# spawn a Python interpreter several times a minute to be told "none".
# Positional parameters are function-local, so this clobbers nothing.
has_accounts() {
  set -- "$CCD_DIR/accounts"/*.json
  [ -e "$1" ]
}


# Move this session onto a spare, in place. The credential ccd writes here is the
# one Claude Code's very next request reads, so nothing has to end and nothing has
# to be relaunched — that was always the expensive half of the hop, and the
# measurements in #57 say no part of it was ever needed.
#
# Move this session to a spare. Three attempts, then stop: a store that moved or
# a lock somebody else held is worth a moment's patience and nothing more.
#
# There are two outcomes and they are not a fork in the road. Either this prints
# `<account>TAB<installed credential>TAB<the credential it replaced>`, or it
# prints nothing and leaves the reason in $SWAP_REASON. Nothing about that reason
# is evidence of anything: there is no second road to take on it. A session that
# cannot be moved to a spare stays where it is, and says so.
# Both answers come back in variables. Reading the line off stdout means calling
# this inside `$( )`, and a subshell cannot hand the reason back — every note then
# says "reason unknown", which is the one thing a note must never say.
SWAP_RESULT=""
SWAP_REASON=""
# A standing stop has a remedy, and it fits in neither a reason nor a wake line.
# doctor carries all of it, so every path that meets the stop says this and only this.
SPLIT_ADVICE="the credential stores disagree with each other — run: ccd doctor"
swap_to_spare() {  # $1=window key  $2=the account the reading was about  $3=budget
  local wkey="$1" from="$2" budget="$3" ab out err i end left
  shift 3
  SWAP_RESULT=""
  SWAP_REASON=""
  if ! ab=$(ccd_account_bin); then
    SWAP_REASON="ccd-account is missing from this install"
    return 1
  fi
  # ONE budget, attempts included. Three tries that each get the whole of it is
  # three times the wait the caller agreed to, and on a prompt tick the caller is
  # a person watching a cursor.
  end=$(( $(date +%s) + budget ))
  # The same kill the reading's tmp file is guarded against (see the probe above):
  # it lands between the redirect below and the rm after it. No other trap is live
  # here — the probe clears its own — so these replace nothing, and are cleared on
  # every way out. The handlers exit for the reason given there.
  trap 'rm -f "$CCD_DIR/.swap-err.$$"' EXIT
  trap 'rm -f "$CCD_DIR/.swap-err.$$"; exit 130' INT
  trap 'rm -f "$CCD_DIR/.swap-err.$$"; exit 143' TERM
  find "$CCD_DIR" -maxdepth 1 -name '.swap-err.*' -mmin +60 -delete 2>/dev/null || true
  for i in 1 2 3; do
    left=$(( end - $(date +%s) ))
    [ "$left" -gt 0 ] || break
    # stdout is the result and stderr is commentary. Folded together, a swap
    # that succeeded AND warned handed back its warning as the account name.
    err="$CCD_DIR/.swap-err.$$"
    if out=$("$ab" --no-color swap --from "$from" --window "$wkey" \
                   --deadline "$left" "$@" 2>"$err") && [ -n "$out" ]; then
      rm -f "$err"
      trap - EXIT INT TERM
      SWAP_RESULT="$out"
      return 0
    fi
    SWAP_REASON=$(tr '\n' ' ' < "$err" 2>/dev/null | head -c 120)
    rm -f "$err"
    sleep 0.2
  done
  trap - EXIT INT TERM
  [ -e "$CCD_DIR/store-split" ] && SWAP_REASON="$SPLIT_ADVICE"
  return 1
}

# Leave one line where the next prompt will find it. A backstop that could not
# move the session must not wake it — the account is still spent, and the woken
# turn would walk into the same wall — but the user is owed the reason, once.
swap_note() {  # $1=message
  CCD_NOTE="$1" CCD_NOTE_FILE="$SWAP_NOTE" python3 - <<'PY' 2>/dev/null || true
import json, os, tempfile
p = os.environ["CCD_NOTE_FILE"]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".swap-note.")
with os.fdopen(fd, "w") as f:
    json.dump({"message": os.environ["CCD_NOTE"]}, f, ensure_ascii=False)
os.chmod(tmp, 0o600)
os.replace(tmp, p)
PY
}

# A swap can succeed and still leave the stop standing: the writes landed, the
# stores were not seen to agree. That is not a failure and must not become a
# retry — but it is the one thing worth saying, so it replaces whatever note the
# caller would have left. False when there is no stop, so the caller carries on.
split_advisory() {  # $1=the account the session is on now
  [ -e "$CCD_DIR/store-split" ] || return 1
  swap_note "[ccd] ccd switched this session to $1, but $SPLIT_ADVICE"
}

# Which account is a reading about? The reading says so when ccd took it; a
# dashboard reading does not, and then this asks — accepting that the answer is
# only as fresh as the moment it is asked.
# `CCD_ACTIVE=` because on the paid backbone `current` answers "openrouter", and
# the account store is what this is a claim about.
reading_account() {  # $1=what the reading itself said
  local ab
  [ -n "$1" ] && { printf '%s' "$1"; return 0; }
  ab=$(ccd_account_bin) || return 1
  CCD_ACTIVE= "$ab" --no-color current 2>/dev/null
}

# Did the credential Claude Code reads actually become the one we installed? The
# swap writes the live store, but a keychain that refused — or this session
# writing its own refreshed blob back over ours — leaves that store holding the
# credential we meant to leave, and waking into it only hits the same wall again.
#
# What is checked is whose credential is live. A plan is not an account — two
# accounts on one plan agree about every plan field there is — and neither is
# "something changed": a third account's token, or the outgoing account's next
# rotation, both differ from what we replaced and neither is the target's.
#
# So the live credential must BE the target's: either the exact one this swap
# installed, or the one the store now holds for that same account, which is what
# a rotation ccd recorded looks like. Twelve seconds is long enough for one, and
# calling that a failed swap leaves a parked turn asleep for nothing.
swap_landed() {  # $1=account  $2=the credential the swap installed
  local ab
  [ -n "$2" ] || return 1
  ab=$(ccd_account_bin) || return 1
  # Pickup is 1-11s. Waking before it lands wastes the turn it was meant to save.
  [ "${SWAP_SETTLE:-0}" -gt 0 ] 2>/dev/null && sleep "$SWAP_SETTLE"
  "$ab" --no-color current --json 2>/dev/null \
    | CCD_WANT="$1" CCD_CRED="$2" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if d.get("account") != os.environ["CCD_WANT"]:
    raise SystemExit(1)
cred = (d.get("live") or {}).get("cred")
stored = d.get("stored_cred") or ""
want = os.environ.get("CCD_CRED") or ""
raise SystemExit(0 if cred and (cred == want or cred == stored) else 1)
' 2>/dev/null
}

# StopFailure fires when a turn ends on an API error. It is the backstop now, not
# the primary path: the swap before the wall catches the quota ccd can measure, and
# what is left for here is what that reading cannot see — a sample up to ten
# minutes old, or a limit ccd does not measure at all.
if [ "$EVENT" = "StopFailure" ]; then
  # Corroborate: the error says rate_limit AND the dashboard agrees we are spent.
  # Either alone is not enough — a rate_limit can be transient, and a high
  # reading alone does not mean the request actually failed.
  if [ "$HOOK_ERROR" = "rate_limit" ] && [ -z "${CCD_ACTIVE:-}" ]; then
    read_peak
    case "$peak" in
      ''|*[!0-9]*) : ;;   # no trustworthy reading → stay disarmed
      *) if [ "$peak" -ge "$ARM_THRESHOLD" ]; then
           # Prefer another subscription over paying. Only when every registered
           # account is spent (or none are registered) do we fall to OpenRouter.
           #
           # The turn has already died, so unlike the path before the wall this
           # one has to bring the session back. Claude Code never resumes a parked
           # session by itself — every recovery in the transcripts was a human
           # typing — so we swap, confirm the credential landed, and exit 2. This
           # branch's JSON output is ignored, but the asyncRewake entry in
           # hooks/hooks.json wakes on exit 2, and its rewakeMessage replaces the
           # "Stop hook blocking error" wording the user would otherwise read.
           # stderr is what carries the account's name into that wake.
           from=$(reading_account "$racct")
           if swap_to_spare "$wkey" "$from" "$SWAP_PICK_BUDGET"; then
             IFS=$'\t' read -r account cred _rest <<EOF
$SWAP_RESULT
EOF
             if swap_landed "$account" "$cred"; then
               split_advisory "$account" || rm -f "$SWAP_NOTE" 2>/dev/null || true
               printf '%s\n' "[ccd] Your claude.ai usage limit was reached and ccd switched this session to $account, which has quota. Continue the task you were working on when the limit was reached; do not repeat work that is already complete." >&2
               exit 2
             fi
             # The credential moved but cannot be proved live. Waking into that is
             # a second 429; say so where the next prompt will read it.
             split_advisory "$account" || \
             swap_note "[ccd] The Claude quota ran out and ccd switched this session to $account, but could not confirm that account's credential went live. Nothing was billed. Carry on — \`ccd account list\` shows which account is active."
             exit 0
           fi
           # No swap. Whether this session may move onto a PAID backbone is a
           # different question with its own answer, and nothing above feeds it:
           # not the swap's exit code, not its reason, not the three attempts. The
           # user's rule is three conditions — a key stored, `ccd setup --auto`,
           # and no subscription able to take the session — and the third is
           # PROVED or it is false. Only here, where the wall was actually hit;
           # the tick before the wall never bills while the subscription answers.
           if paid_optin && have_key && subscriptions_proved_spent; then
             if launcher_ready; then
               # Arm first, then signal: the launcher must find the file when the
               # session exits. If the write fails, do NOT signal — ending a
               # session whose handoff was never recorded leaves nothing to bring
               # it back. And un-arm if the signal fails, so a later launcher
               # cannot consume a stale order.
               if write_handoff true to_fallback "$SESSION_ID" "$HOOK_CWD"; then
                 rm -f "$SWAP_NOTE" 2>/dev/null || true
                 request_handoff || rm -f "$HANDOFF" 2>/dev/null || true
               else
                 rm -f "$HANDOFF" 2>/dev/null || true
               fi
               exit 0
             fi
             # Everything the user asked for holds, and the hop still cannot be
             # made: it is a relaunch, and nothing is here to relaunch. Do not
             # pay, do not pretend — say which half is missing and what fixes it.
             swap_note "[ccd] The Claude quota ran out and every subscription is spent. The automatic OpenRouter handoff is on, but this session was not started through the ccd launcher (or has no terminal to come back to), so it cannot happen here. Nothing was billed. /exit and start \`claude\` again to be covered next time — \`ccd doctor\` shows what is missing — or move this conversation now with \`ccd -c\`."
             exit 0
           fi
           # Not proved, not allowed, or no key: ccd stops here and leaves the
           # reason where the next prompt will say it. Only where a spare could
           # have been the answer: with nothing registered there was never
           # anything to move to, and a note every time the quota runs out is noise.
           has_accounts && swap_note "[ccd] The Claude quota ran out and ccd could not move this session to another subscription (${SWAP_REASON:-reason unknown}). Nothing was billed and nothing was ended. \`ccd account list\` shows what each spare looks like, and \`ccd -c\` moves this conversation onto OpenRouter at your own cost if you want it."
         fi ;;
    esac
  fi
  exit 0
fi

# SessionEnd cannot influence the exit, but it can tell the user what is about to
# happen — the launcher's relaunch is otherwise silent until the new screen draws.
if [ "$EVENT" = "SessionEnd" ]; then
  if [ -f "$HANDOFF" ] && [ -n "${CCD_HANDOFF:-}" ]; then
    CCD_HF="$HANDOFF" python3 - <<'PY'
import json, os
try:
    s = json.load(open(os.environ["CCD_HF"]))
except Exception:
    raise SystemExit(0)
if not s.get("armed"):
    raise SystemExit(0)
if s.get("direction") == "to_fallback":
    msg = "[ccd] 🍩 도넛으로 갈아끼웁니다 — 대화 그대로 이어집니다 (OpenRouter, 유료)"
else:
    msg = "[ccd] ✓ 구독으로 돌아갑니다 — 대화 그대로 이어집니다"
print(json.dumps({"systemMessage": msg}, ensure_ascii=False))
PY
  fi
  exit 0
fi

# Update ccd run cost / recovery state at most once per hook cycle.
# Never interpret an invalid quota response or OpenRouter error as recovery.
update_ccd_state() {
  [ -f "$RUN_STATE" ] || return 0
  local usage now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  usage=$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN:-}" \
    "${ANTHROPIC_BASE_URL:-https://openrouter.ai/api}/v1/key" 2>/dev/null | python3 -c '
import json, sys
try:
    value = (json.load(sys.stdin).get("data") or {}).get("usage")
    print(float(value)) if isinstance(value, (int, float)) else None
except Exception:
    pass
' 2>/dev/null)

  CCD_CACHE="$CACHE" CCD_STATE="$RUN_STATE" CCD_OUTAGE="$OUTAGE_STATE" CCD_USAGE="$usage" CCD_NOW="$now" \
    python3 - <<'PY'
import json, os, tempfile
cache_path = os.environ["CCD_CACHE"]
state_path = os.environ["CCD_STATE"]
outage_path = os.environ["CCD_OUTAGE"]
claude = {}
try:
    cache = json.load(open(cache_path)) if os.path.isfile(cache_path) else {}
    claude = cache.get("claude") or {}
    seven = claude.get("sevenDayPercent")
    reset = claude.get("sevenDayReset")
    valid = (claude.get("available") is True and claude.get("error") is False
             and isinstance(seven, (int, float)) and isinstance(reset, str) and bool(reset))
except Exception:
    valid = False
try:
    state = json.load(open(state_path))
except Exception:
    raise SystemExit(0)

# Cost = successfully-read cumulative key usage minus the baseline.
# run = this ccd process's spend; outage = total for the whole quota outage (survives restarts).
# If the baseline fetch failed at ccd startup (async fill too), adopt the current
# value as baseline — costs from here on are accurate and "n/a" never sticks.
def write_atomic(p, obj):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".ccd-state.")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, p)
    os.chmod(p, 0o600)

try:
    usage = float(os.environ["CCD_USAGE"])
    baseline = state.get("baseline_usage_usd")
    if not isinstance(baseline, (int, float)):
        state["baseline_usage_usd"] = usage
        baseline = usage
    state["ccd_spend_usd"] = max(0.0, usage - baseline)
    state["cost_updated_at"] = os.environ["CCD_NOW"]

    try:
        outage = json.load(open(outage_path))
    except Exception:
        outage = None
    if outage is None or not isinstance(outage.get("baseline_usage_usd"), (int, float)):
        outage = {"started_at": state.get("started_at"),
                  "baseline_usage_usd": baseline, "outage_spend_usd": 0.0}
    outage["outage_spend_usd"] = max(0.0, usage - outage["baseline_usage_usd"])
    outage["updated_at"] = os.environ["CCD_NOW"]
    write_atomic(outage_path, outage)
except (KeyError, ValueError, TypeError):
    pass

# Track exhaustion->reset transitions for both the 5-hour and 7-day windows.
# A reset is: the reset timestamp changed AND the prior observation was near-exhausted (>=95%)
# AND the new observation is lower. Exact 100->0 is too strict in practice: the 10-minute
# cache can skip the 100% moment, and the first post-reset observation is often already >0%.
# API/cache errors and null values are left untouched so stale data never fakes a recovery.
windows = [
    ("five_hour", claude.get("fiveHourPercent"), claude.get("fiveHourReset")),
    ("seven_day", claude.get("sevenDayPercent"), claude.get("sevenDayReset")),
]
valid = (claude.get("available") is True and claude.get("error") is False)
if valid:
    for name, percent, reset in windows:
        if not (isinstance(percent, (int, float)) and isinstance(reset, str) and reset):
            continue
        value = int(percent)
        prior = state.get(f"last_{name}_percent")
        prior_reset = state.get(f"last_{name}_reset")
        state[f"last_{name}_percent"] = value
        state[f"last_{name}_reset"] = reset
        if (isinstance(prior, (int, float)) and prior >= 95
                and value < prior and prior_reset and reset != prior_reset):
            state["recovery_notified_window"] = name
            state["recovery_notified_reset"] = reset
            # Quota recovered: settle the outage total.
            # The first ccd of the next outage recreates it with a fresh baseline.
            try:
                os.remove(outage_path)
            except OSError:
                pass

folder = os.path.dirname(state_path)
fd, tmp = tempfile.mkstemp(dir=folder, prefix=".run-state.")
with os.fdopen(fd, "w") as f:
    json.dump(state, f, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, state_path)
os.chmod(state_path, 0o600)
PY
}

# While on the external backbone, keep updating quota and cost but suppress quota/Codex warnings.
if [ -n "${CCD_ACTIVE:-}" ]; then
  update_ccd_state
  [ -f "$RUN_STATE" ] || exit 0

  # Every minute on the external backbone costs real money, and a spare
  # subscription costs nothing — so do not wait for the account we left to
  # recover if another one already has room. This fires before the recovery
  # logic below and is otherwise entirely additive.
  #
  # This is the one hop a credential alone cannot make: while CCD_ACTIVE is set the
  # backbone is an environment variable, so leaving it really does take a relaunch.
  # Install the spare here and arm the plain return — the launcher lands on
  # whatever the live store holds, so it never has to be told which account.
  #
  # Decide from cache and warm it in the background: this runs on UserPromptSubmit,
  # where a blocking probe would freeze the user's prompt for seconds.
  if has_accounts && launcher_ready; then
    # The same transaction the subscription path takes: deciding and installing
    # here too must not straddle a token rotation, or the relaunch lands on a
    # credential the server has already retired.
    if swap_to_spare none "$(reading_account "")" "$SWAP_TICK_BUDGET" --no-probe; then
      esc=${SWAP_RESULT%%	*}
    else
      esc=""
    fi
    if [ -n "$esc" ]; then
      if write_handoff true to_subscription "$SESSION_ID" "$HOOK_CWD"; then
        ESC="$esc" EVENT="$EVENT" python3 -c '
import json, os
name = os.environ["ESC"]
msg = (f"[ccd] A Claude subscription with quota is available again ({name}). "
       "This conversation is moving off the paid OpenRouter backbone and back onto "
       "that subscription now. Nothing to type.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": os.environ["EVENT"],
                  "additionalContext": msg}}, ensure_ascii=False))'
        request_handoff || rm -f "$HANDOFF" 2>/dev/null || true
      else
        rm -f "$HANDOFF" 2>/dev/null || true
      fi
      exit 0
    fi
    # Nothing to move to on the reading we have. Warm it for the next tick —
    # after the decision and never before it: this fires on UserPromptSubmit,
    # where a blocking probe would freeze the prompt for seconds, and a probe
    # that fails writes rows a decision taken on them would then refuse.
    ab=$(ccd_account_bin) && ("$ab" --no-color pick >/dev/null 2>&1 &) || true
  fi

  # AUTO is on only when the launcher is supervising this process; without it the
  # advice below must keep naming the manual commands, since nothing will relaunch.
  # Auto return needs the same readiness as the outbound trip: a supervising
  # launcher, a valid session id, a usable key, and a resolvable claude process.
  auto_ready=""
  launcher_ready && auto_ready=1
  SIGNAL_FLAG="$CCD_DIR/.handoff-signal.$$"
  rm -f "$SIGNAL_FLAG"
  OUT=$(CCD_STATE="$RUN_STATE" EVENT="$EVENT" CCD_SIGNAL_FLAG="$SIGNAL_FLAG" \
        CCD_AUTO="$auto_ready" CCD_SID="$SESSION_ID" CCD_CWD="$HOOK_CWD" CCD_HF="$HANDOFF" \
        CCD_TOKEN="${CCD_HANDOFF:-}" \
        python3 - <<'PY'
import json, os
try:
    s = json.load(open(os.environ["CCD_STATE"]))
except Exception:
    raise SystemExit(0)
window = s.get("recovery_notified_window")
reset = s.get("recovery_notified_reset")
key = f"{window}:{reset}"
# Deliver while we are still inside the recovered window (reset id unchanged) —
# the post-reset percent may legitimately be nonzero.
if window and reset and s.get(f"last_{window}_reset") == reset:
    # The statusline keeps showing this state; inject the context once per reset.
    if s.get("recovery_context_delivered") != key:
        s["recovery_context_delivered"] = key
        import tempfile
        p = os.environ["CCD_STATE"]
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".run-state.")
        with os.fdopen(fd, "w") as f:
            json.dump(s, f, ensure_ascii=False); f.write("\n")
        os.replace(tmp, p); os.chmod(p, 0o600)
        label = "5-hour" if window == "five_hour" else "7-day"
        auto = bool(os.environ.get("CCD_AUTO"))
        sid = os.environ.get("CCD_SID", "")
        if auto and sid:
            # Arm the return trip. The launcher relaunches on the subscription
            # once this session ends, so don't ask the user to type anything.
            hf = os.environ["CCD_HF"]
            st = {"armed": True, "direction": "to_subscription",
                  "token": os.environ.get("CCD_TOKEN", ""),
                  "session_id": sid, "cwd": os.environ.get("CCD_CWD", ""),
                  "armed_at": int(__import__("time").time())}
            wrote = False
            fd2, tmp2 = tempfile.mkstemp(dir=os.path.dirname(hf), prefix=".handoff.")
            try:
                with os.fdopen(fd2, "w") as f:
                    json.dump(st, f, ensure_ascii=False); f.write("\n")
                os.replace(tmp2, hf); os.chmod(hf, 0o600)
                wrote = True
            except Exception:
                pass
            finally:
                if os.path.exists(tmp2):
                    os.unlink(tmp2)
            msg = (f"[ccd] The Claude {label} quota window has reset — the subscription is usable again. "
                   "Automatic handoff is on: this conversation is returning to the subscription now. "
                   "Nothing to type.")
            # Tell the shell to end the session ONLY if the state landed —
            # signalling against a handoff that was never written would strand it.
            if wrote:
                open(os.environ["CCD_SIGNAL_FLAG"], "w").close()
        else:
            msg = (f"[ccd] The Claude {label} quota window has reset — the subscription is usable again. The current session remains on the OpenRouter backbone. "
                   "To return to the subscription, finish the work, `/exit`, then run `claude --resume` in the same terminal. "
                   "Do not use `/logout` or `ccd -c`.")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": os.environ["EVENT"], "additionalContext": msg}}, ensure_ascii=False))
PY
)
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  # The armed return is only useful if the session actually ends — otherwise it
  # sits until some unrelated exit consumes it. Signal now, and disarm if the
  # signal cannot be delivered so nothing stale is left behind.
  if [ -f "$SIGNAL_FLAG" ]; then
    rm -f "$SIGNAL_FLAG"
    request_handoff || rm -f "$HANDOFF" 2>/dev/null || true
  fi
  exit 0
fi

# Keep spare accounts alive. A refresh token lasts ~8.5 days and every refresh
# mints a new one, so a daily touch keeps an unused account usable indefinitely.
# Without it the spare dies quietly and the user discovers it at the exact moment
# they needed it — the failure ccd exists to prevent. Backgrounded: this must
# never add latency to a prompt, and it is a no-op on all but one tick a day.
if [ -z "${CCD_ACTIVE:-}" ] && has_accounts && ka=$(ccd_account_bin); then
  # --pick re-measures the spares into accounts-quota.json, which keepalive never does
  # and the statusline's spare row reads (#24). On every tick once that reading is past
  # the TTL, not on prompts alone: an autonomous turn can run tool uses for an hour
  # without one (#54). A fresh reading adds nothing to the tick. keepalive and the pick
  # both spend one-time refresh tokens, so they run as one job under one lock, shared
  # with the statusline's trigger (cmd_keepalive). --detach because Claude Code kills a
  # hook that outruns its timeout by process group, and a kill mid token-exchange loses
  # a token the server has already rotated.
  if [ "$(file_age "$CCD_DIR/accounts-quota.json")" -ge "${CCD_CANDIDATE_TTL:-300}" ]; then
    "$ka" --no-color keepalive --pick --detach >/dev/null 2>&1 &
  else
    "$ka" --no-color keepalive --detach >/dev/null 2>&1 &
  fi
fi

# ── Swap before the wall ─────────────────────────────────────────────────────
# The reading that corroborates a rate_limit arrives up to ten minutes before the
# rate_limit does. When it already says the quota is gone and a spare has room,
# there is nothing to wait for: swap here, say so in one line, and let the turn
# run on. Nothing ends, nothing is signalled, no launcher is involved — StopFailure
# above stays for what this cannot see. The pick is cache-only because this fires
# several times a minute and the block above keeps that cache current.
#
# This preempts the two warnings below: both write to stdout, and two JSON objects
# would not parse as one hook result.
if has_accounts; then
  read_peak
  case "$peak" in
    ''|*[!0-9]*) : ;;
    *) if [ "$peak" -ge "$ARM_THRESHOLD" ] \
          && from=$(reading_account "$racct") \
          && { swap_to_spare "$wkey" "$from" "$SWAP_TICK_BUDGET" --no-probe \
               || { [ -e "$CCD_DIR/store-split" ] && swap_note "[ccd] The Claude quota is nearly gone and ccd cannot move this session: $SWAP_REASON"; false; }; } \
          && moved=${SWAP_RESULT%%	*} && [ -n "$moved" ]; then
         split_advisory "$moved" || rm -f "$SWAP_NOTE" 2>/dev/null || true
         MOVED="$moved" EVENT="$EVENT" python3 -c '
import json, os
name = os.environ["MOVED"]
print(json.dumps({
    "systemMessage": f"[ccd] ✓ 쿼타가 바닥나기 전에 {name} 계정으로 갈아탔습니다 "
                     "— 무과금, 대화 그대로 이어집니다",
    "hookSpecificOutput": {
        "hookEventName": os.environ["EVENT"],
        # The model is mid-turn and about to see the account change under it.
        "additionalContext":
            f"[ccd] The Claude subscription behind this session ran out of quota, so ccd "
            f"switched it to {name}, which has room. Nothing was lost and nothing is "
            f"billed — carry on with the task. The model list and /status still describe "
            f"the previous account until this session is next launched.",
    },
}, ensure_ascii=False))'
         exit 0
       fi ;;
  esac
fi

# Deliver the backstop's note. A turn died, ccd could not move it, and the path
# that learned why had no screen to say it on. Claiming by rename is the whole
# "once" mechanism: exactly one of several concurrent prompts wins the file, and
# the reason is gone as soon as it has been said.
if [ "$EVENT" = "UserPromptSubmit" ] && [ -f "$SWAP_NOTE" ]; then
  OUT=$(CCD_NOTE_FILE="$SWAP_NOTE" EVENT="$EVENT" python3 - <<'PY' 2>/dev/null
import json, os
p = os.environ["CCD_NOTE_FILE"]
claim = f"{p}.said.{os.getpid()}"
try:
    os.rename(p, claim)                 # atomic: only one prompt can win it
    msg = json.load(open(claim))["message"]
except Exception:
    raise SystemExit(0)
finally:
    try:
        os.unlink(claim)
    except OSError:
        pass
print(json.dumps({"hookSpecificOutput": {"hookEventName": os.environ["EVENT"],
                                         "additionalContext": msg}},
                 ensure_ascii=False))
PY
)
  if [ -n "$OUT" ]; then
    printf '%s\n' "$OUT"
    exit 0
  fi
fi

# Deliver keepalive's verdict. It runs backgrounded with its output discarded, so
# it leaves a breadcrumb and a later tick surfaces it; before this, a spare that
# stopped refreshing was announced to /dev/null and the user met the failure at
# the moment of the handoff. On prompts only, and at most every four hours:
# staleness moves in days, so tool-use ticks would be pure noise. This preempts
# the quota warning below — that one repeats every ten minutes anyway, and two
# JSON objects on stdout would not parse as one hook result.
if [ "$EVENT" = "UserPromptSubmit" ] && [ -f "$STALE_FILE" ] \
   && [ "$(file_age "$STALE_MARK")" -gt "$STALE_TTL" ]; then
  # The shell check above is only a cheap pre-filter. Prompts from several
  # sessions can land together, and a check-then-touch would let each of them
  # emit; the claim is made under flock so exactly one does.
  OUT=$(python3 - "$STALE_FILE" "$EVENT" "$STALE_MARK" "$STALE_TTL" <<'EOF'
import json, os, sys, time
try:
    msg = json.load(open(sys.argv[1]))["message"]
except Exception:
    sys.exit(0)
fd = os.open(sys.argv[3], os.O_CREAT | os.O_RDWR, 0o600)
try:
    import fcntl
    fcntl.flock(fd, fcntl.LOCK_EX)
except Exception:
    pass
# An empty file is one O_CREAT just made, not a claim: its mtime is "now" and
# would otherwise silence every first warning. A claim writes the time.
st = os.fstat(fd)
if st.st_size and time.time() - st.st_mtime <= int(sys.argv[4]):
    sys.exit(0)
os.ftruncate(fd, 0); os.write(fd, str(int(time.time())).encode())
print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[2],
                                         "additionalContext": msg}}, ensure_ascii=False))
EOF
)
  if [ -n "$OUT" ]; then
    echo "$OUT"
    exit 0
  fi
fi

[ -f "$CACHE" ] || exit 0

# Skip if we already warned within the last 10 minutes
[ "$(file_age "$WARN_MARK")" -le "$TTL" ] && exit 0

OUT=$(python3 - "$CACHE" "$THRESHOLD" "$EVENT" <<'EOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
th = int(sys.argv[2])
event = sys.argv[3]
c = d.get("claude") or {}
five = c.get("fiveHourPercent")
seven = c.get("sevenDayPercent")
vals = [p for p in (five, seven) if isinstance(p, (int, float))]
if not vals or max(vals) < th:
    sys.exit(0)
msg = (
    f"[quota-guard] Claude quota threshold exceeded: 5h {five}%, 7d {seven}% (threshold {th}%)."
)
codex = d.get("codex") or {}
codex_five = codex.get("fiveHourPercent")
if isinstance(codex_five, (int, float)):
    msg += (f" Codex 5h usage: {codex_five}% (plan {codex.get('plan')}). "
            "If the Codex plugin is installed, delegate implementation work to it and keep Claude for specs/review/tests.")
# 95%+ = nearly exhausted. Once quota hits zero the user cannot ask Claude for setup help,
# so the backbone-switch path must be surfaced now, while Claude can still respond.
if max(vals) >= 95:
    msg += (
        " ★QUOTA NEARLY EXHAUSTED★ Tell the user now: (1) `ccd` is ready as an alternate backbone switcher, and "
        "`ccd -c` resumes the last conversation on a low-cost OpenRouter model. "
        "(2) If OPENROUTER_API_KEY in ~/.claude/ccd/providers/keys.env is empty, set it while quota remains and "
        "validate with `ccd doctor`; setup is impossible after exhaustion. "
        "(3) See ~/.claude/ccd/QUOTA-SOS.md for details."
    )
print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": msg}}, ensure_ascii=False))
EOF
)
if [ -n "$OUT" ]; then
  touch "$WARN_MARK"
  echo "$OUT"
fi
