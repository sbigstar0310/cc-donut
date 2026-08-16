---
name: ccd
description: Prepare, check, and configure the ccd backbone fallback for Claude quota exhaustion. Use when the user asks things like "/ccd", "쿼타 떨어지면 어떡하지" (what if quota runs out), "폴백 준비" (prepare fallback), "백본 바꾸는 거 설정" (set up backbone switching), "OpenRouter 키 넣어줘" (add my OpenRouter key), "모델 추천 갱신" / "refresh the ccd model picks" / "are these still the best models?", or when the quota-guard hook reports the quota threshold was exceeded. The actual emergency switch is not this skill — the user runs `ccd -c` in a terminal.
---

# ccd preparation & checkup

`ccd` is a shell tool that keeps the Claude Code scaffold intact when the Claude
quota hits zero and swaps only the backbone model to a cheap OpenRouter model.
**This skill is for the preparation phase only** — once quota is at zero, Claude
cannot run, so the actual switch is the user typing `ccd -c` in a terminal.

Run `/ccd:setup` once for first-time terminal and statusline wiring. Installation works without a key; set it later with `ccd key`.

Full background and design rationale: `~/.claude/ccd/QUOTA-SOS.md`

## Procedure

### 1. Check status

```sh
ccd
```

Verify from the output: the OpenRouter key is set, which models occupy the three
slots (haiku/sonnet/opus), and whether routing is floor or exacto.

### 2. If the key is empty, set it now

```sh
ccd key
```

When run inside Claude Code there is no terminal, so **a native macOS input
dialog opens.** The user pastes the key there and it is saved. The key never
appears in the conversation or shell history. Tell the user: "A dialog is open —
paste the key there."

If they don't have a key yet, point them to https://openrouter.ai/keys.

### 3. Validate

```sh
ccd doctor
```

If it doesn't print `✓ OK`, relay the per-HTTP-code cause verbatim to the user.
401/403 is a key problem, 402 is insufficient balance, 400/404 is a model-slug problem.

### 3.5 Ask whether they have a second Claude subscription

Do this before talking about models — a second subscription is strictly better
than any OpenRouter model, because it is free and it is real Claude.

```sh
ccd account list
```

- **Nothing registered:** ask whether they have another Claude account (a work,
  lab, or personal one). If yes, walk them through it: `ccd account add` registers
  whoever is signed in now; then they run `claude`, `/login` as the other account,
  and `ccd account add` again. After that, quota exhaustion hops to the spare
  subscription and only reaches OpenRouter when every account is spent.
- **One registered:** that alone does nothing. Say so plainly and offer to finish
  the second one.
- **Any account shows `needs re-login`:** this is urgent and easy to miss. That
  spare cannot receive a handoff, and the failure is invisible until the moment
  it is needed. Fix it now: `claude` → `/login` as that account →
  `ccd account add --force --name <name>`.

Registering requires signing in, so it is impossible once quota is at zero — this
belongs in the preparation phase, same as the key.

Do not push this on someone with a single subscription; for them the OpenRouter
path is the whole answer and a second account is not something to go buy.

### 4. Adjust slot assignments if needed

```sh
ccd models     # Catalog with prices and benchmark rationale
ccd pick       # Interactive reassignment — needs direct user input, so tell them to run it in a terminal
```

`ccd pick` is interactive and doesn't work well inside Claude Code. If only the
assignment needs changing, editing `~/.claude/ccd/providers/tiers.env` directly is
faster. Slugs reference the keys in `models.conf`.

### 5. Refresh the model recommendations (LLM research flow)

`ccd pick` is deliberately a dumb offline menu — it must work in a terminal when
Claude is dead. The research lives here instead. When the user asks to refresh or
re-evaluate the model picks (the catalog is a frozen snapshot and goes stale as
prices move and new models ship), do this:

1. **Read the current catalog** at `~/.claude/ccd/providers/models.conf`
   (format: `key slug in/out-price description`, `#` comments).
2. **Research candidates with WebSearch.** Look for recent *independent*
   coding-agent benchmarks (e.g. DeepSWE-style leaderboards, Terminal-Bench).
   Distrust vendor self-reported SWE-bench numbers. Note which harness each
   score was measured in — almost none are measured in Claude Code itself, so
   treat scores as approximate.
