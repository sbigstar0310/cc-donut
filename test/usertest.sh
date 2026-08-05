#!/usr/bin/env bash
# Run a real session against this branch, without touching the installed plugin.
#
# The obvious approach — copying the branch over the plugin cache — does not
# survive: Claude Code re-syncs managed plugins from the marketplace and quietly
# restores the published files. A test that silently reverts to old code is worse
# than no test, because it looks like the feature is broken.
#
# So nothing managed is modified. Instead:
#   · the launchers resolve `cache/*/ccd/*/bin/...` and take the highest version,
#     so a dev-only version directory of symlinks wins without being registered
#   · hooks come from the TEST PROJECT's settings.local.json, pointing straight at
#     this checkout — project settings are not managed either
#
#   test/usertest.sh setup      wire it up, print where
#   test/usertest.sh check      is it actually wired up right now?
#   test/usertest.sh quota 99   pretend the 5-hour window is nearly spent
#   test/usertest.sh quota ok   pretend it just reset (arms the return trip)
#   test/usertest.sh restore    remove everything this created
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEV="$HOME/.claude/plugins/cache/cc-donut/ccd/99.0.0-usertest"
PROJ="${CCD_TEST_PROJECT:-/tmp/ccd-test}"
QUOTA="$HOME/.claude/ccd/quota-cache.json"
QBACKUP="$HOME/.claude/ccd/.usertest-quota"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

case "${1:-}" in
  setup)
    mkdir -p "$DEV/bin" "$DEV/scripts" "$DEV/hooks" "$PROJ/.claude" || exit 1
    for f in ccd ccd-handoff ccd-statusline ccd-price-fetch; do
      ln -sf "$ROOT/bin/$f" "$DEV/bin/$f"
    done
    ln -sf "$ROOT/scripts/quota-guard.sh" "$DEV/scripts/quota-guard.sh"
    ln -sf "$ROOT/hooks/hooks.json" "$DEV/hooks/hooks.json"
    printf '{"name":"ccd","version":"99.0.0-usertest"}\n' > "$DEV/.plugin.json"
    green "✓ launchers now resolve this checkout (via $DEV)"

    # Hooks: the plugin registry still points at the published version, so the
    # events this branch adds would never fire. Register them for the test
    # project only — nothing global changes.
    G="$ROOT/scripts/quota-guard.sh"
    cat > "$PROJ/.claude/settings.local.json" <<JSON
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "'$G' UserPromptSubmit"}]}],
    "PostToolUse":      [{"hooks": [{"type": "command", "command": "'$G' PostToolUse"}]}],
    "StopFailure":      [{"matcher": "rate_limit", "hooks": [{"type": "command", "command": "'$G' StopFailure"}]}],
    "SessionEnd":       [{"hooks": [{"type": "command", "command": "'$G' SessionEnd"}]}]
  }
}
JSON
    green "✓ hooks registered for $PROJ only"
    dim   "  (the installed plugin is untouched, so nothing here can be re-synced away)"
    printf '\n→ Test from %s. Anywhere else runs the published version.\n' "$PROJ"
    ;;

  check)
    fail=0
    t=$(ls -d "$HOME/.claude/plugins/cache"/*/ccd/*/bin/ccd-handoff 2>/dev/null | sort -V | tail -1)
    if [ -n "$t" ] && [ "$(readlink "$t" 2>/dev/null || echo "$t")" = "$ROOT/bin/ccd-handoff" ]; then
      green "✓ launchers resolve this checkout"
    else
      red "✗ launchers resolve ${t:-nothing} — re-run: test/usertest.sh setup"; fail=1
    fi
    if grep -q 'StopFailure' "$PROJ/.claude/settings.local.json" 2>/dev/null; then
      green "✓ handoff hooks registered for $PROJ"
    else
      red "✗ no hooks in $PROJ — re-run: test/usertest.sh setup"; fail=1
    fi
    if [ -n "${CCD_HANDOFF:-}" ]; then
      green "✓ this shell/session is supervised by the launcher"
    else
      dim   "· this shell is not supervised — expected unless you are inside a claude session"
    fi
    q=$(python3 -c "
import json,os
p=os.path.expanduser('~/.claude/ccd/quota-cache.json')
print(json.load(open(p))['claude']['fiveHourPercent'])" 2>/dev/null || echo "?")
    dim "· 5-hour window currently reads ${q}% (needs ≥95 to arm a handoff)"
    exit "$fail"
    ;;

  quota)
    [ -f "$QUOTA" ] || { red "✗ no quota reading yet — open a session first"; exit 1; }
    [ -f "$QBACKUP" ] || cp "$QUOTA" "$QBACKUP"
    case "${2:-}" in
      99) python3 - "$QUOTA" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["claude"]["fiveHourPercent"] = 99
json.dump(d, open(p, "w"))
print("✓ 5-hour window now reads 99% — a rate_limit will arm the handoff")
PY
         ;;
      ok) python3 - "$QUOTA" "$HOME/.claude/ccd/run-state.json" <<'PY'
import json, os, sys, time
# Recovery is a TRANSITION, not a value: the guard arms only when the previous
# observation was >=95%, the new one is lower, and the reset id changed. Seeding
# the cache alone is not enough — the "previous observation" lives in run-state,
# and a real dashboard refresh may have already overwritten what we seeded. So
# state both ends of the transition explicitly.
quota, run = sys.argv[1], sys.argv[2]
d = json.load(open(quota))
old_reset = d["claude"].get("fiveHourReset") or "seeded-old-window"
try:
    s = json.load(open(run))
except Exception:
    s = None
if s is not None:
    s["last_five_hour_percent"] = 99
    s["last_five_hour_reset"] = old_reset
    json.dump(s, open(run, "w"))
d["claude"]["fiveHourPercent"] = 12
d["claude"]["fiveHourReset"] = time.strftime(
    "%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 5 * 3600))
json.dump(d, open(quota, "w"))
print("✓ window reset: 99% -> 12% with a new reset id — the return trip will arm")
print("  send one prompt in the ccd session now, before the real dashboard refreshes")
PY
         ;;
      *) echo "usage: test/usertest.sh quota 99|ok"; exit 2 ;;
    esac
    ;;

  restore)
    [ -d "$DEV" ] && rm -rf "$DEV" && green "✓ dev launcher directory removed"
    [ -f "$PROJ/.claude/settings.local.json" ] \
      && rm -f "$PROJ/.claude/settings.local.json" && green "✓ test-project hooks removed"
    if [ -f "$QBACKUP" ]; then
      cp "$QBACKUP" "$QUOTA" && rm -f "$QBACKUP" && green "✓ quota reading restored"
    fi
    printf '→ Also run: ccd setup --no-auto   (removes the launcher and the PATH line)\n'
    ;;

  *) echo "usage: test/usertest.sh setup|check|quota 99|quota ok|restore"; exit 2 ;;
esac
