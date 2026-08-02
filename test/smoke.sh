#!/usr/bin/env bash
# Portable smoke test — runs the real scripts against a throwaway HOME.
# Intended to run on both macOS and Linux (see test/docker.sh for the Linux run).
# No network, no real key, no writes outside $HOME.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
export HOME="$FAKE"
# The suite must behave identically when launched from inside a ccd session:
# CCD_ACTIVE would suppress quota-guard warnings and flip the statusline branch.
unset CCD_ACTIVE ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL \
      ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL \
      ANTHROPIC_CUSTOM_MODEL_OPTION ANTHROPIC_CUSTOM_MODEL_OPTION_NAME \
      CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL \
      CLAUDE_CODE_AUTO_COMPACT_WINDOW 2>/dev/null || true
pass=0 fail=0

ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
head_() { printf '\n%s\n' "$1"; }

# A fake `node` so we don't need a real one: it prints the JSON we stage.
mkdir -p "$FAKE/fakebin"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
cat "$HOME/.stub-usage.json"
EOF
chmod +x "$FAKE/fakebin/node"
export PATH="$FAKE/fakebin:$PATH"
stub_usage() { # $1=5h $2=7d
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"fiveHourReset":"R1","sevenDayPercent":%s,"sevenDayReset":"D1"}}\n' "$1" "$2" > "$FAKE/.stub-usage.json"
}
DASH="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
mkdir -p "$DASH"; : > "$DASH/check-usage.js"

head_ "1. file_age() — the Linux stat regression"
# shellcheck disable=SC1090
eval "$(sed -n '/^file_age()/,/^}/p' "$ROOT/scripts/quota-guard.sh")"
probe="$FAKE/probe"; : > "$probe"
python3 - "$probe" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time()-3600, time.time()-3600))
PY
age=$(file_age "$probe")
case "$age" in
  ''|*[!0-9]*) bad "file_age returns an integer" "got: '$age'" ;;
  *) [ "$age" -ge 3500 ] && [ "$age" -le 3700 ] \
       && ok "file_age ≈ 3600s for a 1h-old file (got $age)" \
       || bad "file_age plausible" "got $age" ;;
esac
[ "$(file_age "$FAKE/does-not-exist")" = "999999" ] && ok "missing file → 999999" || bad "missing file → 999999"

head_ "2. quota cache refreshes when stale"
mkdir -p "$FAKE/.claude/ccd"
stub_usage 58 96
echo '{}' > "$FAKE/.claude/ccd/quota-cache.json"
python3 - "$FAKE/.claude/ccd/quota-cache.json" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))
PY
"$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
got=$(python3 -c "import json;print((json.load(open('$FAKE/.claude/ccd/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "96" ] && ok "stale cache refreshed (7d=96)" || bad "stale cache refreshed" "got: $got"

head_ "3. 95%+ emits the ccd escape guidance"
rm -f "$FAKE/.claude/ccd/last-warn"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit 2>/dev/null)
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "★QUOTA NEARLY EXHAUSTED★ injected at 96%" ;;
  *) bad "escape guidance at 96%" "got: ${out:0:120}" ;;
esac
case "$out" in *"ccd -c"*) ok "escape command present" ;; *) bad "escape command present" ;; esac

head_ "4. 10-minute warn throttle"
out2=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit 2>/dev/null)
[ -z "$out2" ] && ok "second warning suppressed within TTL" || bad "throttle" "re-warned: ${out2:0:80}"

head_ "5. concurrent hooks don't corrupt the cache"
python3 - "$FAKE/.claude/ccd/quota-cache.json" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time()-7200, time.time()-7200))
PY
for _ in 1 2 3 4 5 6; do "$ROOT/scripts/quota-guard.sh" PostToolUse >/dev/null 2>&1 & done; wait
python3 -c "import json;json.load(open('$FAKE/.claude/ccd/quota-cache.json'))" 2>/dev/null \
  && ok "cache still valid JSON after 6 concurrent runs" || bad "cache valid after concurrency"
[ -z "$(ls "$FAKE/.claude/ccd"/quota-cache.json.tmp* 2>/dev/null)" ] && ok "no leftover tmp files" || bad "no leftover tmp files"

