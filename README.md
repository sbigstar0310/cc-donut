# ccx

**Claude Code just told you the quota is exhausted — mid-task, conversation open, deadline tonight. ccx gets you back into that exact conversation in 10 seconds, on any model you choose, for pennies.**

```text
/exit  →  ccx -c        # same conversation, same tools — now on OpenRouter
```

And when your Claude quota comes back, the statusline tells you, and one command returns you — conversation still intact:

```text
/exit  →  claude --resume
```

Nothing to undo, nothing to reconfigure, your claude.ai login untouched.

## Why this exists

Quota exhaustion never happens at a convenient time. It happens mid-debugging, with context you spent hours building. Your options were: wait 5 hours (or worse, until the weekly reset), or start over in another tool and lose everything.

ccx removes that fear:

- **You never lose your conversation.** `ccx -c` resumes it; `claude --resume` brings it back to your subscription later. Round-trip tested.
- **You never lose your setup.** Tools, hooks, skills, MCP servers, keybindings — the whole Claude Code scaffold keeps running. Only the model behind it changes.
- **You're warned before it's too late.** Near exhaustion the statusline turns red with the exact escape command; when Claude recovers it turns green with the exact return command. You never have to think about what to type.
- **You pay only while stranded, and you see every cent.** Pay-as-you-go through OpenRouter at the cheapest provider for each model (`:floor` routing), with live spend in the statusline — this session and the whole outage:

  ```text
  ccx │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
  ```

## Any model. Seriously.

ccx isn't tied to a model lineup. Anything on [openrouter.ai/models](https://openrouter.ai/models) — hundreds of models, including dirt-cheap and free ones — is one `/model` away, mid-session, no restart:

```text
/model deepseek/deepseek-v4-flash     # ~$0.09/M — grep-and-scan work costs basically nothing
/model z-ai/glm-5.2:floor             # any slug from the catalog, cheapest provider
```

Sensible defaults are pre-wired onto the aliases you already use — `/model haiku` (cheapest), `/model sonnet` (everyday), `/model opus` (hard problems) — and `ccx pick` remaps them to whatever you prefer.

## Setup — 2 minutes, before you need it

Inside Claude Code:

```text
/plugin marketplace add sbigstar0310/ccx
/plugin install ccx@ccx
/ccx:setup
```

Then restart Claude Code. No API key is demanded at install — add one whenever you're ready:

```sh
ccx key       # hidden input / native dialog, verified on save — never typed in chat
ccx doctor    # ✓ OK means you're covered
```

Get a key at [openrouter.ai/keys](https://openrouter.ai/keys). **Do this while you still have quota** — once it's at zero, Claude can't walk you through setup.

## Commands you'll actually use

| Command | When |
| --- | --- |
| `ccx -c` | **The moment quota dies.** Switch and resume the conversation |
| `ccx doctor` | Any time, to confirm the escape route works |
| `ccx key` | Once, to store your OpenRouter key |
| `ccx` / `ccx models` / `ccx pick` | Check status, browse models, remap aliases |
| `ccx -c --routing exacto` | If a cheap provider fumbles tool calls |

Complete runbook (readable without Claude, kept offline at `~/.claude/ccx/QUOTA-SOS.md`): [QUOTA-SOS.md](QUOTA-SOS.md)

## Good to know

- **How it works**: process-scoped environment variables point Claude Code's model slots at OpenRouter's Anthropic-compatible endpoint. Nothing is written to `settings.json`, so no other session or background agent is ever silently rerouted.
- **Quota warnings** need the optional [claude-dashboard](https://github.com/uppinote20/claude-dashboard) plugin (it supplies the quota data). Without it, switching and cost tracking still work — you just don't get the red/green statusline nudges.
- **Officially unsupported path**: both Anthropic and OpenRouter state that Claude Code targeting non-Claude models isn't guaranteed. It works via the standard model-slot variables today, but a Claude Code update could break it — hence `ccx doctor`.
- Gateway models display a 200K context regardless of their real window; use `/compact` on long sessions. Remote Control, voice input, and fast mode are off while on the external backbone.
- **Security**: the key lives only in `~/.claude/ccx/providers/keys.env` (mode 600), is shown only as a masked tail, and is never bundled or requested at install. Never put `ANTHROPIC_*` gateway variables in `settings.json`'s `env` block — that would pin every session to the external backbone permanently. Never `/logout` to switch back — it genuinely logs you out; `ccx` never touches your login.
