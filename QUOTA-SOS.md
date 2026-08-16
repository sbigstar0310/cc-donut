# Quota Outage Emergency Manual (readable without Claude)

Once the Claude subscription quota hits zero, you cannot ask Claude to "set this up."
That is why `ccd` and this document were prepared **in advance**.

## One-line summary

```sh
ccd -c        # Resume the conversation you were in, swapping only the model to a cheap OpenRouter one
```

The Claude Code shell (tools, hooks, skills, conversation history) stays intact.
Only the model answering inside it changes.

**Always type this in a terminal app.** Running it via `!` inside Claude Code drops
claude into headless mode (no interactive screen), and the "last conversation" that
`-c` tries to resume is the very session that is still running, which conflicts.
**Quit Claude Code first**, then type it in the terminal. (ccd detects this case,
blocks it, and explains why — a mistyped attempt cannot cause damage.)

## One-time setup — do this while quota remains

```sh
ccd key       # Paste your OpenRouter key and it is saved (create at openrouter.ai/keys)
ccd doctor    # Must print ✓ OK
```

Skip this and you will be stuck at exactly the moment you need it. `ccd doctor`
makes one API round trip before launching claude, validating the key, URL, and
model names — so you don't burn emergency time debugging.

## If you have a second Claude subscription

Register it and quota exhaustion goes there **before** it ever reaches OpenRouter.
Same conversation, still on the subscription, nothing billed. Do this while quota
remains — registering requires signing in, and you cannot sign in from a dead
session.

```sh
ccd account add          # registers whoever is signed in right now
claude                   # then /login as your other account
ccd account add          # register that one too
ccd account list         # both accounts with live quota — verify before you need it
```

The ladder becomes:

```text
account A spent  →  account B has room?  →  B      free
                 →  B spent too?         →  🍩     OpenRouter (paid)
```

With automatic handoff on (`ccd setup --auto`) this needs nothing typed at all.
Without it, switch by hand between sessions:

```sh
# in a terminal, with Claude Code closed
ccd account use B
claude --resume
```

**The one thing that can quietly rot:** a registered account you never use. Its
refresh token lasts about 8.5 days. ccd refreshes idle accounts once a day to keep
them alive, but if your machine was off for a couple of weeks the spare may need a
re-login. `ccd account list` and `ccd doctor` both say `needs re-login` when that
has happened. Check it *before* you need it — after quota is gone you cannot ask
Claude for help fixing it.

```sh
claude                                     # /login as that account
ccd account add --force --name <name>      # re-register it
```

## After switching — three ways to change models

Claude Code ships with model aliases `haiku`/`sonnet`/`opus`. Each slot is
pre-assigned a model at a different price tier, so you can move between them with
one `/model` line **without restarting Claude Code**. The alias names stay the
same; the models actually attached are:

| You type | Actual model | When to use |
| --- | --- | --- |
| `/model haiku` | deepseek-v4-flash | File scans, log grep, trivial edits |
| `/model sonnet` | gpt-5.6-luna | Default. Everyday coding |
| `/model opus` | kimi-k3 | Design judgment, tricky debugging |

To use a model outside the three slots, **type its slug directly.** This also
applies immediately mid-session.

```
/model z-ai/glm-5.2:floor
```

For a direct model, ccd observes the active ID in the statusline and checks its
cached OpenRouter provider-pool metadata without blocking the UI:

- `checking provider context…` — metadata is absent/stale; wait for the next refresh.
- `verified context → /model provider/model:floor[1m]` — run that exact second
  `/model` command only when shown. The current global compact window is already
  conservative for that pool.
- `restart for safe context → /exit; ccd -c --model provider/model` — use this
  when the active process window is too large for the newly selected pool. The
  restart preserves the conversation and sizes its budget from that model at launch.

`[1m]` is a local Claude Code hint stripped before OpenRouter; it does not create
or increase upstream provider context. ccd cannot mutate a running process's
global compact window after `/model`.

To change the slot assignments themselves:

```sh
ccd models              # What models exist and what they cost
ccd pick                # Interactively reassign the three slots (saved)
ccd -c --opus pro       # Use a different model for the opus slot this run only
ccd -c --model provider/model  # Resume with this direct model as the current/sonnet slot
```

## Cost policy

The same model is served by multiple providers on OpenRouter at different prices.
The default is **`:floor` (always the cheapest provider)**. Since the purpose is
riding out a quota outage, cost comes first.

The tradeoff: a cheap provider that handles tool calls poorly can burn extra
tokens on retries. If file edits or command runs keep misfiring, try this once
and compare:

```sh
ccd -c --routing exacto     # Providers with reliable tool calling (costs more)
```

To keep that permanently, edit `CCD_ROUTING` in `~/.claude/ccd/providers/openrouter.env`.

## Cost and recovery signals in the statusline

After switching to `ccd`, the dashboard (if installed) still shows the Claude
subscription quota/reset times, and **a dedicated ccd row is added below it**.
The ccd row renders on its own even without the dashboard plugin.

```text
ccd │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
```

- **model · effort** — the external model (+routing) actually attached right now
  and the Claude Code effort setting. `/model` changes appear on the next refresh.
- **in/out $…/M** — the current model's price per 1M tokens. With `:floor` it is
  the single cheapest-provider price; other routings show the provider min–max
  range. Sourced from the OpenRouter catalog, refreshed daily. The final source
  of truth for actual billing is the spend numbers.