head_ "6. ccd setup / statusline / uninstall"
"$ROOT/bin/ccd" setup >/dev/null 2>&1
[ -x "$FAKE/.local/bin/ccd" ] && ok "launcher installed" || bad "launcher installed"
grep -qF 'bash ~/.claude/ccd/statusline-launcher.sh' "$FAKE/.claude/settings.json" 2>/dev/null && ok "statusLine wired to the ccd path" || bad "statusLine wired"
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *ccd*luna*) ok "ccd statusline row renders" ;; *) bad "statusline row" "got: ${row:0:80}" ;; esac
warn=$(printf '%s' '{"model":{"id":"claude-fable-5"}}' | "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$warn" in *"quota 96%"*) ok "subscription-mode quota warning renders" ;; *) bad "quota warning row" "got: ${warn:0:80}" ;; esac
"$ROOT/bin/ccd" setup >/dev/null 2>&1 && ok "setup is idempotent" || bad "setup idempotent"
"$ROOT/bin/ccd" uninstall --purge >/dev/null 2>&1
[ -d "$FAKE/.claude/ccd" ] && bad "purge removes state" || ok "uninstall --purge removes state"

head_ "7. key handling (piped path, no network dependency)"
"$ROOT/bin/ccd" >/dev/null 2>&1
printf 'sk-or-v1-smoketest\n' | "$ROOT/bin/ccd" key >/dev/null 2>&1
grep -q 'sk-or-v1-smoketest' "$FAKE/.claude/ccd/providers/keys.env" && ok "piped key stored" || bad "piped key stored"
perm=$(stat -c %a "$FAKE/.claude/ccd/providers/keys.env" 2>/dev/null || stat -f %Lp "$FAKE/.claude/ccd/providers/keys.env" 2>/dev/null)
[ "$perm" = "600" ] && ok "keys.env is 600" || bad "keys.env is 600" "got: $perm"
# capture first: `| grep -q` closes the pipe early and pipefail would report SIGPIPE
status=$(OPENROUTER_API_KEY=sk-or-v1-fromenv "$ROOT/bin/ccd" 2>/dev/null)
case "$status" in *configured*) ok "env var override accepted" ;; *) bad "env var override" ;; esac

head_ "8. opus slot is Kimi K3; [1m] hint for verified >200K pools + dynamic window"
# A fake `claude` that prints the environment ccd assembled for it.
cat > "$FAKE/fakebin/claude" <<'EOF'
#!/bin/sh
env | grep -E '^(ANTHROPIC_(DEFAULT_(HAIKU|SONNET|OPUS|FABLE)_MODEL|MODEL|CUSTOM_MODEL_OPTION)|CLAUDE_CODE_AUTO_COMPACT_WINDOW)=' | sort
EOF
chmod +x "$FAKE/fakebin/claude"
# A fake `curl` from here on: ccd's launch-time prefetch must not race the seeded
# caches with live network data. Append mode keeps every call's args for later checks.
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
echo 200
EOF
chmod +x "$FAKE/fakebin/curl"
# Seed provider data with the REAL shapes: kimi pool min 912K (>200K but <1M — the
# whole point of the dynamic rule), luna exactly 200K (no hint), flash 1M (fresh).
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
now = int(time.time())
json.dump({"models": {
    "moonshotai/kimi-k3":       {"min_context_length": 912384,  "max_context_length": 1048576, "fetched_at": now},
    "openai/gpt-5.6-luna":      {"min_context_length": 200000,  "max_context_length": 200000,  "fetched_at": now},
    "deepseek/deepseek-v4-flash": {"min_context_length": 1048576, "max_context_length": 1048576, "fetched_at": now},
}}, open(sys.argv[1], "w"))
PY
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_DEFAULT_OPUS_MODEL=moonshotai/kimi-k3:floor[1m]' \
  && ok "opus = kimi-k3:floor[1m] (verified 912K pool > 200K)" || bad "opus kimi + [1m]" "got: $(printf '%s\n' "$envout" | grep OPUS)"
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_DEFAULT_SONNET_MODEL=openai/gpt-5.6-luna:floor' \
  && ok "sonnet 200K → no [1m]" || bad "sonnet without [1m]" "got: $(printf '%s\n' "$envout" | grep SONNET)"
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek/deepseek-v4-flash:floor' \
  && ok "haiku chore slot → never hinted (keeps safe 200K)" || bad "haiku unhinted" "got: $(printf '%s\n' "$envout" | grep HAIKU)"
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_CUSTOM_MODEL_OPTION=deepseek/deepseek-v4-flash:floor' \
  && ok "cheapest-picker option → also unhinted" || bad "custom option unhinted" "got: $(printf '%s\n' "$envout" | grep CUSTOM_MODEL_OPTION=)"
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_DEFAULT_FABLE_MODEL=moonshotai/kimi-k3:floor[1m]' \
  && ok "fable inherits opus + [1m]" || bad "fable inherits opus" "got: $(printf '%s\n' "$envout" | grep FABLE)"
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_MODEL=openai/gpt-5.6-luna:floor' \
  && ok "ANTHROPIC_MODEL follows sonnet (no [1m])" || bad "ANTHROPIC_MODEL" "got: $(printf '%s\n' "$envout" | grep -w ANTHROPIC_MODEL)"
