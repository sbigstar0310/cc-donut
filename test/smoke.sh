#!/usr/bin/env bash
# Portable smoke test — runs the real scripts against a throwaway HOME.
# Intended to run on both macOS and Linux (see test/docker.sh for the Linux run).
# No network, no real key, no writes outside $HOME.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE" 2>/dev/null || true' EXIT
export HOME="$FAKE"
# The suite must behave identically when launched from inside a ccd session:
# CCD_ACTIVE would suppress quota-guard warnings and flip the statusline branch.
unset CCD_ACTIVE ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL \
      ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL \
      ANTHROPIC_CUSTOM_MODEL_OPTION ANTHROPIC_CUSTOM_MODEL_OPTION_NAME \
      CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL \
      CLAUDE_CODE_AUTO_COMPACT_WINDOW 2>/dev/null || true

# The handoff tests exercise code whose whole job is to SIGHUP a claude process.
# Run from inside a real Claude Code session — which is exactly how a developer
# runs this suite — an unset or stale CLAUDE_PID lets the ancestor walk find the
# SESSION RUNNING THE TESTS and kill it. Sever the link to any real session:
# the tests always pass an explicit CLAUDE_PID for their own stand-in process.
unset CLAUDE_PID CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

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
echo "ARGS:$*"
env | grep -E '^(ANTHROPIC_(DEFAULT_(HAIKU|SONNET|OPUS|FABLE)_MODEL|MODEL|CUSTOM_MODEL_OPTION)|CLAUDE_CODE_(SUBAGENT_MODEL|AUTO_COMPACT_WINDOW))=' | sort
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
# Use routing-aware cache keys (:floor suffix).
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
now = int(time.time())
json.dump({"models": {
    "moonshotai/kimi-k3:floor":       {"min_context_length": 912384,  "max_context_length": 1048576, "floor_in_per_m": 2.9, "floor_out_per_m": 14.0, "max_in_per_m": 3.0, "max_out_per_m": 15.0, "fetched_at": now},
    "openai/gpt-5.6-luna:floor":      {"min_context_length": 200000,  "max_context_length": 200000,  "floor_in_per_m": 0.1, "floor_out_per_m": 0.6, "max_in_per_m": 1.0, "max_out_per_m": 6.0, "fetched_at": now},
    "deepseek/deepseek-v4-flash:floor": {"min_context_length": 1048576, "max_context_length": 1048576, "floor_in_per_m": 0.11, "floor_out_per_m": 0.22, "max_in_per_m": 0.14, "max_out_per_m": 0.28, "fetched_at": now},
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
# The round trip's ccd half: -c must reach claude as --continue.
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -c -p hi 2>/dev/null)
printf '%s\n' "$envout" | grep -qF 'ARGS:-c -p hi' \
  && ok "ccd -c forwards --continue to claude (resume path)" \
  || bad "-c forwarding" "got: $(printf '%s\n' "$envout" | head -1)"
# A non-interactive `ccd -c` must refuse before banner/prefetch. This is the real
# headless path (the suite itself has no TTY), not the explicit -p exception above.
rm -f "$FAKE/.curl-args"
headless_out=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -c 2>&1 || true)
case "$headless_out" in *'Exit Claude Code first.'*) ok "headless ccd -c refuses before launch" ;; *) bad "headless refusal" "got: ${headless_out:0:120}" ;; esac
if [ -f "$FAKE/.curl-args" ] && grep -q 'models/.*/endpoints' "$FAKE/.curl-args"; then
  bad "headless refusal skips endpoint fetch" "endpoint calls: $(grep -c endpoints "$FAKE/.curl-args")"
else
  ok "headless refusal skips endpoint fetch"
fi
# Launch UX: the banner must be the FIRST output line (instant feedback before any
# network work). A fresh selected-slot cache is never part of the synchronous
# fetch; only the allowed detached catalog warmers may add endpoint calls.
printf '%s\n' "$envout" | head -1 | grep -qF 'Switching backbone: OpenRouter' \
  && ok "banner prints first (no silent network wait)" \
  || bad "banner ordering" "first line: $(printf '%s\n' "$envout" | head -1)"
rm -f "$FAKE/.curl-args"
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'refreshing provider data'*) bad "fresh selected slots avoid synchronous refresh" ;; *) ok "fresh selected slots avoid synchronous refresh" ;; esac
case "$envout" in *'warming 3 catalog candidates in background'*) ok "stale Pareto candidates warm after launch feedback" ;; *) bad "catalog background warm notice" "got: ${envout:0:180}" ;; esac
# The detached catalog warm set is intentionally allowed to fetch extra metadata;
# selected slots remain the only synchronous launch gate.

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
json.dump({"models": {"moonshotai/kimi-k3:floor": {"min_context_length": 912384, "fetched_at": 1}}}, open(sys.argv[1], "w"))
PY
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'[1m]'*) bad "stale cache → no [1m]" "hint leaked" ;; *) ok "stale positive cache → no [1m]" ;; esac
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
json.dump({"models": {"moonshotai/kimi-k3:floor": {"min_context_length": 912384, "fetched_at": int(time.time()) + 999999}}}, open(sys.argv[1], "w"))
PY
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'[1m]'*) bad "future-dated cache → no [1m]" "hint leaked" ;; *) ok "future-dated (poisoned) cache → no [1m]" ;; esac
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys
json.dump({"models": {"moonshotai/kimi-k3:floor": {"min_context_length": 912384, "fetched_at": float("nan")}}}, open(sys.argv[1], "w"))
PY
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$envout" in *'[1m]'*) bad "NaN cache timestamp → no [1m]" "hint leaked" ;; *) ok "NaN cache timestamp → no [1m]" ;; esac
# Idempotence: an already-hinted value must not gain a second suffix.
PRICE_CACHE="$FAKE/.claude/ccd/price-cache.json"
eval "$(sed -n '/^cache_key_for()/,/^}/p' "$ROOT/bin/ccd")"
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
# The stale-cache success path also prints progress before its synchronous fetch.
# Avoid timing assertions: ordered output + verified wiring make this portable in CI.
rm -f "$FAKE/.claude/ccd/price-cache.json" "$FAKE/.curl-args"
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
first_two=$(printf '%s\n' "$envout" | head -2)
printf '%s\n' "$first_two" | head -1 | grep -qF 'Switching backbone: OpenRouter' \
  && ok "stale launch banner prints before refresh" \
  || bad "stale banner ordering" "got: $first_two"
printf '%s\n' "$first_two" | tail -1 | grep -qF 'refreshing provider data' \
  && ok "stale launch shows refresh progress" \
  || bad "stale refresh progress" "got: $first_two"
endpoint_calls=$(grep -c 'models/.*/endpoints' "$FAKE/.curl-args" 2>/dev/null || true)
[ "$endpoint_calls" -ge 3 ] && ok "stale launch refreshes three selected slot endpoints" \
  || bad "stale selected-slot refresh count" "got: $endpoint_calls"
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_DEFAULT_OPUS_MODEL=moonshotai/kimi-k3:floor[1m]' \
  && ok "stale refresh applies verified [1m] before launch" \
  || bad "stale refresh wiring" "got: $(printf '%s\n' "$envout" | grep OPUS)"
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
# A fresh provider-pool entry lets native /model receive an exact manual [1m]
# command only when the inherited process-wide compact window is conservative.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
now = time.time()
json.dump({"models": {"openai/gpt-5.6-terra:floor": {"min_context_length": 1000000, "max_context_length": 1000000, "floor_in_per_m": 1.0, "floor_out_per_m": 6.0, "max_in_per_m": 2.5, "max_out_per_m": 15.0, "fetched_at": now}}}, open(sys.argv[1], "w"))
PY
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-terra:floor"}}' | CLAUDE_CODE_AUTO_COMPACT_WINDOW=800000 CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *'/model openai/gpt-5.6-terra:floor[1m]'*) ok "safe native switch recommends exact [1m] command" ;; *) bad "safe native [1m] guidance" "got: ${row:0:180}" ;; esac
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-terra:floor"}}' | CLAUDE_CODE_AUTO_COMPACT_WINDOW=990000 CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *'ccd -c --model openai/gpt-5.6-terra'*) ok "oversized window recommends restart, not [1m]" ;; *) bad "restart guidance" "got: ${row:0:180}" ;; esac
row=$(printf '%s' '{"model":{"id":"new/provider:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *'checking provider context'*) ok "unknown native model shows non-blocking context check" ;; *) bad "pending context guidance" "got: ${row:0:180}" ;; esac
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-terra:floor[1m]"}}' | CLAUDE_CODE_AUTO_COMPACT_WINDOW=800000 CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *'/model '*|*'ccd -c --model'*) bad "already-hinted model repeats guidance" "got: ${row:0:180}" ;; *) ok "already-hinted model suppresses duplicate guidance" ;; esac
# :free and :floor are separate cache entries. The reported bug was :free showing
# the paid pool's price, so assert both render from their OWN entry.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
now = time.time()
json.dump({"models": {
    "nv/model:free":  {"floor_in_per_m": 0.0, "floor_out_per_m": 0.0, "max_in_per_m": 0.0, "max_out_per_m": 0.0, "min_context_length": 500000, "max_context_length": 500000, "fetched_at": now},
    "nv/model:floor": {"floor_in_per_m": 0.6, "floor_out_per_m": 3.6, "max_in_per_m": 0.6, "max_out_per_m": 3.6, "min_context_length": 500000, "max_context_length": 500000, "fetched_at": now},
}}, open(sys.argv[1], "w"))
PY
row=$(printf '%s' '{"model":{"id":"nv/model:free"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in
  *'in $0/M · out $0/M'*) ok ":free renders \$0 from its own cache entry" ;;
  *) bad ":free pricing" "got: ${row:0:160}" ;;
esac
row=$(printf '%s' '{"model":{"id":"nv/model:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in
  *'in $0.60/M · out $3.60/M'*) ok ":floor keeps the paid pool price (no \$0 bleed)" ;;
  *) bad ":floor pricing" "got: ${row:0:160}" ;;
esac
# A stale/missing :free entry must request the ROUTING-AWARE key, not the bare slug —
# otherwise the background refresh writes an entry the statusline never reads and
# the row stays "pricing…" forever. Assert on the argv the fetcher receives.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys
json.dump({"models": {}}, open(sys.argv[1], "w"))
PY
SLBIN="$FAKE/slbin"; mkdir -p "$SLBIN"
cp "$ROOT/bin/ccd-statusline" "$SLBIN/ccd-statusline"
cat > "$SLBIN/ccd-price-fetch" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" > "$HOME/.pf-arg"
EOF
chmod +x "$SLBIN/ccd-price-fetch"
rm -f "$FAKE/.pf-arg"
printf '%s' '{"model":{"id":"nv/model:free"}}' | CCD_ACTIVE=1 "$SLBIN/ccd-statusline" >/dev/null 2>&1
for _ in 1 2 3 4 5; do [ -s "$FAKE/.pf-arg" ] && break; sleep 0.2; done
stale_req=$(cat "$FAKE/.pf-arg" 2>/dev/null)
[ "$stale_req" = "nv/model:free" ] \
  && ok "statusline refreshes the routing-aware key" || bad "stale refresh key" "got: '$stale_req'"
rm -rf "$SLBIN"

head_ "12. ccd -c --model selects a verified launch-time context budget"
rm -f "$FAKE/.curl-args"
# Seed the selected slug as stale/future: --model must nevertheless synchronously
# refresh it and consume neither flag nor value as a Claude prompt.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
json.dump({"models": {"openai/gpt-5.6-terra:floor": {"min_context_length": 1000000, "floor_in_per_m": 1.0, "floor_out_per_m": 6.0, "max_in_per_m": 2.5, "max_out_per_m": 15.0, "fetched_at": time.time() + 999999}}}, open(sys.argv[1], "w"))
PY
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
cat <<'JSON'
{"data":{"endpoints":[{"tag":"p","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":1000000}]}}
JSON
EOF
chmod +x "$FAKE/fakebin/curl"
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -c --model openai/gpt-5.6-terra -p hi 2>/dev/null)
printf '%s\n' "$envout" | grep -qF 'ARGS:-c -p hi' \
  && ok "--model is consumed rather than forwarded to claude" || bad "--model argument forwarding" "got: $(printf '%s\n' "$envout" | head -1)"
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_MODEL=openai/gpt-5.6-terra:floor[1m]' \
  && ok "--model drives current sonnet model with [1m]" || bad "selected current model" "got: $(printf '%s\n' "$envout" | grep ANTHROPIC_MODEL)"
printf '%s\n' "$envout" | grep -qFx 'CLAUDE_CODE_SUBAGENT_MODEL=openai/gpt-5.6-terra:floor[1m]' \
  && ok "--model drives subagent model" || bad "selected subagent model" "got: $(printf '%s\n' "$envout" | grep SUBAGENT)"
# The forced refresh must land on the SAME routing-aware key the hint readers use.
# A bare-key write leaves the routing-aware entry stale, so a pool that SHRANK
# below 200K would still hand out [1m] — the exact overflow ccd exists to prevent.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
json.dump({"models": {"openai/gpt-5.6-terra:floor": {"min_context_length": 1000000, "max_context_length": 1000000, "fetched_at": time.time()}}}, open(sys.argv[1], "w"))
PY
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
cat <<'JSON'
{"data":{"endpoints":[{"tag":"p","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":150000}]}}
JSON
EOF
chmod +x "$FAKE/fakebin/curl"
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" --model openai/gpt-5.6-terra -p hi 2>/dev/null)
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_MODEL=openai/gpt-5.6-terra:floor' \
  && ok "shrunk pool overrides the stale routing-aware entry (no [1m])" \
  || bad "forced refresh writes the key readers use" "got: $(printf '%s\n' "$envout" | grep ANTHROPIC_MODEL)"
# A direct --model launch promises fresh verification. If its forced refresh fails,
# discard even a fresh positive cache entry rather than reusing an old [1m] budget.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
json.dump({"models": {"openai/gpt-5.6-terra:floor": {"min_context_length": 1000000, "max_context_length": 1000000, "fetched_at": time.time()}}}, open(sys.argv[1], "w"))
PY
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$HOME/.curl-args"
exit 1
EOF
chmod +x "$FAKE/fakebin/curl"
envout=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" --model openai/gpt-5.6-terra -p hi 2>/dev/null)
printf '%s\n' "$envout" | grep -qFx 'ANTHROPIC_MODEL=openai/gpt-5.6-terra:floor' \
  && ok "failed direct refresh discards old [1m] context" || bad "failed direct refresh stays safe" "got: $(printf '%s\n' "$envout" | grep ANTHROPIC_MODEL)"
