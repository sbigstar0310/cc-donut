---
name: update
description: Update the ccd plugin to the latest version in one step. Use for /ccd:update, "ccd 업데이트" (update ccd), "update the ccd plugin", or when the user wants the newest ccd release applied.
---

# ccd update

Update the installed ccd plugin to the latest published version. Everything runs
from the CLI — the user does not need the interactive `/plugin` menu.

## Procedure

1. Refresh the marketplace and update the plugin:

```sh
claude plugin marketplace update cc-donut
claude plugin update ccd@cc-donut
```

(The `plugin@marketplace` form is required — a bare `ccd` reports "not found".)

2. Verify what the terminal launcher now resolves to (it picks the newest
   installed version automatically — no rewiring needed):

```sh
ls -d "$HOME/.claude/plugins/cache"/*/ccd/*/bin/ccd | sort -V | tail -1
```

3. Report the result in at most 3 short lines (old → new version; launcher OK).

4. **The last line of your reply must be exactly this call to action, alone,
   with nothing after it** — Claude cannot run slash commands, so the user must:

   ```
   → Type /reload-plugins now — until then, this session still runs the OLD version's skills and hooks.
   ```

   (Skip that line only when the plugin was already at the latest version and
   nothing changed.) The statusline and terminal `ccd` command are already on
   the new version via the dynamic launchers; the reload is the only remaining
   step, so never bury it in prose.

## Notes

- If `claude plugin update` reports the plugin was installed from a local path
  marketplace, the same commands still work — the marketplace update re-reads
  the local directory.
- Never touch `~/.claude/ccd/` state or `providers/` during an update; user
  config and keys are outside the plugin directory by design and survive
  updates untouched.
