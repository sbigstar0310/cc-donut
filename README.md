# ccx — backbone switcher

ccx is an emergency OpenRouter backbone for Claude Code when a Claude subscription quota is exhausted. It preserves the Claude Code shell, tools, hooks, skills, and conversation while changing the model provider.

## Install

```text
/plugin marketplace add <owner>/ccx
/plugin install ccx@ccx
/ccx:setup
```

For local development, add `~/Desktop/02_Projects/ccx` as the marketplace. Installation never asks for a key. Set one later, optionally, with `ccx key`; it is stored only in `~/.claude/ccx/providers/keys.env` with mode 600.

## Emergency and return flow

When quota is exhausted, leave Claude Code with `/exit`, then run `ccx -c` in the same terminal. To return to the subscription, use `/exit`, then `claude --resume`. Never use `/logout` for switching back.

While ccx is active, the statusline adds `ccx │ model · effort │ input/output price │ run/total cost`. The row works standalone. claude-dashboard is optional; install it only for quota warnings and automatic recovery detection.

See [QUOTA-SOS.md](QUOTA-SOS.md) for the complete emergency runbook.

## Security and support

No API key is bundled, requested at install time, or written to plugin files. `ccx key` uses hidden terminal input or a native macOS dialog and stores the key locally. Do not put gateway variables in `settings.json`.

Routing Claude Code through non-Anthropic models is unsupported by Anthropic and OpenRouter and may break after upstream changes. Run `ccx doctor` before relying on it.