rm -f "$FAKE/.curl-args"
bad_model=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" --model 'openai/gpt-5.6-terra:floor' -p hi 2>&1 || true)
case "$bad_model" in *'bare provider/model slug'*) ok "--model rejects routing suffix before network" ;; *) bad "--model validation" "got: ${bad_model:0:160}" ;; esac
[ -e "$FAKE/.curl-args" ] && bad "invalid --model makes a provider call" || ok "invalid --model skips provider calls"
conflict=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" --model openai/gpt-5.6-terra --sonnet luna -p hi 2>&1 || true)
case "$conflict" in *'ambiguous'*) ok "--model and --sonnet reject ambiguity" ;; *) bad "--model conflict" "got: ${conflict:0:160}" ;; esac

head_ "13. doctor never sends [1m] to the provider"
rm -f "$FAKE/.curl-args"   # assert on doctor's calls only
# Restore a fresh positive cache for every selected slot so detached catalog warming
# cannot add calls while this assertion isolates the doctor's actual wire request.
python3 - "$FAKE/.claude/ccd/price-cache.json" <<'PY'
import json, sys, time
now = int(time.time())
json.dump({"models": {
    "openai/gpt-5.6-luna:floor": {"min_context_length": 1000000, "fetched_at": now},
    "moonshotai/kimi-k3:floor": {"min_context_length": 1000000, "fetched_at": now},
    "deepseek/deepseek-v4-flash:floor": {"min_context_length": 1000000, "fetched_at": now},
    "openai/gpt-5.6-sol:floor": {"min_context_length": 1000000, "fetched_at": now},
    "openai/gpt-5.6-terra:floor": {"min_context_length": 1000000, "fetched_at": now},
    "z-ai/glm-5.1:floor": {"min_context_length": 1000000, "fetched_at": now},
}}, open(sys.argv[1], "w"))
PY
OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" doctor >/dev/null 2>&1
if grep -qF '[1m]' "$FAKE/.curl-args" 2>/dev/null; then
  bad "doctor strips [1m] before the probe" "got: $(grep -F '[1m]' "$FAKE/.curl-args" | head -1)"
else
  ok "doctor probe carries no [1m]"
fi
grep -qF '"model":"openai/gpt-5.6-luna:floor"' "$FAKE/.curl-args" 2>/dev/null \
  && ok "doctor probes slug:floor" || bad "doctor probe model" "got: $(grep -F '"model"' "$FAKE/.curl-args" | head -1)"
# doctor refreshes each slot then reports what the NEXT launch will wire. Its fetch
# and its read must share one key: a bare-key fetch made every row print
# "ctx unknown" and "[1m] not applied" for pools that plainly qualify.
rm -f "$FAKE/.claude/ccd/price-cache.json" "$FAKE/.curl-args"
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *"/v1/messages"*) echo 200; exit 0 ;;
esac
cat <<'JSON'
{"data":{"endpoints":[{"tag":"p","pricing":{"prompt":"0.000001","completion":"0.000002"},"context_length":900000}]}}
JSON
EOF
chmod +x "$FAKE/fakebin/curl"
doc=$(OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" doctor 2>&1)
case "$doc" in
  *'OPUS'*'900,000 ctx'*) ok "doctor reads back the pool it just refreshed" ;;
  *) bad "doctor context row" "got: $(printf '%s\n' "$doc" | grep OPUS)" ;;
esac
printf '%s\n' "$doc" | grep -q 'OPUS.*\[1m\] applied' \
  && ok "doctor applies [1m] for a verified >200K pool" \
  || bad "doctor [1m] row" "got: $(printf '%s\n' "$doc" | grep OPUS)"
rm -f "$FAKE/fakebin/curl"

head_ "14. rename surface: manifests, README coords, launcher resolution, uninstall text"
python3 - "$ROOT" <<'PY' \
  && ok "manifest identities: ccd / cc-donut, one version" || bad "manifest identity"
import json, sys
root = sys.argv[1]
p = json.load(open(f"{root}/.claude-plugin/plugin.json"))
m = json.load(open(f"{root}/.claude-plugin/marketplace.json"))
assert p["name"] == "ccd", p
assert m["name"] == "cc-donut" and m["plugins"][0]["name"] == "ccd", m
# one version, written in three places — they must agree (release bumps touch all)
assert p["version"] == m["version"] == m["plugins"][0]["version"], (p, m)
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

head_ "15. recovery: quota reset → flag recorded + green statusline"
# The round-trip claim: hook notices a reset transition and the statusline shows it.
mkdir -p "$FAKE/.claude/ccd"   # section 13's uninstall --purge removed it
# Fresh quota data with a NEW 7-day reset id and low percent (the stub node serves it).
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"fiveHourReset":"R1","sevenDayPercent":3,"sevenDayReset":"D2"}}\n' > "$FAKE/.stub-usage.json"
# Prior observation: 97% under the OLD reset id — the transition must be detected.
cat > "$FAKE/.claude/ccd/run-state.json" <<'EOF'
{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"last_seven_day_percent":97,"last_seven_day_reset":"D1"}
EOF
rm -f "$FAKE/.claude/ccd/quota-cache.json"   # force a refresh from the stub
# Block the cost path's real curl; recovery tracking must not depend on it.
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
echo 200
EOF
chmod +x "$FAKE/fakebin/curl"
CCD_ACTIVE=1 "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
python3 - "$FAKE/.claude/ccd/run-state.json" <<'PY' \
  && ok "reset transition records the recovery flag" || bad "recovery flag"
import json, sys
s = json.load(open(sys.argv[1]))
assert s.get("recovery_notified_window") == "seven_day", s
assert s.get("recovery_notified_reset") == "D2", s
PY
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in
  *"Claude recovered"*) ok "statusline shows the green recovery banner" ;;
  *) bad "recovery banner" "got: ${row:0:120}" ;;
esac
rm -f "$FAKE/fakebin/curl"

head_ "16. automatic handoff: arming predicate + hook stdin"
mkdir -p "$FAKE/.claude/ccd/providers"
hf_reset() { rm -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json"; }
hf_get() { python3 -c "
import json,os,sys
p='$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json'
print(json.load(open(p)).get(sys.argv[1],'') if os.path.exists(p) else '')" "$1" 2>/dev/null; }
# Quota cache the hook reads to corroborate a rate_limit error.
quota() { printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"fiveHourReset":"R1","sevenDayPercent":%s,"sevenDayReset":"D1"}}\n' "$1" "$2" > "$FAKE/.claude/ccd/quota-cache.json"; }
# StopFailure payload as Claude Code delivers it.
stopfail() { printf '{"session_id":"%s","cwd":"/tmp/w","hook_event_name":"StopFailure","error_type":"%s"}' "$1" "$2"; }

# Arming requires the full readiness set, so these run as a supervised session
# would: a launcher marker, a key, and a resolvable claude process. Section 19
# covers what happens when each of those is missing.
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"
# Stand-in for the claude process. Nothing resolves as "claude" on every
# platform at once — a symlink shows the target on Linux, a script shows the
# interpreter on macOS, and copied system binaries fail code-signing there. On
# Linux /proc names the script correctly; on macOS the harness puts a fake `ps`
# on PATH that reports this pid as claude. Production has neither, so the code
# under test carries no test-only branch.
mkdir -p "$FAKE/sigbin"
printf '#!/bin/sh\nsleep "${1:-60}"\n' > "$FAKE/sigbin/claude"
chmod +x "$FAKE/sigbin/claude"
# macOS path: ps must answer "claude" for the stand-in and the truth otherwise.
if [ ! -d /proc ]; then
  cat > "$FAKE/fakebin/ps" <<'PSEOF'
#!/bin/sh
# Test double: name $CCD_STANDIN_PID "claude"; defer everything else to real ps.
for a in "$@"; do case "$a" in -p) next=1 ;; *) [ "${next:-}" = 1 ] && { want=$a; next=0; } ;; esac; done
if [ -n "${CCD_STANDIN_PID:-}" ] && [ "${want:-}" = "$CCD_STANDIN_PID" ]; then
  case "$*" in *comm=*) echo claude; exit 0 ;; esac
fi
exec /bin/ps "$@"
PSEOF
  chmod +x "$FAKE/fakebin/ps"
fi
set +m 2>/dev/null
"$FAKE/sigbin/claude" 8 2>/dev/null & ARMPID=$!
sleep 0.3
# Signalling is section 17's subject; here we only care what gets armed, so aim
# CLAUDE_PID at a live stand-in and let it be killed.
arm_run() { stopfail "$1" "$2" | CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" CLAUDE_PID=$ARMPID CCD_STANDIN_PID=$ARMPID "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1; }

# rate_limit ALONE is not enough — it can be transient throttling. The dashboard
# reading has to agree, and a missing reading must never arm.
hf_reset; quota 58 96
arm_run sess-a rate_limit
[ "$(hf_get armed)" = "True" ] && ok "rate_limit + 96% arms the handoff" \
  || bad "arming on corroborated rate_limit" "armed=$(hf_get armed)"
[ "$(hf_get direction)" = "to_fallback" ] && ok "armed toward the OpenRouter backbone" \
  || bad "handoff direction" "got: $(hf_get direction)"
[ "$(hf_get session_id)" = "sess-a" ] && ok "session id recorded for --resume" \
  || bad "session id" "got: $(hf_get session_id)"
kill -9 $ARMPID 2>/dev/null; wait $ARMPID 2>/dev/null

"$FAKE/sigbin/claude" 8 2>/dev/null & ARMPID=$!
sleep 0.3
hf_reset; quota 20 40
arm_run sess-b rate_limit
[ -z "$(hf_get armed)" ] && ok "rate_limit at 40% does not arm (transient throttle)" \
  || bad "must not arm below threshold" "armed=$(hf_get armed)"

hf_reset; quota 58 96
arm_run sess-c overloaded
[ -z "$(hf_get armed)" ] && ok "overloaded does not arm (not a quota problem)" \
  || bad "must not arm on non-rate_limit" "armed=$(hf_get armed)"

hf_reset; rm -f "$FAKE/.claude/ccd/quota-cache.json"
arm_run sess-d rate_limit
[ -z "$(hf_get armed)" ] && ok "no quota reading does not arm (fails closed)" \
  || bad "must not arm without corroboration" "armed=$(hf_get armed)"
kill -9 $ARMPID 2>/dev/null; wait $ARMPID 2>/dev/null

# The discarded prototype used `timeout 0.5 cat` to read stdin. macOS has no
# timeout(1), so under `set -e` every hook died silently — taking the quota
# warnings with it. Assert the no-stdin path still works.
quota 58 96; rm -f "$FAKE/.claude/ccd/last-warn"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "hook still warns when stdin is absent" ;;
  *) bad "no-stdin regression" "got: ${out:0:100}" ;;
esac
# Malformed stdin must be ignored, not fatal.
rm -f "$FAKE/.claude/ccd/last-warn"
out=$(printf 'not json at all' | "$ROOT/scripts/quota-guard.sh" UserPromptSubmit 2>/dev/null)
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "malformed hook stdin degrades gracefully" ;;
  *) bad "malformed stdin" "got: ${out:0:100}" ;;
esac

head_ "17. automatic handoff: the SIGHUP interlock"
# THE safety property: never signal unless a relaunch loop is there to catch it.
# Otherwise the session just dies with nothing bringing it back.
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"
# Stand-in for the claude process. Nothing resolves as "claude" on every
# platform at once — a symlink shows the target on Linux, a script shows the
# interpreter on macOS, and copied system binaries fail code-signing there. On
# Linux /proc names the script correctly; on macOS the harness puts a fake `ps`
# on PATH that reports this pid as claude. Production has neither, so the code
# under test carries no test-only branch.
mkdir -p "$FAKE/sigbin"
printf '#!/bin/sh\nsleep "${1:-60}"\n' > "$FAKE/sigbin/claude"
chmod +x "$FAKE/sigbin/claude"
# macOS path: ps must answer "claude" for the stand-in and the truth otherwise.
if [ ! -d /proc ]; then
  cat > "$FAKE/fakebin/ps" <<'PSEOF'
#!/bin/sh
# Test double: name $CCD_STANDIN_PID "claude"; defer everything else to real ps.
for a in "$@"; do case "$a" in -p) next=1 ;; *) [ "${next:-}" = 1 ] && { want=$a; next=0; } ;; esac; done
if [ -n "${CCD_STANDIN_PID:-}" ] && [ "${want:-}" = "$CCD_STANDIN_PID" ]; then
  case "$*" in *comm=*) echo claude; exit 0 ;; esac
fi
exec /bin/ps "$@"
PSEOF
  chmod +x "$FAKE/fakebin/ps"
fi
quota 58 96

"$FAKE/sigbin/claude" 8 & TARGET=$!
sleep 0.3
hf_reset
stopfail sess-e rate_limit | CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
sleep 0.4
if kill -0 "$TARGET" 2>/dev/null; then ok "no CCD_HANDOFF → session is never signalled"
else bad "interlock breached" "target died without a relaunch loop"; fi
kill -9 "$TARGET" 2>/dev/null; wait "$TARGET" 2>/dev/null

# The signal is the point of this test, so the shell's "Hangup" job notice is
# expected — silence it rather than letting it look like a failure.
set +m 2>/dev/null
"$FAKE/sigbin/claude" 8 2>/dev/null & TARGET=$!
sleep 0.3
hf_reset
stopfail sess-f rate_limit | CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
sleep 0.6
if kill -0 "$TARGET" 2>/dev/null; then bad "handoff signal" "target survived CCD_HANDOFF=1"; else ok "CCD_HANDOFF=1 → SIGHUP delivered to the claude process"; fi
kill -9 "$TARGET" 2>/dev/null; wait "$TARGET" 2>/dev/null

# An armed handoff with no key would end the session with nowhere to go.
: > "$FAKE/.claude/ccd/providers/keys.env"
"$FAKE/sigbin/claude" 8 & TARGET=$!
sleep 0.3
hf_reset
stopfail sess-g rate_limit | CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
sleep 0.4
if kill -0 "$TARGET" 2>/dev/null; then ok "missing OpenRouter key → no signal (fails closed)"
else bad "signalled without a key" "target died with no fallback available"; fi
kill -9 "$TARGET" 2>/dev/null; wait "$TARGET" 2>/dev/null
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"

head_ "17b. the statusline never waits on the dashboard"
# ccd renders the dashboard's rows above its own, by running it as a child. That
# child is usually instant, but it refreshes its usage reading on its own
# schedule — and while it does, waiting for it blanks the WHOLE statusline. A
# user reported that as "the dashboard takes five seconds to appear". Serve the
# rows we saw last and refresh behind them: slightly stale beats absent.
mkdir -p "$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
: > "$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist/index.js"
printf 'CACHED-DASHBOARD-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
cp "$FAKE/fakebin/node" "$FAKE/node.real"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
sleep 5
echo "FRESH-DASHBOARD-ROW"
EOF
chmod +x "$FAKE/fakebin/node"
sl_start=$(date +%s)
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
sl_elapsed=$(( $(date +%s) - sl_start ))
[ "$sl_elapsed" -le 2 ] \
  && ok "a five-second dashboard does not hold up the statusline (${sl_elapsed}s)" \
  || bad "statusline latency" "waited ${sl_elapsed}s for the dashboard"
