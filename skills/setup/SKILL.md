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

1. Run `~/.local/bin/ccx key`. With no TTY it falls back automatically: the
   controlling terminal if one exists (hidden inline input — works on headless
   Linux), else a **native macOS dialog**. Tell the user where to paste (the
   command prints it); output only ever shows a masked tail.
   If it exits with "No terminal available here", tell the user to type
   `! ccx key` directly in the Claude Code prompt — that runs it with their
   terminal attached, input hidden, still in-session.
2. Then run `~/.local/bin/ccx doctor` and relay its one-line verdict.

If the key was already configured, just run `~/.local/bin/ccx doctor` directly and
relay the verdict — no question needed. Either way the user should finish setup,
key, and validation without leaving the session; only the final "restart Claude
Code" remains.

Never ask for or type an API key in the chat. Never edit files directly; the
script owns all writes. If the script fails, show the error and stop.