# Effective window = smallest hinted pool (kimi 912384) × 0.92 = 839393, NOT a fake 1M.
printf '%s\n' "$envout" | grep -qFx 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=839393' \
  && ok "auto-compact window = 839393 (smallest hinted pool − headroom)" \
  || bad "dynamic auto-compact window" "got: $(printf '%s\n' "$envout" | grep AUTO_COMPACT)"

head_ "9. [1m] safety: missing/malformed/stale/future cache → 200K (no hint)"
# The launch-path sync prefetch fires here — the stub's "200" is not JSON, so the
# cache stays unusable and the safe 200K default must win.
rm -f "$FAKE/.claude/ccd/price-cache.json"
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_DEFAULT_OPUS_MODEL=moonshotai/kimi-k3:floor' \
  && ok "missing cache → no [1m]" || bad "missing cache → no [1m]" "got: $(printf '%s\n' "$envout" | grep OPUS)"
printf '%s\n' "$envout" | grep -qFx 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000' \
  && ok "nothing verified → static 1000000 fallback kept" \
  || bad "static window fallback" "got: $(printf '%s\n' "$envout" | grep AUTO_COMPACT)"
echo 'not json' > "$FAKE/.claude/ccd/price-cache.json"
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'[1m]'*) bad "malformed cache → no [1m]" "hint leaked" ;; *) ok "malformed cache → no [1m]" ;; esac
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys
json.dump({"models": {"moonshotai/kimi-k3": {"min_context_length": 912384, "fetched_at": 1}}}, open(sys.argv[1], "w"))
PY
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'[1m]'*) bad "stale cache → no [1m]" "hint leaked" ;; *) ok "stale positive cache → no [1m]" ;; esac
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
json.dump({"models": {"moonshotai/kimi-k3": {"min_context_length": 912384, "fetched_at": int(time.time()) + 999999}}}, open(sys.argv[1], "w"))
PY
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'[1m]'*) bad "future-dated cache → no [1m]" "hint leaked" ;; *) ok "future-dated (poisoned) cache → no [1m]" ;; esac
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys
json.dump({"models": {"moonshotai/kimi-k3": {"min_context_length": 912384, "fetched_at": float("nan")}}}, open(sys.argv[1], "w"))
PY
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'[1m]'*) bad "NaN cache timestamp → no [1m]" "hint leaked" ;; *) ok "NaN cache timestamp → no [1m]" ;; esac
# Idempotence: an already-hinted value must not gain a second suffix.
PRICE_CACHE="$FAKE/.claude/ccd/price-cache.json"
eval "$(sed -n '/^with_context_hint()/,/^}/p' "$ROOT/bin/ccd")"
[ "$(with_context_hint 'moonshotai/kimi-k3:floor[1m]')" = 'moonshotai/kimi-k3:floor[1m]' ] \
  && ok "already-hinted input stays single-[1m]" || bad "idempotent [1m]"

head_ "10. price-fetch: pool verification, writer races, suffix normalization"
# Slug-dependent stub: luna's pool is the SMALLER one (800K), so the launch tests
# prove the global window takes the minimum over BOTH hinted conversation slots —
# a regression that ignored sonnet would compute kimi's 874000 instead of 736000.
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
case "$*" in
  *gpt-5.6-luna*) ctx=800000 ;;
  *)              ctx=950000 ;;
