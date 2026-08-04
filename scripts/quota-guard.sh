#!/bin/bash
# Claude Code hook shared by UserPromptSubmit, PostToolUse, StopFailure, and SessionEnd.
# Checks claude-dashboard usage through a ten-minute cache. In normal sessions it recommends
# Codex delegation at 85%; in ccd sessions it tracks cost and Claude quota resets only.
# StopFailure/SessionEnd additionally record automatic-handoff state (see arm_handoff).
EVENT="${1:-UserPromptSubmit}"
CCD_DIR="$HOME/.claude/ccd"
CACHE="$CCD_DIR/quota-cache.json"
WARN_MARK="$CCD_DIR/last-warn"
RUN_STATE="$CCD_DIR/run-state.json"
OUTAGE_STATE="$CCD_DIR/outage-state.json"
# The launcher names its own state file and passes the path down; a fixed name
# would be shared by every concurrent session (see write_handoff).
HANDOFF="${CCD_HANDOFF_STATE:-$CCD_DIR/handoff.json}"
mkdir -p "$CCD_DIR"
TTL=600
THRESHOLD=85
# Arming needs the quota reading to corroborate the API error: a bare rate_limit
# can be transient throttling, and a handoff on that would be a false alarm.
ARM_THRESHOLD=95

# Hook payloads arrive on stdin as one JSON object. Read it with pure bash: the
# obvious `timeout 0.5 cat` is not portable — macOS has no timeout(1), and under
# `set -e` its absence silently killed every hook, taking the quota warnings with
# it. Claude Code closes stdin after the payload, so a plain read terminates.
# `-t 0` means "is stdin a terminal": when run by hand there is no payload to wait for.
HOOK_INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' HOOK_INPUT || true
fi

# Extract the fields this script uses. Absent/malformed input leaves them empty,
# which every caller below treats as "not applicable" rather than an error.
SESSION_ID=""; HOOK_CWD=""; ERROR_TYPE=""; EXIT_REASON=""
if [ -n "$HOOK_INPUT" ]; then
  # Tab-separated so a value containing spaces survives; newlines are impossible
  # in these fields (they are ids, paths, and enum tags).
  IFS=$'\t' read -r SESSION_ID HOOK_CWD ERROR_TYPE EXIT_REASON <<EOF
$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    print("\t\t\t"); raise SystemExit(0)
def s(k):
    v = d.get(k)
    return v if isinstance(v, str) else ""
print("\t".join((s("session_id"), s("cwd"), s("error_type"), s("exit_reason"))))
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

if [ "$(file_age "$CACHE")" -gt "$TTL" ]; then
  script=$(ls -d "$HOME/.claude"/plugins/cache/claude-dashboard/claude-dashboard/*/dist/check-usage.js 2>/dev/null | sort -V | tail -1)
  node_bin=$(find_node) || node_bin=""
  # This hook fires on both UserPromptSubmit and PostToolUse, so instances run
  # concurrently. A shared tmp name lets one instance truncate/delete another's
  # in-flight write and the refresh silently fails forever under load — use a
  # per-process tmp and install it only when it parses as JSON.
  tmp="$CACHE.tmp.$$"
  if [ -n "$script" ] && [ -n "$node_bin" ] && "$node_bin" "$script" --json > "$tmp" 2>/dev/null \
     && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp" 2>/dev/null; then
    mv "$tmp" "$CACHE"
    rm -f "$CCD_DIR/refresh-failed"
  else
    rm -f "$tmp"
    # Leave a breadcrumb so `ccd doctor` can say quota data is stale instead of
    # the warnings just never appearing.
    { [ -n "$script" ] || echo "claude-dashboard not installed"
      [ -n "$node_bin" ] || echo "node not found in hook PATH"; } > "$CCD_DIR/refresh-failed" 2>/dev/null
  fi
fi

# ── Automatic handoff ────────────────────────────────────────────────────────
# Records whether the launcher should relaunch this conversation on the other
# backbone. Writing the file is always safe; only the launcher acts on it, and
# only when it installed itself (see the CCD_HANDOFF interlock below).

# Highest observed quota percentage, or empty when the data is unusable.
# Unusable is deliberately NOT zero: a missing reading must never arm a handoff.
quota_peak() {
  [ -f "$CACHE" ] || return 0
  python3 - "$CACHE" 2>/dev/null <<'PY'
import json, sys
try:
    c = (json.load(open(sys.argv[1])).get("claude") or {})
except Exception:
    raise SystemExit(0)
if c.get("available") is not True or c.get("error") is not False:
    raise SystemExit(0)
vals = [p for p in (c.get("fiveHourPercent"), c.get("sevenDayPercent"))
        if isinstance(p, (int, float)) and not isinstance(p, bool)]
if vals:
    print(int(max(vals)))
PY
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
    "direction": os.environ["CCD_DIR_TO"],      # to_fallback | to_subscription
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

# Everything that must hold before a session may be ended. Checked BEFORE arming,
# not after: an armed file left behind by an unsupervised or unready session
# would be consumed by a later launcher and resume the wrong conversation.
handoff_ready() {
  launcher_present || return 1
  valid_session_id "$SESSION_ID" || return 1
  have_key || return 1
  claude_pid >/dev/null || return 1
}

# StopFailure fires when a turn ends on an API error. Its output is ignored by
# Claude Code, so this branch exists purely for the side effect.
if [ "$EVENT" = "StopFailure" ]; then
  # Corroborate: the error says rate_limit AND the dashboard agrees we are spent.
  # Either alone is not enough — a rate_limit can be transient, and a high
  # reading alone does not mean the request actually failed.
  if [ "$ERROR_TYPE" = "rate_limit" ] && [ -z "${CCD_ACTIVE:-}" ] && handoff_ready; then
    peak=$(quota_peak)
    case "$peak" in
      ''|*[!0-9]*) : ;;   # no trustworthy reading → stay disarmed
      *) if [ "$peak" -ge "$ARM_THRESHOLD" ]; then
           # Arm first, then signal: the launcher must find the file when the
           # session exits. If the write fails, do NOT signal — ending a session
           # whose handoff was never recorded leaves nothing to bring it back.
           if write_handoff true to_fallback "$SESSION_ID" "$HOOK_CWD"; then
             request_handoff || rm -f "$HANDOFF" 2>/dev/null || true
           else
             rm -f "$HANDOFF" 2>/dev/null || true
           fi
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
msg = ("[ccd] 🍩 도넛으로 갈아끼웁니다 — 대화 그대로 이어집니다"
       if s.get("direction") == "to_fallback"
       else "[ccd] ✓ 구독으로 돌아갑니다 — 대화 그대로 이어집니다")
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

  # AUTO is on only when the launcher is supervising this process; without it the
  # advice below must keep naming the manual commands, since nothing will relaunch.
  # Auto return needs the same readiness as the outbound trip: a supervising
  # launcher, a valid session id, a usable key, and a resolvable claude process.
  auto_ready=""
  handoff_ready && auto_ready=1
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
