<p align="center">
  <img src="assets/logo.svg" alt="cc-donut logo" width="220">
</p>

# cc-donut

**The donut spare for Claude Code. Max 50 mph, gets you home.**

[한국어](README.ko.md) · English

[![License: MIT](https://img.shields.io/github/license/sbigstar0310/cc-donut)](LICENSE)
[![tests](https://github.com/sbigstar0310/cc-donut/actions/workflows/test.yml/badge.svg?branch=main&event=push)](https://github.com/sbigstar0310/cc-donut/actions/workflows/test.yml?query=branch%3Amain+event%3Apush)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet)](#install)

<p align="center">
  <img src="assets/loop.gif" alt="Tire goes flat, donut spare on, drive home, real tire back" width="480">
</p>

## What it does

When your Claude quota runs out, cc-donut moves the conversation to your **other
Claude subscription**. The conversation, tools, hooks, skills and MCP servers all
stay where they are, and nothing is billed: it is a subscription you already pay
for. When the window resets, it moves you back.

Two subscriptions rarely run out at the same time, so switching between them is
enough for most people. If they all run out, OpenRouter takes over as a paid
fallback.

## Install

```sh
claude plugin marketplace add sbigstar0310/cc-donut
claude plugin install ccd@cc-donut
```

Then run `/ccd:setup` inside Claude Code.

<details>
<summary>Prefer to install from inside Claude Code?</summary>

Slash commands are parsed **one line at a time**, so enter each separately
(pasting the block as one message will not work):

1. `/plugin marketplace add sbigstar0310/cc-donut`
2. `/plugin install ccd@cc-donut`
3. `/reload-plugins`
4. `/ccd:setup`

The statusline appears on your next interaction. No restart needed.

</details>

## Set it up while you still have quota

After you hit zero, Claude cannot walk you through anything.

```sh
ccd account add     # registers the account you are signed in as right now
claude              # /login as your other account, then /exit
ccd account add     # register that one too
ccd account list    # both accounts, with live quota
ccd setup --auto    # optional: the hop happens by itself, both ways
```

That is the whole setup for two subscriptions. OpenRouter is optional and only
matters once every subscription is spent.

## When the quota dies

```text
BEFORE   stuck mid-task, restart, lose the thread

MANUAL   !ccd account use <name>    right there in the session
         /exit, claude --resume     same conversation, nothing billed

AUTO     nothing to type at all     ccd setup --auto handles both directions
```

`!` runs a shell command without leaving Claude Code, so the swap happens where
you already are. It takes effect immediately; the session you are in keeps the
old account's models and limits until it restarts, which is what the `/exit` and
`claude --resume` are for.

---

<details>
<summary><b>Two subscriptions, in detail</b></summary>

Accounts are tried in registration order, which `--priority` changes. An account
is offered only if it has quota left in **both** the 5-hour and the 7-day window:
an account at 99% of its weekly quota would run out again within minutes.

The statusline shows the account you are on, how much of the spare's quota is
used, and when that quota resets:

```text
● claude:personal │ spare work 20% (2h10m)     # room to switch to, right now
● claude:personal │ spare work 98% (13m)       # spent, but worth waiting out
```

`ccd doctor` reports each account's quota and flags any that needs a re-login.
Lapsed tokens look fine until the moment you need them, so ccd refreshes idle
accounts once a day and tells you in-session if one has stopped refreshing.
Recovering one takes a plain `/login` as that account. ccd notices and stores the
new token itself, with nothing to re-register by hand.

Your MCP logins (Notion, Slack) are unaffected by a swap. Tokens live in
`~/.claude/ccd/accounts/` (mode 600, see [SECURITY.md](SECURITY.md)), and
`ccd account rm <name>` removes one.

> **On holding more than one subscription.** Anthropic has said holding more than
> one subscription is not a terms violation. What is prohibited is sharing an
> account and reselling access. This feature is for subscriptions *you* hold.
> Registering an account several people share is your call and your risk.

</details>

<details>
<summary><b>Automatic handoff, with no commands at all</b></summary>

```sh
ccd setup --auto
```

That installs a launcher at `~/.claude/ccd/bin/claude` and asks before adding one
line to your shell startup file, so your shell finds it first:

```sh
export PATH="$HOME/.claude/ccd/bin:$PATH"
```

It gets its own directory rather than shadowing `~/.local/bin/claude`, which the
official installer owns. Say no to the prompt and ccd prints the line for you.
`--yes` answers it in advance.

Then start sessions as usual with `claude`. The launcher runs the real claude and
watches its exit code, so when quota runs out the conversation continues on the
next account by itself, and comes back when the quota resets.

Conditions and limits:

- **All three conditions must hold.** The launcher must be running, a quota
  reading must confirm the rate-limit error, and there must be somewhere to go.
  Otherwise ccd does nothing, and no session is ended with nowhere to go.
- **The in-flight turn is lost.** The switch happens after the failed turn, so
  re-send that last prompt.
- **Non-interactive runs are not relaunched.** `claude -p ...`, or anything with
  its output redirected, has no terminal to come back to and no prompt to
  re-send. ccd tells you how to continue instead.

The manual procedure still works if a handoff does not fire.
`ccd setup --no-auto` turns automatic handoff off and `ccd uninstall` removes it. A
`~/.claude/ccd/bin/claude` that is not ours, and a PATH line we did not write,
are always left alone.

</details>

<details>
<summary><b>OpenRouter, the last resort</b></summary>

Only reached when every registered subscription is spent. It is paid per token
with your own key, so it is worth setting up before you need it:

```sh
ccd key           # store your OpenRouter key (hidden input, never enters chat)
ccd doctor        # ✓ OK means the escape route works
```

Default models, mapped onto the aliases you already use:

| Alias | Default model | Price (in/out per 1M) | Use for |
| --- | --- | --- | --- |
| `/model haiku` | deepseek/deepseek-v4-flash | $0.11 / $0.22 | scans, grep, trivial edits |
| `/model sonnet` | openai/gpt-5.6-luna | $0.10 / $0.60 | everyday coding |
| `/model opus` | moonshotai/kimi-k3 | $2.90 / $14.00 | hard problems, debugging |

Any slug from [openrouter.ai/models](https://openrouter.ai/models) works
mid-session: `/model z-ai/glm-5.2:floor`. Remap the aliases permanently with
`ccd pick`, or for one run with `ccd -c --opus sol`. To resume the conversation
on a model you name yourself, with the context budget measured at launch, use
`ccd -c --model provider/model`.

Cheapest provider by default (`:floor`), with spend on screen for this run and
for the whole outage:

```text
ccd │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
```

The catalog is a snapshot and goes stale. To refresh it with current benchmarks
and prices, ask Claude while you still have quota: *"refresh the ccd model
picks"*. The `/ccd` skill proposes an updated catalog before writing anything.

`ccd -c --routing exacto` is the switch to try if a cheap provider fumbles tool
calls.

</details>

<details>
<summary><b>Commands</b></summary>

| Command | When |
| --- | --- |
| `ccd account add` | Register the signed-in account as a spare subscription |
| `ccd account list` | Registered accounts with live quota |
| `ccd account use <name>` | Hop to that account. `!ccd account use <name>` works inside a session; `/exit` and `claude --resume` to pick it up |
| `ccd account rm <name>` | Remove one |
| `ccd setup --auto` | Opt in to automatic handoff |
| `ccd setup --no-auto` | Turn automatic handoff back off |
| `ccd doctor [model]` | Diagnose the whole escape route |
| `ccd` | Status: accounts, key, slots, routing, procedure |
| `ccd key` | Store the OpenRouter key |
| `ccd -c` | Switch to OpenRouter and resume the conversation |
| `ccd go` | Switch to OpenRouter in a fresh session instead |
| `ccd models` / `ccd pick` | Browse the catalog / remap the three aliases |
| `ccd off` | Run claude on the subscription again |

**Skills inside Claude Code** (type `/` to find them):

| Skill | What it does |
| --- | --- |
| `/ccd` | Readiness checkup and configuration by chat |
| `/ccd:setup` | First-time setup, then key and doctor in the same session |
| `/ccd:key` | Set the OpenRouter key through native masked input |
| `/ccd:doctor` | Diagnose accounts, key, API, slugs and wiring, and offer a fix when a check fails |
| `/ccd:update` | One-step plugin update |
| `/ccd:uninstall` | Clean removal (keeps your key unless you ask to purge) |

Emergency runbook, readable without Claude and kept offline at
`~/.claude/ccd/QUOTA-SOS.md`: [QUOTA-SOS.md](QUOTA-SOS.md)

</details>

<details>
<summary><b>How it works</b></summary>

Swapping accounts replaces only the `claudeAiOauth` subtree of the live Claude
credentials, between sessions, when no process owns them. Everything else in that
blob, including your MCP logins, is left untouched.

The OpenRouter route launches `claude` with process-scoped environment variables
pointing the model slots (`ANTHROPIC_DEFAULT_*_MODEL`) at OpenRouter's
Anthropic-compatible endpoint. Nothing is written to `settings.json`, so no other
session or background agent is ever silently rerouted, and your claude.ai login
is only masked inside the ccd process.

A `UserPromptSubmit`/`PostToolUse` hook reads Claude quota through a ten-minute
cache, and a `StopFailure` hook arms the handoff when a rate-limit error and the
quota reading agree. ccd takes that reading from the same Anthropic usage
endpoint it already uses for spare accounts, so **claude-dashboard is not
required**. Install it if you want its more detailed rows, which render above ccd's.

State and config live under `~/.claude/ccd/`.

</details>

<details>
<summary><b>Requirements and caveats</b></summary>

macOS and Linux, with bash, python3 and curl. Only the key-entry dialog is
macOS-specific (osascript); elsewhere it falls back to a hidden terminal prompt.

- **Officially unsupported path** (OpenRouter only): Anthropic and OpenRouter
  both state that Claude Code is not guaranteed to work with non-Claude models.
  It works through the standard model-slot variables today, but a Claude Code
  update could break it. Check with `ccd doctor`.
- Behind a gateway, Claude Code budgets 200K context unless the model ID carries
  the `[1m]` hint. ccd applies `[1m]` at launch only when fresh cached OpenRouter
  endpoint data confirms every eligible provider serves more than 200K for that
  slug, and only on the conversation slots. The auto-compact window is then set
  from the smallest verified pool, so compaction fires at the model's real
  ceiling rather than a fake 1M. `[1m]` does not enlarge the upstream model, and
  a running process cannot be resized: the statusline will say whether a manual
  reselect is safe or whether a restart is required.
- Remote Control, voice input and fast mode are off while on OpenRouter.
- Never `/logout` to switch back. It genuinely logs you out. Returning is `/exit`
  then `claude --resume`.

</details>

<details>
<summary><b>Security</b></summary>

- Account tokens live in `~/.claude/ccd/accounts/` (directory 700, files 600) and
  never leave the machine. ccd talks to Anthropic and OpenRouter directly, with
  no relay in between.
- The OpenRouter key lives only in `~/.claude/ccd/providers/keys.env` (mode 600),
  is displayed only as a masked tail, and is never bundled with or requested by
  the plugin at install. An exported `OPENROUTER_API_KEY` takes precedence over
  the file, which is the standard plugin convention.
- Key capture is native input only (dialog or hidden terminal prompt). If you
  paste a key into the chat anyway, ccd saves it but recommends rotating it,
  since it persists in the conversation history.
- Never put `ANTHROPIC_*` gateway variables in the `env` block of
  `settings.json`. They override shell exports and permanently pin every session,
  including background agents, to the external backbone.

</details>

<details>
<summary><b>Development</b></summary>

```sh
test/smoke.sh                 # portable checks against the real scripts in a throwaway HOME
test/docker.sh                # same suite in a clean Debian container
test/docker.sh alpine:3.20    # and on musl/BusyBox
```

No network, no real key, no writes outside the temp HOME. Run the container tests
before releasing: GNU/BSD differences (`stat`, for one) go unnoticed on macOS and
fail for Linux users. CI runs all three on every push.

</details>
