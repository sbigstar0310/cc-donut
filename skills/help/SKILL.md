---
name: help
description: Explain and carry out any ccd task — registering or switching Claude accounts, changing which models fill the slots, reading status, turning the automatic handoff on or off. Use for "/ccd:help", "ccd 명령어 알려줘" (what are the ccd commands), "계정 추가하려면?" (how do I add an account), "계정 바꾸고 싶어" (I want to switch accounts), "기본 모델 바꾸려면?" (how do I change the default model), "ccd 어떻게 써" / "how do I use ccd", or any "how do I ..." question about ccd. Answer the one thing asked and do the work; never hand over the manual.
---

# ccd help — answer the question, then do it

Almost every ccd task is a shell command that needs no terminal, so **carry it
out yourself rather than telling the user what to type.** Only three things need
the user's own hands, listed at the bottom.

Resolve the binary once. Prefer the installed launcher, fall back to the plugin
so this still works before `/ccd:setup` has run:

```sh
CCD=$([ -x "$HOME/.local/bin/ccd" ] && echo "$HOME/.local/bin/ccd" \
      || ls -d "$HOME/.claude/plugins/cache"/*/ccd/*/bin/ccd 2>/dev/null | sort -V | tail -1)
```

## How to answer

1. **Ground it first.** Run `$CCD` (status) or `$CCD account list` before
   explaining anything, so the answer names their real accounts, models and key
   state instead of placeholders.
2. **Do it, then report what changed** in a line or two.
3. **Answer only what was asked.** Never paste the tables below at the user and
   never list commands they did not ask about.
4. **Hand off rather than duplicate:** `/ccd:setup` (first-time wiring),
   `/ccd:key` (OpenRouter key), `/ccd:doctor` (diagnosis), `/ccd:update`,
   `/ccd:uninstall`. `/ccd` covers preparation and re-researching model picks.

## Claude accounts — the spare subscriptions

With two or more registered, quota exhaustion moves the conversation to a spare
subscription and only reaches OpenRouter when every one is spent.

| They want | You run |
|---|---|
| See registered accounts and quota | `$CCD account list` |
| Register the account signed in right now | `$CCD account add` |
| Switch the active account | `$CCD account use <name>` |
| Remove one | `$CCD account rm <name>` — destructive, confirm first |
| Refresh the stored tokens | `$CCD account refresh` |

**Registering a second account** is the one flow with a step you cannot do: the
user runs `claude`, signs in with `/login` as the other account, and then you run
`$CCD account add`. Signing in is impossible once quota is at zero, so this
belongs in the preparation phase — `/ccd` walks the whole preparation checklist
and is the better skill when nothing is set up yet.

**Switching does not move the session you are in.** `account use` rewrites the
credential store, and a running Claude Code keeps serving from the tokens it
already holds until it next refreshes them. `ccd account use` says so itself when
it finds other sessions running. For the switch to carry this conversation, the
user does `/exit` then `claude --resume` in the same terminal.

**An account reporting `needs re-login`** means ccd's stored copy of its refresh
token is dead, not that the account is. The fix is one step: run `claude` and
sign in with `/login` as that account. ccd copies the new token into its store by
itself on its next command. Do not ask for `ccd account add --force` — that was
the old rule, and treating it as required is what made healthy accounts look
broken.

## Models

Three different questions hide behind "change the model". Find out which one it
is before acting.

**1. Change the model for the session I am in now.** The user types `/model` —
an in-session slash command, so it is theirs to run. `/model haiku|sonnet|opus`
picks a slot; `/model <slug>` names a model directly. No restart needed.

**2. Change which OpenRouter models the three slots use.** This is what ccd
saves and reuses on every donut run. Show the catalog, then set the slots
without sending anyone to a terminal — `pick` reads three answers in order
(haiku, sonnet, opus), where a catalog key sets that slot and a blank line keeps
it:

```sh
$CCD models                          # catalog: keys, slugs, prices, rationale
printf 'flash\nluna\nkimi\n' | $CCD pick    # set all three
printf '\n\nkimi\n' | $CCD pick             # change only opus
```

Use catalog keys, never the menu numbers — the numbers shift when the catalog
changes. Saved to `~/.claude/ccd/providers/tiers.env`; delete that file to
restore the defaults. Takes effect on the next `ccd` run.

Do not confuse `ccd pick` with `ccd account pick`. The first assigns models to
slots. The second is the internal chooser that decides which spare subscription a
handoff goes to, and nobody needs to run it by hand.

**3. Use a different model for one run only.** Flags on the launcher, which the
user runs: `ccd -c --opus kimi`, or `ccd -c --model provider/model` to resume
with a bare slug in the sonnet slot.

## Status and the backbone switch

| They want | You run |
|---|---|
| Current state: key, model slots, routing, what happens at zero | `$CCD` |
| Which account is active, and spare quota | `$CCD account list` |
| Diagnose a failure with one live API round trip | `/ccd:doctor` |
| Set or replace the OpenRouter key | `/ccd:key` |

`ccd` status does not name the account; that comes from `account list` (or
`account current`). Do not promise one command for both.

**Turning the automatic handoff on** is `$CCD setup --auto`, and it may need to
add one line to a startup file so the shim leads `PATH`. It asks before touching
a dotfile, reaching `/dev/tty` when stdin is a pipe. Get the user's agreement in
the conversation first, then run `$CCD setup --auto --yes` so it does not stop on
a prompt they cannot see. `$CCD setup --no-auto` turns it back off.

The switch onto OpenRouter and back is the user's to type, because each command
replaces itself with `claude`:

- `ccd -c` — switch and resume the last conversation. This is the emergency one.
- `ccd go` — switch into a new session.
- `ccd off` — run with the subscription again.
- Back to the subscription after a donut run: `/exit`, then `claude --resume` in
  the same terminal.

## The three things the user must do themselves

1. **`/login`** — Claude Code's own sign-in prompt.
2. **`ccd -c` / `ccd go` / `ccd off`** — each replaces the process with `claude`,
   so it only works from their terminal.
3. **`/model`** — an in-session slash command.

Everything else on this page you run for them. `setup --auto` is the one command
that needs their word before you run it, not their hands: agree on the dotfile
edit in the conversation, then pass `--yes`.

## Never

- Never say a re-login needs a follow-up `ccd account add --force`. It does not.
- Never print the contents of `~/.claude/ccd/providers/keys.env`; only report
  whether a key is set.
- Never suggest `/logout` — it genuinely signs the user out, and the accounts are
  the whole point.