case "$row" in
  *"CACHED-DASHBOARD-ROW"*) ok "the rows we saw last are shown meanwhile" ;;
  *) bad "statusline" "lost the dashboard rows: $(printf '%s' "$row" | head -c 70)" ;;
esac
case "$row" in
  *"ccd"*) ok "and the ccd row is still rendered alongside them" ;;
  *) bad "statusline" "no ccd row" ;;
esac
# With nothing cached yet, one render pays for it so the rows exist at all.
# Let the refresh above finish first: while one is in flight it holds the lock,
# and a second render would correctly decline to start another.
pkill -f "$FAKE/fakebin/node" 2>/dev/null
rm -rf "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
echo "FIRST-DASHBOARD-ROW"
EOF
chmod +x "$FAKE/fakebin/node"
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in
  *"FIRST-DASHBOARD-ROW"*) ok "the very first render still fetches, so nothing is missing" ;;
  *) bad "statusline" "first render had no dashboard rows" ;;
esac
[ -s "$FAKE/.claude/ccd/.dashboard-row" ] \
  && ok "...and remembers them for next time" || bad "statusline" "nothing cached"
# A statusline renders on every prompt and tool call. Without single-flight, a
# stalled dashboard would leave a new `node` behind on each render, and two that
# finished out of order would let the older row win.
printf 'CACHED-DASHBOARD-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
sleep 30
echo "SLOW-ROW"
EOF
chmod +x "$FAKE/fakebin/node"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 \
    "$ROOT/bin/ccd-statusline" >/dev/null 2>&1
done
sleep 1
children=$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null | wc -l | tr -d ' ')
[ "${children:-0}" -le 1 ] \
  && ok "ten renders against a stalled dashboard leave at most one child ($children)" \
  || bad "statusline fan-out" "$children dashboard children alive"
[ -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "the refresh holds a lock while it runs" || bad "single-flight" "no lock"
pkill -f "$FAKE/fakebin/node" 2>/dev/null
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"

# A child that hangs must not outlive the row it was fetched for.
printf 'CACHED-DASHBOARD-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 CCD_DASH_TIMEOUT=1 \
  "$ROOT/bin/ccd-statusline" >/dev/null 2>&1
sleep 3
[ "$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && ok "a hung dashboard child is killed by the watchdog" \
  || bad "watchdog" "child survived its timeout"
[ ! -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "...and the lock is released with it" || bad "watchdog" "lock leaked"

# A lock left behind by a killed refresher must not freeze refreshes forever.
mkdir -p "$FAKE/.claude/ccd/.dashboard-row.lock"
python3 -c "import os,sys;os.utime(sys.argv[1], (0, 0))" "$FAKE/.claude/ccd/.dashboard-row.lock"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
echo "REFRESHED-ROW"
EOF
chmod +x "$FAKE/fakebin/node"
printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 \
  "$ROOT/bin/ccd-statusline" >/dev/null 2>&1
# Wait for the refresh rather than guessing at it: a container can take a second
# or two to get a detached child scheduled, and a fixed sleep turns that into a
# flake that looks like a product bug.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'REFRESHED-ROW' "$FAKE/.claude/ccd/.dashboard-row" 2>/dev/null && break
  sleep 0.5
done
grep -q 'REFRESHED-ROW' "$FAKE/.claude/ccd/.dashboard-row" \
  && ok "a stale lock is reclaimed instead of blocking refreshes forever" \
  || bad "stale lock" "refresh never ran again"

# Staleness has a ceiling: past it, the render pays rather than showing a lie.
printf 'ANCIENT-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
python3 -c "import os,sys;os.utime(sys.argv[1], (0, 0))" "$FAKE/.claude/ccd/.dashboard-row"
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 \
      "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in
  *"REFRESHED-ROW"*) ok "a row too old to stand behind is fetched fresh instead" ;;
  *"ANCIENT-ROW"*) bad "staleness" "served a row with no upper bound on its age" ;;
  *) bad "staleness" "got: $(printf '%s' "$row" | head -c 60)" ;;
esac

# The cold and over-stale path fetches synchronously, and needs the same bounds:
# a hung dashboard there would hold the statusline hostage with no cache to fall
# back on. On timeout we render our own row without its rows rather than freeze.
rm -rf "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
sleep 30
echo "NEVER-ARRIVES"
EOF
chmod +x "$FAKE/fakebin/node"
sl_start=$(date +%s)
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 CCD_DASH_TIMEOUT=2 \
      "$ROOT/bin/ccd-statusline" 2>/dev/null)
sl_elapsed=$(( $(date +%s) - sl_start ))
[ "$sl_elapsed" -le 5 ] \
  && ok "a hung dashboard with nothing cached is bounded too (${sl_elapsed}s)" \
  || bad "cold-path timeout" "waited ${sl_elapsed}s"
case "$row" in
  *"NEVER-ARRIVES"*) bad "cold-path timeout" "served output from a child it killed" ;;
  *"ccd"*) ok "...and the ccd row is rendered without the dashboard rows" ;;
  *) bad "cold-path timeout" "no row at all: $(printf '%s' "$row" | head -c 60)" ;;
esac
[ ! -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "the lock is released on the cold path as well" || bad "cold-path lock" "leaked"
pkill -f "$FAKE/fakebin/node" 2>/dev/null

cp "$FAKE/node.real" "$FAKE/fakebin/node"; chmod +x "$FAKE/fakebin/node"
rm -rf "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock" "$FAKE/node.real"

head_ "18. automatic handoff: launcher shim"
SHIM="$FAKE/.claude/ccd/bin/claude"
# The shim must be invisible until a handoff happens: every exit code other
# than 129 passes through untouched.
HB="$FAKE/.claude/plugins/cache/cc-donut/ccd/0.2.0/bin"
mkdir -p "$HB" "$FAKE/realbin"
cp "$ROOT/bin/ccd-handoff" "$HB/ccd-handoff"; chmod +x "$HB/ccd-handoff"
cat > "$HB/ccd" <<'EOF'
#!/bin/sh
echo "CCD-RESUMED:$*"
EOF
chmod +x "$HB/ccd"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
[ -x "$SHIM" ] && ok "setup --auto installs the claude shim" \
  || bad "shim install" "not executable"
"$ROOT/bin/ccd" setup >/dev/null 2>&1
[ -x "$SHIM" ] && ok "bare setup leaves the shim alone" || bad "bare setup removed the shim"

# The launcher decides whether a relaunch is possible from its terminal state:
# production always has one, and a session with no terminal must not be relaunched
# into ccd's "exit Claude Code first" refusal. Command substitution takes that
# terminal away, so drive the shim through a pty and capture what it wrote.
# Exit status is forwarded exactly — several tests assert on it. Reading stops as
# soon as the child is reaped, so a detached grandchild holding the pty open (real
# ccd warms its price cache in the background) cannot wedge the suite.
cat > "$FAKE/ptyrun.py" <<'PYRUN'
import os, pty, select, sys

# Give the child a terminal without losing a byte of what it writes.
#
# pty.fork() is the obvious tool and the wrong one here: on Linux, once the last
# slave fd closes, output the master has not read yet is discarded, so a launcher
# that relaunches and exits quickly loses everything after the first leg. That is
# a property of the harness, not of the code under test, and it made the suite
# fail on Alpine for reasons that had nothing to do with the handoff.
#
# So the parent holds a slave fd open for the whole run: the stream cannot end
# early, and draining continuously also keeps a chatty child from filling the
# buffer and blocking. Only once the child is reaped and the pty has gone quiet
# do we close our slave and finish.
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    # A session of its own with the slave as controlling terminal, so /dev/tty and
    # job control behave as they would in a real terminal — openpty alone would
    # only hand over tty-shaped file descriptors.
    os.setsid()
    try:
        import fcntl, termios
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    except Exception:
        pass
    for target in (0, 1, 2):
        os.dup2(slave, target)
    if slave > 2:
        os.close(slave)
    try:
        os.execvp(sys.argv[1], sys.argv[1:])
    except OSError:
        os._exit(127)

def drain(timeout):
    """Copy one readable chunk. False when there was nothing to read."""
    r, _, _ = select.select([master], [], [], timeout)
    if not r:
        return False
    try:
        chunk = os.read(master, 65536)
    except OSError:
        return False
    if not chunk:
        return False
    # A pty turns every \n into \r\n; assertions compare against plain text.
    sys.stdout.buffer.write(chunk.replace(b"\r\n", b"\n"))
    return True

status = None
while status is None:
    if drain(0.05):
        continue
    done, st = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        status = st
while drain(0.2):                # whatever the child wrote on its way out
    pass
os.close(slave)
os.close(master)
sys.stdout.buffer.flush()
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PYRUN
shim_run() { python3 "$FAKE/ptyrun.py" "$@"; }

SHIMPATH="$FAKE/.claude/ccd/bin:$FAKE/realbin:$PATH"
# Pin the launcher token so these tests know where its state file lives; a real
# launch mints a random one. HSTATE is that path.
export CCD_HANDOFF_TOKEN=00000000000000000000000000000001
HSTATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000001.json"
fake_real() { printf '%s\n' "$1" > "$FAKE/realbin/claude"; chmod +x "$FAKE/realbin/claude"; }

fake_real '#!/bin/sh
echo "REAL:$*"'
out=$(PATH="$SHIMPATH" shim_run "$SHIM" --flag 2>/dev/null)
[ "$out" = "REAL:--flag" ] && ok "shim forwards argv to the real claude" || bad "argv forwarding" "got: $out"

fake_real '#!/bin/sh
exit 3'
PATH="$SHIMPATH" shim_run "$SHIM" >/dev/null 2>&1
[ "$?" -eq 3 ] && ok "non-129 exit codes pass through unchanged" || bad "exit passthrough" "got: $?"

# 129 can also mean a closing terminal. Without an armed handoff, don't invent one.
fake_real '#!/bin/sh
exit 129'
hf_reset
PATH="$SHIMPATH" shim_run "$SHIM" >/dev/null 2>&1
[ "$?" -eq 129 ] && ok "129 without an armed handoff does not relaunch" || bad "unarmed 129" "got: $?"

# --resume only happens when the session actually has a transcript.
mkdir -p "$FAKE/.claude/projects/-tmp"; : > "$FAKE/.claude/projects/-tmp/sess-x.jsonl"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-x","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>/dev/null)
case "$out" in
  *"CCD-RESUMED:--resume sess-x"*) ok "armed 129 relaunches the conversation on ccd" ;;
  *) bad "handoff relaunch" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 100)" ;;
esac
[ ! -f "$HSTATE" ] && ok "handoff is disarmed before relaunching" \
  || bad "stale handoff left armed"

# to_subscription goes back to the real binary, not to ccd.
fake_real '#!/bin/sh
[ "$1" = --resume ] && { echo "REAL-RESUMED:$*"; exit 0; }
exit 129'
: > "$FAKE/.claude/projects/-tmp/sess-y.jsonl"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_subscription","session_id":"sess-y","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>/dev/null)
case "$out" in
  *"REAL-RESUMED:--resume sess-y"*) ok "recovery relaunches on the subscription" ;;
  *) bad "subscription relaunch" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 100)" ;;
esac

# A transcript can exist and still fail to open — Claude Code answers "No
# conversation found" and exits 1. That happens right after an automatic switch,
# so the user would be dropped at an error with no idea what to do. Carry on in a
# fresh session instead, and say the thread was not restored.
: > "$FAKE/.claude/projects/-tmp/sess-bad.jsonl"
rm -f "$FAKE/.tries"
fake_real '#!/bin/sh
exit 129'
cat > "$HB/ccd" <<'EOF'
#!/bin/sh
printf "%s\n" "$*" >> "$HOME/.tries"
case "$1" in --resume) echo "No conversation found"; exit 1 ;; esac
echo "CCD-FRESH:$*"
EOF
chmod +x "$HB/ccd"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-bad","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>&1)
case "$out" in
  *"CCD-FRESH:go"*) ok "a resume that fails starts a fresh session instead of erroring" ;;
  *) bad "resume fallback" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
case "$out" in
  *"복원하지 못했습니다"*"--resume sess-bad"*) ok "...and says the thread is still there, with how to get it" ;;
  *) bad "resume fallback" "silent about the lost thread" ;;
esac
[ "$(grep -c . "$FAKE/.tries" 2>/dev/null)" = "2" ] \
  && ok "it retries exactly once, not in a loop" \
  || bad "resume fallback" "ran $(grep -c . "$FAKE/.tries" 2>/dev/null) times"
rm -f "$HSTATE" "$FAKE/.tries" "$FAKE/.claude/projects/-tmp/sess-bad.jsonl"

# Worst case: something keeps re-arming the handoff while every launch exits 129.
# Disarm alone cannot stop that, so the burst's visited set is the backstop being
# tested here — the fake claude re-arms on every run, exactly as a stuck quota
# signal would.
rm -f "$FAKE/.hops"
fake_real '#!/bin/sh
printf "%s\n" x >> "$HOME/.hops"
printf "{\"armed\":true,\"token\":\"00000000000000000000000000000001\",\"direction\":\"to_fallback\",\"session_id\":\"sess-z\",\"cwd\":\"/tmp\",\"armed_at\":1}" > "$HOME/.claude/ccd/handoff-00000000000000000000000000000001.json"
exit 129'
cat > "$HB/ccd" <<'EOF'
#!/bin/sh
printf "%s\n" x >> "$HOME/.hops"
printf "{\"armed\":true,\"token\":\"00000000000000000000000000000001\",\"direction\":\"to_fallback\",\"session_id\":\"sess-z\",\"cwd\":\"/tmp\",\"armed_at\":1}" > "$HOME/.claude/ccd/handoff-00000000000000000000000000000001.json"
exit 129
EOF
chmod +x "$HB/ccd"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-z","cwd":"/tmp","armed_at":1}' > "$HSTATE"
PATH="$SHIMPATH" shim_run "$SHIM" >/dev/null 2>&1
hops=$(wc -l < "$FAKE/.hops" 2>/dev/null | tr -d ' ')
# Exactly 2 launches. Every arming here points at the SAME destination
# (fallback), and a destination may be entered once per burst — so the second
# 129 is refused rather than relaunched. This is stricter than the old hop
# counter, which allowed a third launch before tripping: repeating a destination
# is a loop by definition, no matter how high a numeric cap is set.
# An exact count matters — a loose range would also pass if the loop stopped
# early for an unrelated reason (a token mismatch, say).
[ "${hops:-0}" -eq 2 ] \
  && ok "a destination is never entered twice in one burst (ran $hops times)" \
  || bad "burst loop guard" "expected 2 launches, ran ${hops:-0}"
rm -f "$HSTATE"

