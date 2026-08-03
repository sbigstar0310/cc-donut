---
name: setup
description: Wire ccd terminal launchers and statusline after plugin installation. Use for /ccd:setup or first-time ccd setup.
---

# ccd setup

Run setup from the newest installed ccd plugin:

```sh
t=$(ls -d "$HOME/.claude/plugins/cache"/*/ccd/*/bin/ccd 2>/dev/null | sort -V | tail -1); "$t" setup
```

Add one short introductory line, then relay the script's output to the user verbatim. If the script prints a PATH line, make sure the user sees it.

## Continue in-session — don't send the user to a terminal

If the setup output says the OpenRouter key is not set, offer to finish right
now by following the `key` skill in this plugin (skills/key/SKILL.md): the
default path is pasting the key in chat with informed consent; macOS can use
the `ccd key` native dialog. After the key lands, run `~/.local/bin/ccd doctor` and relay its one-line verdict.

If the key was already configured, just run `~/.local/bin/ccd doctor` directly and
relay the verdict — no question needed. Either way the user finishes setup, key,
and validation without leaving the session, and no restart is needed: Claude Code
reloads settings automatically (statusline appears on the next interaction) and
`/reload-plugins` activates the hooks in the current session.

Key handling follows the `key` skill: chat paste only with the consent notice,
never echo a full key back, never write it anywhere but through `ccd key`.
Never edit files directly; the script owns all writes. If the script fails,
show the error and stop.
