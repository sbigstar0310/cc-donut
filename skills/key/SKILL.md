---
name: key
description: Set the OpenRouter API key for ccx without leaving the session. Use for /ccx:key, "키 설정해줘" (set my key), "set my OpenRouter key", or when setup/doctor reports the key is empty.
---

# ccx key — in-session key setup

Offer the user these paths, in this order. All paths end with the key in
`~/.claude/ccx/providers/keys.env` (mode 600) for the terminal-side `ccx -c`.

## First: does the user have a key at all?

If they don't (or aren't sure), open the key-creation page for them right now —
don't just paste a URL and hope:

```sh
open  https://openrouter.ai/keys   # macOS
xdg-open https://openrouter.ai/keys   # Linux with a desktop
```

On a headless box (no DISPLAY), show the URL on its own line instead so it's
one click/copy away. Either way add one tip: "While creating it, set a credit
limit on the key — then even a leaked key can only spend that much."

## A. Paste in chat — default (works everywhere, zero navigation)

Say:

> Paste the key here and I'll save + verify it now. Heads-up: it stays in this
> conversation's local history — that's why the spend cap above is a good idea.

When they paste it, save via the piped path (never echo it back, never write it
anywhere else):

```sh
printf '%s\n' 'PASTED_KEY' | ~/.local/bin/ccx key
```

Relay only the masked one-line result.

## B. Native input — macOS dialog or any terminal (zero trace)

`~/.local/bin/ccx key` run from this session opens a native dialog on macOS.
On Linux without a dialog, `ccx key` in any terminal window prompts with hidden
input.

Whatever the path: never repeat the full key in any output, and finish with
`~/.local/bin/ccx doctor` so the user sees `✓ OK`.