# The cap must not count LEGITIMATE transitions. Quota dying, recovering, and
# dying again over a workday is ordinary; a lifetime counter would strand the
# user on the third one. Sessions that ran a while reset the counter.
rm -f "$FAKE/.hops2"
fake_real '#!/bin/sh
printf "%s\n" x >> "$HOME/.hops2"
sleep 2
printf "{\"armed\":true,\"token\":\"00000000000000000000000000000001\",\"direction\":\"to_fallback\",\"session_id\":\"sess-z\",\"cwd\":\"/tmp\",\"armed_at\":1}" > "$HOME/.claude/ccd/handoff-00000000000000000000000000000001.json"
exit 129'
cat > "$HB/ccd" <<'EOF'
#!/bin/sh
printf "{\"armed\":true,\"token\":\"00000000000000000000000000000001\",\"direction\":\"to_subscription\",\"session_id\":\"sess-z\",\"cwd\":\"/tmp\",\"armed_at\":1}" > "$HOME/.claude/ccd/handoff-00000000000000000000000000000001.json"
exit 129
EOF
chmod +x "$HB/ccd"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-z","cwd":"/tmp","armed_at":1}' > "$HSTATE"
# A 1s window makes each 2s session count as "long"; run briefly and count.
( PATH="$SHIMPATH" CCD_HOP_RESET_SECONDS=1 shim_run "$SHIM" >/dev/null 2>&1 ) &
LOOPPID=$!
sleep 11
kill -9 $LOOPPID 2>/dev/null; wait $LOOPPID 2>/dev/null
longruns=$(wc -l < "$FAKE/.hops2" 2>/dev/null | tr -d ' ')
[ "${longruns:-0}" -gt 3 ] \
  && ok "long-running sessions reset the relaunch counter (ran $longruns)" \
  || bad "lifetime hop cap" "stopped after ${longruns:-0} legitimate transitions"
rm -f "$HSTATE" "$FAKE/.hops2"

# Never strand the user: if the plugin is gone, fall through to the real claude.
mv "$FAKE/.claude/plugins/cache/cc-donut" "$FAKE/plugin-away"
fake_real '#!/bin/sh
echo "REAL-FALLBACK:$*"'
out=$(PATH="$SHIMPATH" shim_run "$SHIM" --z 2>/dev/null)
case "$out" in
  *"REAL-FALLBACK:--z"*) ok "missing plugin falls through to the real claude" ;;
  *) bad "plugin-missing fallback" "got: $out" ;;
esac
mv "$FAKE/plugin-away" "$FAKE/.claude/plugins/cache/cc-donut"

"$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ ! -e "$SHIM" ] && ok "setup --no-auto removes the shim" || bad "--no-auto left the shim"
# A claude the user installed themselves must survive uninstall.
printf '#!/bin/sh\necho mine\n' > "$SHIM"; chmod +x "$SHIM"
out=$("$ROOT/bin/ccd" uninstall 2>&1)
case "$out" in
  *"not a ccd shim"*) ok "a foreign ~/.local/bin/claude is left alone" ;;
  *) bad "foreign claude warning" "got: $(printf '%s' "$out" | grep -i claude | head -1)" ;;
esac
[ -e "$SHIM" ] && ok "foreign claude survives uninstall" || bad "deleted a foreign claude"
# Install must protect what uninstall protects — otherwise `setup --auto` deletes
# exactly the file we refuse to remove.
out=$("$ROOT/bin/ccd" setup --auto --yes 2>&1)
case "$out" in
  *"not a ccd shim"*) ok "setup --auto refuses to clobber a foreign claude" ;;
  *) bad "install-side protection" "got: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')" ;;
esac
[ "$(cat "$SHIM")" = "$(printf '#!/bin/sh\necho mine')" ] \
  && ok "the foreign claude is byte-identical after a refused install" \
  || bad "foreign claude was modified"

# Ownership decides whether we overwrite and delete. A wrapper that merely
# mentions ccd in a comment is still the user's file, so the check has to match
# the whole signature line rather than a substring of it.
printf '#!/bin/sh\n# my wrapper, sits in front of the ccd launcher\nexec /usr/bin/claude "$@"\n' \
  > "$SHIM"; chmod +x "$SHIM"
before=$(cat "$SHIM")
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
[ "$(cat "$SHIM")" = "$before" ] \
  && ok "a wrapper that merely mentions ccd is not claimed as ours" \
  || bad "ownership marker" "overwrote a foreign wrapper that mentioned ccd"
"$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ -e "$SHIM" ] && ok "...and --no-auto does not delete it either" \
  || bad "ownership marker" "deleted a foreign wrapper that mentioned ccd"
rm -f "$SHIM"

head_ "18b. automatic handoff: the PATH line"
# The shim only works if its directory precedes the real claude, and that means
# editing a startup file. Consent is explicit, the edit is exact, and removal
# takes back only what we wrote.
export SHELL=/bin/zsh
RC="$FAKE/.zshrc"
rm -f "$RC" "$SHIM"
printf '# my own file\nexport EDITOR=vim\n' > "$RC"

# No terminal and no --yes: say what is needed, change nothing.
out=$(HOME="$FAKE" "$ROOT/bin/ccd" setup --auto 2>&1)
case "$out" in
  *"Skipped"*) ok "no terminal, no --yes → the startup file is left alone" ;;
  *) bad "consent" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
[ "$(cat "$RC")" = "$(printf '# my own file\nexport EDITOR=vim')" ] \
  && ok "the startup file is byte-identical after a skipped install" \
  || bad "consent" "edited a startup file without being asked"
[ -x "$SHIM" ] && ok "the shim is installed either way" || bad "shim install" "missing"

# --yes carries the consent.
out=$(HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes 2>&1)
grep -qxF 'export PATH="$HOME/.claude/ccd/bin:$PATH"' "$RC" \
  && ok "--yes adds the PATH line" || bad "PATH line" "not added"
grep -c 'ccd-auto-handoff-path' "$RC" | grep -qx 1 \
  && ok "the line is written once, with its marker" || bad "PATH line" "marker count wrong"

# Running it again must not stack duplicates.
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
[ "$(grep -c 'ccd-auto-handoff-path' "$RC")" = "1" ] \
  && ok "a second install does not duplicate the line" || bad "PATH line" "duplicated"

# Removal takes back exactly two lines: the marker and the export.
mine_before=$(grep -c 'EDITOR=vim' "$RC")
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ "$(grep -c 'ccd-auto-handoff-path' "$RC")" = "0" ] \
  && ok "--no-auto removes the PATH line" || bad "PATH line" "left behind"
grep -q 'ccd/bin:\$PATH' "$RC" && bad "PATH line" "export survived its marker" \
  || ok "the export goes with its marker"
[ "$(grep -c 'EDITOR=vim' "$RC")" = "$mine_before" ] \
  && ok "lines we did not write are untouched" || bad "PATH line" "removed something else"

# If the user edits the export under our marker, that line is theirs now. Take
# the marker back and leave their edit standing — deleting a line we did not
# write is the one failure this design exists to prevent.
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
python3 - "$RC" <<'PYX'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
i = lines.index('# ccd-auto-handoff-path v1 (managed by: ccd setup --auto)')
lines[i + 1] = 'export PATH="$HOME/.claude/ccd/bin:$HOME/my/tools:$PATH"'   # user edit
open(p, 'w').write('\n'.join(lines) + '\n')
PYX
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
grep -q 'my/tools' "$RC" \
  && ok "an edited export is left standing when the marker is removed" \
  || bad "PATH line" "deleted a line the user had edited"
[ "$(grep -c 'ccd-auto-handoff-path' "$RC")" = "0" ] \
  && ok "...and the marker still goes" || bad "PATH line" "marker survived"
python3 - "$RC" <<'PYX'
import sys
p = sys.argv[1]
open(p, 'w').write('\n'.join(
    l for l in open(p).read().splitlines() if 'my/tools' not in l) + '\n')
PYX

# Removal must find the line even when rc_file() would now answer differently —
# bash reads different files for login and interactive shells, and a .bashrc
# created after install would otherwise strand our line in the old one.
rm -f "$FAKE/.bashrc" "$FAKE/.bash_profile" "$FAKE/.profile"
printf '# login file\n' > "$FAKE/.bash_profile"     # rc_file() answers this one...
SHELL=/bin/bash HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
if grep -q 'ccd-auto-handoff-path' "$FAKE/.bash_profile"; then
  ok "bash install lands in the file rc_file chose"
  printf '# interactive file\n' > "$FAKE/.bashrc"   # ...and now it answers this one
  SHELL=/bin/bash HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
  grep -q 'ccd-auto-handoff-path' "$FAKE/.bash_profile" \
    && bad "PATH line" "stranded in .bash_profile once .bashrc moved the rc target" \
    || ok "removal finds the line even after the rc target moves"
else
  bad "PATH line" "bash install did not write to .bash_profile"
fi
rm -f "$FAKE/.bashrc" "$FAKE/.bash_profile" "$FAKE/.profile"
export SHELL=/bin/zsh

# Removing our line must never be able to ruin the file. Copying a rewrite back
# over the original truncates it first; an interrupted copy would leave someone
# with an empty startup file. Check the swap keeps content, mode, and symlinks.
rm -f "$RC" "$FAKE/.claude/ccd/auto-path"
printf '# top\nexport EDITOR=vim\n' > "$RC"; chmod 600 "$RC"
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ "$(cat "$RC")" = "$(printf '# top\nexport EDITOR=vim')" ] \
  && ok "the rewrite keeps every line it did not remove" \
  || bad "atomic swap" "content changed: $(tr '\n' ' ' < "$RC")"
[ "$(ls -l "$RC" | cut -c1-10)" = "-rw-------" ] \
  && ok "the rewrite keeps the original file mode" \
  || bad "atomic swap" "mode became $(ls -l "$RC" | cut -c1-10)"
# A startup file that is a symlink must stay one.
mkdir -p "$FAKE/dotfiles"; mv "$RC" "$FAKE/dotfiles/zshrc"; ln -s "$FAKE/dotfiles/zshrc" "$RC"
rm -f "$FAKE/.claude/ccd/auto-path"
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ -L "$RC" ] && ok "a symlinked startup file is still a symlink afterwards" \
  || bad "atomic swap" "replaced the symlink instead of its target"
grep -q 'EDITOR=vim' "$FAKE/dotfiles/zshrc" \
  && ok "...and the file it points at kept its contents" \
  || bad "atomic swap" "symlink target lost its contents"
rm -f "$RC"; rm -rf "$FAKE/dotfiles"; printf '# my own file\nexport EDITOR=vim\n' > "$RC"

# A rewrite that cannot happen must leave the file exactly as it was and say so,
# rather than half-writing it. Only meaningful as a non-root user — root writes
# through a read-only directory, so the containers skip this one.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$FAKE/ro"; printf '# theirs\n' > "$FAKE/ro/rc"
  printf '\n%s\n%s\n' '# ccd-auto-handoff-path v1 (managed by: ccd setup --auto)' \
    'export PATH="$HOME/.claude/ccd/bin:$PATH"' >> "$FAKE/ro/rc"
  before=$(cat "$FAKE/ro/rc")
  mkdir -p "$FAKE/.claude/ccd"; printf '%s\n' "$FAKE/ro/rc" > "$FAKE/.claude/ccd/auto-path"
  chmod 500 "$FAKE/ro"                       # no new files: mktemp will fail
  out=$(HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto 2>&1)
  chmod 700 "$FAKE/ro"
  [ "$(cat "$FAKE/ro/rc")" = "$before" ] \
    && ok "a rewrite that cannot be staged leaves the file untouched" \
    || bad "atomic swap" "damaged a file it could not rewrite"
  case "$out" in
    *"could not rewrite"*) ok "...and reports the failure instead of claiming success" ;;
    *) bad "atomic swap" "silent failure: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
  esac
  [ -f "$FAKE/.claude/ccd/auto-path" ] \
    && ok "the ownership record survives a failed removal, so a retry can find it" \
    || bad "atomic swap" "dropped the record after failing to use it"
  rm -rf "$FAKE/ro" "$FAKE/.claude/ccd/auto-path"
fi

# An edit that escapes the ownership record could never be removed, and setup
# would still have claimed success. If the record cannot be written, the startup
# file must not be touched at all.
rm -rf "$FAKE/.claude/ccd/auto-path"
mkdir -p "$FAKE/.claude/ccd/auto-path"        # a directory: appending will fail
printf '# untouched\n' > "$RC"
out=$(HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes 2>&1)
[ "$(cat "$RC")" = "# untouched" ] \
  && ok "an unrecordable install leaves the startup file alone" \
  || bad "ownership record" "edited a startup file it could not record"
case "$out" in
  *"could not record ownership"*) ok "...and says why instead of claiming success" ;;
  *) bad "ownership record" "got: $(printf '%s' "$out" | grep -i 'added\|record' | head -1)" ;;
esac
rmdir "$FAKE/.claude/ccd/auto-path"

# Claude Code runs shell commands with stdin and stdout as PIPES while the
# controlling terminal is still there. That is neither "interactive" nor
# "scripted", and getting it wrong means the consent prompt silently never
# appears — which is exactly what happened in the first user test. This helper
# reproduces that shape, and `bare` drops the controlling terminal too, for the
# genuinely scripted case.
cat > "$FAKE/ttyask.py" <<'TTYASK'
import os, pty, select, sys, time

mode, answer, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
argv = sys.argv[4:]
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    if mode == "ctty":                      # a terminal exists, just not on 0/1
        import fcntl, termios
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    r, w = os.pipe()
    os.dup2(r, 0)                           # stdin: a pipe nobody writes to
    os.close(w)
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    if slave > 2:
        os.close(slave)
    try:
        os.execvp(argv[0], argv)
    except OSError:
        os._exit(127)

seen = b""
status = None
deadline = time.time() + 25
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if chunk:
            seen += chunk
            if b"[Y/n]" in seen and answer != "none":
                os.write(master, answer.encode() + b"\n")
                answer = "none"
            continue
    done, st = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        status = st
        break
if status is None:
    os.kill(pid, 9)
    _, status = os.waitpid(pid, 0)
os.close(slave)
os.close(master)
sys.stdout.buffer.write(seen.replace(b"\r\n", b"\n"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
TTYASK

# The prompt has to reach a person wherever one is sitting. `ccd key` already
# reaches past a piped stdin to /dev/tty; consent must do the same, or every
# install run from inside Claude Code silently declines.
rm -f "$RC" "$FAKE/.claude/ccd/auto-path" "$FAKE/.claude/ccd/bin/claude"
printf '# mine\n' > "$RC"
asked=$(python3 "$FAKE/ttyask.py" ctty "" "$FAKE/.ask-out" \
          env HOME="$FAKE" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --auto 2>/dev/null)
case "$asked" in
  *"[Y/n]"*) ok "the consent prompt reaches the terminal even with piped stdio" ;;
  *) bad "consent prompt" "never asked: $(printf '%s' "$asked" | tr '\n' ' ' | head -c 70)" ;;