esac
cat <<JSON
{"data":{"endpoints":[
 {"tag":"cheap","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":$ctx},
 {"tag":"dear","pricing":{"prompt":"0.000002","completion":"0.000003"},"context_length":$ctx}
]}}
JSON
EOF
chmod +x "$FAKE/fakebin/curl"
rm -f "$FAKE/.claude/ccd/price-cache.json"
# This is also the launch-path test: an empty cache must be synchronously populated
# before apply_tiers, so the very first invocation receives the verified hint.
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_DEFAULT_OPUS_MODEL=moonshotai/kimi-k3:floor[1m]' \
  && ok "first launch prefetches before apply_tiers → [1m]" \
  || bad "first-launch synchronous prefetch" "got: $(printf '%s\n' "$envout" | grep OPUS)"
printf '%s\n' "$envout" | grep -qFx 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=736000' \
  && ok "window = min over BOTH hinted slots (luna 800K → 736000)" \
  || bad "two-hinted-slot window" "got: $(printf '%s\n' "$envout" | grep AUTO_COMPACT)"
rm -f "$FAKE/.claude/ccd/price-cache.json"
# Fixed-pool stub for the aggregation checks: two default-pool providers WITH
# context plus a tier-tagged (flex) endpoint that must be excluded.
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
cat <<'JSON'
{"data":{"endpoints":[
 {"tag":"cheap","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":1000000},
 {"tag":"dear","pricing":{"prompt":"0.000002","completion":"0.000003"},"context_length":800000},
 {"tag":"acme/flex","pricing":{"prompt":"0.0000005","completion":"0.000001"},"context_length":50000}
]}}
JSON
EOF
chmod +x "$FAKE/fakebin/curl"
"$ROOT/bin/ccd-price-fetch" "ok/model" >/dev/null 2>&1
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY' \
  && ok "pool min/max recorded; tier-tagged (flex) endpoint excluded" \
  || bad "pool context aggregation"
import json, sys
e = json.load(open(sys.argv[1]))["models"]["ok/model"]
assert e["min_context_length"] == 800000, e       # 50K flex endpoint must not drag the min down
assert e["max_context_length"] == 1000000, e
PY
# One default-pool endpoint WITHOUT context_length → the pool is UNVERIFIED:
# recording only the known endpoints would overstate the safe budget (Codex P1).
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
cat <<'JSON'
{"data":{"endpoints":[
 {"tag":"cheap","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":1000000},
 {"tag":"mystery","pricing":{"prompt":"0.000002","completion":"0.000003"}}
]}}
JSON
EOF
chmod +x "$FAKE/fakebin/curl"
"$ROOT/bin/ccd-price-fetch" "unk/model" >/dev/null 2>&1
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY' \
  && ok "endpoint missing context_length → pool unverified (min recorded as null)" \
  || bad "unknown context must not verify"
import json, sys
e = json.load(open(sys.argv[1]))["models"]["unk/model"]
assert "min_context_length" in e and e["min_context_length"] is None, e
assert "floor_in_per_m" in e, e   # prices still cached
PY
[ "$(with_context_hint 'unk/model:floor')" = 'unk/model:floor' ] \
  && ok "unverified pool → no [1m] from with_context_hint" || bad "unverified pool hint"
# Compound input tolerance: slug:routing[1m] must query the BARE slug's URL.
rm -f "$FAKE/.curl-args"
"$ROOT/bin/ccd-price-fetch" "ok/model:floor[1m]" >/dev/null 2>&1
grep -qF '/models/ok/model/endpoints' "$FAKE/.curl-args" \
  && ok "price-fetch strips :floor[1m] before the request" \
  || bad "price-fetch suffix normalization" "got: $(tail -1 "$FAKE/.curl-args")"
# Writer race: launch starts one writer per slot. 4 concurrent writers on an empty
# cache must ALL land (lockfile + merge), with the file left as valid JSON.
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"data":{"endpoints":[{"tag":"p","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":1000000}]}}
JSON
EOF
chmod +x "$FAKE/fakebin/curl"
rm -f "$FAKE/.claude/ccd/price-cache.json"
for s in race/m1 race/m2 race/m3 race/m4; do "$ROOT/bin/ccd-price-fetch" "$s" >/dev/null 2>&1 & done; wait
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY' \
  && ok "4 concurrent writers → all 4 entries survive" \
  || bad "concurrent writers lose entries"
import json, sys
m = json.load(open(sys.argv[1]))["models"]
missing = [s for s in ("race/m1", "race/m2", "race/m3", "race/m4") if s not in m]
assert not missing, f"lost: {missing}"
PY
# Restore the invalid-response stub for the remaining sections.
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
echo 200
EOF
chmod +x "$FAKE/fakebin/curl"

