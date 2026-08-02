---
name: key
description: Set the OpenRouter API key for ccd. Use for /ccd:key, "키 설정해줘" (set my key), "set my OpenRouter key", or when setup/doctor reports the key is empty.
---

# ccd key — key setup

All paths end with the key in `~/.claude/ccd/providers/keys.env` (mode 600),
readable by both this plugin and the terminal-side `ccd -c`. An exported
`OPENROUTER_API_KEY` env var also works and takes precedence (the standard
MCP/plugin convention).

## First: does the user have a key at all?

If they don't (or aren't sure), open the key-creation page for them right now —
don't just paste a URL and hope:

```sh
open https://openrouter.ai/keys       # macOS
xdg-open https://openrouter.ai/keys   # Linux with a desktop
```

On a headless box (no DISPLAY), show the URL on its own line so it's one
click/copy away. Either way add one tip: "While creating it, set a credit limit
on the key — then even a leaked key can only spend that much."

## Default path: native input — the key never enters this chat

- **macOS, right from this session**: run `~/.local/bin/ccd key` — a native
  dialog opens; tell the user to paste there. Output shows only a masked tail.
  Then run `~/.local/bin/ccd doctor` and relay the verdict.
- **Linux / no dialog**: tell the user to run `ccd key` once in any terminal
  window (hidden input, like `gh auth login`'s paste-token prompt), then come
  back; you run `~/.local/bin/ccd doctor` and relay the verdict.

Do not invite the user to paste the key into the chat — every surveyed tool
treats that as an anti-pattern (the key persists in transcripts).

## If the user pastes a key into chat anyway

Accept it gracefully — don't scold, don't refuse:

1. Save it via the piped path (never echo it back, never write it elsewhere):
   ```sh
   printf '%s\n' 'PASTED_KEY' | ~/.local/bin/ccd key
   ```
2. Relay the masked one-line result, then run doctor.
3. Add one line: "Since the key touched this conversation, consider rotating it
   at openrouter.ai/keys when convenient — or rely on its credit limit."

Never print the key file's contents; never repeat a full key in any output.