esac
grep -q 'ccd-auto-handoff-path' "$RC" \
  && ok "...and Enter accepts it" || bad "consent prompt" "answer was not applied"

# Saying no must still mean no.
rm -f "$RC" "$FAKE/.claude/ccd/auto-path" "$FAKE/.claude/ccd/bin/claude"
printf '# mine\n' > "$RC"
python3 "$FAKE/ttyask.py" ctty n "$FAKE/.ask-out" \
  env HOME="$FAKE" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --auto >/dev/null 2>&1
grep -q 'ccd-auto-handoff-path' "$RC" \
  && bad "consent prompt" "added the line after the user said no" \
  || ok "answering n leaves the startup file alone"
grep -q 'not active yet' "$FAKE/.ask-out" \
  && ok "...and says the feature is installed but not active" \
  || bad "consent prompt" "declining left the user with no idea where they stand"

# With no controlling terminal at all there is nobody to ask, and a scripted
# install must not rewrite a startup file on its own.
rm -f "$RC" "$FAKE/.claude/ccd/auto-path" "$FAKE/.claude/ccd/bin/claude"
printf '# mine\n' > "$RC"
python3 "$FAKE/ttyask.py" bare none "$FAKE/.ask-out" \
  env HOME="$FAKE" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --auto >/dev/null 2>&1
[ "$(cat "$RC")" = "# mine" ] \
  && ok "a truly scripted install changes nothing" \
  || bad "consent prompt" "edited a startup file with nobody to ask"
rm -f "$FAKE/.ask-out"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1

# Nothing internal may leak onto stderr. A missing shell function still "works"
# — bash treats command-not-found as false — so only stderr reveals it, and every
# other test here redirects stderr away. This one exists to look at it.
rm -f "$RC" "$FAKE/.claude/ccd/auto-path"
err=$(HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes 2>&1 >/dev/null)
case "$err" in
  *"command not found"*|*"unbound variable"*|*"syntax error"*)
    bad "setup stderr" "$(printf '%s' "$err" | head -1)" ;;
  *) ok "setup --auto runs without shell errors on stderr" ;;
esac
# Same again on the path where the shim already leads PATH — a different branch.
err=$(PATH="$FAKE/.claude/ccd/bin:$PATH" HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes 2>&1 >/dev/null)
case "$err" in
  *"command not found"*|*"unbound variable"*)
    bad "setup stderr" "$(printf '%s' "$err" | head -1)" ;;
  *) ok "...and when the shim already leads PATH" ;;
esac
out=$(PATH="$FAKE/.claude/ccd/bin:$PATH" HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes 2>/dev/null)
case "$out" in
  *"already first on PATH"*) ok "a shim that already leads PATH needs no line" ;;
  *) bad "shim_leads_path" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1

# The marker asserts ownership of a line WE appended. The same text sitting in
# someone else'"'"'s file — inside a heredoc, a pasted snippet, documentation — is
# their data, and editing it would break the promise the whole design rests on.
cat > "$FAKE/.bashrc" <<'FIXTURE'
cat > /tmp/example <<'INNER'
# ccd-auto-handoff-path v1 (managed by: ccd setup --auto)
export PATH="$HOME/.claude/ccd/bin:$PATH"
INNER
echo done
FIXTURE
fixture=$(cat "$FAKE/.bashrc")
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ "$(cat "$FAKE/.bashrc")" = "$fixture" ] \
  && ok "a marker inside a heredoc is data, not ours to delete" \
  || bad "candidate sweep" "edited a file ccd never wrote to"
out=$(HOME="$FAKE" "$ROOT/bin/ccd" uninstall 2>&1)
[ "$(cat "$FAKE/.bashrc")" = "$fixture" ] \
  && ok "uninstall leaves it alone too" || bad "uninstall" "edited a file ccd never wrote to"
case "$out" in
  *"left alone"*) ok "and says where the unowned line is" ;;
  *) bad "candidate sweep" "silently ignored a marker it refused to touch" ;;
esac
rm -f "$FAKE/.bashrc"

# "Why did nothing happen?" ended the first user test. Installed is not active,
# and active in some shell is not supervising THIS session — doctor has to be
# able to tell those three apart, because that is the whole diagnosis.
rm -f "$RC" "$FAKE/.claude/ccd/auto-path"
"$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
out=$("$ROOT/bin/ccd" doctor 2>&1 | sed -n '/Automatic handoff/,/^$/p')
case "$out" in
  *"off"*"ccd setup --auto"*) ok "doctor: off says how to turn it on" ;;
  *) bad "doctor handoff" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
out=$(CLAUDECODE=1 "$ROOT/bin/ccd" doctor 2>&1 | sed -n '/Automatic handoff/,/^$/p')
case "$out" in
  *"not active in this shell"*"NOT supervised"*)
    ok "doctor: installed but inactive says both, and why" ;;
  *) bad "doctor handoff" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
out=$(CLAUDECODE=1 CCD_HANDOFF=0123456789abcdef0123456789abcdef \
      PATH="$FAKE/.claude/ccd/bin:$PATH" "$ROOT/bin/ccd" doctor 2>&1 \
      | sed -n '/Automatic handoff/,/^$/p')
case "$out" in
  *"active in this shell"*"is supervised"*)
    case "$out" in
      *"not active"*|*"NOT supervised"*) bad "doctor handoff" "reported ready and not-ready at once" ;;
      *) ok "doctor: a supervised session is reported as ready" ;;
    esac ;;
  *) bad "doctor handoff" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac

# The one thing still to do must be the LAST line, not buried between checkmarks.
rm -f "$RC" "$FAKE/.claude/ccd/auto-path"; printf '# mine\n' > "$RC"
"$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
last=$("$ROOT/bin/ccd" setup --auto --yes 2>&1 | grep -v '^$' | tail -1)
case "$last" in
  *"Open a new terminal"*) ok "the remaining step is the last line of setup" ;;
  *) bad "setup ordering" "last line was: $(printf '%s' "$last" | head -c 70)" ;;
esac

# A PATH entry the user wrote themselves has no marker, so we must not claim it.
printf 'export PATH="$HOME/.claude/ccd/bin:$PATH"\n' >> "$RC"
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
grep -q 'ccd/bin:\$PATH' "$RC" \
  && ok "an unmarked PATH line the user wrote is left alone" \
  || bad "PATH line" "deleted a line we did not write"

# uninstall cleans up after itself too.
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
HOME="$FAKE" "$ROOT/bin/ccd" uninstall >/dev/null 2>&1
[ "$(grep -c 'ccd-auto-handoff-path' "$RC")" = "0" ] \
  && ok "uninstall removes the PATH line" || bad "uninstall" "PATH line left behind"
[ ! -e "$SHIM" ] && ok "uninstall removes the shim" || bad "uninstall" "shim left behind"
rm -f "$RC"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1

head_ "19. automatic handoff: readiness gates"
# Each of these ends a session, so each must fail closed. A key ccd would later
# reject is the same as no key: the session would end with nowhere to go.
eval "$(sed -n '/^have_key()/,/^}/p' "$ROOT/scripts/quota-guard.sh")"
CCD_DIR="$FAKE/.claude/ccd"
keyfile="$CCD_DIR/providers/keys.env"
mkdir -p "$CCD_DIR/providers"
keycase() { printf '%s\n' "$2" > "$keyfile"
  if env -u OPENROUTER_API_KEY bash -c "CCD_DIR='$CCD_DIR'; $(declare -f have_key); have_key" 2>/dev/null
  then got=usable; else got=unusable; fi
  [ "$got" = "$3" ] && ok "key: $1 → $3" || bad "key: $1" "got $got, want $3"; }
keycase 'empty double quotes'  'OPENROUTER_API_KEY=""'                     unusable
keycase 'empty single quotes'  "OPENROUTER_API_KEY=''"                     unusable
keycase 'commented out'        '# OPENROUTER_API_KEY="sk-or-v1-real"'      unusable
keycase 'whitespace only'      'OPENROUTER_API_KEY="   "'                  unusable
keycase 'bare assignment'      'OPENROUTER_API_KEY='                       unusable
keycase 'real key'             'OPENROUTER_API_KEY="sk-or-v1-real"'        usable
keycase 'export prefix'        'export OPENROUTER_API_KEY="sk-or-v1-real"' usable
keycase 'unquoted'             'OPENROUTER_API_KEY=sk-or-v1-real'          usable

# Arming must not outlive the conditions that justified it: a file left behind by
# an unsupervised session would be consumed by a later launcher.
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$keyfile"
quota 58 96
hf_reset
stopfail sess-h rate_limit | "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
[ ! -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" ] \
  && ok "an unsupervised session never leaves armed state behind" \
  || bad "stale armed handoff" "written without CCD_HANDOFF"

: > "$keyfile"
hf_reset
stopfail sess-i rate_limit | CCD_HANDOFF=1 "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
[ ! -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" ] \
  && ok "no key → nothing is armed either" \
  || bad "armed without a key" "would end the session with nowhere to go"
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$keyfile"

# The headline promise: on recovery the session must actually END, or the return
# trip waits for an unrelated exit that may never come.
cat > "$FAKE/.claude/ccd/run-state.json" <<'EOF'
{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"last_seven_day_percent":97,"last_seven_day_reset":"D1"}
EOF
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"fiveHourReset":"R1","sevenDayPercent":3,"sevenDayReset":"D2"}}\n' > "$FAKE/.claude/ccd/quota-cache.json"
cat > "$FAKE/fakebin/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKE/fakebin/curl"
set +m 2>/dev/null
"$FAKE/sigbin/claude" 8 2>/dev/null & TARGET=$!
sleep 0.3
hf_reset
printf '{"session_id":"sess-r","cwd":"/tmp/w","hook_event_name":"UserPromptSubmit"}' \
  | CCD_ACTIVE=1 CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
sleep 0.6
if kill -0 "$TARGET" 2>/dev/null; then bad "automatic return" "recovery armed but never ended the session"; kill -9 "$TARGET" 2>/dev/null
else ok "quota recovery ends the session so the launcher can return"; fi
wait "$TARGET" 2>/dev/null
[ "$(hf_get direction)" = "to_subscription" ] && ok "recovery arms the return trip" \
  || bad "return direction" "got: $(hf_get direction)"
rm -f "$FAKE/fakebin/curl" "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json"

# A session that ended before its first exchange has no transcript, and
# `--resume` on it fails with "No conversation found". Found by driving the real
# thing under a pty: the handoff worked but landed the user on an error.
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
# Exit 129 the first time so the shim performs a handoff, then 0 so the loop
# ends — without the second launch the relaunch would spin to the hop cap.
fake_real '#!/bin/sh
printf "REAL:%s\n" "$*"
[ -f "$HOME/.been-here" ] && exit 0
: > "$HOME/.been-here"
exit 129'
cat > "$HB/ccd" <<'EOF'
#!/bin/sh
printf "CCD:%s\n" "$*"
EOF
chmod +x "$HB/ccd"
rm -rf "$FAKE/.claude/projects" "$FAKE/.been-here" "$HSTATE"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-new","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>/dev/null)
case "$out" in
  *"CCD:go"*) ok "a session with no transcript starts fresh instead of failing" ;;
  *) bad "no-transcript handoff" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
# With a transcript present it must still resume rather than start over.
mkdir -p "$FAKE/.claude/projects/-tmp"
: > "$FAKE/.claude/projects/-tmp/sess-old.jsonl"
rm -f "$FAKE/.been-here"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-old","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>/dev/null)
case "$out" in
  *"CCD:--resume sess-old"*) ok "an existing transcript is resumed, not discarded" ;;
  *) bad "transcript resume" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
rm -rf "$FAKE/.claude/projects" "$HSTATE"

# The launcher's token goes into a filename it later deletes, so a traversing
# value must be refused rather than reaching rm. Exit 0 here: a refused token
# still mints a random one, and a 129 would pair with whatever ccd stub the
# previous test left behind into a relaunch loop.
fake_real '#!/bin/sh
echo "REAL-RAN"
exit 0'
out=$(PATH="$SHIMPATH" CCD_HANDOFF_TOKEN='../../escape' shim_run "$SHIM" 2>&1)
case "$out" in
  *"invalid CCD_HANDOFF_TOKEN"*) ok "a path-traversing token is refused" ;;
  *) bad "token validation" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac
case "$out" in
  *"REAL-RAN"*) ok "a refused token still launches claude normally" ;;
  *) bad "token refusal strands the user" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac
[ ! -e "$FAKE/.claude/handoff-.json" ] && [ ! -e "$FAKE/handoff-.json" ] \
  && ok "no state file is created outside the ccd directory" \
  || bad "token traversal" "a file escaped ~/.claude/ccd"

# An over-long token passes a character-class check but names a file the write
# cannot create. Signalling against state that was never written is exactly the
# "session dies and never comes back" failure, so the shape check is on length too.
long=$(printf 'a%.0s' $(seq 1 300))
out=$(PATH="$SHIMPATH" CCD_HANDOFF_TOKEN="$long" shim_run "$SHIM" 2>&1)
case "$out" in
  *"invalid CCD_HANDOFF_TOKEN"*) ok "an over-long token is refused" ;;
  *) bad "token length check" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac
# A wrong-length token must not satisfy the interlock either.
eval "$(sed -n '/^launcher_present()/,/^}/p' "$ROOT/scripts/quota-guard.sh")"
CCD_DIR="$FAKE/.claude/ccd"
if CCD_HANDOFF=abc CCD_HANDOFF_STATE="$CCD_DIR/handoff-abc.json" launcher_present 2>/dev/null
then bad "short token accepted" "a token of the wrong shape satisfies the interlock"
else ok "a token of the wrong length is refused"; fi

# The hook must not signal when the state write fails. Point the state at a path
# whose parent directory does not exist: that fails for root too, unlike chmod,
# which the container tests run as root and would ignore.
quota 58 96
set +m 2>/dev/null
"$FAKE/sigbin/claude" 8 2>/dev/null & TARGET=$!
sleep 0.3
# CCD_DIR moves with HOME, so a HOME whose ccd directory is missing makes the
# state write fail while the contract still matches — no production knob needed.
BROKEN="$FAKE/broken-home"
mkdir -p "$BROKEN/.claude"     # deliberately no ccd/ subdirectory
cp -R "$FAKE/.claude/ccd" "$BROKEN/.claude/ccd-backup" 2>/dev/null || true
stopfail sess-w rate_limit | HOME="$BROKEN" CCD_HANDOFF=00000000000000000000000000000002 \
  CCD_HANDOFF_STATE="$BROKEN/.claude/ccd/handoff-00000000000000000000000000000002.json" \
  CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
sleep 0.5
if kill -0 "$TARGET" 2>/dev/null; then ok "a failed state write means no signal"
else bad "signalled without state" "the session would never come back"; fi
kill -9 "$TARGET" 2>/dev/null; wait "$TARGET" 2>/dev/null