- **run $…** — pay-as-you-go spend accrued **in this ccd process only**, measured
  against the OpenRouter key's cumulative usage at ccd launch. Updates when you
  send a prompt or a tool runs; it does not refresh while idle. (Different from
  the lifetime total on the OpenRouter site.)
- **total $…** — spend accrued across **the whole quota outage**, surviving ccd
  restarts. Created by the first ccd of an outage and cleared automatically when
  a Claude quota reset is detected.
- `✓ Claude recovered → /exit then claude --resume` — a Claude 5-hour or 7-day
  quota went from exhausted (100%) to reset (0%). If both windows reset at the
  same moment they merge into one notice. Shown once per reset.

## Returning to the subscription

When the recovery signal appears (or whenever you want to go back), **end the
current ccd session first.**

```text
/exit
```

Then, in the same terminal:

```sh
claude --resume
```

`--resume` picks the conversation you were working on in ccd right back up.
(Verified by a real round-trip test — returns to the subscription with the
conversation intact.)

**Nothing needs to be undone.** Why: `ANTHROPIC_AUTH_TOKEN` masks the claude.ai
login only within that process; the login itself stays saved. **Never run
`/logout`** — that genuinely logs you out and forces a re-login.

## Doing all of this automatically

Everything above is the manual round trip. It always works and needs nothing
installed. If you would rather not type any of it:

```sh
ccd setup --auto
```

Keep starting sessions as `claude`. When quota dies the conversation reopens on
OpenRouter by itself, and when the window resets it returns to the subscription
the same way. Turn it off with `ccd setup --no-auto`.

It is deliberately conservative, and each rule exists so a failure leaves you no
worse off than doing nothing:

- A `rate_limit` error alone never triggers it — the quota reading has to agree,
  so transient throttling is ignored. No reading, no handoff.
- Nothing is signalled unless the launcher is running to catch it, and nothing is
  signalled without an OpenRouter key. Ending a session with nowhere to go would
  be worse than leaving it alone.
- The turn that failed is not retried. Re-send that prompt after the switch.
- If anything is missing — plugin, key, launcher — you land in the ordinary
  manual flow above, not in a broken state.

## If it doesn't work

`ccd doctor` reports the cause by HTTP status code.

- **401/403** — the OpenRouter key is wrong or expired
- **402** — insufficient OpenRouter balance; top up
- **400/404** — auth passed; the model slug is the problem. Check the current
  slug at openrouter.ai/models and fix `openrouter.env`
- **400 mentioning `context_management` / `Extra inputs are not permitted`** —
  `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` is missing
- **Context-overflow errors phrased by the gateway** — auto-compact isn't
  triggering. Run `/compact` manually

## Constraints to know

- Anthropic does **not officially support** routing Claude Code to non-Claude
  models. Not an account-sanction issue — it means breakage is unsupported and a
  Claude Code update may stop it working overnight. Hence `ccd doctor`.
- On an external backbone, **Remote Control, voice input, and fast mode are disabled**.
- Never put these variables in the `env` block of `~/.claude/settings.json`.
  There they override shell exports and pin **every session permanently** —
  including background agents — to the external backbone. This is why `ccd`
  uses the shell approach.

## This is an "unsupported path" — by both sides

Both parties have drawn the line explicitly. Not forbidden — just **not guaranteed**.

- Anthropic: routing Claude Code to non-Claude models is unsupported.
- OpenRouter: their own Claude Code docs state "Claude Code is optimized for
  Anthropic models and may not work correctly with other providers." All their
  examples use `~anthropic/` slugs.

In practice it works through the `ANTHROPIC_DEFAULT_*_MODEL` slots, but a Claude
Code update could break it any day. So always run `ccd doctor` before relying on it.

One known unresolved issue: Claude Code sends the `thinking` field on some
requests and omits it on others (subagent creation, structured output), which can
clash with provider expectations and produce 400s. Filed as Anthropic issue
#69379 and **closed as "not planned."** No environment variable fixes it. If
subagent-heavy work keeps producing 400s, suspect this.

## When a flat-rate plan beats ccd

`ccd` is **pay-as-you-go**. If you must ride out several days until quota
recovers, a flat-rate coding plan can win on total cost. All of the below offer
their own **first-party Anthropic-compatible endpoints**, so they are better
supported than the OpenRouter path.

| Provider | Monthly | Notes |
| --- | --- | --- |
| Z.ai GLM Coding Plan | $18~ (Lite) | Confirmed in official docs. Higher-tier USD unverified |
| Moonshot Kimi Code | $19 / $39 / $99 / $199 | `api.moonshot.ai/anthropic` |
| MiniMax | $20 / $50 / $120 | `api.minimax.io/anthropic` |

The quality cost is measurable: GLM scores 58.7% on Terminal-Bench in the Claude
Code harness, clearly below Sonnet 5's 74.6%.

**Check what you already pay for first.** With a ChatGPT Plus subscription,
gpt-5.6-luna is available flat-rate in the Codex CLI. You lose the Claude Code
harness, but the marginal cost is zero — and Luna's benchmark scores were
measured in Codex anyway, so the harness fit is right.

Also: Anthropic Sonnet 5's introductory pricing of $2/$10 (per 1M) runs through
2026-08-31. Within that window, **topping up Anthropic credits** may be the
simplest answer with zero breakage risk.

## Alternatives to swapping the backbone

Code exploration/implementation can be handed wholesale to the already-installed
Codex (GPT subscription); the `quota-guard` hook recommends that mode
automatically above 85%. But Claude still has to orchestrate, so **once quota is
fully at zero that path is closed.** That is when you use `ccd`.
