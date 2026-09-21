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

## A bare setup installs no launcher, and needs none

The hop between registered Claude subscriptions happens inside the running
session, so a plain `ccd setup` shadows nothing and edits no startup file. There
is no PATH line to relay and no restart to ask for. If the user has a second
subscription, `ccd account add` is the rest of that setup — not a flag here.

`--auto` is a separate question and the only one that installs a launcher: it
grants consent for the paid OpenRouter hop when every subscription is spent. Never
reach for it unprompted, and never as a remedy for something else.

## A non-zero exit is not always a dead end

`ccd setup --auto` exits non-zero when it finished everything else but could not
put that launcher on PATH, so the paid hop is installed and inert. Its last line
says so. Relay it verbatim, including the remedy it names — but it is not a reason
to abandon the rest of this skill: the statusline, hooks and `ccd` command are all
already wired by that point, and the subscription hop is unaffected. Carry on with
the key and `ccd doctor` steps above; stop only when setup failed before doing any
of that.

Do not substitute your own remedy. `ccd setup --auto --yes` is what repairs a
declined PATH prompt. An unwritable startup file, or a shell ccd will not edit,
needs the user to place the line by hand — setup says which case it hit.