# CCD_HANDOFF alone must not satisfy the interlock: `CCD_HANDOFF=x claude` would
# otherwise end a session with no launcher waiting to bring it back.
eval "$(sed -n '/^launcher_present()/,/^}/p' "$ROOT/scripts/quota-guard.sh")"
CCD_DIR="$FAKE/.claude/ccd"
if CCD_HANDOFF=x CCD_HANDOFF_STATE= launcher_present 2>/dev/null
then bad "bare CCD_HANDOFF satisfies the interlock" "a session could be stranded"
else ok "a token without its state path is refused"; fi
if CCD_HANDOFF=00000000000000000000000000000003 CCD_HANDOFF_STATE=/tmp/elsewhere.json launcher_present 2>/dev/null
then bad "mismatched state path accepted" "state path is not checked"
else ok "a state path that does not match the token is refused"; fi
if CCD_HANDOFF=00000000000000000000000000000003 CCD_HANDOFF_STATE="$CCD_DIR/handoff-00000000000000000000000000000003.json" launcher_present 2>/dev/null
then ok "the real launcher contract is accepted"
else bad "valid contract refused" "the launcher could never hand off"; fi

# Two sessions running at once must not consume each other's handoff. With one
# shared state file, whichever exits 129 first — for any reason — resumes the
# other's conversation and leaves the signalled session with nothing to bring it
# back. State is per-launcher and token-tagged to make that impossible.
printf '{"armed":true,"token":"000000000000000000000000000000ff","direction":"to_fallback","session_id":"sess-other","cwd":"/tmp","armed_at":1}' \
  > "$FAKE/.claude/ccd/handoff-000000000000000000000000000000ff.json"
rm -f "$HSTATE"
# A plain ccd stub: the earlier loop-cap test left one that exits 129, which
# would pair with this 129 into a relaunch loop rather than a single check.
cat > "$HB/ccd" <<'EOF'
#!/bin/sh
printf "CCD:%s\n" "$*"
EOF
chmod +x "$HB/ccd"
fake_real '#!/bin/sh
printf "REAL:%s\n" "$*"
exit 129'
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>/dev/null)
case "$out" in
  *"CCD:"*) bad "cross-session handoff" "consumed another launcher's state" ;;
  *) ok "another session's handoff is never consumed" ;;
esac
[ -f "$FAKE/.claude/ccd/handoff-000000000000000000000000000000ff.json" ] \
  && ok "the other session's state survives untouched" \
  || bad "cross-session state" "deleted a handoff belonging to another launcher"
rm -f "$FAKE/.claude/ccd/handoff-000000000000000000000000000000ff.json"

# Malformed state must not be guessed at.
fake_real '#!/bin/sh
exit 129'
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"sideways","session_id":"sess-q","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>&1)
case "$out" in
  *"unrecognized handoff direction"*) ok "an unknown direction fails closed" ;;
  *) bad "unknown direction" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac
rm -f "$FAKE/.claude/ccd/handoff.json"

head_ "20. automatic handoff: one launcher, never a nested one"
# The launcher runs the REAL bin/ccd on the fallback leg, and ccd ends by exec'ing
# claude. If that exec resolved through ~/.local/bin/claude, ccd would start a
# SECOND handoff launcher underneath the first — one that inherits ccd's
# OpenRouter environment. Its "return to the subscription" would then hand the
# user a session still pointed at OpenRouter, and the outer hop cap would no
# longer govern the round trip.
#
# The discriminator is the token, not the binary: both layouts eventually reach
# the real claude, but a nested launcher mints a token of its own. These tests
# use the real bin/ccd deliberately — a stub that exits on its own cannot show
# which claude the real one resolves.
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
cp "$ROOT/bin/ccd" "$HB/ccd"; chmod +x "$HB/ccd"
mkdir -p "$FAKE/realbin"
NESTPATH="$FAKE/.claude/ccd/bin:$FAKE/realbin:$PATH"

# Invoked straight from a shell, there is no launcher at all — so the claude ccd
# execs must not have one either.
cat > "$FAKE/realbin/claude" <<'EOF'
#!/bin/sh
echo "REAL-CLAUDE:$*"
echo "TOKEN:${CCD_HANDOFF:-<none>}"
env | grep -E '^(CCD_ACTIVE|ANTHROPIC_BASE_URL)=' | sed 's/=.*/=set/' | sort
EOF
chmod +x "$FAKE/realbin/claude"
out=$(PATH="$NESTPATH" OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$out" in
  *"TOKEN:<none>"*) ok "ccd execs the real claude without minting a launcher" ;;
  *"TOKEN:"*) bad "nested launcher" "ccd bounced through the shim: $(printf '%s' "$out" | grep TOKEN | head -1)" ;;
  *) bad "ccd exec" "never reached the real claude: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
case "$out" in
  *"CCD_ACTIVE=set"*) ok "the fallback leg runs claude with the OpenRouter environment" ;;
  *) bad "fallback environment" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac

# The production path: an armed launcher hands off to the real ccd, which execs
# claude. That claude must still belong to the ORIGINAL launcher — same token,
# same loop, same hop cap governing the round trip.
#
# The token is NOT pinned here: a pinned one would be inherited by a nested
# launcher too and hide the very thing under test. The fake arms the handoff
# with whatever token it was given and reports it on both legs; a nested
# launcher mints its own, so the two legs would disagree.
#
# The fake reports through files rather than stdout: shim_run's pty output is
# interleaved with everything else the real ccd prints on launch.
cat > "$FAKE/realbin/claude" <<'EOF'
#!/bin/sh
[ "$1" = --resume ] && { printf '%s' "${CCD_HANDOFF:-<none>}" > "$HOME/.tok2"; exit 0; }
printf '%s' "${CCD_HANDOFF:-<none>}" > "$HOME/.tok1"
printf '{"armed":true,"token":"%s","direction":"to_fallback","session_id":"sess-n","cwd":"/tmp","armed_at":1}' \
  "${CCD_HANDOFF:-x}" > "${CCD_HANDOFF_STATE:-/dev/null}"
exit 129
EOF
chmod +x "$FAKE/realbin/claude"
mkdir -p "$FAKE/.claude/projects/-tmp"; : > "$FAKE/.claude/projects/-tmp/sess-n.jsonl"
rm -f "$FAKE/.tok1" "$FAKE/.tok2"
PATH="$NESTPATH" OPENROUTER_API_KEY=sk-or-v1-smoketest CCD_HANDOFF_TOKEN= \
  shim_run "$SHIM" >/dev/null 2>&1
tok1=$(cat "$FAKE/.tok1" 2>/dev/null); tok2=$(cat "$FAKE/.tok2" 2>/dev/null)
case "$tok1" in
  ''|'<none>') bad "fallback leg" "the first leg had no launcher token" ;;
  *) case "$tok2" in
       '') bad "fallback leg" "the handed-off session never started" ;;
       "$tok1") ok "the handed-off session stays under the original launcher" ;;
       *) bad "nested launcher" "fallback got a fresh token ($tok1 -> $tok2)" ;;
     esac ;;
esac
rm -f "$FAKE/.claude/ccd"/handoff-*.json "$FAKE/.tok1" "$FAKE/.tok2"

# A headless run has no terminal to relaunch into and no prompt to re-send, so
# it must pass the exit code through with instructions rather than hand the user
# ccd's "exit Claude Code first" refusal.
fake_real '#!/bin/sh
exit 129'
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-n","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$NESTPATH" shim_run "$SHIM" -p hi 2>&1)
case "$out" in
  *"non-interactive run"*"ccd --resume sess-n"*) ok "a headless run is not relaunched, and says how to continue" ;;
  *) bad "headless handoff" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac

# `-p` is not the only way in: Claude Code also goes non-interactive when its
# output is redirected. Relaunching that one lands the user in ccd's no-terminal
# refusal where they expected output, so no pty here — the point is its absence.
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-n","cwd":"/tmp","armed_at":1}' > "$HSTATE"
PATH="$NESTPATH" "$SHIM" hello > "$FAKE/.piped" 2> "$FAKE/.piped-err"
case "$(cat "$FAKE/.piped-err")" in
  *"non-interactive run"*) ok "redirected output counts as headless too" ;;
  *) bad "non-tty handoff" "got: $(tr '\n' ' ' < "$FAKE/.piped-err" | head -c 90)" ;;
esac
rm -f "$HSTATE" "$FAKE/.piped" "$FAKE/.piped-err"

# `ccd off` is the manual counterpart of the recovery leg: real claude, routing
# environment gone, no launcher invented on the way.
cat > "$FAKE/realbin/claude" <<'EOF'
#!/bin/sh
echo "REAL-CLAUDE:$*"
env | grep -E '^(CCD_ACTIVE|ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN)=' | sed 's/=.*/=LEAKED/' | sort
EOF
chmod +x "$FAKE/realbin/claude"
out=$(PATH="$NESTPATH" ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_AUTH_TOKEN=x CCD_ACTIVE=1 \
      "$ROOT/bin/ccd" off 2>/dev/null)
case "$out" in
  *LEAKED*) bad "ccd off" "left the OpenRouter environment in place: $(printf '%s' "$out" | grep LEAKED | tr '\n' ' ')" ;;
  *"REAL-CLAUDE:"*) ok "ccd off returns to a clean subscription environment" ;;
  *) bad "ccd off" "did not reach the real claude: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac

# The recovery relaunch clears the routing environment even if it leaked in — a
# session announcing "구독으로 복귀" while still on OpenRouter is the worst outcome
# this feature can produce.
cat > "$FAKE/realbin/claude" <<'EOF'
#!/bin/sh
[ "$1" = --resume ] && {
  echo "RECOVERED:$*"
  env | grep -E '^(CCD_ACTIVE|ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN)=' | sed 's/=.*/=LEAKED/'
  exit 0
}
exit 129
EOF
chmod +x "$FAKE/realbin/claude"
mkdir -p "$FAKE/.claude/projects/-tmp"; : > "$FAKE/.claude/projects/-tmp/sess-r.jsonl"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_subscription","session_id":"sess-r","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$NESTPATH" CCD_HANDOFF_TOKEN=00000000000000000000000000000001 \
      ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_AUTH_TOKEN=x CCD_ACTIVE=1 \
      shim_run "$SHIM" 2>/dev/null)
case "$out" in
  *LEAKED*) bad "recovery environment" "relaunched on the subscription still pointed at OpenRouter" ;;
  *"RECOVERED:--resume sess-r"*) ok "recovery relaunch clears the OpenRouter environment" ;;
  *) bad "recovery relaunch" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
rm -f "$FAKE/.claude/ccd"/handoff-*.json
"$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1

head_ "21. multi-account: the store"
# Every credential operation stays inside $HOME. Without this the suite would
# overwrite the developer's real Claude login on macOS.
export CCD_CREDENTIALS_BACKEND=file
# No test may reach the real network. If one does, fail in ~1s rather than
# stalling for the full timeout on every account.
export CCD_HTTP_TIMEOUT=1
ACCT="$ROOT/bin/ccd-account"
ADIR="$FAKE/.claude/ccd/accounts"
CREDS="$FAKE/.claude/.credentials.json"
rm -rf "$ADIR" "$FAKE/.claude/ccd/accounts-quota.json"

# ── The regression that matters most ────────────────────────────────────────
# Sections 1-20 all ran with no account store at all, which covers the upgrade
# path for existing users. This covers the shape production actually has after an
# update: ccd-account IS installed, but nobody has registered anything. It must
# stay silent, make no network call, and leave the OpenRouter route untouched.
cp "$ACCT" "$HB/ccd-account"; chmod +x "$HB/ccd-account"
"$ACCT" --no-color pick >/dev/null 2>&1 \
  && bad "empty store" "offered an account when none are registered" \
  || ok "an empty store offers nothing, without touching the network"
out=$("$ACCT" --no-color list 2>&1)
case "$out" in
  *"No accounts registered"*) ok "...and says so plainly" ;;
  *) bad "empty store list" "got: $out" ;;
esac
[ -z "$("$ACCT" --no-color keepalive 2>&1)" ] \
  && ok "...and keepalive is a no-op below two accounts" \
  || bad "keepalive" "did something with an empty store"

# A live blob carrying BOTH an account login and account-independent MCP logins.
write_creds() { # $1=token marker
  cat > "$CREDS" <<EOF
{"mcpOAuth":{"notion|abc":{"serverName":"notion","accessToken":"MCP-NOTION"},
 "slack|def":{"serverName":"slack","accessToken":"MCP-SLACK"}},
 "claudeAiOauth":{"accessToken":"AT-$1","refreshToken":"RT-$1",
 "expiresAt":$(( ($(date +%s) + 99999) * 1000 )),"subscriptionType":"max"}}
EOF
}
write_creds one
"$ACCT" --no-color add --name one --label "first@example.com" >/dev/null 2>&1 \
  && ok "add registers the signed-in account" || bad "account add" "failed"

perm=$(python3 -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$ADIR/one.json" 2>/dev/null)
[ "$perm" = "0o600" ] && ok "account files are written 600" || bad "account perms" "got $perm"
dperm=$(python3 -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$ADIR" 2>/dev/null)
[ "$dperm" = "0o700" ] && ok "the account directory is 700" || bad "account dir perms" "got $dperm"

# The same login must never be registered twice under two names: it would look
# like a spare, then hand off to the account that just ran out.
"$ACCT" --no-color add --name dup >/dev/null 2>&1 \
  && bad "duplicate guard" "registered the same login twice" \
  || ok "the same login cannot be registered under a second name"

write_creds two
"$ACCT" --no-color add --name two --label "second@example.com" >/dev/null 2>&1
[ -f "$ADIR/two.json" ] && ok "a second account registers" || bad "second add" "missing"

# ── The regression that must never come back ────────────────────────────────
# A swap replaces ONLY claudeAiOauth. Overwriting the whole blob would log the
# user out of every MCP server on every hop.
"$ACCT" --no-color use one --force >/dev/null 2>&1
python3 - "$CREDS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
mcp = d.get("mcpOAuth") or {}
ok = (mcp.get("notion|abc", {}).get("accessToken") == "MCP-NOTION"
      and mcp.get("slack|def", {}).get("accessToken") == "MCP-SLACK")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && ok "a swap preserves mcpOAuth (Notion/Slack stay logged in)" \
  || bad "surgical merge" "the swap destroyed account-independent OAuth state"

grep -q 'AT-one' "$CREDS" && ok "a swap installs the target account's token" \
  || bad "swap" "the live blob does not carry the target token"
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "one" ] \
  && ok "the active pointer follows the swap" || bad "active pointer" "wrong"

# Swapping away must bank whatever Claude Code rotated in during the session,
# or the outgoing account comes back with a dead refresh token.
python3 - "$CREDS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["claudeAiOauth"]["refreshToken"] = "RT-rotated"      # as a live session would
json.dump(d, open(p, "w"))
PY
"$ACCT" --no-color use two --force >/dev/null 2>&1
grep -q 'RT-rotated' "$ADIR/one.json" \
  && ok "swapping away banks the tokens the live session rotated" \
  || bad "token banking" "rotated refresh token was discarded"

head_ "22. multi-account: identity, not bookkeeping"
# Claude Code records who it is signed in as in ~/.claude.json. That accountUuid
# is the only identifier that survives token rotation, so it — not ccd's own
# pointer — is what decides which account a session belongs to.
set_identity() { # $1=uuid $2=email $3=profileFetchedAt(ms)
  printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"%s","profileFetchedAt":%s}}\n' \
    "$1" "$2" "$3" > "$FAKE/.claude.json"
}
rm -rf "$ADIR" "$FAKE/.claude/ccd/accounts-quota.json" "$FAKE/.claude.json"

