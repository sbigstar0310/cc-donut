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

Then open Claude Code and run `/ccd:setup`. No restart needed — Claude Code reloads settings automatically, so the statusline appears on your next interaction, and `/reload-plugins` activates the hooks in an already-open session.

<details>
<summary>Prefer installing inside Claude Code?</summary>

Slash commands are parsed **one line at a time** — enter each separately (pasting the block as one message won't work):

1. `/plugin marketplace add sbigstar0310/cc-donut`
2. `/plugin install ccd@cc-donut`
3. `/reload-plugins`
4. `/ccd:setup` — the statusline appears on your next interaction; no restart needed

</details>

## What it does

When Claude quota hits the wall, cc-donut keeps your tools, hooks, skills, MCP servers, and the very conversation — and swaps only the model to OpenRouter. And because a spare is temporary by definition: as you keep working, cc-donut spots the quota reset and takes you back to your subscription. Not your forever ride. Just enough donut to get home.

Two commands each way, or [none at all](#automatic-handoff) — `ccd setup --auto` and the round trip stops needing you.

## Before / After

```text
BEFORE   quota dies mid-task → stuck, restart, lose the thread

AFTER    quota dies    → /exit → ccd -c       same conversation, spare on
         quota resets  → we flag it for you   /exit → claude --resume
         same conversation, back on your subscription — round trip, zero thread lost

AUTO     quota dies    → 🍩 donut goes on by itself      (ccd setup --auto)
         quota resets  → back on the subscription        nothing to type
```

Set it up **while you still have quota** — after zero, Claude can't walk you through it:

```sh
ccd key           # store your OpenRouter key (hidden input, never enters chat)
ccd doctor        # ✓ OK = your spare is inflated and ready
ccd setup --auto  # optional: hand off by itself, both ways
```

That's everything you need. Details below when you want them.

<a name="automatic-handoff"></a>

<details>
<summary><b>Automatic handoff — no commands at all</b></summary>

Opt in once and the round trip stops needing you:

```sh
ccd setup --auto
```

That installs a launcher at `~/.claude/ccd/bin/claude` and asks before adding one
line to your shell startup file, so your shell finds it first:

```sh
export PATH="$HOME/.claude/ccd/bin:$PATH"
```

It gets its own directory on purpose. `~/.local/bin/claude` is where the official
installer already puts a symlink to the real binary — shadowing it there would
break that link, and a Claude Code update would rewrite the symlink and silently
remove the launcher. Say no to the prompt and ccd just prints the line for you;
`--yes` answers it in advance. `ccd setup --no-auto` and `ccd uninstall` take
both the launcher and that line back out.

Then keep starting sessions the way you already do — `claude`, unchanged. When
quota runs out, the conversation comes back on OpenRouter by itself; when the
window resets, it returns to your subscription the same way. The statusline's
ccd row tells you which backbone is answering and what it costs.

How it works: the launcher
that runs the real claude and watches its exit code. A `StopFailure` hook sees
the `rate_limit` error, confirms against the quota reading, and ends the session
with SIGHUP — Claude Code exits gracefully (code 129) after flushing, and the
launcher relaunches the same conversation on the other backbone.

What it will not do:

- **Nothing is signalled unless the launcher is there to catch it.** The hook
  checks for a marker the launcher exports; without it, no signal is ever sent.
- **A bare rate-limit is not enough.** The quota reading has to agree, so
  transient throttling doesn't trigger a handoff. No reading means no handoff.
- **No key, no signal.** Ending a session with nowhere to go is worse than
  leaving it alone.
- **The in-flight turn is lost.** The transition happens after the failed turn,
  so re-send that last prompt.
- **Non-interactive runs are not relaunched.** `claude -p ...`, or anything with its
  output redirected, has no terminal to come back to and no prompt to re-send;
  ccd tells you how to continue instead.
- **Your subscription credential is never touched.** ccd replaces the process,
  it does not proxy or relay your login.

The manual route is not replaced. `/exit` then `ccd -c` still works exactly as
before, and stays documented — automation you cannot step around is worse than
none, so if a handoff ever fails to fire you take the two commands and carry on.

Turn it off with `ccd setup --no-auto`; `ccd uninstall` removes it too. A
`~/.claude/ccd/bin/claude` that isn't ours, and a PATH line we did not write,
are always left alone.

</details>

---

<details>
<summary><b>What you get</b></summary>

- 🧰 **Your whole Claude Code, untouched** — the entire scaffold (tools, hooks, skills, MCP servers, keybindings, history) keeps running; ccd swaps nothing but the model behind it
- 🔄 **The conversation survives both directions** — `ccd -c` resumes it on OpenRouter, `claude --resume` brings it home; same conversation store either way
- 🎛 **Any OpenRouter model, mid-session** — hundreds of models incl. dirt-cheap ones, one `/model` away, no restart
- 🚨 **We watch the tank so you don't have to** — red near exhaustion, green when the reset is detected (re-checked on each interaction, ≤10 min fresh, on the 5-hour and 7-day windows), each with the exact command to run
- 🏠 **A spare, not a second car** — recovery detection means you never ride the donut a mile longer than needed; back on your subscription as soon as the reset shows up
- 💸 **Cheapest provider by default, every cent visible** — `:floor` routing + live run/outage spend in the statusline
- 🔒 **Zero auth risk** — your claude.ai login is never touched; key stored locally (600), never typed in chat

```text
ccd │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
```

</details>

<details>
<summary><b>Models — defaults and switching</b></summary>

Sensible defaults are pre-wired onto the aliases you already use:

| Alias | Default model | Price (in/out per 1M) | Use for |
| --- | --- | --- | --- |
| `/model haiku` | deepseek/deepseek-v4-flash | $0.09 / $0.18 | scans, grep, trivial edits |
| `/model sonnet` | openai/gpt-5.6-luna | $0.10 / $0.60 | everyday coding |
| `/model opus` | moonshotai/kimi-k3 | $2.90 / $14.00 | hard problems, debugging |

But you're not limited to these. Any slug from [openrouter.ai/models](https://openrouter.ai/models) works mid-session:

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

The catalog is a snapshot and goes stale. To refresh it with current benchmarks and prices, ask Claude (while you have quota): *"refresh the ccd model picks"* — the `/ccd` skill researches independent benchmarks and live OpenRouter pricing, recomputes the price/performance frontier, and proposes an updated catalog before writing anything.

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

Quota warnings and recovery detection need the optional [claude-dashboard](https://github.com/uppinote20/claude-dashboard) plugin (it supplies the quota data). Without it, switching and cost tracking still work — you just don't get the red/green nudges.

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
- macOS-focused (the key dialog uses osascript); the core flow is plain bash + python3 + curl.

</details>

<details>
<summary><b>Security notes</b></summary>

- The key lives only in `~/.claude/ccd/providers/keys.env` (mode 600), is displayed only as a masked tail, and is never bundled with or requested by the plugin at install. An exported `OPENROUTER_API_KEY` env var takes precedence over the file — the standard MCP/plugin convention.
- Key capture is native input only (dialog or hidden terminal prompt, `gh auth login`-style). If you paste a key into the chat anyway, ccd saves it but recommends rotating it, since it persists in the conversation history.
- Never put `ANTHROPIC_*` gateway variables in `settings.json`'s `env` block — they override shell exports and permanently pin every session (including background agents) to the external backbone.
- Never `/logout` to switch back — it genuinely logs you out. Returning is just `/exit` then `claude --resume`.

</details>
