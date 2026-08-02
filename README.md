# ccx — **C**laude **C**ode e**X**ternal backbone

**Keep 100% of your Claude Code — tools, hooks, skills, MCP servers, and the very conversation you're in. Swap only the model.**

Built for the moment your Claude subscription quota dies mid-task: you're back in the same conversation in 10 seconds, on any OpenRouter model, for pennies — and back on your subscription the moment it recovers.

```text
/exit  →  ccx -c              # quota died: same everything, now on OpenRouter
/exit  →  claude --resume     # quota recovered: back on subscription, conversation intact
```

## What you get

- 🧰 **Your whole Claude Code, untouched** — the entire scaffold (tools, hooks, skills, MCP servers, keybindings, history) keeps running; ccx swaps nothing but the model behind it
- 🔄 **The conversation survives both directions** — `ccx -c` resumes it on OpenRouter, `claude --resume` brings it home (round-trip tested)
- 🎛 **Any OpenRouter model, mid-session** — hundreds of models incl. dirt-cheap ones, one `/model` away, no restart
- 🚨 **Told exactly what to type, exactly when** — statusline turns red near exhaustion, green on recovery, each with the command to run
- 💸 **Cheapest provider by default, every cent visible** — `:floor` routing + live run/outage spend in the statusline
- 🔒 **Zero auth risk** — your claude.ai login is never touched; key stored locally (600), never typed in chat

```text
ccx │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
```

## Setup — 2 minutes, while you still have quota

**From a terminal** (safe to paste as one block):

```sh
claude plugin marketplace add sbigstar0310/ccx
claude plugin install ccx@ccx
```

Then open Claude Code and run `/ccx:setup`, then restart Claude Code.

<details>
<summary>Prefer doing it inside Claude Code?</summary>

