---
name: uninstall
description: Cleanly uninstall the ccd plugin. Triggers: "/ccd:uninstall", "ccd 지워줘 / 삭제" (remove ccd), "uninstall ccd".
---

# ccd uninstall

If the user's request is ambiguous, confirm the intent in one line; otherwise proceed. Ask whether to keep the OpenRouter key and state (the default is to keep them). Map "wipe everything" to `--purge`.

Resolve the newest installed plugin binary and run uninstall, adding `--purge` only when requested:

```sh
t=$(ls -d "$HOME/.claude/plugins/cache"/*/ccd/*/bin/ccd 2>/dev/null | sort -V | tail -1); "$t" uninstall [--purge]
```

Then run the two commands printed by the script:

```sh
claude plugin uninstall ccd@cc-donut
claude plugin marketplace remove cc-donut
```

Relay the script output and CLI results verbatim, then tell the user to restart Claude Code. Never echo the key and never delete anything the script does not.
