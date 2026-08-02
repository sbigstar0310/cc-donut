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

If the setup output says the OpenRouter key is not set, offer to finish right now
(one short question, e.g. "Set the key now? A native dialog will open — your key
never appears in this chat."). If the user agrees:

1. On macOS, run `~/.local/bin/ccx key` — with no TTY it opens a **native input
   dialog**; tell the user to paste the key there. The command output only shows
   a masked tail. On Linux/no-osascript this step needs a real terminal — only
   then tell the user to run `ccx key` there.
2. Then run `~/.local/bin/ccx doctor` and relay its one-line verdict.

If the key was already configured, just run `~/.local/bin/ccx doctor` directly and
relay the verdict — no question needed. Either way the user should finish setup,
key, and validation without leaving the session; only the final "restart Claude
Code" remains.

Never ask for or type an API key in the chat. Never edit files directly; the
script owns all writes. If the script fails, show the error and stop.
