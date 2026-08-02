---
name: setup
description: Wire ccx terminal launchers and statusline after plugin installation, and safely migrate a legacy pre-plugin ccx installation. Use for /ccx:setup or first-time ccx setup.
---

# ccx setup

Run setup from the newest installed ccx plugin:

```sh
t=$(ls -d "$HOME/.claude/plugins/cache"/*/ccx/*/bin/ccx 2>/dev/null | sort -V | tail -1); "$t" setup
```

Add one short introductory line, then relay the script's output to the user verbatim. If the script prints a PATH line, make sure the user sees it.

## Continue in-session — don't send the user to a terminal

If the setup output says the OpenRouter key is not set, offer to finish right
now by following the `key` skill in this plugin (skills/key/SKILL.md): the
default path is pasting the key in chat with informed consent; macOS can use
the `ccx key` native dialog. After the key lands, run `~/.local/bin/ccx doctor` and relay its one-line verdict.

If the key was already configured, just run `~/.local/bin/ccx doctor` directly and
relay the verdict — no question needed. Either way the user should finish setup,
key, and validation without leaving the session; only the final "restart Claude
Code" remains.

Key handling follows the `key` skill: chat paste only with the consent notice,
never echo a full key back, never write it anywhere but through `ccx key`.
Never edit files directly; the script owns all writes. If the script fails,
show the error and stop.
