---
name: uninstall
description: Cleanly uninstall the ccx plugin. Triggers: "/ccx:uninstall", "ccx 지워줘 / 삭제" (remove ccx), "uninstall ccx".
---

# ccx uninstall

If the user's request is ambiguous, confirm the intent in one line; otherwise proceed. Ask whether to keep the OpenRouter key and state (the default is to keep them). Map "wipe everything" to `--purge`.

Resolve the newest installed plugin binary and run uninstall, adding `--purge` only when requested:

```sh
t=$(ls -d "$HOME/.claude/plugins/cache"/*/ccx/*/bin/ccx 2>/dev/null | sort -V | tail -1); "$t" uninstall [--purge]
```

Then run the two commands printed by the script:

```sh
claude plugin uninstall ccx@ccx
claude plugin marketplace remove ccx
```

Relay the script output and CLI results verbatim, then tell the user to restart Claude Code. Never echo the key and never delete anything the script does not.
