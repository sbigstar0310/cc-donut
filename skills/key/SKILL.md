---
name: key
description: Set the OpenRouter API key for ccx without leaving the session. Use for /ccx:key, "키 설정해줘" (set my key), "set my OpenRouter key", or when setup/doctor reports the key is empty.
---

# ccx key — in-session key setup

Offer the user these paths, in this order. All three end with the key in
`~/.claude/ccx/providers/keys.env` (mode 600) for the terminal-side `ccx -c`.

## A. Plugin config menu — recommended (secure, works everywhere incl. headless Linux)

Tell the user:

> Type `/plugin`, pick **ccx → Configure options**, and paste your key there.
> The input is masked and stored in the system keychain — it never appears in
> this chat. Then send me any message and I'll verify it.

On their next message the quota-guard hook automatically syncs the key into
`keys.env`. Then run `~/.local/bin/ccx doctor` and relay the one-line verdict.

## B. Paste in chat — fastest, with informed consent

If the user prefers zero menu navigation, say:

> Paste the key here and I'll save + verify it now. Heads-up: it stays in this
> conversation's local history — consider a spend-capped key
> (openrouter.ai/keys lets you set a credit limit per key).

When they paste it, save via the piped path (never echo it back, never write it
anywhere else):

```sh
printf '%s\n' 'PASTED_KEY' | ~/.local/bin/ccx key
```

Relay only the masked one-line result.

## C. Native input — macOS dialog or any terminal

`~/.local/bin/ccx key` run from this session opens a native dialog on macOS.
On Linux without a dialog, `ccx key` in any terminal window prompts with hidden
input.

Whatever the path: never repeat the full key in any output, and finish with
`~/.local/bin/ccx doctor` so the user sees `✓ OK`.
