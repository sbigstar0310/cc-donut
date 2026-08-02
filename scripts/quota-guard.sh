#!/bin/bash
# Claude Code hook shared by UserPromptSubmit and PostToolUse.
# Checks claude-dashboard usage through a ten-minute cache. In normal sessions it recommends
# Codex delegation at 85%; in ccx sessions it tracks cost and Claude quota resets only.
EVENT="${1:-UserPromptSubmit}"
CCX_DIR="$HOME/.claude/ccx"
CACHE="$CCX_DIR/quota-cache.json"
WARN_MARK="$CCX_DIR/last-warn"
RUN_STATE="$CCX_DIR/run-state.json"
OUTAGE_STATE="$CCX_DIR/outage-state.json"
mkdir -p "$CCX_DIR"
[ -f "$HOME/.claude/quota-guard-cache.json" ] && [ ! -f "$CACHE" ] && mv "$HOME/.claude/quota-guard-cache.json" "$CACHE" 2>/dev/null || true
[ -f "$HOME/.claude/quota-guard-last-warn" ] && [ ! -f "$WARN_MARK" ] && mv "$HOME/.claude/quota-guard-last-warn" "$WARN_MARK" 2>/dev/null || true
[ -f "$HOME/.claude/ccx-run-state.json" ] && [ ! -f "$RUN_STATE" ] && mv "$HOME/.claude/ccx-run-state.json" "$RUN_STATE" 2>/dev/null || true
[ -f "$HOME/.claude/ccx-outage-state.json" ] && [ ! -f "$OUTAGE_STATE" ] && mv "$HOME/.claude/ccx-outage-state.json" "$OUTAGE_STATE" 2>/dev/null || true
TTL=600
THRESHOLD=85

# Bridge the plugin's userConfig key (set via /plugin → ccx → Configure options,
# stored in the system keychain, injected here as an env var) into keys.env so
# the terminal-side `ccx` — which runs outside Claude Code — can use it too.
# Only fills an empty slot; an existing key is never overwritten.
KEYS_ENV="$CCX_DIR/providers/keys.env"
if [ -n "${CLAUDE_PLUGIN_OPTION_OPENROUTER_API_KEY:-}" ] \
   && ! grep -q '^OPENROUTER_API_KEY="..*"' "$KEYS_ENV" 2>/dev/null; then
  mkdir -p "$CCX_DIR/providers"
  printf 'OPENROUTER_API_KEY="%s"\n' "$CLAUDE_PLUGIN_OPTION_OPENROUTER_API_KEY" > "$KEYS_ENV"
  chmod 600 "$KEYS_ENV"
fi

file_age() {
  local f="$1" now mtime
  now=$(date +%s)
  [ -f "$f" ] || { echo 999999; return; }
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
  [ -n "$mtime" ] && echo $((now - mtime)) || echo 999999
}

# Refresh the dashboard's Claude quota cache regardless of ccx state,
# so Claude resets are visible even while the external backbone is active.
if [ "$(file_age "$CACHE")" -gt "$TTL" ]; then
  script=$(ls -d "$HOME/.claude"/plugins/cache/claude-dashboard/claude-dashboard/*/dist/check-usage.js 2>/dev/null | sort -V | tail -1)
  [ -n "$script" ] && node "$script" --json > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE" || rm -f "$CACHE.tmp"
fi

# Update ccx run cost / recovery state at most once per hook cycle.
# Never interpret an invalid quota response or OpenRouter error as recovery.
update_ccx_state() {
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

  CCX_CACHE="$CACHE" CCX_STATE="$RUN_STATE" CCX_OUTAGE="$OUTAGE_STATE" CCX_USAGE="$usage" CCX_NOW="$now" \
    python3 - <<'PY'
import json, os, tempfile
cache_path = os.environ["CCX_CACHE"]
state_path = os.environ["CCX_STATE"]
outage_path = os.environ["CCX_OUTAGE"]
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
# run = this ccx process's spend; outage = total for the whole quota outage (survives restarts).
# If the baseline fetch failed at ccx startup (async fill too), adopt the current
# value as baseline — costs from here on are accurate and "n/a" never sticks.
def write_atomic(p, obj):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".ccx-state.")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, p)
    os.chmod(p, 0o600)

try:
    usage = float(os.environ["CCX_USAGE"])
    baseline = state.get("baseline_usage_usd")
    if not isinstance(baseline, (int, float)):
        state["baseline_usage_usd"] = usage
        baseline = usage
    state["ccx_spend_usd"] = max(0.0, usage - baseline)
    state["cost_updated_at"] = os.environ["CCX_NOW"]

    try:
        outage = json.load(open(outage_path))
    except Exception:
        outage = None
    if outage is None or not isinstance(outage.get("baseline_usage_usd"), (int, float)):
        outage = {"started_at": state.get("started_at"),
                  "baseline_usage_usd": baseline, "outage_spend_usd": 0.0}
    outage["outage_spend_usd"] = max(0.0, usage - outage["baseline_usage_usd"])
    outage["updated_at"] = os.environ["CCX_NOW"]
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
            # The first ccx of the next outage recreates it with a fresh baseline.
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
if [ -n "${CCX_ACTIVE:-}" ]; then
  update_ccx_state
  [ -f "$RUN_STATE" ] || exit 0

  OUT=$(CCX_STATE="$RUN_STATE" EVENT="$EVENT" python3 - <<'PY'
import json, os
try:
    s = json.load(open(os.environ["CCX_STATE"]))
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
        p = os.environ["CCX_STATE"]
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".run-state.")
        with os.fdopen(fd, "w") as f:
            json.dump(s, f, ensure_ascii=False); f.write("\n")
        os.replace(tmp, p); os.chmod(p, 0o600)
        label = "5-hour" if window == "five_hour" else "7-day"
        msg = (f"[ccx] The Claude {label} quota window has reset — the subscription is usable again. The current session remains on the OpenRouter backbone. "
               "To return to the subscription, finish the work, `/exit`, then run `claude --resume` in the same terminal. "
               "Do not use `/logout` or `ccx -c`.")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": os.environ["EVENT"], "additionalContext": msg}}, ensure_ascii=False))
PY
)
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
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
        " ★QUOTA NEARLY EXHAUSTED★ Tell the user now: (1) `ccx` is ready as an alternate backbone switcher, and "
        "`ccx -c` resumes the last conversation on a low-cost OpenRouter model. "
        "(2) If OPENROUTER_API_KEY in ~/.claude/ccx/providers/keys.env is empty, set it while quota remains and "
        "validate with `ccx doctor`; setup is impossible after exhaustion. "
        "(3) See ~/.claude/ccx/QUOTA-SOS.md for details."
    )
print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": msg}}, ensure_ascii=False))
EOF
)
if [ -n "$OUT" ]; then
  touch "$WARN_MARK"
  echo "$OUT"
fi
