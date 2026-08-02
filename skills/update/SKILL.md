---
name: update
description: Update the ccx plugin to the latest version in one step. Use for /ccx:update, "ccx 업데이트" (update ccx), "update the ccx plugin", or when the user wants the newest ccx release applied.
---

# ccx update

Update the installed ccx plugin to the latest published version. Everything runs
from the CLI — the user does not need the interactive `/plugin` menu.

## Procedure

1. Refresh the marketplace and update the plugin:

```sh
claude plugin marketplace update ccx
claude plugin update ccx
```

2. Verify what the terminal launcher now resolves to (it picks the newest
   installed version automatically — no rewiring needed):

```sh
ls -d "$HOME/.claude/plugins/cache"/*/ccx/*/bin/ccx | sort -V | tail -1
```

3. Report the old → new version to the user (the update command prints it;
   `claude plugin list` shows the installed version if needed).

4. Tell the user to run `/reload-plugins` (or restart Claude Code) to apply the
   updated hooks and skills to the current session. The statusline and terminal
   `ccx` command are already on the new version via the dynamic launchers.

## Notes

- If `claude plugin update` reports the plugin was installed from a local path
  marketplace, the same commands still work — the marketplace update re-reads
  the local directory.
- Never touch `~/.claude/ccx/` state or `providers/` during an update; user
  config and keys are outside the plugin directory by design and survive
  updates untouched.