NOWMS=$(( $(date +%s) * 1000 ))
set_identity uuid-A a@example.com "$NOWMS"
write_creds A
"$ACCT" --no-color add >/dev/null 2>&1
# The email is the obvious name and Claude Code already knows it — nobody should
# have to invent one or type a label.
[ -f "$ADIR/a.json" ] && ok "add names the account from the signed-in email" \
  || bad "auto-name" "expected a.json, got: $(ls "$ADIR" 2>/dev/null | tr '\n' ' ')"
grep -q 'a@example.com' "$ADIR/a.json" && ok "...and labels it with that email" \
  || bad "auto-label" "no email recorded"

set_identity uuid-B b@example.com "$((NOWMS + 1000))"
write_creds B
"$ACCT" --no-color add >/dev/null 2>&1
[ -f "$ADIR/b.json" ] && ok "a second identity registers separately" || bad "second add" "missing"

# Re-running add for an account already known is the normal repair for an expired
# spare. It must update in place, not demand --force or make a duplicate.
"$ACCT" --no-color add >/dev/null 2>&1 \
  && ok "re-adding a known account updates it in place" \
  || bad "re-add" "refused a re-registration of the same account"
[ "$(ls "$ADIR"/*.json | wc -l | tr -d ' ')" = "2" ] \
  && ok "...without creating a duplicate entry" \
  || bad "re-add" "left $(ls "$ADIR"/*.json | wc -l | tr -d ' ') entries"

# ── The UX this replaces ─────────────────────────────────────────────────────
# The user signs in with /login, entirely outside ccd. Nothing may be required of
# them afterwards: ccd notices on its own, because the profile is now newer than
# ccd's last swap and names a different account.
"$ACCT" --no-color use a --force >/dev/null 2>&1
[ "$(cat "$ADIR/.active")" = "a" ] || bad "setup" "swap to a failed"
write_creds B
set_identity uuid-B b@example.com "$(( $(date +%s) * 1000 + 60000 ))"
[ "$("$ACCT" --no-color current)" = "b" ] \
  && ok "a manual /login is detected with no command from the user" \
  || bad "login detection" "still reports $("$ACCT" --no-color current)"
[ "$(cat "$ADIR/.active")" = "b" ] \
  && ok "...and the stale pointer repairs itself" || bad "self-heal" "pointer not updated"

# The mirror image: right after ccd swaps, ~/.claude.json still describes the
# account we just LEFT, because Claude Code only re-reads it on restart. The
# pointer must win there, or the swap would appear to undo itself.
# The profile here was fetched BEFORE the swap — which is the whole point.
set_identity uuid-B b@example.com "$(( ($(date +%s) - 3600) * 1000 ))"
"$ACCT" --no-color use a --force >/dev/null 2>&1
[ "$("$ACCT" --no-color current)" = "a" ] \
  && ok "a profile older than the swap does not override it" \
  || bad "stale profile" "reported $("$ACCT" --no-color current) right after swapping to a"

# Banking the outgoing tokens must follow identity, never the pointer. This is
# the corruption case: signed in as B while the pointer still said A, a swap
# would file B's tokens under A and make "spare" a lie.
write_creds B
set_identity uuid-B b@example.com "$(( $(date +%s) * 1000 + 60000 ))"
python3 - "$CREDS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["refreshToken"] = "RT-B-rotated"
json.dump(d, open(sys.argv[1], "w"))
PY
"$ACCT" --no-color use a --force >/dev/null 2>&1
grep -q 'RT-B-rotated' "$ADIR/b.json" \
  && ok "outgoing tokens are banked under the account that owns them" \
  || bad "banking" "tokens went to the wrong file"
grep -q 'RT-B-rotated' "$ADIR/a.json" \
  && bad "banking" "another account's tokens were written into a.json" \
  || ok "...and never into the account the pointer happened to name"

# Signed into something ccd has never seen: there is no right file to bank into,
# so nothing must be written anywhere.
write_creds Z
set_identity uuid-Z z@example.com "$(( $(date +%s) * 1000 + 120000 ))"
[ -z "$("$ACCT" --no-color current)" ] || [ "$("$ACCT" --no-color current)" = "unknown" ] \
  && ok "an unregistered login resolves to no account" \
  || bad "unknown identity" "claimed $("$ACCT" --no-color current)"
"$ACCT" --no-color use b --force >/dev/null 2>&1
grep -q 'RT-Z' "$ADIR/a.json" "$ADIR/b.json" 2>/dev/null \
  && bad "banking" "an unregistered account's tokens were stored" \
  || ok "...and its tokens are not banked into anyone"

rm -f "$FAKE/.claude.json"     # later sections exercise the no-identity fallback

head_ "23. multi-account: choosing where to go"
seed_quota() { printf '%s' "$1" > "$FAKE/.claude/ccd/accounts-quota.json"; }
NOW=$(date +%s)
q() { printf '"%s":{"status":"ok","checked_at":%s,"five_hour_percent":%s,"seven_day_percent":%s}' "$1" "$NOW" "$2" "$3"; }

# Rebuild the store this section talks about instead of inheriting whatever the
# previous one left. Every account here must also have a seeded quota entry: a
# cache miss makes pick probe for real, and these tokens are fake, so the suite
# would sit through HTTP timeouts while quietly calling Anthropic.
rm -rf "$ADIR"
for n in one two; do write_creds "$n"; "$ACCT" --no-color add --name "$n" >/dev/null 2>&1; done
"$ACCT" --no-color use one --force >/dev/null 2>&1   # 'one' is spent, 'two' is the spare
seed_quota "{$(q one 99 99),$(q two 10 20)}"
[ "$("$ACCT" --no-color pick)" = "two" ] \
  && ok "pick returns the spare with room" || bad "pick" "wrong account"

# The account currently in use is never its own escape route.
seed_quota "{$(q one 10 10),$(q two 10 20)}"
[ "$("$ACCT" --no-color pick)" = "two" ] \
  && ok "the active account is never offered as its own spare" \
  || bad "active exclusion" "picked the account already in use"

# The 7-day window is not optional: an account whose 5h just reset but whose week
# is spent dies again within minutes.
seed_quota "{$(q one 99 99),$(q two 5 99)}"
"$ACCT" --no-color pick >/dev/null 2>&1 \
  && bad "7d gate" "offered an account with a saturated weekly window" \
  || ok "an account with a spent 7-day window is not offered"

# An unreadable account is not an available one. Treating "unknown" as "has room"
# would hand off into a dead end.
seed_quota "{$(q one 99 99),\"two\":{\"status\":\"error\",\"checked_at\":$NOW}}"
"$ACCT" --no-color pick >/dev/null 2>&1 \
  && bad "error handling" "treated an unreadable account as having room" \
  || ok "an unreadable account is never treated as having room"

seed_quota "{$(q one 99 99),\"two\":{\"status\":\"dead\",\"checked_at\":$NOW}}"
"$ACCT" --no-color pick >/dev/null 2>&1 \
  && bad "dead handling" "offered an account that needs re-login" \
  || ok "an account needing re-login is not offered"

# The exclusion list is how the launcher's visited set reaches the picker.
seed_quota "{$(q one 99 99),$(q two 10 20)}"
"$ACCT" --no-color pick --exclude two >/dev/null 2>&1 \
  && bad "exclude" "returned an excluded account" \
  || ok "--exclude removes an account already visited this burst"

# Priority decides, not raw usage: the primary account is preferred while it has
# room, even when a lower-priority one is emptier.
write_creds three
"$ACCT" --no-color add --name three --priority 5 >/dev/null 2>&1
"$ACCT" --no-color use one --force >/dev/null 2>&1
seed_quota "{$(q one 99 99),$(q two 40 40),$(q three 1 1)}"
[ "$("$ACCT" --no-color pick)" = "two" ] \
  && ok "priority wins over lower usage" || bad "priority" "picked by usage instead"

# --no-probe is what the prompt hook uses; it must never open a socket, so stale
# cache entries simply stop counting.
seed_quota "{$(q one 99 99),\"two\":{\"status\":\"ok\",\"checked_at\":1,\"five_hour_percent\":1,\"seven_day_percent\":1}}"
"$ACCT" --no-color pick --no-probe >/dev/null 2>&1 \
  && bad "--no-probe" "used a long-stale cache entry" \
  || ok "--no-probe ignores stale cache instead of reaching for the network"

# Names become filenames. A traversing name must never escape the store.
"$ACCT" --no-color add --name "../../evil" >/dev/null 2>&1 \
  && bad "name validation" "accepted a traversing account name" \
  || ok "a path-traversing account name is refused"

head_ "24. multi-account: handoff to another subscription"
cp "$ACCT" "$HB/ccd-account"; chmod +x "$HB/ccd-account"
mkdir -p "$FAKE/.claude/projects/-tmp"; : > "$FAKE/.claude/projects/-tmp/sess-m.jsonl"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1

# The cheap hop: quota dies, another subscription has room, the conversation
# continues on the subscription backbone with nothing billed.
seed_quota "{$(q one 99 99),$(q two 10 20)}"
"$ACCT" --no-color use one --force >/dev/null 2>&1
fake_real '#!/bin/sh
echo "SUB:$*"
exit 0'
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_account","account":"two","session_id":"sess-m","cwd":"/tmp","armed_at":1}' > "$HSTATE"
cat > "$FAKE/realbin/claude" <<'EOF'
#!/bin/sh
if [ -f "$HOME/.hopped" ]; then echo "SUB2:$*"; exit 0; fi
: > "$HOME/.hopped"
exit 129
EOF
chmod +x "$FAKE/realbin/claude"
rm -f "$FAKE/.hopped"
out=$(PATH="$SHIMPATH" CCD_CREDENTIALS_BACKEND=file shim_run "$SHIM" 2>/dev/null)
case "$out" in
  *"SUB2:--resume sess-m"*) ok "a quota handoff to another account resumes the same conversation" ;;
  *) bad "to_account relaunch" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 110)" ;;
esac
grep -q 'AT-two' "$CREDS" \
  && ok "...on the other account's credentials" || bad "to_account swap" "credentials unchanged"
case "$out" in
  *"무과금"*) ok "...and says plainly that nothing is being billed" ;;
  *) bad "to_account message" "no free-of-charge signal" ;;
esac
rm -f "$HSTATE" "$FAKE/.hopped"

# THE ladder test. Five accounts, every one spent: the run must traverse all of
# them and still reach OpenRouter. A hardcoded hop cap of 3 would have stopped
# this two accounts short of the escape it exists to provide.
for n in a b c d e; do
  write_creds "$n"
  "$ACCT" --no-color add --name "acct$n" >/dev/null 2>&1
done
rm -f "$ADIR/one.json" "$ADIR/two.json" "$ADIR/three.json"
"$ACCT" --no-color use accta --force >/dev/null 2>&1
rm -f "$FAKE/.ladder"
# Each leg arms the next rung; the last one has nowhere left but the fallback.
cat > "$FAKE/realbin/claude" <<'EOF'
#!/bin/sh
n=$(cat "$HOME/.rung" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" > "$HOME/.rung"
printf 'L%s\n' "$n" >> "$HOME/.ladder"
case "$n" in
  1) d='{"armed":true,"token":"00000000000000000000000000000001","direction":"to_account","account":"acctb","session_id":"sess-m","cwd":"/tmp","armed_at":1}' ;;
  2) d='{"armed":true,"token":"00000000000000000000000000000001","direction":"to_account","account":"acctc","session_id":"sess-m","cwd":"/tmp","armed_at":1}' ;;
  3) d='{"armed":true,"token":"00000000000000000000000000000001","direction":"to_account","account":"acctd","session_id":"sess-m","cwd":"/tmp","armed_at":1}' ;;
  4) d='{"armed":true,"token":"00000000000000000000000000000001","direction":"to_account","account":"accte","session_id":"sess-m","cwd":"/tmp","armed_at":1}' ;;
  *) d='{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-m","cwd":"/tmp","armed_at":1}' ;;
esac
printf '%s' "$d" > "$HOME/.claude/ccd/handoff-00000000000000000000000000000001.json"
exit 129
EOF
chmod +x "$FAKE/realbin/claude"
cat > "$HB/ccd" <<'EOF'
#!/bin/sh
printf 'FALLBACK\n' >> "$HOME/.ladder"
exit 0
EOF
chmod +x "$HB/ccd"
rm -f "$FAKE/.rung"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_account","account":"acctb","session_id":"sess-m","cwd":"/tmp","armed_at":1}' > "$HSTATE"
PATH="$SHIMPATH" CCD_CREDENTIALS_BACKEND=file shim_run "$SHIM" >/dev/null 2>&1
rungs=$(grep -c '^L' "$FAKE/.ladder" 2>/dev/null || echo 0)
[ "$rungs" -eq 5 ] \
  && ok "five spent accounts are all traversed (ran $rungs legs)" \
  || bad "ladder length" "expected 5 account legs, ran $rungs"
grep -q FALLBACK "$FAKE/.ladder" \
  && ok "...and the run still reaches OpenRouter at the end" \
  || bad "ladder end" "never reached the final fallback"
rm -f "$HSTATE" "$FAKE/.rung" "$FAKE/.ladder"
"$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
unset CCD_CREDENTIALS_BACKEND

