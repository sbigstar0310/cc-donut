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
  <img src="assets/loop.gif" alt="Tire goes flat → donut spare on → drive home → real tire back" width="480">
</p>

## Install

```sh
claude plugin marketplace add sbigstar0310/cc-donut
claude plugin install ccd@cc-donut
```

Then open Claude Code and run `/ccd:setup`. In a session that is already open, `/reload-plugins` activates the hooks.

<details>
<summary>Prefer installing inside Claude Code?</summary>

Slash commands are parsed **one line at a time** — enter each separately (pasting the block as one message won't work):

1. `/plugin marketplace add sbigstar0310/cc-donut`
2. `/plugin install ccd@cc-donut`
3. `/reload-plugins`
4. `/ccd:setup` — the statusline appears on your next interaction; no restart needed

</details>

## What it does

When quota runs out, cc-donut moves the conversation to a spare Claude subscription if you have one, and to OpenRouter otherwise. Everything else stays in place: tools, hooks, skills, MCP servers, and the conversation you were in. When the quota window resets, it moves you back.

Two commands each way, or [none at all](#automatic-handoff) with `ccd setup --auto`.

## Before / After

```text
BEFORE   quota dies mid-task → stuck, restart, lose the thread

AFTER    quota dies    → /exit → ccd -c       same conversation, spare on
         quota resets  → we flag it for you   /exit → claude --resume
         same conversation, back on your subscription

AUTO     quota dies    → 🍩 donut goes on by itself      (ccd setup --auto)
         quota resets  → back on the subscription        nothing to type

2 ACCTS  quota dies    → your other subscription         free, nothing billed
         both spent    → 🍩 donut                        (ccd account add)
```

Set it up **while you still have quota** — after zero, Claude can't walk you through it:

```sh
ccd key           # store your OpenRouter key (hidden input, never enters chat)
ccd doctor        # ✓ OK = the escape route works
ccd setup --auto  # optional: hand off by itself, both ways
```

Runs on macOS and Linux (bash, python3, curl). You need an OpenRouter account
with credit — this is a paid fallback. Got a [second Claude
subscription](#multi-account)? ccd uses that first, and it costs nothing.

<a name="multi-account"></a>

<details>
<summary><b>More than one Claude subscription? Use it before you pay</b></summary>

Register both accounts and quota exhaustion moves the conversation to whichever
one still has room. Same conversation, still on the subscription, nothing billed.
OpenRouter stays the last resort.

```sh
ccd account add                  # registers whoever is signed in right now
claude                           # /login as your other account
ccd account add                  # register that one too
ccd account list                 # both accounts, with live quota
```

Nothing else changes, and your MCP logins (Notion, Slack) are unaffected by the
switch. The statusline names the account you are on and whether a spare is ready:

```text
● claude:personal │ spare work 20%
```

Accounts are tried in registration order (`--priority` to change), and only while
**both** the 5-hour and 7-day windows have room — a weekly window at 99% would
run out again minutes after arriving.

`ccd doctor` reports each account's quota and flags any that needs a re-login.
Lapsed tokens look fine until the moment you need them, so ccd refreshes idle
accounts once a day and tells you in-session if one has stopped refreshing.
Recovering one takes a plain `/login` as that account — ccd notices and stores
the new token itself, with nothing to re-register by hand.
Tokens are stored in `~/.claude/ccd/accounts/` (mode 600,
see [SECURITY.md](SECURITY.md)); `ccd account rm <name>` removes one.

> **On multiple accounts.** Anthropic has said holding more than one subscription
> is not a terms violation; what is prohibited is sharing an account and reselling
> access. This feature is for subscriptions *you* hold. Registering an account
> several people share is your call and your risk.

</details>

<a name="automatic-handoff"></a>

<details>
<summary><b>Automatic handoff — no commands at all</b></summary>

```sh
ccd setup --auto
```

That installs a launcher at `~/.claude/ccd/bin/claude` and asks before adding one
line to your shell startup file, so your shell finds it first:

```sh
export PATH="$HOME/.claude/ccd/bin:$PATH"
```

It gets its own directory rather than shadowing `~/.local/bin/claude`, which the
official installer owns. Say no to the prompt and ccd prints the line for you;
`--yes` answers it in advance.

Then start sessions the way you already do: `claude`, unchanged. The launcher
runs the real claude and watches its exit code, so when quota runs out the
conversation comes back on OpenRouter on its own, and returns when the window
resets. The ccd statusline row shows which backbone is answering and what it
costs.

What it will not do:

- **It only fires when it can land.** The launcher has to be running, the quota
  reading has to confirm the rate-limit error, and a key has to be configured.
  Miss any of those and nothing happens — no session is ever ended with nowhere
  to go.
- **The in-flight turn is lost.** The switch happens after the failed turn, so
  re-send that last prompt.
- **Non-interactive runs are not relaunched.** `claude -p ...`, or anything with
  its output redirected, has no terminal to come back to and no prompt to
  re-send; ccd tells you how to continue instead.

`/exit` then `ccd -c` still works and stays documented, for whenever a handoff
doesn't fire.

`ccd setup --no-auto` turns it off and `ccd uninstall` removes it. A
`~/.claude/ccd/bin/claude` that isn't ours, and a PATH line we did not write, are
always left alone.

</details>

---

<details>
<summary><b>What you get</b></summary>

- **Any OpenRouter model, mid-session.** Hundreds of them, one `/model` away, no restart.
- **Quota warnings in the statusline.** Red near exhaustion, green when the reset lands, each with the command to run. Checked on every interaction against the 5-hour and 7-day windows.
- **`:floor` routing, spend on screen.** Cheapest provider by default; this run and the whole outage, live.
- **Your claude.ai login is never touched.** ccd replaces the process; it does not proxy or relay. The key stays local (mode 600) and never enters the chat.

```text
ccd │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
```

</details>

<details>
<summary><b>Models — defaults and switching</b></summary>

Defaults, wired onto the aliases you already use:

| Alias | Default model | Price (in/out per 1M) | Use for |
| --- | --- | --- | --- |
| `/model haiku` | deepseek/deepseek-v4-flash | $0.09 / $0.18 | scans, grep, trivial edits |
| `/model sonnet` | openai/gpt-5.6-luna | $0.10 / $0.60 | everyday coding |
| `/model opus` | moonshotai/kimi-k3 | $2.90 / $14.00 | hard problems, debugging |

Any slug from [openrouter.ai/models](https://openrouter.ai/models) works mid-session:

```text
/model z-ai/glm-5.2:floor
```

For a direct model whose OpenRouter provider pool is verified above 200K, the ccd statusline checks the cached pool metadata and gives one of these next actions:

```text
checking provider context…
verified context → /model provider/model:floor[1m]
restart for safe context → /exit; ccd -c --model provider/model
```

The statusline cannot change a running Claude Code process itself. Follow its exact `[1m]` command only when it says the inherited compact window is safe; otherwise use the restart/resume route so ccd can verify the selected pool before launch. `[1m]` is stripped before the OpenRouter request and does **not** increase provider capacity.

Remap the aliases permanently with `ccd pick` (an offline menu over the curated catalog), per-run with `ccd -c --opus sol`, or resume a direct model with its launch-time context budget via `ccd -c --model provider/model`.

The catalog is a snapshot and goes stale. To refresh it with current benchmarks and prices, ask Claude (while you have quota): *"refresh the ccd model picks"* — the `/ccd` skill proposes an updated catalog from current benchmarks and prices before writing anything.

</details>

<details>
<summary><b>Command reference</b></summary>

| Command | When |
| --- | --- |
| `ccd -c` | **The moment quota dies** — switch and resume the conversation |
| `ccd doctor [model]` | Any time — one API round trip confirms the escape route |
| `ccd key` | Once — store the OpenRouter key |
| `ccd` | Status: key, slots, routing, escape procedure |
| `ccd models` / `ccd pick` | Browse the catalog / remap the three aliases |
| `ccd go` | Switch into a fresh session instead of resuming |
| `ccd -c --routing exacto` | If a cheap provider fumbles tool calls |
| `ccd -c --model provider/model` | Resume with a direct model; verify and budget its pool at launch |
| `ccd off` | Run claude on the subscription again |
| `ccd account add` | Register the signed-in account as a spare subscription ([above](#multi-account)) |
| `ccd account list` | Registered accounts with live quota |
| `ccd account rm <name>` | Remove one |
| `ccd setup --auto` | Opt in to automatic handoff — no `/exit`, no commands ([below](#automatic-handoff)) |
| `ccd setup --no-auto` | Turn automatic handoff back off |

**Skills inside Claude Code** (type `/` to find them):

| Skill | What it does |
| --- | --- |
| `/ccd` | Readiness checkup and configuration by chat: verifies key/slots/routing, sets the key via native dialog, refreshes the model catalog with fresh benchmarks & prices on request ("refresh the ccd model picks") |
| `/ccd:setup` | First-time wiring — launchers and statusline, then key + doctor without leaving the session |
| `/ccd:key` | Set the OpenRouter key — opens the key-creation page if you don't have one, then native masked input (macOS dialog / terminal prompt); the key never enters the chat |
| `/ccd:doctor` | Diagnose the escape route: key, API, model slugs, wiring — with the fix offered on failure |
| `/ccd:update` | One-step plugin update to the latest release |
| `/ccd:uninstall` | Clean removal (keeps your key unless you ask to purge) |

Complete emergency runbook (readable without Claude, kept offline at `~/.claude/ccd/QUOTA-SOS.md`): [QUOTA-SOS.md](QUOTA-SOS.md)

</details>

<details>
<summary><b>How it works</b></summary>

`ccd` launches `claude` with process-scoped environment variables pointing the model slots (`ANTHROPIC_DEFAULT_*_MODEL`) at OpenRouter's Anthropic-compatible endpoint. Nothing is written to `settings.json`, so no other session or background agent is ever silently rerouted, and your claude.ai login is only masked inside the ccd process — never modified.

A `UserPromptSubmit`/`PostToolUse` hook tracks OpenRouter spend against two baselines (this run, this whole outage) and detects Claude quota resets. State and config live under `~/.claude/ccd/`.

Quota readings come from the [claude-dashboard](https://github.com/uppinote20/claude-dashboard) plugin. **Automatic handoff needs it**: a handoff only arms when a quota reading confirms the rate-limit error, so with no reading there is nothing to confirm and nothing fires. Manual `ccd -c`, cost tracking, and model switching work without it.

</details>

<details>
<summary><b>Development & testing</b></summary>

```sh
test/smoke.sh                 # portable checks against the real scripts in a throwaway HOME
test/docker.sh                # same suite in a clean Debian container
test/docker.sh alpine:3.20    # …and on musl/BusyBox
```

No network, no real key, no writes outside the temp HOME. Run the container
tests before releasing: GNU/BSD differences (e.g. `stat`) pass silently on
macOS and break Linux users. CI runs all three on every push.

</details>

<details>
<summary><b>Caveats</b></summary>

- **Officially unsupported path**: both Anthropic and OpenRouter state that Claude Code targeting non-Claude models isn't guaranteed. It works via the standard model-slot variables today, but a Claude Code update could break it — hence `ccd doctor`.
- Behind a gateway, Claude Code budgets 200K context unless the model ID carries the `[1m]` hint. ccd applies `[1m]` automatically at launch when fresh cached OpenRouter endpoint data confirms every eligible default-pool provider serves >200K for that slug (unverified models stay at the safe 200K budget; check with `ccd doctor`). `[1m]` goes only on the conversation slots (sonnet/opus) — the haiku chore slot keeps the safe 200K budget, because Claude Code has one global auto-compact window per process and hinting a small chore-model pool would crush it for every model. The **effective window** is the smallest verified pool minimum among hinted slots with headroom (`min × 0.92`, capped at `min − 40K`), so auto-compaction fires at the model's real context ceiling (e.g. ~839K for a 912K-pool model), never at a fake 1M. Catalog Pareto/default candidates warm their metadata in the background after launch; this never delays the selected-slot gate. A later native `/model <slug>` cannot resize the already-running global window: ccd can only show whether a manual `[1m]` reselect is safe or whether restart/resume is required. `[1m]` does not enlarge the upstream model.
- Remote Control, voice input, and fast mode are off while on the external backbone.
- macOS and Linux. The core is plain bash + python3 + curl; only the key-entry dialog is macOS-specific (osascript), and elsewhere it falls back to a hidden terminal prompt.

</details>

<details>
<summary><b>Security notes</b></summary>

- The key lives only in `~/.claude/ccd/providers/keys.env` (mode 600), is displayed only as a masked tail, and is never bundled with or requested by the plugin at install. An exported `OPENROUTER_API_KEY` env var takes precedence over the file — the standard MCP/plugin convention.
- Key capture is native input only (dialog or hidden terminal prompt, `gh auth login`-style). If you paste a key into the chat anyway, ccd saves it but recommends rotating it, since it persists in the conversation history.
- Never put `ANTHROPIC_*` gateway variables in `settings.json`'s `env` block — they override shell exports and permanently pin every session (including background agents) to the external backbone.
- Never `/logout` to switch back — it genuinely logs you out. Returning is just `/exit` then `claude --resume`.

</details>
