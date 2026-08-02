---
name: key
description: Set the OpenRouter API key for ccx without leaving the session. Use for /ccx:key, "키 설정해줘" (set my key), "set my OpenRouter key", or when setup/doctor reports the key is empty.
---

# ccx key — in-session key setup

Offer the user these paths, in this order. All paths end with the key in
`~/.claude/ccx/providers/keys.env` (mode 600) for the terminal-side `ccx -c`.

## A. Paste in chat — default (works everywhere, zero navigation)

Say:

> Paste the key here and I'll save + verify it now. Heads-up: it stays in this
> conversation's local history — consider a spend-capped key
> (openrouter.ai/keys lets you set a credit limit per key).

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

## C. Plugin config menu — only if the user's Claude Code supports it

`/plugin` → **ccx → Configure options** (masked input, keychain; the quota-guard
hook syncs it to keys.env on the next message). Known to be missing/broken on
some Claude Code versions ("No configuration changes" with no input UI) — if the
user reports that, fall back to A or B without retrying.

Whatever the path: never repeat the full key in any output, and finish with
`~/.local/bin/ccx doctor` so the user sees `✓ OK`.
