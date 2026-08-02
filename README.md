# ccx — emergency backbone switcher for Claude Code

**When your Claude subscription quota hits zero, keep working — same conversation, same tools, same workflow — on a low-cost OpenRouter model. One command: `ccx -c`.**

Claude Code's scaffold (tools, hooks, skills, conversation history) stays exactly as it is. Only the model answering inside it changes. When your Claude quota resets, ccx tells you, and you return with `claude --resume` — conversation intact, nothing to undo.

```text
Claude quota exhausted ──▶ /exit ──▶ ccx -c ──▶ keep coding on OpenRouter
Claude quota recovered ──▶ /exit ──▶ claude --resume ──▶ back on subscription
```

## Features

- **Resume, don't restart** — `ccx -c` reopens the conversation you were in, on an external backbone. Returning with `claude --resume` also keeps the conversation.
- **Three price tiers on the standard aliases** — `/model haiku|sonnet|opus` switches between a cheap scan model, an everyday coding model, and a heavyweight debugging model, mid-session, no restart.
- **Cheapest-provider routing by default** — every model runs with OpenRouter's `:floor` routing (lowest-cost provider). Switch to `:exacto` if tool calls misbehave.
- **Live cost in the statusline** — a dedicated row shows the active model, per-1M-token pricing, this run's spend, and the cumulative spend for the whole quota outage (survives restarts, auto-cleared on quota recovery):

  ```text
  ccx │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
  ```

- **Quota warnings before it's too late** — with the optional [claude-dashboard](https://github.com/uppinote20/claude-dashboard) plugin, you get a red statusline warning near exhaustion (`⚠ quota 96% → /exit then ccx -c`) and a green one when Claude recovers (`✓ Claude recovered → /exit then claude --resume`). Without it, switching and cost tracking still work; only the warnings are absent.
- **Safe key handling** — the OpenRouter key is optional at install, entered via hidden terminal input or a native macOS dialog (never in chat or shell history), stored locally with mode 600, and verified automatically on save.
- **No auth risk** — your claude.ai login is masked only inside the ccx process, never touched. `/logout` is never needed (and never use it — it genuinely logs you out).

## Install

Inside Claude Code:

```text
/plugin marketplace add sbigstar0310/ccx
/plugin install ccx@ccx
/ccx:setup
```

`/ccx:setup` wires the terminal launcher (`~/.local/bin/ccx`) and the statusline, then restart Claude Code. No API key is requested during installation — set one whenever you like:

```sh
ccx key       # paste key (hidden input / native dialog), verified on save
ccx doctor    # one API round trip; must print ✓ OK
```

Create a key at [openrouter.ai/keys](https://openrouter.ai/keys). Do this **while you still have Claude quota** — once it hits zero, Claude can't help you set things up.

## Default model slots

| Alias | Model | Price (in/out per 1M) | Use for |
| --- | --- | --- | --- |
| `/model haiku` | deepseek/deepseek-v4-flash | $0.09 / $0.18 | file scans, log grep, trivial edits |
| `/model sonnet` | openai/gpt-5.6-luna | $0.10 / $0.60 | default — everyday coding |
| `/model opus` | openai/gpt-5.6-terra | $1.00 / $6.00 | design judgment, tricky debugging |

Any OpenRouter slug also works directly: `/model z-ai/glm-5.2:floor`. Reassign the slots with `ccx pick`, or per-run with `ccx -c --opus sol`.

## Commands

| Command | What it does |
| --- | --- |
| `ccx` | Status: key, slots, routing, escape procedure |
| `ccx -c` | **The emergency command** — switch backbone and resume the last conversation |
| `ccx go` | Switch backbone into a fresh session |
| `ccx key` | Set the OpenRouter key (hidden input, auto-verified) |
| `ccx doctor [model]` | Validate key, URL, and model with one API call |
| `ccx models` / `ccx pick` | Show the catalog / reassign the three slots |
| `ccx -c --routing exacto` | Use providers with reliable tool calling (costs more) |
| `ccx off` | Run claude on the subscription again |

Full runbook — written to be readable *without* Claude: [QUOTA-SOS.md](QUOTA-SOS.md) (also copied to `~/.claude/ccx/QUOTA-SOS.md` so it's available offline at a stable path).

## How it works

`ccx` launches `claude` with `ANTHROPIC_BASE_URL` pointed at OpenRouter's Anthropic-compatible endpoint and the three `ANTHROPIC_DEFAULT_*_MODEL` slots mapped to OpenRouter slugs. Everything is process-scoped shell environment — nothing is written to `settings.json`, so background agents and other sessions are never silently pinned to the external backbone. A `UserPromptSubmit`/`PostToolUse` hook tracks OpenRouter spend against per-run and per-outage baselines and detects Claude quota resets from the dashboard cache.

State and config live under `~/.claude/ccx/` (`providers/` for config and the key, `run-state.json` / `outage-state.json` / caches for tracking).

## Caveats

- Routing Claude Code to non-Anthropic models is **officially unsupported by both Anthropic and OpenRouter**. It works today via the model-slot environment variables, but a Claude Code update could break it any day — run `ccx doctor` before relying on it.
- Context is displayed as 200K for gateway models regardless of the model's real window; manage long sessions with `/compact`.
- On the external backbone, Remote Control, voice input, and fast mode are disabled.
- macOS-focused (the key dialog uses osascript); the core flow is plain bash + python3 + curl.

## Security

- No key is bundled, requested at install, or written to plugin files; `ccx key` stores it only in `~/.claude/ccx/providers/keys.env` (mode 600) and prints only the masked tail.
- Never put `ANTHROPIC_*` gateway variables in the `env` block of `~/.claude/settings.json` — they would override shell exports and permanently pin every session to the external backbone.