head_ "11. statusline shows the effective context window"
row=$(printf '%s' '{"model":{"id":"moonshotai/kimi-k3:floor[1m]"}}' | CLAUDE_CODE_AUTO_COMPACT_WINDOW=839393 CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *'kimi-k3:floor'*'· 839K'*) ok "effective window (839K) shown from CLAUDE_CODE_AUTO_COMPACT_WINDOW" ;; *) bad "statusline effective window" "got: ${row:0:100}" ;; esac
case "$row" in *'[1m]'*) bad "raw [1m] leaks into display" "got: ${row:0:100}" ;; *) ok "no raw [1m] in display" ;; esac
row=$(printf '%s' '{"model":{"id":"moonshotai/kimi-k3:floor[1m]"}}' | env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *'· 1M'*) ok "1M shown when the hint stands without a dynamic window" ;; *) bad "statusline 1M fallback" "got: ${row:0:100}" ;; esac
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *'· 200K'*) ok "200K shown without the hint" ;; *) bad "statusline 200K" "got: ${row:0:100}" ;; esac

head_ "12. doctor never sends [1m] to the provider"
rm -f "$FAKE/.curl-args"   # assert on doctor's calls only
# Restore a fresh 1M-positive cache so apply_tiers wires the hint.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
now = int(time.time())
json.dump({"models": {"openai/gpt-5.6-luna": {"min_context_length": 1000000, "fetched_at": now}}}, open(sys.argv[1], "w"))
PY
OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" doctor >/dev/null 2>&1
if grep -qF '[1m]' "$FAKE/.curl-args" 2>/dev/null; then
  bad "doctor strips [1m] before the probe" "got: $(grep -F '[1m]' "$FAKE/.curl-args" | head -1)"
else
  ok "doctor probe carries no [1m]"
fi
grep -qF '"model":"openai/gpt-5.6-luna:floor"' "$FAKE/.curl-args" 2>/dev/null \
  && ok "doctor probes slug:floor" || bad "doctor probe model" "got: $(grep -F '"model"' "$FAKE/.curl-args" | head -1)"
rm -f "$FAKE/fakebin/curl"

head_ "13. rename surface: manifests, README coords, launcher resolution, uninstall text"
python3 - "$ROOT" <<'PY' \
  && ok "manifests are ccd / cc-donut / 0.2.0" || bad "manifest identity"
import json, sys
root = sys.argv[1]
p = json.load(open(f"{root}/.claude-plugin/plugin.json"))
m = json.load(open(f"{root}/.claude-plugin/marketplace.json"))
assert p["name"] == "ccd" and p["version"] == "0.2.0", p
assert m["name"] == "cc-donut" and m["version"] == "0.2.0", m
assert m["plugins"][0]["name"] == "ccd" and m["plugins"][0]["version"] == "0.2.0", m
PY
grep -qF 'claude plugin marketplace add sbigstar0310/cc-donut' "$ROOT/README.md" \
  && ok "README marketplace coordinate" || bad "README marketplace coordinate"
grep -qF 'claude plugin install ccd@cc-donut' "$ROOT/README.md" \
  && ok "README plugin coordinate" || bad "README plugin coordinate"
# The generated launcher must resolve the ccd plugin cache and exec the newest bin/ccd.
"$ROOT/bin/ccd" setup >/dev/null 2>&1
mkdir -p "$FAKE/.claude/plugins/cache/cc-donut/ccd/0.2.0/bin"
cat > "$FAKE/.claude/plugins/cache/cc-donut/ccd/0.2.0/bin/ccd" <<'EOF'
#!/bin/sh
echo LAUNCHED-BY-LAUNCHER
EOF
chmod +x "$FAKE/.claude/plugins/cache/cc-donut/ccd/0.2.0/bin/ccd"
[ "$("$FAKE/.local/bin/ccd" 2>/dev/null)" = "LAUNCHED-BY-LAUNCHER" ] \
  && ok "generated launcher resolves + execs the ccd plugin cache" \
  || bad "launcher resolution" "got: $("$FAKE/.local/bin/ccd" 2>&1 | head -1)"
out=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" uninstall --purge 2>&1)
case "$out" in
  *'ccd@cc-donut'*'cc-donut'*) ok "uninstall prints ccd@cc-donut removal commands" ;;
  *) bad "uninstall command text" "got: ${out:0:120}" ;;
esac

printf '\n──────────\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
