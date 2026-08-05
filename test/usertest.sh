#!/usr/bin/env bash
# Stage this branch into the installed plugin so a real session runs it — and put
# everything back afterwards. The published plugin has neither the handoff
# launcher nor the StopFailure hook, so without this a `claude` launch would
# quietly fall through and the test would look broken for the wrong reason.
#
#   test/usertest.sh setup     stage the branch, back up what was there
#   test/usertest.sh quota 99  pretend the 5-hour window is 99% used
#   test/usertest.sh quota ok  pretend it just reset (triggers the return trip)
#   test/usertest.sh restore   put the plugin and the quota reading back
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CACHE="$HOME/.claude/plugins/cache/cc-donut/ccd"
QUOTA="$HOME/.claude/ccd/quota-cache.json"
BACKUP="$HOME/.claude/ccd/.usertest-backup"

plugin_dir() { ls -d "$CACHE"/*/ 2>/dev/null | sort -V | tail -1; }

case "${1:-}" in
  setup)
    P=$(plugin_dir) || true
    [ -n "${P:-}" ] || { echo "✗ ccd plugin is not installed — install it first"; exit 1; }
    P=${P%/}
    if [ -e "$BACKUP" ]; then
      echo "✓ backup already exists — staging over the current copy"
    else
      cp -a "$P" "$BACKUP" || exit 1
      echo "✓ backed up $P → $BACKUP"
    fi
    mkdir -p "$P/bin" "$P/scripts" "$P/hooks"
    cp "$ROOT/bin/ccd" "$ROOT/bin/ccd-handoff" "$ROOT/bin/ccd-statusline" \
       "$ROOT/bin/ccd-price-fetch" "$P/bin/" || exit 1
    cp "$ROOT/scripts/quota-guard.sh" "$P/scripts/" || exit 1
    cp "$ROOT/hooks/hooks.json" "$P/hooks/" || exit 1
    chmod +x "$P/bin/"* "$P/scripts/"*
    echo "✓ staged this branch into $P"
    echo "→ Run /reload-plugins in this session so the new hooks take effect."
    ;;
  quota)
    [ -f "$QUOTA" ] || { echo "✗ no quota reading yet — open a session first"; exit 1; }
    [ -f "$BACKUP.quota" ] || cp "$QUOTA" "$BACKUP.quota"
    case "${2:-}" in
      99) python3 - "$QUOTA" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["claude"]["fiveHourPercent"] = 99
json.dump(d, open(p, "w"))
print("✓ 5-hour window now reads 99% — a rate_limit will arm the handoff")
PY
         ;;
      ok) python3 - "$QUOTA" <<'PY'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p))
d["claude"]["fiveHourPercent"] = 12          # recovered
# A different reset id is what marks the window as having turned over.
d["claude"]["fiveHourReset"] = time.strftime(
    "%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 5 * 3600))
json.dump(d, open(p, "w"))
print("✓ 5-hour window now reads 12% with a new reset — the return trip will arm")
PY
         ;;
      *) echo "usage: test/usertest.sh quota 99|ok"; exit 2 ;;
    esac
    ;;
  restore)
    P=$(plugin_dir); P=${P%/}
    if [ -d "$BACKUP" ]; then
      rm -rf "$P" && cp -a "$BACKUP" "$P" && rm -rf "$BACKUP" \
        && echo "✓ plugin restored from backup"
    else
      echo "· no plugin backup to restore"
    fi
    if [ -f "$BACKUP.quota" ]; then
      cp "$BACKUP.quota" "$QUOTA" && rm -f "$BACKUP.quota" && echo "✓ quota reading restored"
    else
      echo "· no quota backup to restore"
    fi
    echo "→ Also run: ccd setup --no-auto   (removes the launcher and the PATH line)"
    ;;
  *)
    echo "usage: test/usertest.sh setup|quota 99|quota ok|restore"; exit 2 ;;
esac
