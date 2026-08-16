---
name: doctor
description: Diagnose the ccd escape route in-session — key, API reachability, model slugs, wiring. Use for /ccd:doctor, "ccd 진단" / "ccd 되는지 확인" (is ccd working?), "check the escape route", or after any ccd-related failure.
---

# ccd doctor — in-session diagnosis

Run everything yourself and report tersely; never send the user to a terminal.

## Procedure

1. Run the core check and relay its one-line verdict:

   ```sh
   ~/.local/bin/ccd doctor
   ```

2. If it printed `✓ OK`, also confirm the wiring in one shot and report at most
   4 short ✓ lines (key: configured/empty · doctor: ✓ OK · statusline: wired ·
   plugin: v<installed> latest / v<latest> available):

   ```sh
   grep -c '^OPENROUTER_API_KEY="..*"' ~/.claude/ccd/providers/keys.env 2>/dev/null  # 1 = key set (never cat this file)
   grep -o 'statusline-launcher' ~/.claude/settings.json | head -1
   installed=$(ls -d ~/.claude/plugins/cache/*/ccd/* 2>/dev/null | sort -V | tail -1); installed=${installed##*/}
   latest=$(curl -fsS --max-time 5 https://raw.githubusercontent.com/sbigstar0310/cc-donut/main/.claude-plugin/plugin.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null)
   echo "installed=$installed latest=${latest:-unknown}"
   ```

   If `latest` is newer than `installed`, report it as
   `⬆ v<latest> available — run /ccd:update`; if the fetch failed (offline),
   say the version check was skipped, never guess.

3. `ccd doctor` also prints a **Spare Claude accounts** block. Report it in one
   line, and treat two cases as findings rather than status:
   - any account marked `needs re-login` → surface it even if everything else is
     `✓ OK`. That spare cannot receive a handoff, and nothing else in the system
     will reveal it until the handoff itself fails. Offer the fix: `claude` →
     `/login` as that account → `ccd account add --force --name <name>`.
   - a `✗` on store permissions → the file holds a refresh token good for days.
     Offer to run the `chmod` it names.

   If no accounts are registered, mention once that a second Claude subscription
   would be used before OpenRouter, and drop it if they have only one.

4. On failure, map the code to the fix and offer to do it now:
   - 401/403 → key invalid/expired → offer the `key` skill paths (paste in
     chat with consent, or native dialog/terminal)
   - 402 → OpenRouter balance empty → link openrouter.ai/credits
   - 400/404 → model slug stale → show the failing slug, check
     openrouter.ai/models, offer to fix the catalog after approval
   - network → retry once, then report
5. If the user asks about a specific model/slot, run `~/.local/bin/ccd doctor <key>`
   for that slot (e.g. `flash`, `terra`).

Never print the key file's contents; only ever state whether the key is set.