head_ "25. multi-account: a spare must not die in silence"
# The failure this covers happened in production: every keepalive pass failed for
# sixteen days with a 429, the code only reported "dead", and the user met the
# re-login at the moment of the handoff. Nothing here touches the network — the
# refresh endpoint has no shim, and these are the decisions around it.
rm -rf "$ADIR"; mkdir -p "$ADIR"
ka() { HOME="$FAKE" python3 - "$@" <<'PY'
import json, os, sys, time, types
# Grab the arguments before clearing sys.argv: ccd-account parses it at import.
argv = sys.argv[1:]
m = types.ModuleType("m"); sys.argv = ["x"]
src = open(os.environ["ROOT"] + "/bin/ccd-account").read()
exec(compile(src.replace('if __name__ == "__main__":', 'if False:'), "x", "exec"), m.__dict__)
cmd = argv[0] if argv else ""
if cmd == "mk":                       # mk <name> <days since refresh> <rt days left>
    name, ago, left = argv[1], int(argv[2]), int(argv[3])
    n = m.now()
    m.account_save(name, {
        "name": name, "label": name, "priority": 1, "storage": "file",
        "refreshed_at": n - ago * 86400, "added_at": n - ago * 86400,
        "claudeAiOauth": {"accessToken": "a", "refreshToken": "r",
                          "expiresAt": (n - 3600) * 1000,
                          "refreshTokenExpiresAt": int((n + left * 86400) * 1000)}})
elif cmd == "gate":                   # gate <mark content|-> <age seconds>
    content, age = argv[1], int(argv[2])
    if content == "-":
        os.path.exists(m.KEEPALIVE_MARK) and os.unlink(m.KEEPALIVE_MARK)
    else:
        m.write_atomic(m.KEEPALIVE_MARK, content, 0o600)
        t = time.time() - age; os.utime(m.KEEPALIVE_MARK, (t, t))
    due, fails = m.keepalive_due()
    print("due" if due else "wait", fails)
elif cmd == "stale":
    print(json.dumps([s["name"] for s in m.stale_spares()]))
elif cmd == "msg":
    s = m.stale_spares(); print(m.stale_message(s) if s else "")
elif cmd == "breadcrumb":
    m.stale_breadcrumb(m.stale_spares()); print("yes" if os.path.exists(m.STALE_FILE) else "no")
elif cmd == "quiet":                  # park keepalive so hook runs make no network call
    m.write_json(m.KEEPALIVE_MARK, {"fails": 0}, 0o600)
elif cmd == "ua":
    print(m.claude_ua())
elif cmd == "refresh-ua":             # what UA does a token refresh present?
    seen = []
    m._http_json = lambda url, data=None, headers=None, timeout=None: (
        seen.append((headers or {}).get("User-Agent")), (0, None))[1]
    m.token_refresh("tok")
    print(seen[0] if seen else "")
PY
}
export ROOT
ka mk active-acct 0 8; ka mk fresh-spare 1 8; ka mk stale-spare 16 -3
printf 'active-acct\n' > "$ADIR/.active"

[ "$(ka stale)" = '["stale-spare"]' ] \
  && ok "a spare that stopped refreshing is spotted by age, not by error class" \
  || bad "stale detection" "got: $(ka stale)"
ka mk stale-spare 1 8
[ "$(ka stale)" = "[]" ] \
  && ok "...and a spare refreshed yesterday is left alone" \
  || bad "stale detection" "flagged a fresh spare: $(ka stale)"
ka mk active-acct 30 -3
[ "$(ka stale)" = "[]" ] \
  && ok "...and the active account is never reported as a stale spare" \
  || bad "stale detection" "reported the active account: $(ka stale)"
ka mk active-acct 0 8

# The message has to carry urgency, not just a name: how long is left before the
# account needs a human at a browser is the whole basis for acting today or not.
ka mk stale-spare 16 11
# Matched by shape, not by an exact count: the remaining days are floored so the
# warning never overstates the time left, and the boundary is a second wide.
case "$(ka msg)" in
  *[0-9]"d before it needs a re-login"*) ok "the warning says how long is left to recover without a re-login" ;;
  *) bad "stale message" "no deadline: $(ka msg)" ;;
esac
ka mk stale-spare 16 -3
case "$(ka msg)" in
  *"already past re-login"*) ok "...and says plainly when that window has closed" ;;
  *) bad "stale message" "no closed-window wording: $(ka msg)" ;;
esac

# The endpoint's front door throttles unrecognized clients to a trickle — the
# refreshes that starved the reporter's spare for 16 days all died there as 429s.
# These tokens are Claude Code logins on Claude Code's client_id, so the refresh
# must present as that client, at a version, whatever machine it runs on.
case "$(ka refresh-ua)" in
  "claude-cli/"*[0-9].[0-9]*" (external, cli)") ok "a token refresh presents as the client the tokens belong to" ;;
  *) bad "refresh UA" "got: $(ka refresh-ua)" ;;
esac

# A failed pass used to stamp the mark before trying, so one bad window per day
# was the account's entire budget: ~8 all-or-nothing tries in a token's lifetime.
[ "$(ka gate '{"fails":0}' 3600)" = "wait 0" ] \
  && ok "a clean pass holds off for the full day" \
  || bad "keepalive gate" "ran early after success"
[ "$(ka gate '{"fails":1}' 1200)" = "due 1" ] \
  && ok "...but a failed pass is retried in minutes, not tomorrow" \
  || bad "keepalive gate" "a failure still burned the whole interval"
[ "$(ka gate '{"fails":1}' 300)" = "wait 1" ] \
  && ok "...though not so fast that it hammers a refusing endpoint" \
  || bad "keepalive gate" "retried before the backoff elapsed"
[ "$(ka gate '{"fails":5}' 3600)" = "wait 5" ] \
  && ok "...and the backoff widens as failures pile up" \
  || bad "keepalive gate" "no backoff growth"
[ "$(ka gate '{"fails":8}' 90000)" = "due 8" ] \
  && ok "...capped at the daily cadence, never longer" \
  || bad "keepalive gate" "backed off past a day"
# Upgrading installs inherit an empty mark file written by the old code.
[ "$(ka gate '' 3600)" = "wait 0" ] && [ "$(ka gate '' 90000)" = "due 0" ] \
  && ok "an empty mark left by an older ccd still gates correctly" \
  || bad "keepalive gate" "upgrade path misread the old mark"
[ "$(ka gate - 0)" = "due 0" ] \
  && ok "...and a missing mark runs immediately" \
  || bad "keepalive gate" "did not run on first use"

# keepalive is backgrounded with its output discarded, so the warning can only
# reach the user as a breadcrumb the next hook tick picks up.
[ "$(ka breadcrumb)" = "yes" ] \
  && ok "the verdict is left where the hook can find it" \
  || bad "breadcrumb" "keepalive left nothing behind"
# Park keepalive: hook runs below must not fire a background token refresh.
ka quiet
rm -f "$FAKE/.claude/ccd/last-stale-warn"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
case "$out" in
  *stale-spare*"refresh --all"*) ok "...and the prompt hook delivers it, with the recovery command" ;;
  *) bad "stale warning" "got: ${out:-<nothing>}" ;;
esac
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
[ -z "$out" ] \
  && ok "...once, not on every prompt" \
  || bad "stale warning" "repeated inside its cooldown"
rm -f "$FAKE/.claude/ccd/last-stale-warn"
out=$("$ROOT/scripts/quota-guard.sh" PostToolUse < /dev/null 2>/dev/null)
case "$out" in
  *stale-spare*) bad "stale warning" "fired on a tool-use tick" ;;
  *) ok "...and never on a tool-use tick" ;;
esac
ka mk stale-spare 1 8
[ "$(ka breadcrumb)" = "no" ] \
  && ok "recovering the account clears the warning by itself" \
  || bad "breadcrumb" "warning outlived the problem"
# A half-written breadcrumb must not become a hook that emits malformed JSON.
printf '{}' > "$FAKE/.claude/ccd/accounts-stale"
rm -f "$FAKE/.claude/ccd/last-stale-warn"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
[ -z "$out" ] \
  && ok "a breadcrumb with no message says nothing rather than something broken" \
  || bad "stale warning" "emitted from a malformed breadcrumb: $out"
rm -f "$FAKE/.claude/ccd/accounts-stale"

# The hook is killed whenever it outruns its timeout, which used to strand its
# tmp file; eight had accumulated in the reporter's CCD_DIR over four weeks.
QDIR="$FAKE/.claude/ccd"
rm -f "$QDIR/quota-cache.json"
: > "$QDIR/quota-cache.json.tmp.999001"; touch -t 202001010000 "$QDIR/quota-cache.json.tmp.999001"
: > "$QDIR/quota-cache.json.tmp.999002"
"$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null >/dev/null 2>&1
[ ! -e "$QDIR/quota-cache.json.tmp.999001" ] \
  && ok "a tmp file stranded by an earlier hard kill is swept" \
  || bad "tmp sweep" "orphan survived"
[ -e "$QDIR/quota-cache.json.tmp.999002" ] \
  && ok "...while a live sibling's in-flight tmp is left alone" \
  || bad "tmp sweep" "deleted a concurrent instance's tmp"
rm -f "$QDIR"/quota-cache.json.tmp.*
# The trap is what stops the hook from creating new orphans in the first place.
( trap 'rm -f "$QDIR/t.$$"; exit 143' TERM; : > "$QDIR/t.$$"; sleep 5 ) & tp=$!
sleep 1; kill -TERM $tp 2>/dev/null; wait $tp 2>/dev/null
[ -z "$(ls "$QDIR"/t.* 2>/dev/null)" ] \
  && ok "...and a killed hook removes its own tmp on the way out" \
  || bad "tmp trap" "a terminated hook still left its tmp behind"

# The version presented must be the one in use. The native installer leaves old
# and newer directories in its store across up- and downgrades, so the store is
# only a fallback for when no `claude` is on the hook's PATH.
VS="$FAKE/.local/share/claude/versions"; mkdir -p "$VS/9.9.9" "$FAKE/clbin"
: > "$VS/1.2.3"; chmod +x "$VS/1.2.3"; ln -sf "$VS/1.2.3" "$FAKE/clbin/claude"
[ "$(PATH="$FAKE/clbin:$PATH" ka ua)" = "claude-cli/1.2.3 (external, cli)" ] \
  && ok "the UA names the version the claude on PATH actually is" \
  || bad "claude_ua" "got: $(PATH="$FAKE/clbin:$PATH" ka ua)"
# A PATH with python3 and nothing else, so the helper itself still runs.
mkdir -p "$FAKE/pybin"; ln -sf "$(command -v python3)" "$FAKE/pybin/python3"
[ "$(PATH="$FAKE/pybin" ka ua)" = "claude-cli/9.9.9 (external, cli)" ] \
  && ok "...and falls back to the newest in the store only when PATH has none" \
  || bad "claude_ua" "got: $(PATH="$FAKE/pybin" ka ua)"
rm -rf "$VS" "$FAKE/clbin" "$FAKE/pybin"

# The hook fires on each prompt and each tool use, so keepalive passes start
# within the same second. Each must not read a refresh token another is about
# to rotate: a local token endpoint counts what actually arrives.
rm -rf "$ADIR"; mkdir -p "$ADIR"
ka mk active-acct 0 8; ka mk lone-spare 0 8
printf 'active-acct\n' > "$ADIR/.active"
rm -f "$FAKE/.claude/ccd/accounts-keepalive" "$FAKE/.port" "$FAKE/.hits"
# The server is a file, not a heredoc on a backgrounded command: bash 3.2 (the
# macOS CI runner) never started the latter, and its stderr is kept so a CI
# failure says why instead of "never came up".
cat > "$FAKE/tokserver.py" <<'PY'
import http.server, json, os, socketserver, sys, time
port_file, hits = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        time.sleep(1)                      # hold the window open for the race
        with open(hits, "a") as f: f.write("x\n")
        body = json.dumps({"access_token": "a" + str(time.time()),
                           "refresh_token": "r" + str(time.time()),
                           "expires_in": 28800}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
class S(http.server.ThreadingHTTPServer):
    # HTTPServer.server_bind calls socket.getfqdn(), a reverse-DNS lookup that
    # stalls for tens of seconds on the macOS CI runner; the port file then
    # never appears and the test reads as "endpoint never came up".
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]
srv = S(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.replace(port_file + ".tmp", port_file)
srv.serve_forever()
PY
python3 "$FAKE/tokserver.py" "$FAKE/.port" "$FAKE/.hits" </dev/null >/dev/null 2>"$FAKE/tokserver.err" &
srv_pid=$!
# Measured, not assumed: this is the reverse-DNS lookup HTTPServer.server_bind
# performs by default, and the reason the server above skips it. Printed on
# every platform so a CI log shows the number, not a guess.
printf '  · getfqdn(127.0.0.1) on this runner: %s\n' \
  "$(python3 -c 'import socket,time;t=time.time();socket.getfqdn("127.0.0.1");print(f"{time.time()-t:.2f}s")' 2>&1)"
n=0; while [ ! -s "$FAKE/.port" ] && [ $n -lt 75 ]; do sleep 0.2; n=$((n+1)); done
[ -s "$FAKE/.port" ] || bad "keepalive race" "local token endpoint never came up after ${n}00ms; server: $(ps -o stat=,etime= -p "$srv_pid" 2>/dev/null | tr -s ' '); stderr: $(head -c 300 "$FAKE/tokserver.err" 2>/dev/null)"
TOK="http://127.0.0.1:$(cat "$FAKE/.port" 2>/dev/null)/token"
# The suite shortens CCD_HTTP_TIMEOUT elsewhere; the endpoint's deliberate delay
# must not read as a client-side timeout here.
for _ in 1 2 3 4 5; do
  CCD_TOKEN_URL="$TOK" CCD_HTTP_TIMEOUT=10 HOME="$FAKE" "$ACCT" --no-color keepalive >/dev/null 2>&1 &
done; wait $(jobs -p | grep -v "^$srv_pid$") 2>/dev/null
hits=$(grep -c x "$FAKE/.hits" 2>/dev/null || echo 0)
[ "$hits" -eq 1 ] \
  && ok "five keepalive passes at once refresh the spare exactly once (sent $hits)" \
  || bad "keepalive race" "the endpoint saw $hits refreshes for one spare"
python3 - "$FAKE/.claude/ccd/accounts-keepalive" <<'PY' \
  && ok "...and the pass is recorded as clean, not as four rotated-token failures" \
  || bad "keepalive race" "mark: $(cat "$FAKE/.claude/ccd/accounts-keepalive")"
import json, sys; assert json.load(open(sys.argv[1]))["fails"] == 0
PY
kill $srv_pid 2>/dev/null; wait $srv_pid 2>/dev/null; rm -f "$FAKE/.port" "$FAKE/.hits"

# Prompts from several sessions can land together; "at most every four hours"
# has to hold across them, not per process.
ka mk lone-spare 16 -3; ka breadcrumb >/dev/null; ka quiet
rm -f "$FAKE/.claude/ccd/last-stale-warn" "$FAKE"/hook.*
for i in 1 2 3 4 5; do
  "$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null > "$FAKE/hook.$i" 2>/dev/null &
done; wait
emitted=$(cat "$FAKE"/hook.* | grep -c "lone-spare")
[ "$emitted" -eq 1 ] \
  && ok "five simultaneous prompt hooks deliver the warning exactly once" \
  || bad "stale warning race" "$emitted hooks emitted at once"
rm -f "$FAKE"/hook.*

rm -rf "$ADIR" "$FAKE/.claude/ccd/accounts-stale" "$FAKE/.claude/ccd/last-stale-warn" \
       "$FAKE/.claude/ccd/accounts-keepalive"

printf '\n──────────\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
