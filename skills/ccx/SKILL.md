---
name: ccx
description: Prepare, check, and configure the ccx backbone fallback for Claude quota exhaustion. Use when the user asks things like "/ccx", "쿼타 떨어지면 어떡하지" (what if quota runs out), "폴백 준비" (prepare fallback), "백본 바꾸는 거 설정" (set up backbone switching), "OpenRouter 키 넣어줘" (add my OpenRouter key), or when the quota-guard hook reports the quota threshold was exceeded. The actual emergency switch is not this skill — the user runs `ccx -c` in a terminal.
---

# ccx preparation & checkup

`ccx` is a shell tool that keeps the Claude Code scaffold intact when the Claude
quota hits zero and swaps only the backbone model to a cheap OpenRouter model.
**This skill is for the preparation phase only** — once quota is at zero, Claude
cannot run, so the actual switch is the user typing `ccx -c` in a terminal.

Run `/ccx:setup` once for first-time terminal and statusline wiring. Installation works without a key; set it later with `ccx key`.

Full background and design rationale: `~/.claude/ccx/QUOTA-SOS.md`

## Procedure

### 1. Check status

```sh
ccx
```

Verify from the output: the OpenRouter key is set, which models occupy the three
slots (haiku/sonnet/opus), and whether routing is floor or exacto.

### 2. If the key is empty, set it now

```sh
ccx key
```

When run inside Claude Code there is no terminal, so **a native macOS input
dialog opens.** The user pastes the key there and it is saved. The key never
appears in the conversation or shell history. Tell the user: "A dialog is open —
paste the key there."

If they don't have a key yet, point them to https://openrouter.ai/keys.

### 3. Validate

```sh
ccx doctor
```

If it doesn't print `✓ OK`, relay the per-HTTP-code cause verbatim to the user.
401/403 is a key problem, 402 is insufficient balance, 400/404 is a model-slug problem.

### 4. Adjust slot assignments if needed

```sh
ccx models     # Catalog with prices and benchmark rationale
ccx pick       # Interactive reassignment — needs direct user input, so tell them to run it in a terminal
```

`ccx pick` is interactive and doesn't work well inside Claude Code. If only the
assignment needs changing, editing `~/.claude/ccx/providers/tiers.env` directly is
faster. Slugs reference the keys in `models.conf`.

## Always tell the user

- The emergency switch is one command in a terminal: **`ccx -c`**. It resumes the
  conversation they were in.
- After switching, models change in-session via `/model haiku|sonnet|opus`, or a
  direct `/model <slug>`. No restart needed.
- After switching, the statusline gains a row:
  `ccx │ <model> · <effort> │ in $x/M · out $y/M │ run $a · total $b`.
  in/out is the current model's per-1M-token price (cheapest provider under
  :floor); `run` is this ccx process's OpenRouter spend, `total` is the whole
  quota outage's cumulative spend (survives ccx restarts, cleared on quota
  recovery). Updated on prompts/tool runs; unchanged while idle. This row
  renders even without the claude-dashboard plugin.
- Install claude-dashboard to get quota warnings and automatic recovery detection;
  it is an optional enhancement, not a ccx dependency.
- The statusline's `✓ Claude recovered` means a Claude 5-hour or 7-day quota
  went from 100% to 0% after a reset. Then: `/exit`, and in the same terminal
  `claude --resume`.
- Returning to the subscription is `/exit` then `claude --resume` in the same
  terminal. **Never `/logout`** — that genuinely logs the user out.
- This path is officially unsupported by both Anthropic and OpenRouter. It can
  break, so run `ccx doctor` before relying on it.

## Never do

- Never print the API key in the conversation or have the user type it via
  `echo`. Use `ccx key`.
- Never put ANTHROPIC_* gateway variables in the `env` block of
  `~/.claude/settings.json`. They override shell exports and permanently pin
  every session — including background agents — to the external backbone.