Slash commands are parsed **one line at a time** — enter each separately (pasting the block as one message won't work):

1. `/plugin marketplace add sbigstar0310/ccx`
2. `/plugin install ccx@ccx`
3. `/reload-plugins`
4. `/ccx:setup` — then restart Claude Code

</details>

Optionally add your OpenRouter key (any time, but **before** quota hits zero — after that, Claude can't walk you through it). Key from [openrouter.ai/keys](https://openrouter.ai/keys):

```sh
ccx key       # hidden input, verified on save
ccx doctor    # ✓ OK = your escape route works
```

That's everything you need. Details below when you want them.

---

<details>
<summary><b>Models — defaults and switching</b></summary>

Sensible defaults are pre-wired onto the aliases you already use:

| Alias | Default model | Price (in/out per 1M) | Use for |
| --- | --- | --- | --- |
| `/model haiku` | deepseek/deepseek-v4-flash | $0.09 / $0.18 | scans, grep, trivial edits |
| `/model sonnet` | openai/gpt-5.6-luna | $0.10 / $0.60 | everyday coding |
| `/model opus` | openai/gpt-5.6-terra | $1.00 / $6.00 | hard problems, debugging |

But you're not limited to these. Any slug from [openrouter.ai/models](https://openrouter.ai/models) works mid-session:

```text
/model z-ai/glm-5.2:floor
```

Remap the aliases permanently with `ccx pick` (an offline menu over the curated catalog), or per-run: `ccx -c --opus sol`.

The catalog is a snapshot and goes stale. To refresh it with current benchmarks and prices, ask Claude (while you have quota): *"refresh the ccx model picks"* — the `/ccx` skill researches independent benchmarks and live OpenRouter pricing, recomputes the price/performance frontier, and proposes an updated catalog before writing anything.

</details>

<details>
<summary><b>Command reference</b></summary>

| Command | When |
| --- | --- |
| `ccx -c` | **The moment quota dies** — switch and resume the conversation |
| `ccx doctor [model]` | Any time — one API round trip confirms the escape route |
| `ccx key` | Once — store the OpenRouter key |
| `ccx` | Status: key, slots, routing, escape procedure |
| `ccx models` / `ccx pick` | Browse the catalog / remap the three aliases |
| `ccx go` | Switch into a fresh session instead of resuming |
| `ccx -c --routing exacto` | If a cheap provider fumbles tool calls |
| `ccx off` | Run claude on the subscription again |

**Skills inside Claude Code** (type `/` to find them):

| Skill | What it does |
| --- | --- |
| `/ccx` | Readiness checkup and configuration by chat: verifies key/slots/routing, sets the key via native dialog, refreshes the model catalog with fresh benchmarks & prices on request ("refresh the ccx model picks") |
| `/ccx:setup` | First-time wiring — launchers, statusline, legacy migration, then key + doctor without leaving the session |
| `/ccx:key` | Set the OpenRouter key — opens the key-creation page if you don't have one, then native masked input (macOS dialog / terminal prompt); the key never enters the chat |
| `/ccx:doctor` | Diagnose the escape route: key, API, model slugs, wiring — with the fix offered on failure |
| `/ccx:update` | One-step plugin update to the latest release |
| `/ccx:uninstall` | Clean removal (keeps your key unless you ask to purge) |

Complete emergency runbook (readable without Claude, kept offline at `~/.claude/ccx/QUOTA-SOS.md`): [QUOTA-SOS.md](QUOTA-SOS.md)

</details>

<details>
<summary><b>How it works</b></summary>

`ccx` launches `claude` with process-scoped environment variables pointing the model slots (`ANTHROPIC_DEFAULT_*_MODEL`) at OpenRouter's Anthropic-compatible endpoint. Nothing is written to `settings.json`, so no other session or background agent is ever silently rerouted, and your claude.ai login is only masked inside the ccx process — never modified.

A `UserPromptSubmit`/`PostToolUse` hook tracks OpenRouter spend against two baselines (this run, this whole outage) and detects Claude quota resets. State and config live under `~/.claude/ccx/`.

Quota warnings and recovery detection need the optional [claude-dashboard](https://github.com/uppinote20/claude-dashboard) plugin (it supplies the quota data). Without it, switching and cost tracking still work — you just don't get the red/green nudges.

</details>

<details>
<summary><b>Development & testing</b></summary>

```sh
test/smoke.sh                 # 17 checks against the real scripts in a throwaway HOME
test/docker.sh                # same suite in a clean Debian container
test/docker.sh alpine:3.20    # …and on musl/BusyBox
```

No network, no real key, no writes outside the temp HOME. Run the container
tests before releasing: GNU/BSD differences (e.g. `stat`) pass silently on
macOS and break Linux users.

</details>

<details>
<summary><b>Caveats</b></summary>

- **Officially unsupported path**: both Anthropic and OpenRouter state that Claude Code targeting non-Claude models isn't guaranteed. It works via the standard model-slot variables today, but a Claude Code update could break it — hence `ccx doctor`.
- Gateway models display a 200K context regardless of the model's real window; use `/compact` on long sessions.
- Remote Control, voice input, and fast mode are off while on the external backbone.
- macOS-focused (the key dialog uses osascript); the core flow is plain bash + python3 + curl.

</details>

<details>
<summary><b>Security notes</b></summary>

- The key lives only in `~/.claude/ccx/providers/keys.env` (mode 600), is displayed only as a masked tail, and is never bundled with or requested by the plugin at install. An exported `OPENROUTER_API_KEY` env var takes precedence over the file — the standard MCP/plugin convention.
- Key capture is native input only (dialog or hidden terminal prompt, `gh auth login`-style). If you paste a key into the chat anyway, ccx saves it but recommends rotating it, since it persists in the conversation history.
- Never put `ANTHROPIC_*` gateway variables in `settings.json`'s `env` block — they override shell exports and permanently pin every session (including background agents) to the external backbone.
- Never `/logout` to switch back — it genuinely logs you out. Returning is just `/exit` then `claude --resume`.

</details>
