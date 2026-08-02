---
name: setup
description: Wire ccx terminal launchers and statusline after plugin installation, and safely migrate a legacy pre-plugin ccx installation. Use for /ccx:setup or first-time ccx setup.
---

# ccx setup

Run setup from the newest installed ccx plugin:

```sh
t=$(ls -d "$HOME/.claude/plugins/cache"/*/ccx/*/bin/ccx 2>/dev/null | sort -V | tail -1); "$t" setup
```

Add one short introductory line, then relay the script's output to the user verbatim and add nothing else. If the script prints a PATH line, make sure the user sees it.

Never ask for or expose an OpenRouter API key. Never edit files directly; the script owns all writes. If the script fails, show the error and stop.