3. **Verify live pricing** from OpenRouter's public API (no key needed):
   `GET https://openrouter.ai/api/v1/models/<slug>/endpoints` — take the
   cheapest endpoint whose `tag` does NOT contain `/` (tags with `/` are
   service-tier variants like `openai/flex`, not what `:floor` selects).
4. **Compute the pareto frontier** on (benchmark score, blended cost). Flag
   currently-cataloged models that are now dominated and candidates that
   dominate them.
5. **Answer the question the user actually asked: what goes in the three
   slots?** The deliverable is one table with exactly three rows — one per
   alias — and nothing above it but a one-line verdict:

   ```
   Catalog is current — no slot changes worth making. (flash price drifted +24%, updating that line.)

   | slot     | recommended                | $/M in·out   | why |
   | /model haiku  | deepseek/deepseek-v4-flash | 0.11 · 0.22 | cheapest usable; scans & grep |
   | /model sonnet | openai/gpt-5.6-luna        | 0.10 · 0.60 | best value at everyday coding |
   | /model opus   | moonshotai/kimi-k3         | 2.90 · 14.00 | hard problems, debugging |

   Swap in? [y/n]  ·  runner-up for opus: gpt-5.6-sol (72.7%, $5/$30) — pricier, only for the hardest work
   ```

   Rules for that report:
   - Three rows. Extra catalog entries (reference/experimental models) get at
     most one trailing "runner-up" line, never their own table.
   - `why` is one clause. No methodology, no benchmark-provenance paragraphs,
     no verification plans — the user asked which models to use, not how you
     decided. Offer details only if they ask.
   - If nothing should change, say so in the first line and stop there; don't
     manufacture a diff to look busy.
6. **Write only after approval.** Update `models.conf` (keep the file format
   and one-line rationale notes) and, if slot assignments change, `tiers.env`.
   Then run `ccd doctor <key>` once per changed slot and report the verdicts as
   one line each.

## Always tell the user

- The emergency switch is one command in a terminal: **`ccd -c`**. It resumes the
  conversation they were in.
- **If a second Claude account is registered, OpenRouter is no longer the first
  stop.** Quota exhaustion moves the conversation to the spare subscription —
  free, still real Claude — and only reaches OpenRouter when every registered
  account is spent. `ccd account list` shows which account is active and whether
  a spare has room; the statusline shows the same as `● claude:<name> │ spare …`.
- A spare account that reports `needs re-login` is the one failure worth raising
  unprompted. It looks healthy in every other view and only surfaces at the
  moment of the handoff, which is the moment the user cannot fix it.
- After switching, models change in-session via `/model haiku|sonnet|opus`, or a
  direct `/model <slug>`. Selection needs no restart. A direct model is outside
  ccd's launch-time context budget until the statusline evaluates fresh provider
  metadata: obey `checking provider context…`, the exact safe `[1m]` command, or
  `restart for safe context → /exit; ccd -c --model provider/model` as shown.
  Never claim ccd can resize an already-running Claude Code process.
- `[1m]` is a local Claude Code hint, stripped before OpenRouter; it does not
  expand upstream capacity. ccd's conservative provider-pool metadata policy is
  implementation-specific and can become stale, so it is not a provider guarantee.
- After switching, the statusline gains a row:
  `ccd │ <model> · <effort> │ in $x/M · out $y/M │ run $a · total $b`.
  in/out is the current model's per-1M-token price (cheapest provider under
  :floor); `run` is this ccd process's OpenRouter spend, `total` is the whole
  quota outage's cumulative spend (survives ccd restarts, cleared on quota
  recovery). Updated on prompts/tool runs; unchanged while idle. This row
  renders even without the claude-dashboard plugin.
- Install claude-dashboard to get quota warnings and automatic recovery detection;
  it is an optional enhancement, not a ccd dependency.
- The statusline's `✓ Claude recovered` means a Claude 5-hour or 7-day quota
  went from 100% to 0% after a reset. Then: `/exit`, and in the same terminal
  `claude --resume`.
- Returning to the subscription is `/exit` then `claude --resume` in the same
  terminal. **Never `/logout`** — that genuinely logs the user out.
- This path is officially unsupported by both Anthropic and OpenRouter. It can
  break, so run `ccd doctor` before relying on it.

## Never do

- Never print the API key in the conversation or have the user type it via
  `echo`. Use `ccd key`.
- Never put ANTHROPIC_* gateway variables in the `env` block of
  `~/.claude/settings.json`. They override shell exports and permanently pin
  every session — including background agents — to the external backbone.
