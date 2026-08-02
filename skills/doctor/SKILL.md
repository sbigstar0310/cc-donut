---
name: doctor
description: Diagnose the ccx escape route in-session — key, API reachability, model slugs, wiring. Use for /ccx:doctor, "ccx 진단" / "ccx 되는지 확인" (is ccx working?), "check the escape route", or after any ccx-related failure.
---

# ccx doctor — in-session diagnosis

Run everything yourself and report tersely; never send the user to a terminal.

## Procedure

1. Run the core check and relay its one-line verdict:

   ```sh
   ~/.local/bin/ccx doctor
   ```

2. If it printed `✓ OK`, also confirm the wiring in one shot and report at most
   4 short ✓ lines (key: configured/empty · doctor: ✓ OK · statusline: wired ·
   plugin: v<installed> latest / v<latest> available):

   ```sh
   grep -c '^OPENROUTER_API_KEY="..*"' ~/.claude/ccx/providers/keys.env 2>/dev/null  # 1 = key set (never cat this file)
   grep -o 'statusline-launcher' ~/.claude/settings.json | head -1
   installed=$(ls -d ~/.claude/plugins/cache/*/ccx/* 2>/dev/null | sort -V | tail -1); installed=${installed##*/}
   latest=$(curl -fsS --max-time 5 https://raw.githubusercontent.com/sbigstar0310/ccx/main/.claude-plugin/plugin.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null)
   echo "installed=$installed latest=${latest:-unknown}"
   ```

   If `latest` is newer than `installed`, report it as
   `⬆ v<latest> available — run /ccx:update`; if the fetch failed (offline),
   say the version check was skipped, never guess.

3. On failure, map the code to the fix and offer to do it now:
   - 401/403 → key invalid/expired → offer the `key` skill paths (paste in
     chat with consent, or native dialog/terminal)
   - 402 → OpenRouter balance empty → link openrouter.ai/credits
   - 400/404 → model slug stale → show the failing slug, check
     openrouter.ai/models, offer to fix the catalog after approval
   - network → retry once, then report
4. If the user asks about a specific model/slot, run `~/.local/bin/ccx doctor <key>`
   for that slot (e.g. `flash`, `terra`).

Never print the key file's contents; only ever state whether the key is set.
