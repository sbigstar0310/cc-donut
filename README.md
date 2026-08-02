# ccx

**Claude Code quota just ran out mid-task? Get back into that exact conversation in 10 seconds — on any model you choose, for pennies.**

```text
/exit  →  ccx -c              # quota died: same conversation, same tools, now on OpenRouter
/exit  →  claude --resume     # quota recovered: back on subscription, conversation intact
```

## What you get

- 🔄 **Never lose the conversation** — switch out and back with it intact (round-trip tested)
- 🧰 **Never lose your setup** — tools, hooks, skills, MCP servers all keep running; only the model changes
- 🚨 **Told exactly what to type, exactly when** — statusline turns red near exhaustion, green on recovery, each with the command to run
- 🎛 **Any OpenRouter model, mid-session** — hundreds of models incl. dirt-cheap ones, one `/model` away, no restart
- 💸 **Cheapest provider by default, every cent visible** — `:floor` routing + live run/outage spend in the statusline
- 🔒 **Zero auth risk** — your claude.ai login is never touched; key stored locally (600), never typed in chat

```text
ccx │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
```

## Setup — 2 minutes, while you still have quota

```text
/plugin marketplace add sbigstar0310/ccx
/plugin install ccx@ccx
/ccx:setup                    # then restart Claude Code
```

```sh
ccx key       # optional until you need it — hidden input, verified on save
ccx doctor    # ✓ OK = your escape route works
```

Key from [openrouter.ai/keys](https://openrouter.ai/keys). Set it up **before** quota hits zero — after that, Claude can't walk you through it.

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

Remap the aliases permanently with `ccx pick`, or per-run: `ccx -c --opus sol`.

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

Complete emergency runbook (readable without Claude, kept offline at `~/.claude/ccx/QUOTA-SOS.md`): [QUOTA-SOS.md](QUOTA-SOS.md)

</details>

<details>
<summary><b>How it works</b></summary>

`ccx` launches `claude` with process-scoped environment variables pointing the model slots (`ANTHROPIC_DEFAULT_*_MODEL`) at OpenRouter's Anthropic-compatible endpoint. Nothing is written to `settings.json`, so no other session or background agent is ever silently rerouted, and your claude.ai login is only masked inside the ccx process — never modified.

A `UserPromptSubmit`/`PostToolUse` hook tracks OpenRouter spend against two baselines (this run, this whole outage) and detects Claude quota resets. State and config live under `~/.claude/ccx/`.

Quota warnings and recovery detection need the optional [claude-dashboard](https://github.com/uppinote20/claude-dashboard) plugin (it supplies the quota data). Without it, switching and cost tracking still work — you just don't get the red/green nudges.

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

- The key lives only in `~/.claude/ccx/providers/keys.env` (mode 600), is displayed only as a masked tail, and is never bundled with or requested by the plugin at install.
- Never put `ANTHROPIC_*` gateway variables in `settings.json`'s `env` block — they override shell exports and permanently pin every session (including background agents) to the external backbone.
- Never `/logout` to switch back — it genuinely logs you out. Returning is just `/exit` then `claude --resume`.

</details>
