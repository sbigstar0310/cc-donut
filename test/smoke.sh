#!/usr/bin/env bash
# Portable smoke test — runs the real scripts against a throwaway HOME.
# Intended to run on both macOS and Linux (see test/docker.sh for the Linux run).
# No network, no real key, no writes outside $HOME.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE" 2>/dev/null || true' EXIT
export HOME="$FAKE"
# CLAUDE_CONFIG_DIR outranks HOME everywhere ccd looks, so an inherited one would
# send fixture writes to the developer's real configuration. Cases that test it
# set it themselves. CLAUDE_SECURESTORAGE_CONFIG_DIR outranks both for where
# Claude Code keeps its credential locks, which a swap takes.
unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR
# The suite imports bin/ccd-account as a module; Python would otherwise leave its
# bytecode in bin/, and one such file shipped in v0.8.0 (#77).
export PYTHONDONTWRITEBYTECODE=1

# One reading per account, one file each — the layout bin/ccd-account's reading_save
# writes. Fixtures still think of "the readings" as one dict, so these carry a dict
# to and from that layout; nothing in the product reads one.
RQD="$HOME/.claude/ccd/readings"
rq_put() { # stdin: {"<account>": {row}, ...} — REPLACES every reading on file
  rm -rf "$RQD"; mkdir -p "$RQD"; chmod 700 "$RQD"
  python3 -c '
import json, os, sys
for name, row in json.load(sys.stdin).items():
    p = os.path.join(sys.argv[1], name + ".json")
    with open(p, "w") as f:
        json.dump(row, f)
    os.chmod(p, 0o600)
    # A reading is written when it is taken, so its file is as old as it is. Fixtures
    # that seed an OLD reading would otherwise seed a file that looks brand new.
    ts = row.get("checked_at") if isinstance(row, dict) else None
    if isinstance(ts, (int, float)):
        os.utime(p, (ts, ts))' "$RQD"
}
rq_gather() { # every reading as one dict, in a temp file; prints its path
  python3 -c '
import glob, json, os, sys, tempfile
d = {}
for p in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try: d[os.path.basename(p)[:-5]] = json.load(open(p))
    except Exception: pass
fd, t = tempfile.mkstemp(prefix="rq.", suffix=".json", dir=os.environ["HOME"])
with os.fdopen(fd, "w") as f:
    json.dump(d, f)
print(t)' "$RQD"
}
rq_scatter() { # $1=that file, possibly edited → back to one file per account
  [ -f "$1" ] || return 0
  rq_put < "$1"; rm -f "$1"
}
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

# Every credential operation stays inside $HOME. The keychain is the one thing
# ccd touches outside it, so without this the suite reads (and could overwrite)
# the developer's real Claude login on macOS. It belongs at the top: `ccd doctor`
# lists accounts long before the multi-account sections start.
export CCD_CREDENTIALS_BACKEND=file

# A key exported in the developer's own shell is not this suite's key. It reaches
# have_key() ahead of the throwaway HOME, and the assertions that a missing key
# must stop a handoff then measure the developer's environment instead of the
# code. Those passed in CI and failed only on the machine of whoever set a key.
unset OPENROUTER_API_KEY 2>/dev/null || true

pass=0 fail=0

ok()   { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
head_() { printf '\n%s\n' "$1"; }

# The paid hop bills, so it is gated on an opt-in that `ccd setup --auto` records,
# while the free hop between subscriptions is not gated at all. Most sections here
# are about thresholds, corroboration and signalling rather than about consent, so
# they run on a machine where that question is already settled. The sections that
# ARE about the gate turn it off explicitly and say so.
paid_optin_on()  { : > "$HOME/.claude/ccd/paid-handoff"; }
paid_optin_off() { rm -f "$HOME/.claude/ccd/paid-handoff"; }

# A fake `node` so we don't need a real one: it prints the JSON we stage.
mkdir -p "$FAKE/fakebin"
cat > "$FAKE/fakebin/node" <<'EOF'
#!/bin/sh
cat "$HOME/.stub-usage.json"
EOF
chmod +x "$FAKE/fakebin/node"
export PATH="$FAKE/fakebin:$PATH"
# No case may reach the network, and "there is no fake on PATH" is how one does:
# the real curl is right behind it. So a REJECTING curl is always there, and a
# section that needs an answer stages its own over it and puts this one back.
curl_reject() {
  printf '#!/bin/sh\necho "$*" >> "$HOME/.unstaged-curl"\necho "curl: unstaged network call in the test suite" >&2\nexit 7\n' \
    > "$FAKE/fakebin/curl"
  chmod +x "$FAKE/fakebin/curl"
}
curl_reject
# A stand-in for the Anthropic usage endpoint. ccd-account reaches it with urllib
# rather than curl, so the double goes in as a sitecustomize module on PYTHONPATH.
# It is inert unless CCD_FAKE_USAGE names a staged response, which is what keeps
# it out of the way of every other python3 in this suite and keeps production
# free of any test-only branch.
mkdir -p "$FAKE/pysite"
cat > "$FAKE/pysite/sitecustomize.py" <<'SCEOF'
import json, os
_stage = os.environ.get("CCD_FAKE_USAGE")
if _stage:
    import urllib.error, urllib.request

    def _urlopen(req, timeout=None, *a, **k):
        # Count attempts, not successes: the backoff assertion needs to see the
        # call that failed. The timeout each call was given rides along: a budget
        # that never reaches the socket is a budget that bounds nothing.
        log = os.environ.get("CCD_FAKE_USAGE_LOG")
        if log:
            with open(log, "a") as f:
                f.write(f"call\t{timeout}\n")
        with open(_stage) as f:
            staged = json.load(f)
        # One answer for everybody is not enough any more: the wall re-reads the
        # live account and then the swap probes a spare, in the same run. An answer
        # staged for a bearer token wins over the default one.
        _auth = ""
        try:
            _auth = (req.get_header("Authorization") or "").replace("Bearer ", "")
        except Exception:
            pass
        staged = dict(staged, **(staged.get("by_token") or {}).get(_auth, {}))
        # A slow endpoint, and one that honours the caller's bound the way a
        # socket would: past it the call fails rather than running on.
        delay = staged.get("delay") or 0
        if delay:
            import time as _t
            if timeout is not None and delay > timeout:
                _t.sleep(timeout)
                raise urllib.error.URLError("timed out")
            _t.sleep(delay)
        url = getattr(req, "full_url", "") or str(req)
        if "/token" in url and staged.get("token_body") is not None:
            status = staged.get("token_status", 200)
            body = json.dumps(staged["token_body"]).encode()
            if status != 200:
                raise urllib.error.HTTPError(url, status, "staged", {}, None)

            class _T:
                def __init__(self):
                    self.status = status

                def read(self):
                    return body

                def __enter__(self):
                    return self

                def __exit__(self, *e):
                    return False

            return _T()
        status = staged.get("status", 200)
        body = json.dumps(staged.get("body", {})).encode()
        if status != 200:
            raise urllib.error.HTTPError(
                getattr(req, "full_url", ""), status, "staged", {}, None)

        class _R:
            def __init__(self):
                self.status = status

            def read(self):
                return body

            def __enter__(self):
                return self

            def __exit__(self, *e):
                return False

        return _R()

    urllib.request.urlopen = _urlopen
SCEOF
stage_usage() { # $1=5h utilization  $2=7d utilization  [$3=http status] [$4=delay s] [$5=rotated access token]
  python3 - "$STAGE" "$1" "$2" "${3:-200}" "${4:-0}" "${5:-}" <<'SUEOF'
import datetime, json, sys
out, fh, sd, status, delay, rotated = sys.argv[1:7]
fh, sd, status, delay = int(fh), int(sd), int(status), float(delay)
now = datetime.datetime.now(datetime.timezone.utc)
ahead = lambda h: (now + datetime.timedelta(hours=h)).isoformat()
staged = {"status": status, "delay": delay,
          "body": {"five_hour": {"utilization": fh, "resets_at": ahead(2)},
                   "seven_day": {"utilization": sd, "resets_at": ahead(72)}}}
if rotated:
    # A token exchange answers on the same double; a rotation is the one thing
    # that must be seen to happen under a lock rather than beside one.
    staged["token_body"] = {"access_token": rotated, "refresh_token": "RT-" + rotated,
                            "expires_in": 3600}
with open(out, "w") as f:
    json.dump(staged, f)
SUEOF
}
stage_token() { # $1=access token  $2=5h  $3=7d  [$4=http status] — an answer for ONE bearer token
  python3 - "$STAGE" "$1" "$2" "$3" "${4:-200}" <<'STEOF'
import datetime, json, os, sys
out, tok, fh, sd, status = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
now = datetime.datetime.now(datetime.timezone.utc)
ahead = lambda h: (now + datetime.timedelta(hours=h)).isoformat()
d = json.load(open(out)) if os.path.exists(out) else {"status": 500, "body": {}}
d.setdefault("by_token", {})[tok] = {"status": status, "body": {
    "five_hour": {"utilization": fh, "resets_at": ahead(2)}, "seven_day": {"utilization": sd, "resets_at": ahead(72)}}}
json.dump(d, open(out, "w"))
STEOF
}
# What a hook run AT THE WALL needs. It re-reads the account through ccd-account, so
# it needs the real tool and the stand-in endpoint; without them the re-read fails,
# nothing fires, and a case about anything else would pass for that reason alone.
STAGE="$FAKE/.stage-usage.json"
WALLENV=(PYTHONPATH="$FAKE/pysite" CCD_FAKE_USAGE="$STAGE")
# ...and somebody signed in, because the wall measures the LIVE login. Sections that
# are about accounts write their own; this is for the ones that never needed one.
wall_login() { # [$1=home]
  local h="${1:-$FAKE}"; mkdir -p "$h/.claude"
  [ -f "$h/.claude/.credentials.json" ] || printf '{"claudeAiOauth":{"accessToken":"AT-wall","refreshToken":"RT-wall","expiresAt":%s}}\n' \
    "$(( ($(date +%s) + 99999) * 1000 ))" > "$h/.claude/.credentials.json"
}
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
# --yes and an explicit SHELL on both calls: harmless for a bare setup, which asks
# nothing now that the launcher belongs to `--auto`, and they keep this pair honest
# if a prompt ever comes back — a blocked first call would make the second one the
# install rather than a repeat of it.
SHELL=/bin/zsh "$ROOT/bin/ccd" setup --yes >/dev/null 2>&1
[ -x "$FAKE/.local/bin/ccd" ] && ok "launcher installed" || bad "launcher installed"
grep -qF 'bash ~/.claude/ccd/statusline-launcher.sh' "$FAKE/.claude/settings.json" 2>/dev/null && ok "statusLine wired to the ccd path" || bad "statusLine wired"
row=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$row" in *ccd*luna*) ok "ccd statusline row renders" ;; *) bad "statusline row" "got: ${row:0:80}" ;; esac
warn=$(printf '%s' '{"model":{"id":"claude-fable-5"}}' | "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$warn" in *"quota 96%"*) ok "subscription-mode quota warning renders" ;; *) bad "quota warning row" "got: ${warn:0:80}" ;; esac
SHELL=/bin/zsh "$ROOT/bin/ccd" setup --yes >/dev/null 2>&1 \
  && ok "setup is idempotent" || bad "setup idempotent"
"$ROOT/bin/ccd" uninstall --purge >/dev/null 2>&1
[ -d "$FAKE/.claude/ccd" ] && bad "purge removes state" || ok "uninstall --purge removes state"

# Both producers of the live reading round the same way, where the reading is
# published. The dashboard hands over floats and the hook used to truncate them, so
# 99.6 was 99 to the hook and 100 to ccd-account: one account, two answers to "is it
# spent". (Its own HOME: nothing else in the suite should see this reading.)
RND="$FAKE/rounding"; rm -rf "$RND"; mkdir -p "$RND/.claude/ccd" "$RND/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
: > "$RND/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist/check-usage.js"
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58.2,"fiveHourReset":"R1","sevenDayPercent":99.6,"sevenDayReset":"D1"}}\n' > "$RND/.stub-usage.json"
HOME="$RND" CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/scripts/quota-guard.sh" UserPromptSubmit </dev/null >/dev/null 2>&1
got=$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]))["claude"];print(repr(c["fiveHourPercent"]), repr(c["sevenDayPercent"]))' "$RND/.claude/ccd/quota-cache.json" 2>/dev/null)
[ "$got" = "58 100" ] && ok "a dashboard reading of 99.6 is published as 100, as ccd's own producer would" \
  || bad "two rounding rules" "published: ${got:-nothing}"
rm -rf "$RND"

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
curl_reject

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
curl_reject

head_ "16. automatic handoff: arming predicate + hook stdin"
wall_login
mkdir -p "$FAKE/.claude/ccd/providers"
hf_reset() { rm -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json"; }
# Did a signalled stand-in exit within the ceiling? A single sleep turns "was it
# signalled?" into "was it signalled fast enough?", and the answer to the second
# depends on how busy the machine is.
died_within() { # $1=pid  $2=seconds
  local waited=0 ceiling
  ceiling=$(( ${2%%.*} * 10 ))
  while [ "$waited" -lt "$ceiling" ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}
hf_get() { python3 -c "
import json,os,sys
p='$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json'
print(json.load(open(p)).get(sys.argv[1],'') if os.path.exists(p) else '')" "$1" 2>/dev/null; }
# Quota cache the hook reads to corroborate a rate_limit error.
# The reading is staged in the cache AND at the endpoint the wall re-reads. A turn
# that dies on rate_limit decides on a measurement taken then and there, so a case
# that staged only the cache would have its wall re-measured away.
quota() { printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"fiveHourReset":"R1","sevenDayPercent":%s,"sevenDayReset":"D1"}}\n' "$1" "$2" \
            > "$FAKE/.claude/ccd/quota-cache.json"; stage_usage "$1" "$2"; }
# StopFailure payload as Claude Code delivers it.
stopfail() { printf '{"session_id":"%s","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"%s"}' "$1" "$2"; }

# Arming requires the full readiness set, so these run as a supervised session
# would: a launcher marker, a key, and a resolvable claude process. Section 19
# covers what happens when each of those is missing.
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"
paid_optin_on
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
fire_stopfail() { CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" CLAUDE_PID=$ARMPID CCD_STANDIN_PID=$ARMPID CLAUDE_PLUGIN_ROOT="$ROOT" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1; }
arm_run() { stopfail "$1" "$2" | fire_stopfail; }

# rate_limit ALONE is not enough — it can be transient throttling. The dashboard
# reading has to agree, and a missing reading must never arm.
hf_reset; quota 58 100
arm_run sess-a rate_limit
[ "$(hf_get armed)" = "True" ] && ok "rate_limit + 96% arms the handoff" \
  || bad "arming on corroborated rate_limit" "armed=$(hf_get armed)"
[ "$(hf_get direction)" = "to_fallback" ] && ok "armed toward the OpenRouter backbone" \
  || bad "handoff direction" "got: $(hf_get direction)"
[ "$(hf_get session_id)" = "sess-a" ] && ok "session id recorded for --resume" \
  || bad "session id" "got: $(hf_get session_id)"
kill -9 $ARMPID 2>/dev/null; wait $ARMPID 2>/dev/null

# The payload Claude Code really sends, verbatim from an interactive session
# driven into a 429 (2.1.274, #60) — stopfail() paraphrases the shape, this IS
# the shape. Being our own literal it cannot notice a rename upstream; what it
# pins is our end, so the parser cannot drift off the real key again unnoticed.
# Seeds its own readiness set rather than inheriting one.
captured_stopfail() { # $1=session id
  printf '{"session_id":"%s","transcript_path":"/tmp/w/t.jsonl","cwd":"/tmp/w","prompt_id":"42d3d934-7b41-49f6-91a7-f3355451fcd6","effort":{"level":"xhigh"},"hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error: Request rejected (429)"}' "$1"
}
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"
paid_optin_on
"$FAKE/sigbin/claude" 8 2>/dev/null & ARMPID=$!
sleep 0.3
hf_reset; quota 58 100
captured_stopfail sess-real | fire_stopfail
[ "$(hf_get armed)" = "True" ] && ok "the payload Claude Code actually sends arms the handoff" \
  || bad "arming on the real StopFailure payload" "armed=$(hf_get armed)"
[ "$(hf_get session_id)" = "sess-real" ] && ok "...and its session id is the one recorded for --resume" \
  || bad "session id from the real payload" "got: $(hf_get session_id)"
kill -9 $ARMPID 2>/dev/null; wait $ARMPID 2>/dev/null

# No version of Claude Code sends error_type. Reading it as well would let the
# real key rot unnoticed behind a fixture only this suite ever produces.
"$FAKE/sigbin/claude" 8 2>/dev/null & ARMPID=$!
sleep 0.3
hf_reset; quota 58 100
printf '{"session_id":"sess-legacy","cwd":"/tmp/w","hook_event_name":"StopFailure","error_type":"rate_limit"}' \
  | fire_stopfail
[ -z "$(hf_get armed)" ] && ok "the retired error_type key arms nothing" \
  || bad "error_type must not be read" "armed=$(hf_get armed)"
# Positive control. Nothing armed is also what a dead stand-in, a readiness check
# that failed, or a hook that never ran leaves behind — so the assertion above can
# pass while proving nothing. The real payload through the SAME stand-in and the
# SAME fixture must arm: only then was that silence the key being rejected.
hf_reset
captured_stopfail sess-legacy-control | fire_stopfail
[ "$(hf_get armed)" = "True" ] && ok "...on a fixture that arms the moment the key is right" \
  || bad "positive control for the error_type case" "armed=$(hf_get armed)"
kill -9 $ARMPID 2>/dev/null; wait $ARMPID 2>/dev/null

"$FAKE/sigbin/claude" 8 2>/dev/null & ARMPID=$!
sleep 0.3
hf_reset; quota 20 40
arm_run sess-b rate_limit
[ -z "$(hf_get armed)" ] && ok "rate_limit at 40% does not arm (transient throttle)" \
  || bad "must not arm below threshold" "armed=$(hf_get armed)"

hf_reset; quota 58 100
arm_run sess-c overloaded
[ -z "$(hf_get armed)" ] && ok "overloaded does not arm (not a quota problem)" \
  || bad "must not arm on non-rate_limit" "armed=$(hf_get armed)"

# No reading ANYWHERE: a turn that dies on rate_limit takes the reading again, so the
# stand-in dashboard has to be silent too, or this proves nothing about a missing one.
hf_reset; rm -f "$FAKE/.claude/ccd/quota-cache.json"; stage_usage 58 100 500
arm_run sess-d rate_limit
[ -z "$(hf_get armed)" ] && ok "no quota reading does not arm (fails closed)" \
  || bad "must not arm without corroboration" "armed=$(hf_get armed)"
kill -9 $ARMPID 2>/dev/null; wait $ARMPID 2>/dev/null

# The discarded prototype used `timeout 0.5 cat` to read stdin. macOS has no
# timeout(1), so under `set -e` every hook died silently — taking the quota
# warnings with it. Assert the no-stdin path still works.
# Its own clean state: an earlier backstop may have left a note, and a tick shows it.
quota 58 96; rm -f "$FAKE/.claude/ccd/last-warn" "$FAKE/.claude/ccd/swap-note"
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
paid_optin_on
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
quota 58 100

"$FAKE/sigbin/claude" 8 & TARGET=$!
sleep 0.3
hf_reset
stopfail sess-e rate_limit | CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET CLAUDE_PLUGIN_ROOT="$ROOT" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
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
stopfail sess-f rate_limit | CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET CLAUDE_PLUGIN_ROOT="$ROOT" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
if died_within "$TARGET" 5; then ok "CCD_HANDOFF=1 → SIGHUP delivered to the claude process"
else bad "handoff signal" "target survived CCD_HANDOFF=1"; fi
kill -9 "$TARGET" 2>/dev/null; wait "$TARGET" 2>/dev/null

# An armed handoff with no key would end the session with nowhere to go.
: > "$FAKE/.claude/ccd/providers/keys.env"
"$FAKE/sigbin/claude" 8 & TARGET=$!
sleep 0.3
hf_reset
stopfail sess-g rate_limit | CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET CLAUDE_PLUGIN_ROOT="$ROOT" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
sleep 0.4
if kill -0 "$TARGET" 2>/dev/null; then ok "missing OpenRouter key → no signal (fails closed)"
else bad "signalled without a key" "target died with no fallback available"; fi
kill -9 "$TARGET" 2>/dev/null; wait "$TARGET" 2>/dev/null
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"
paid_optin_on

head_ "17b. the statusline never waits on the dashboard"
# ccd renders the dashboard's rows above its own by running it as a child. That
# child is usually instant, but it refreshes its usage reading on its own schedule,
# and one reported host measured 11s for that refresh: naming the Codex model
# shells out to `codex exec` under a 10s timeout of its own. Waiting for that on
# the render path froze the whole statusline and — when the wait lost the race, as
# it always did at a 10s watchdog — blanked the dashboard's rows. Alternating
# between the two is the flicker in #9. So the render never runs the dashboard at
# all now: it reads the row it cached and hands the refresh to a background job.
# Nothing Claude Code waits on can be made slow by another plugin's provider call.
DASH_DIST="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
mkdir -p "$DASH_DIST"; : > "$DASH_DIST/index.js"
cp "$FAKE/fakebin/node" "$FAKE/node.real"
dash_node() { cat > "$FAKE/fakebin/node"; chmod +x "$FAKE/fakebin/node"; }
# Move the file into the past rather than the clock into the future: production
# only ever compares against a real now.
age_file() { python3 -c "import os,sys,time;t=time.time()-float(sys.argv[2]);os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
render() { printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | env CCD_ACTIVE=1 "$@" "$ROOT/bin/ccd-statusline" 2>/dev/null; }
dash_reap() { pkill -f "$FAKE/fakebin/node" 2>/dev/null; true; }
# Refreshers are backgrounded copies of ccd-statusline, and its path is shared with
# any real session rendering from this same checkout. Narrow to what appeared since
# a snapshot rather than signalling everything the pattern matches. That is not
# proof of ownership — a real refresher starting inside the same window would be
# caught too — but it keeps the blast radius to this checkout and this moment.
dash_refreshers() { pgrep -f "$ROOT/bin/ccd-statusline" 2>/dev/null | tr '\n' ' '; }
dash_started_since() { # $1 = a dash_refreshers snapshot taken before the render
  local pid
  for pid in $(dash_refreshers); do
    case " $1 " in *" $pid "*) ;; *) printf '%s ' "$pid" ;; esac
  done
}
# Fail closed. Where pgrep is missing every assertion that counts processes counts
# zero and passes on nothing — which is how debian:stable-slim ran this suite until
# test/docker.sh started installing procps.
for dash_tool in pgrep pkill; do
  command -v "$dash_tool" >/dev/null 2>&1 \
    || bad "test environment" "$dash_tool is missing: the process assertions below cannot run"
done
dash_wait() { # $1=needle — a background refresh is done when its row lands
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q "$1" "$FAKE/.claude/ccd/.dashboard-row" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

# The exact shape of #9: a row past its refresh age and a dashboard slower than any
# watchdog we would set. The render must neither wait for it nor drop its rows.
dash_node <<'EOF'
#!/bin/sh
sleep 30
echo "SLOW-ROW"
EOF
printf 'CACHED-DASHBOARD-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
sl_start=$(date +%s)
row=$(render)
sl_elapsed=$(( $(date +%s) - sl_start ))
[ "$sl_elapsed" -le 2 ] \
  && ok "a stalled dashboard does not hold up the statusline (${sl_elapsed}s)" \
  || bad "statusline latency" "waited ${sl_elapsed}s for the dashboard"
case "$row" in
  *"CACHED-DASHBOARD-ROW"*) ok "...and its rows stay on screen while it refreshes" ;;
  *) bad "statusline" "blanked the dashboard rows: $(printf '%s' "$row" | head -c 70)" ;;
esac
case "$row" in
  *"ccd"*) ok "and the ccd row is still rendered alongside them" ;;
  *) bad "statusline" "no ccd row" ;;
esac
# A statusline renders on every prompt and tool call. Without single-flight, a
# stalled dashboard would leave a new `node` behind on each render, and two that
# finished out of order would let the older row win.
for _ in 1 2 3 4 5 6 7 8 9; do render >/dev/null; done
sleep 1
children=$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null | wc -l | tr -d ' ')
[ "${children:-0}" -le 1 ] \
  && ok "ten renders against a stalled dashboard leave at most one child ($children)" \
  || bad "statusline fan-out" "$children dashboard children alive"
[ -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "the refresh holds a lock while it runs" || bad "single-flight" "no lock"

# A child that hangs must not outlive the row it was fetched for.
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_reap
render CCD_DASH_TIMEOUT=1 >/dev/null
sleep 3
[ "$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && ok "a hung dashboard child is killed by the watchdog" \
  || bad "watchdog" "child survived its timeout"
[ ! -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "...and the lock is released with it" || bad "watchdog" "lock leaked"
# The kill that leaks is not the watchdog's, though — it is the render's whole
# process group going away with the terminal, mid-refresh. A refresh that dies that
# way still has to clean up after itself.
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
dash_node <<'EOF'
#!/bin/sh
sleep 30
EOF
dash_before=$(dash_refreshers)
render >/dev/null
sleep 1
for dash_pid in $(dash_started_since "$dash_before"); do kill -TERM "$dash_pid" 2>/dev/null; done
sleep 1
[ -z "$(ls "$FAKE/.claude/ccd"/.dashboard-row.?????? 2>/dev/null)" ] \
  && ok "a refresher killed by a signal takes its temp file with it" \
  || bad "signal cleanup" "temp left behind"
[ ! -d "$FAKE/.claude/ccd/.dashboard-row.lock" ] \
  && ok "...and releases its lock on the way out" || bad "signal cleanup" "lock leaked"
[ -z "$(pgrep -f "$FAKE/fakebin/node" 2>/dev/null)" ] \
  && ok "...and does not leave an unsupervised dashboard running behind it" \
  || bad "signal cleanup" "dashboard survived the refresher that owned it"
dash_reap
# Killed refreshers used to leave their half-written temp behind — one report had
# 203 of them, 194 empty. Whatever the kill, the next refresh sweeps the debris.
: > "$FAKE/.claude/ccd/.dashboard-row.ZZleak"
age_file "$FAKE/.claude/ccd/.dashboard-row.ZZleak" 300
[ -e "$FAKE/.claude/ccd/.dashboard-row.ZZleak" ] || bad "temp sweep" "fixture vanished early"

# The refresh the render declined to wait for still has to land, or the row would
# never change again.
dash_node <<'EOF'
#!/bin/sh
echo "REFRESHED-ROW"
EOF
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
render >/dev/null
dash_wait REFRESHED-ROW \
  && ok "the background refresh lands for the next render" \
  || bad "background refresh" "the row never changed"
case "$(render)" in
  *"REFRESHED-ROW"*) ok "...and that render serves it" ;;
  *) bad "background refresh" "the fresh row was not served" ;;
esac
[ ! -e "$FAKE/.claude/ccd/.dashboard-row.ZZleak" ] \
  && ok "a refresh sweeps temp files leaked by killed refreshers" \
  || bad "temp sweep" "leaked temp survived a refresh"

# Nothing cached yet: the render still costs nothing, and the row it could not
# show arrives for the render after it. One row of latency, once, beats a
# statusline that can be frozen by a plugin ccd does not control.
dash_reap
rm -rf "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
sleep 30
echo "NEVER-ARRIVES"
EOF
sl_start=$(date +%s)
row=$(render)
sl_elapsed=$(( $(date +%s) - sl_start ))
[ "$sl_elapsed" -le 2 ] \
  && ok "a hung dashboard with nothing cached costs the render nothing either (${sl_elapsed}s)" \
  || bad "cold path" "waited ${sl_elapsed}s"
case "$row" in
  *"NEVER-ARRIVES"*) bad "cold path" "served output from a child it killed" ;;
  *"ccd"*) ok "...and the ccd row is rendered without the dashboard rows" ;;
  *) bad "cold path" "no row at all: $(printf '%s' "$row" | head -c 60)" ;;
esac
dash_reap
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
echo "FIRST-DASHBOARD-ROW"
EOF
render >/dev/null
dash_wait FIRST-DASHBOARD-ROW \
  && ok "the first render's refresh still fills the cache, so nothing is missing" \
  || bad "cold path" "nothing cached"

# A lock left behind by a killed refresher must not freeze refreshes forever.
mkdir -p "$FAKE/.claude/ccd/.dashboard-row.lock"
python3 -c "import os,sys;os.utime(sys.argv[1], (0, 0))" "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
echo "RECLAIMED-ROW"
EOF
age_file "$FAKE/.claude/ccd/.dashboard-row" 600
render >/dev/null
dash_wait RECLAIMED-ROW \
  && ok "a stale lock is reclaimed instead of blocking refreshes forever" \
  || bad "stale lock" "refresh never ran again"

# Half of what the dashboard draws it computes from the payload of the render that
# ran it: the context bar, the session cost, the burn rate. Refreshing only once a
# row has aged out would freeze those at whatever the last refresh saw, so every
# render kicks one — including a render whose row is seconds old.
printf 'FRESH-ENOUGH-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
dash_node <<'EOF'
#!/bin/sh
echo "TRACKS-THE-PAYLOAD"
EOF
render >/dev/null
dash_wait TRACKS-THE-PAYLOAD \
  && ok "a row seconds old is refreshed anyway, so payload cells keep moving" \
  || bad "refresh cadence" "a fresh row was left alone until it aged out"

# Staleness has a ceiling. Serving a row beats blanking it at almost any age — but
# ccd exists to catch a quota running out, and an hour-old percentage is not a
# stale reading, it is a wrong one.
printf 'ANCIENT-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
python3 -c "import os,sys;os.utime(sys.argv[1], (0, 0))" "$FAKE/.claude/ccd/.dashboard-row"
dash_node <<'EOF'
#!/bin/sh
sleep 30
echo "NEVER-ARRIVES"
EOF
row=$(render)
case "$row" in
  *"ANCIENT-ROW"*) bad "staleness" "served a row with no upper bound on its age" ;;
  *"ccd"*) ok "a row too old to be a reading is dropped rather than shown" ;;
  *) bad "staleness" "got: $(printf '%s' "$row" | head -c 60)" ;;
esac
# A row inside the ceiling but past its refresh age is the opposite call: show it.
printf 'STALE-BUT-USABLE' > "$FAKE/.claude/ccd/.dashboard-row"
age_file "$FAKE/.claude/ccd/.dashboard-row" 900
case "$(render)" in
  *"STALE-BUT-USABLE"*) ok "...while one inside the ceiling is still served" ;;
  *) bad "staleness" "dropped a row it should have served" ;;
esac
dash_reap

# A row dated into the future is a clock skew or a poisoned file, never a fresh
# reading. Trusting the arithmetic would pin the row until wall time caught up.
dash_node <<'EOF'
#!/bin/sh
sleep 30
EOF
printf 'FUTURE-ROW' > "$FAKE/.claude/ccd/.dashboard-row"
age_file "$FAKE/.claude/ccd/.dashboard-row" -86400
row=$(render)
case "$row" in
  *"FUTURE-ROW"*) bad "future mtime" "served a row dated a day ahead" ;;
  *"ccd"*) ok "a row dated into the future is not treated as fresh" ;;
  *) bad "future mtime" "got: $(printf '%s' "$row" | head -c 60)" ;;
esac
# The same arithmetic gates the lock, and a future-dated one would never be reclaimed.
# Let the refresh above finish releasing first: its EXIT trap removes the lock, and
# would remove the one staged here instead.
dash_reap; sleep 1
rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
mkdir -p "$FAKE/.claude/ccd/.dashboard-row.lock"
age_file "$FAKE/.claude/ccd/.dashboard-row.lock" -86400
dash_node <<'EOF'
#!/bin/sh
echo "UNSTUCK-ROW"
EOF
render >/dev/null
dash_wait UNSTUCK-ROW \
  && ok "...and a lock dated into the future is reclaimed, not honoured forever" \
  || bad "future mtime" "refreshes stayed blocked behind it"

# WHICH build gets run. Claude Code never prunes old versions, so the newest
# directory in the cache is not necessarily the one it loaded: an interrupted
# update leaves a version there that was never installed. Resolving it costs a
# python3, which is why only the background refresh may ask.
dash_node <<'EOF'
#!/bin/sh
echo "RAN:$1"
EOF
DASH_CACHE_ROOT="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard"
mkdir -p "$DASH_CACHE_ROOT/9.9.9/dist"; : > "$DASH_CACHE_ROOT/9.9.9/dist/index.js"
ran() { cat "$FAKE/.claude/ccd/.dashboard-row" 2>/dev/null; }
resolve_render() {
  rm -f "$FAKE/.claude/ccd/.dashboard-row"; rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
  render >/dev/null
  dash_wait "RAN:" || bad "build resolution" "no refresh landed at all"
}
# Claude Code never prunes, so 9.9.9 can sit in the cache without ever having been
# installed. Only the registry knows which build actually was.
cat > "$FAKE/.claude/plugins/installed_plugins.json" <<EOF
{"version":2,"plugins":{"claude-dashboard@claude-dashboard":[
 {"scope":"user","installPath":"$DASH_CACHE_ROOT/1.0.0","version":"1.0.0"}]}}
EOF
resolve_render
case "$(ran)" in
  *"/1.0.0/dist/index.js") ok "the installed build is run, not merely the newest in the cache" ;;
  *"/9.9.9/"*) bad "build resolution" "ran a build that was never installed" ;;
  *) bad "build resolution" "ran: $(ran)" ;;
esac
# From 1.32.0 the plugin ships a shim that makes this choice itself. Where one
# exists, running it is running exactly what the plugin's own statusline would.
DASH_SHIM_DIR="$FAKE/.claude/plugins/data/claude-dashboard-claude-dashboard"
mkdir -p "$DASH_SHIM_DIR"; : > "$DASH_SHIM_DIR/statusline.mjs"
resolve_render
case "$(ran)" in
  *"/statusline.mjs") ok "...and the plugin's own shim outranks every record when it is there" ;;
  *) bad "build resolution" "ran: $(ran)" ;;
esac
rm -rf "$DASH_SHIM_DIR" "$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/9.9.9" \
       "$FAKE/.claude/plugins/installed_plugins.json"

# The EXIT trap deletes "$tmp" and signals "$watchdog"/"$node_pid". On a refresh that
# fails before it owns any of them, those names must be empty rather than whatever
# the environment happened to export — otherwise the trap reaches for a stranger's
# file and a stranger's process group. Only meaningful as a non-root user, since the
# containers can write through anything; they skip this one.
if [ "$(id -u)" -ne 0 ]; then
  # dash_present sees a build, dash_resolve finds no version it can name: the
  # refresher exits between the lock and its first resource.
  rm -rf "$DASH_CACHE_ROOT/1.0.0" "$DASH_CACHE_ROOT/9.9.9" \
         "$FAKE/.claude/plugins/installed_plugins.json"
  mkdir -p "$DASH_CACHE_ROOT/not-a-version/dist"; : > "$DASH_CACHE_ROOT/not-a-version/dist/index.js"
  sentinel="$FAKE/not-my-temp"; : > "$sentinel"
  set -m; sleep 3002 & victim=$!; set +m
  rm -rf "$FAKE/.claude/ccd/.dashboard-row.lock"
  printf '%s' '{"model":{"id":"m"}}' \
    | env CCD_ACTIVE=1 tmp="$sentinel" watchdog="$victim" node_pid="$victim" \
          "$ROOT/bin/ccd-statusline" >/dev/null 2>&1
  sleep 1
  [ -e "$sentinel" ] \
    && ok "a refresh that owns no temp file deletes nobody else's" \
    || bad "trap state" "deleted a file named by an inherited \$tmp"
  kill -0 "$victim" 2>/dev/null \
    && ok "...and signals no process group it never started" \
    || bad "trap state" "killed a process named by an inherited \$watchdog/\$node_pid"
  kill -9 "$victim" 2>/dev/null
  rm -rf "$DASH_CACHE_ROOT/not-a-version"
  mkdir -p "$DASH_DIST"; : > "$DASH_DIST/index.js"
fi

cp "$FAKE/node.real" "$FAKE/fakebin/node"; chmod +x "$FAKE/fakebin/node"
rm -rf "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock" "$FAKE/node.real"
unset -f dash_node age_file render dash_wait

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
# The launcher asks the proof again before it relaunches onto the paid backbone.
# This stand-in answers NO unless the launcher cases have switched it on: it sits
# in the plugin cache, which is also where an unrooted hook run looks for
# ccd-account, and a stand-in that vouches for whoever asks hands "proof" to
# sections that never staged any. Switched off again where those cases end.
cat > "$HB/ccd-account" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = exhausted ] && { [ -e "$HOME/.launcher-proof" ] || exit 1; echo every-subscription-measured-spent; exit 0; }; done
exit 0
EOF
chmod +x "$HB/ccd-account"
: > "$FAKE/.launcher-proof"
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

# Consent is checked again here, not only where the hop was armed. The two moments
# are separated by the whole of Claude Code's shutdown, and a `--no-auto` inside
# that window must not be outrun by a hop armed a minute earlier.
rm -f "$FAKE/.claude/ccd/paid-handoff"
: > "$FAKE/.claude/projects/-tmp/sess-revoked.jsonl"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-revoked","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>&1)
case "$out" in
  *CCD-RESUMED*) bad "revoked paid hop" "billed on a permission that was withdrawn" ;;
  *"claude --resume sess-revoked"*) ok "a paid hop whose opt-in was withdrawn does not relaunch" ;;
  *) bad "revoked paid hop" "stopped without saying how to carry on: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
: > "$FAKE/.claude/ccd/paid-handoff"

# ...and so is the proof. Between the hook arming and the launcher relaunching,
# another session can move the store onto an account with room; an order written
# a moment ago is not evidence about now.
rm -f "$FAKE/.launcher-proof"
: > "$FAKE/.claude/projects/-tmp/sess-unproved.jsonl"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-unproved","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>&1)
case "$out" in
  *CCD-RESUMED*) bad "unproved paid hop" "relaunched onto OpenRouter on an order it did not re-check" ;;
  *"claude --resume sess-unproved"*) ok "a paid hop that is no longer proved does not relaunch, and says how to carry on" ;;
  *) bad "unproved paid hop" "stopped without saying how to carry on: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
# ...and the same refusal for a session that never got a transcript must not offer
# a --resume that fails with "No conversation found".
rm -f "$FAKE/.launcher-proof" "$FAKE/.claude/projects/-tmp/sess-blank.jsonl"
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_fallback","session_id":"sess-blank","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$SHIMPATH" shim_run "$SHIM" 2>&1)
case "$out" in
  *CCD-*) bad "unproved paid hop" "relaunched a blank session onto OpenRouter unproved" ;;
  *"--resume"*) bad "resume hint" "offered to resume a conversation that does not exist" ;;
  *"claude"*) ok "...and with no transcript it says to start again, not to resume nothing" ;;
  *) bad "resume hint" "said nothing about carrying on: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
: > "$FAKE/.launcher-proof"

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
  *"off"*"ccd setup"*) ok "doctor: off says how to turn it on" ;;
  *) bad "doctor handoff" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac
# ...but "off" may only ever describe the paid hop. The hop between subscriptions
# happens inside the session, so with nothing installed it is still on — reporting
# it off the launcher's state is how a working escape route reads as a broken one.
case "$out" in
  *"no launcher"*) ok "doctor: the subscription hop is reported working with nothing installed" ;;
  *) bad "doctor handoff" "no launcher, so it claimed there was no hop: $(printf '%s' "$out" | tr '\n' ' ' | head -c 110)" ;;
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

head_ "18c. an install that leaves handoff inert must not report success"
# The failure this section exists for: `ccd setup --auto` ran, wrote the shim, could
# not get the PATH line in, printed "Skipped", and exited 0. Automatic handoff was
# dead for four days while every surface but `ccd doctor` agreed it was fine, and the
# user found out by being stranded at 100% quota with a healthy spare registered.
#
# An install that produced nothing runnable is a failed install. This is the same rule
# 18b already applies to the other direction — "reports the failure instead of claiming
# success" — pointed at install rather than removal.
export SHELL=/bin/zsh
RC="$FAKE/.zshrc"
rm -f "$RC" "$SHIM" "$FAKE/.claude/ccd/auto-path"
printf '# my own file\n' > "$RC"

# No terminal and no --yes: the PATH line is skipped, so nothing can hand off.
# `bare` gives the child no controlling terminal, so the consent branch is reached
# for the reason this test claims. Command substitution alone does not: it redirects
# stdout and leaves /dev/tty open, so on a developer's machine setup would prompt.
python3 - "$FAKE/.claude/settings.json" <<'PYX'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("statusLine", None)          # so the assertion below measures THIS run
json.dump(d, open(p, "w"))
PYX
python3 "$FAKE/ttyask.py" bare none "$FAKE/.ask-out" \
  env HOME="$FAKE" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --auto >/dev/null 2>&1; st=$?
out=$(cat "$FAKE/.ask-out")
[ "$st" -ne 0 ] \
  && ok "a skipped PATH line makes setup exit non-zero (got $st)" \
  || bad "inert install" "exited 0 while automatic handoff was left inert"
case "$out" in
  *"not active"*) ok "...and says so in words" ;;
  *) bad "inert install" "no explanation: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)" ;;
esac
# The remedy has to be a command that actually installs the line. A bare setup
# stopped touching PATH when the launcher became the paid hop's, so advising it
# here sends the user to a command that does nothing about their problem.
case "$out" in
  *"setup --auto --yes"*) ok "...and names a command that would fix it" ;;
  *) bad "inert install" "advised a bare setup, which no longer wires PATH: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
[ -x "$SHIM" ] \
  && ok "...and the shim stays, so --yes can finish what this run started" \
  || bad "inert install" "removed the shim as well"

# Everything else setup does must still happen: the wiring is not all-or-nothing, and
# a non-zero exit that also skipped the statusline would trade one silence for another.
[ "$(python3 -c "
import json;d=json.load(open('$FAKE/.claude/settings.json'))
print('statusline-launcher.sh' in ((d.get('statusLine') or {}).get('command') or ''))")" = "True" ] \
  && ok "...and the rest of setup still ran (statusline wired)" \
  || bad "inert install" "a failed PATH line took the statusline down with it"

# The same run with consent completes, and must not be dragged down with it.
out=$(HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes 2>&1); st=$?
[ "$st" -eq 0 ] \
  && ok "a completed install still exits 0" \
  || bad "completed install" "exited $st: $(printf '%s' "$out" | tr '\n' ' ' | head -c 80)"

# An rc file that cannot be written is the same failure by another route. Only
# meaningful as a non-root user — root writes through a read-only file.
if [ "$(id -u)" -ne 0 ]; then
  rm -f "$FAKE/.claude/ccd/auto-path"
  mkdir -p "$FAKE/rodir"; printf '# theirs\n' > "$FAKE/rodir/.zshrc"
  chmod 400 "$FAKE/rodir/.zshrc"
  out=$(ZDOTDIR="$FAKE/rodir" HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes 2>&1); st=$?
  chmod 600 "$FAKE/rodir/.zshrc"
  [ "$st" -ne 0 ] \
    && ok "an rc file that cannot be written also exits non-zero (got $st)" \
    || bad "unwritable rc" "exited 0 after failing to write the PATH line"
  rm -rf "$FAKE/rodir"
fi

# A line the user added by hand carries no marker of ours, so we cannot claim it —
# but the wiring is done and a new terminal is all that is missing. Declining to add
# a second copy of it is not a failed install.
rm -f "$SHIM" "$FAKE/.claude/ccd/auto-path"
printf '# my own file\nexport PATH="$HOME/.claude/ccd/bin:$PATH"\n' > "$RC"
python3 "$FAKE/ttyask.py" bare none "$FAKE/.ask-out" \
  env HOME="$FAKE" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --auto >/dev/null 2>&1; st=$?
[ "$st" -eq 0 ] \
  && ok "an export already in the file is not reported as a failed install" \
  || bad "already wired" "exited $st although the PATH line was already there"
[ "$(grep -c 'ccd/bin:\$PATH' "$RC")" = "1" ] \
  && ok "...and no second copy of the line is added" \
  || bad "already wired" "line count is now $(grep -c 'ccd/bin:\$PATH' "$RC")"
grep -q 'ccd-auto-handoff-path' "$RC" \
  && bad "already wired" "claimed a line the user wrote by adding our marker" \
  || ok "...and their line is still theirs, unmarked"

# A bare `ccd setup` has no launcher to leave unreachable — the hop it sets up runs
# inside the session — so the inert install this section is about cannot happen to
# it. What must hold instead is that it succeeds with no terminal to ask at, and
# still wires everything it does own.
rm -f "$RC" "$SHIM" "$FAKE/.claude/ccd/auto-path"; printf '# my own file\n' > "$RC"
python3 "$FAKE/ttyask.py" bare none "$FAKE/.ask-out" \
  env HOME="$FAKE" SHELL=/bin/zsh "$ROOT/bin/ccd" setup >/dev/null 2>&1; st=$?
{ [ "$st" -eq 0 ] && [ ! -e "$SHIM" ] \
  && [ "$(grep -c 'ccd-auto-handoff-path' "$RC")" = "0" ]; } \
  && ok "a bare setup with nowhere to prompt is still a complete install" \
  || bad "bare setup" "exited $st with shim=$([ -e "$SHIM" ] && echo yes || echo no)"
[ "$(python3 -c "
import json;d=json.load(open('$FAKE/.claude/settings.json'))
print('statusline-launcher.sh' in ((d.get('statusLine') or {}).get('command') or ''))")" = "True" ] \
  && ok "...with the statusline it does own still wired" \
  || bad "bare setup" "left the statusline unwired"

# Turning the feature off on purpose is not a failure.
rm -f "$RC"; printf '# my own file\n' > "$RC"
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1; st=$?
[ "$st" -eq 0 ] && ok "--no-auto exits 0" || bad "--no-auto" "exited $st"
rm -f "$RC" "$FAKE/.claude/ccd/auto-path"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1


head_ "18d. --auto is the opt-in for the paid hop, and only for that"
# The free hop between registered subscriptions costs nothing and is what the
# product promises; the hop to OpenRouter spends the user's money. One flag used to
# stand for both. `--auto` now records consent for the paid one, and the launcher
# it installs carries the free one on its own.
rm -f "$RC"; printf '# my own file\n' > "$RC"
rm -f "$FAKE/.claude/ccd/paid-handoff" "$FAKE/.claude/ccd/auto-path"
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
[ -f "$FAKE/.claude/ccd/paid-handoff" ] \
  && ok "--auto records the paid-hop opt-in" \
  || bad "paid opt-in" "setup --auto left no record of consent"

HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ ! -f "$FAKE/.claude/ccd/paid-handoff" ] \
  && ok "--no-auto takes it back" \
  || bad "paid opt-in" "consent survived --no-auto"

# Consent must not be re-granted by a run that never asked for it. A bare setup
# installs neither the launcher nor the opt-in, so it must leave this alone in
# both directions.
HOME="$FAKE" "$ROOT/bin/ccd" setup >/dev/null 2>&1
[ ! -f "$FAKE/.claude/ccd/paid-handoff" ] \
  && ok "a bare setup does not grant it" \
  || bad "paid opt-in" "a bare setup opted the user into billing"
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
HOME="$FAKE" "$ROOT/bin/ccd" setup >/dev/null 2>&1
[ -f "$FAKE/.claude/ccd/paid-handoff" ] \
  && ok "...and does not revoke it either" \
  || bad "paid opt-in" "a bare setup revoked consent the user had given"

# Removing ccd removes the consent with it.
HOME="$FAKE" "$ROOT/bin/ccd" uninstall >/dev/null 2>&1
[ ! -f "$FAKE/.claude/ccd/paid-handoff" ] \
  && ok "uninstall removes it" || bad "paid opt-in" "left behind by uninstall"

# It has to be legible somewhere. `ccd doctor` is where the handoff already
# explains itself, and the two hops now have different answers.
rm -f "$RC"; printf '# my own file\n' > "$RC"
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
out=$(HOME="$FAKE" "$ROOT/bin/ccd" doctor 2>&1)
# "OpenRouter" alone is not enough: doctor names it in the key section too, so that
# string was green before this line existed. Match the state, not the word.
case "$out" in
  *"OpenRouter hop allowed"*) ok "doctor says where the paid hop stands" ;;
  *) bad "doctor paid hop" "no mention: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
rm -f "$FAKE/.claude/ccd/paid-handoff"
out=$(HOME="$FAKE" "$ROOT/bin/ccd" doctor 2>&1)
case "$out" in
  *"ccd setup --auto"*) ok "...and how to turn it on when it is off" ;;
  *) bad "doctor paid hop" "no remedy: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
# The status screen makes a promise about where a session goes. With the paid hop
# off it must not promise OpenRouter, because nothing will take it there.
rm -f "$FAKE/.claude/ccd/paid-handoff"
# SHIMPATH puts the shim ahead of the real claude, which is the branch that makes
# the promise at all — without it status only says "installed, but not active".
out=$(PATH="$SHIMPATH" HOME="$FAKE" "$ROOT/bin/ccd" 2>&1)
case "$out" in
  *"to OpenRouter only when none do"*)
    bad "status promise" "promised a paid hop that is not allowed" ;;
  *"Subscriptions only"*) ok "status promises subscriptions only when the paid hop is off" ;;
  *) bad "status promise" "said neither: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
out=$(PATH="$SHIMPATH" HOME="$FAKE" "$ROOT/bin/ccd" 2>&1)
case "$out" in
  *"to OpenRouter only when none do"*) ok "...and names it once it is allowed" ;;
  *) bad "status promise" "never names the paid hop: $(printf '%s' "$out" | tr '\n' ' ' | head -c 90)" ;;
esac

head_ "18e. the launcher is the paid hop's, and nothing else's"
# The hop between registered subscriptions happens inside the session now (§29):
# the credential ccd writes is the one the next request reads, so nothing is
# relaunched and nothing shadows `claude`. What is left for the launcher is the
# paid OpenRouter hop and the return from it — so it arrives with `--auto`, the
# paid opt-in, and a bare `ccd setup` neither installs it nor edits PATH for it.
export SHELL=/bin/zsh
RC="$FAKE/.zshrc"
HOME="$FAKE" "$ROOT/bin/ccd" uninstall >/dev/null 2>&1
rm -f "$RC" "$SHIM" "$FAKE/.claude/ccd/auto-path" "$FAKE/.claude/ccd/paid-handoff"
printf '# my own file\n' > "$RC"

out=$(HOME="$FAKE" "$ROOT/bin/ccd" setup --yes 2>&1); rc=$?
[ ! -e "$SHIM" ] && ok "a bare setup installs no launcher" \
  || bad "default install" "a bare setup shadowed claude for a hop that needs no launcher"
grep -q 'ccd-auto-handoff-path' "$RC" \
  && bad "default install" "edited PATH for a launcher it did not install" \
  || ok "...and leaves PATH alone"
{ [ "$rc" -eq 0 ] && [ -x "$FAKE/.local/bin/ccd" ] \
  && grep -qF 'bash ~/.claude/ccd/statusline-launcher.sh' "$FAKE/.claude/settings.json"; } \
  && ok "...while still being a complete install that reports success" \
  || bad "default install" "rc=$rc — an install with nothing missing must not fail"
case "$out" in
  *"no restart"*) ok "...saying the subscription hop needs none of it" ;;
  *) bad "default install" "said nothing about the hop that does work: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
# The status screen promises the same thing the install does, and with no launcher
# anywhere it must still promise it — otherwise the one working escape route reads
# as something the user forgot to switch on.
out=$(HOME="$FAKE" "$ROOT/bin/ccd" 2>&1)
case "$out" in
  *"no restart"*) ok "...and \`ccd\` says it too, with no launcher installed" ;;
  *) bad "status" "sent the user to /exit for a hop that needs neither: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac

# The paid road and the permission to take it arrive together.
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
[ -x "$SHIM" ] && ok "--auto installs the launcher that carries the paid hop" \
  || bad "paid install" "no shim after --auto"
grep -qxF 'export PATH="$HOME/.claude/ccd/bin:$PATH"' "$RC" \
  && ok "...and wires it onto PATH" || bad "paid install" "no PATH line"

# --no-auto takes back both halves, so the directory it pointed at is not left on
# PATH after the shim that lived there is gone.
HOME="$FAKE" "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
[ ! -e "$SHIM" ] && ok "--no-auto removes it" || bad "opt-out" "shim survived --no-auto"
grep -q 'ccd-auto-handoff-path' "$RC" \
  && bad "opt-out" "left PATH pointing at a directory it just emptied" \
  || ok "...and takes its PATH line with it"

# Consent is asked on the way through, never remembered from last time.
python3 "$FAKE/ttyask.py" ctty n "$FAKE/.ask-out" \
  env HOME="$FAKE" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --auto >/dev/null 2>&1
grep -q 'ccd-auto-handoff-path' "$RC" \
  && bad "consent" "shadowed claude after the user declined" \
  || ok "a later --auto asks again, and n still means no"
HOME="$FAKE" "$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
grep -qxF 'export PATH="$HOME/.claude/ccd/bin:$PATH"' "$RC" \
  && ok "...and yes wires it" || bad "consent" "y did not wire the PATH line"

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
paid_optin_on
quota 58 100
hf_reset
stopfail sess-h rate_limit | CLAUDE_PLUGIN_ROOT="$ROOT" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
[ ! -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" ] \
  && ok "an unsupervised session never leaves armed state behind" \
  || bad "stale armed handoff" "written without CCD_HANDOFF"

: > "$keyfile"
hf_reset
stopfail sess-i rate_limit | CCD_HANDOFF=1 CLAUDE_PLUGIN_ROOT="$ROOT" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
[ ! -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json" ] \
  && ok "no key → nothing is armed either" \
  || bad "armed without a key" "would end the session with nowhere to go"
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$keyfile"
paid_optin_on

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
if died_within "$TARGET" 5; then ok "quota recovery ends the session so the launcher can return"
else bad "automatic return" "recovery armed but never ended the session"; kill -9 "$TARGET" 2>/dev/null; fi
wait "$TARGET" 2>/dev/null
[ "$(hf_get direction)" = "to_subscription" ] && ok "recovery arms the return trip" \
  || bad "return direction" "got: $(hf_get direction)"
curl_reject; rm -f "$FAKE/.claude/ccd/handoff-00000000000000000000000000000002.json"

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
quota 58 100
set +m 2>/dev/null
"$FAKE/sigbin/claude" 8 2>/dev/null & TARGET=$!
sleep 0.3
# CCD_DIR moves with HOME, so a HOME whose ccd directory is missing makes the
# state write fail while the contract still matches — no production knob needed.
BROKEN="$FAKE/broken-home"
# Everything a paid hop needs IS here — login, key, opt-in, nothing registered — so
# the hook gets as far as recording the order, and that is the step that fails: a
# directory sits where the state file goes, which stops root too. (It used to have
# no ccd/ at all, which also meant no opt-in and no key: nothing was ever going to
# be signalled, and the case passed for that reason.)
rm -rf "$BROKEN"; mkdir -p "$BROKEN/.claude/ccd/providers" "$BROKEN/.claude/ccd/handoff-00000000000000000000000000000002.json"
: > "$BROKEN/.claude/ccd/paid-handoff"
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$BROKEN/.claude/ccd/providers/keys.env"
wall_login "$BROKEN"
stopfail sess-w rate_limit | HOME="$BROKEN" CCD_HANDOFF=00000000000000000000000000000002 \
  CCD_HANDOFF_STATE="$BROKEN/.claude/ccd/handoff-00000000000000000000000000000002.json" \
  CLAUDE_PID=$TARGET CCD_STANDIN_PID=$TARGET CLAUDE_PLUGIN_ROOT="$ROOT" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
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
# A print-mode run has no terminal to come back to. Supervising it only gives it
# a way to be killed: the hook can arm a return, the SIGHUP lands mid-batch, and
# the launcher then discovers it is headless and refuses to relaunch.
out=$(PATH="$NESTPATH" OPENROUTER_API_KEY=sk-or-v1-smoketest "$ROOT/bin/ccd" -p hi 2>/dev/null)
case "$out" in
  *"TOKEN:<none>"*) ok "a print-mode run is never put under a launcher" ;;
  *TOKEN:*) bad "supervised batch" "a batch job got a launcher that can end it: $(printf '%s' "$out" | grep TOKEN | head -1)" ;;
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
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_subscription","session_id":"sess-n","cwd":"/tmp","armed_at":1}' > "$HSTATE"
out=$(PATH="$NESTPATH" shim_run "$SHIM" -p hi 2>&1)
case "$out" in
  *"non-interactive run"*"claude --resume sess-n"*) ok "a headless run is not relaunched, and says how to continue on the subscription" ;;
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

rm -f "$FAKE/.launcher-proof"          # the launcher cases are over; the stand-in vouches for nobody
head_ "21. multi-account: the store"
# No test may reach the real network. If one does, fail in ~1s rather than
# stalling for the full timeout on every account.
export CCD_HTTP_TIMEOUT=1
ACCT="$ROOT/bin/ccd-account"
ADIR="$FAKE/.claude/ccd/accounts"
CREDS="$FAKE/.claude/.credentials.json"
rm -rf "$ADIR" "$RQD"

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
rm -rf "$ADIR" "$RQD" "$FAKE/.claude.json"

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

# ── The command the user must never have to remember ────────────────────────
# A refresh token is single-use. /login mints a new one and ccd's stored snapshot
# dies in that instant, so signing in has to be enough on its own. The rule it
# replaces was "then run `ccd account add --force`" — and forgetting it is
# precisely how a healthy account comes to report `needs re-login`.
#
# Profile timestamps here are REAL: `date`, never `date + minutes`. A profile
# stamped in the future hides the defect these tests exist for — banking that
# works once and then stops, because the pointer self-heal dated ccd's install
# after the login.
#
# What must be moved instead is the INSTALL. In production a swap always predates
# a later /login, but `date +%s` is second-granular while ccd stamps in
# milliseconds, so a swap in the same second looks newer and the gate correctly
# refuses. Age the stamp to model the real ordering.
age_install() {
  python3 - "$ADIR/.active-at" <<'PY'
import sys, time
open(sys.argv[1], "w").write(f"{int((time.time() - 60) * 1000)}\n")
PY
}
"$ACCT" --no-color use a --force >/dev/null 2>&1; age_install
write_creds B-relogin
set_identity uuid-B b@example.com "$(( $(date +%s) * 1000 ))"
"$ACCT" --no-color current >/dev/null 2>&1
grep -q 'RT-B-relogin' "$ADIR/b.json" \
  && ok "a /login to a registered account is banked with no command from the user" \
  || bad "auto-banking" "b.json still holds the token /login had already replaced"
grep -q 'RT-B-relogin' "$ADIR/a.json" \
  && bad "auto-banking" "the new token was filed under the account the pointer named" \
  || ok "...and not under the account the stale pointer still named"

# The half that a future-dated profile concealed. The first command above healed
# the pointer; if that counted as a ccd install, every rotation after it is
# dropped and the account rots again within hours.
write_creds B-rotated-later
"$ACCT" --no-color current >/dev/null 2>&1
grep -q 'RT-B-rotated-later' "$ADIR/b.json" \
  && ok "...and every later rotation is banked too, not just the login" \
  || bad "auto-banking" "the pointer self-heal stopped banking after one pass"
write_creds B-rotated-again
"$ACCT" --no-color list --json >/dev/null 2>&1
grep -q 'RT-B-rotated-again' "$ADIR/b.json" \
  && ok "...on any subcommand, not only the cheap one" \
  || bad "auto-banking" "banking is wired to one command instead of dispatch"

# `add` records who is signed in but installs no credentials, so it must not
# stamp either — stamping dates ccd's "install" after the /login that preceded it
# and kills banking for everything that follows, exactly as the self-heal did.
rm -f "$ADIR/.active-at"
set_identity uuid-B b@example.com "$(( $(date +%s) * 1000 ))"
write_creds B-readded
"$ACCT" --no-color add --name b --force >/dev/null 2>&1
write_creds B-after-add
"$ACCT" --no-color current >/dev/null 2>&1
grep -q 'RT-B-after-add' "$ADIR/b.json" \
  && ok "registering an account leaves later rotations bankable" \
  || bad "auto-banking" "add stamped an install it never performed"

# `use` on the account already signed in used to install the stored copy over a
# fresher live one — repairing an account by throwing away the repair. It only
# bites when banking did not run first, so take the identity away: with no
# profile, active_name() answers from the pointer and banking correctly refuses.
"$ACCT" --no-color use b --force >/dev/null 2>&1
rm -f "$FAKE/.claude.json"                     # every later case sets it again
write_creds B-newest
"$ACCT" --no-color use b --force >/dev/null 2>&1
grep -q 'RT-B-newest' "$CREDS" \
  && ok "switching to the account already active keeps the live token" \
  || bad "self-swap" "a stale stored copy was installed over the live token"
grep -q 'RT-B-newest' "$ADIR/b.json" \
  && ok "...and banks it under that account instead of dropping it" \
  || bad "self-swap" "the rotation was discarded"
grep -q 'MCP-NOTION' "$CREDS" \
  && ok "...and still leaves mcpOAuth alone" || bad "self-swap" "mcpOAuth destroyed"

# Ownership is proven by accountUuid, but the live blob is shared by every Claude
# Code process. A blob already on file under a DIFFERENT account means some other
# session wrote it, so the profile is not describing it.
python3 - "$ADIR/a.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["refreshToken"] = "RT-belongs-to-A"
json.dump(d, open(sys.argv[1], "w"))
PY
python3 - "$CREDS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["refreshToken"] = "RT-belongs-to-A"
json.dump(d, open(sys.argv[1], "w"))
PY
age_install
set_identity uuid-B b@example.com "$(( $(date +%s) * 1000 ))"
"$ACCT" --no-color current >/dev/null 2>&1
grep -q 'RT-belongs-to-A' "$ADIR/b.json" \
  && bad "auto-banking" "filed another account's token under b" \
  || ok "a token already on file under another account is refused"

# Why banking is gated on the profile timestamp. For a window after a swap the
# profile still names the account we LEFT; banking on it would file the incoming
# account's tokens under the outgoing one — the §12.0 corruption, reintroduced.
"$ACCT" --no-color use a --force >/dev/null 2>&1
set_identity uuid-B b@example.com "$(( ($(date +%s) - 3600) * 1000 ))"
python3 - "$CREDS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["refreshToken"] = "RT-must-not-bank"
json.dump(d, open(sys.argv[1], "w"))
PY
"$ACCT" --no-color current >/dev/null 2>&1
grep -q 'RT-must-not-bank' "$ADIR"/*.json \
  && bad "auto-banking" "banked on a profile older than our own swap" \
  || ok "a profile older than the install banks nothing"

# An identical stamp leaves the order undecidable, so a tie is not proof. (A
# MISSING stamp reads as zero and deliberately passes: ccd installed nothing, so
# there is no swap for the profile to be stale against — see §12.0.1.)
python3 - "$ADIR/.active-at" "$FAKE/.claude.json" <<'PY'
import json, sys
stamp = int(json.load(open(sys.argv[2]))["oauthAccount"]["profileFetchedAt"])
open(sys.argv[1], "w").write(f"{stamp}\n")
PY
"$ACCT" --no-color current >/dev/null 2>&1
grep -q 'RT-must-not-bank' "$ADIR"/*.json \
  && bad "auto-banking" "an equal timestamp was accepted as proof" \
  || ok "...and a profile stamped at the very moment of the install banks nothing"

# The same tie reaching the other writer. swap_to banks from active_name(), so if
# that one accepts a tie the profile can name B while the blob still belongs to A,
# and the swap files A's token under B — §12.0 corruption through a second door.
"$ACCT" --no-color use a --force >/dev/null 2>&1
python3 - "$ADIR/.active-at" "$FAKE/.claude.json" <<'PY'
import json, sys
stamp = int(open(sys.argv[1]).read().strip())
json.dump({"oauthAccount": {"accountUuid": "uuid-B", "emailAddress": "b@example.com",
                            "profileFetchedAt": stamp}}, open(sys.argv[2], "w"))
PY
python3 - "$CREDS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["refreshToken"] = "RT-tie-belongs-to-A"
json.dump(d, open(sys.argv[1], "w"))
PY
"$ACCT" --no-color use b --force >/dev/null 2>&1
grep -q 'RT-tie-belongs-to-A' "$ADIR/b.json" \
  && bad "tie" "a tied profile let the swap file A's token under b" \
  || ok "...and a tie does not let a swap bank across accounts either"

# A `dead` verdict is cached for 20 minutes, so it must not outlive the token it
# was measured against — otherwise the account the user just repaired keeps
# reporting `needs re-login` and the /login looks inert. Retired by comparing
# identity rather than by deleting the row, so an unlocked cache writer cannot
# bring it back — the row is judged by which account and which credential it
# describes, not by a second-granular clock. The quota reading itself has to
# survive: it describes the account, not the credential.
"$ACCT" --no-color use b --force >/dev/null 2>&1; age_install
# Capture the credential BEFORE the bank: the seeded verdict has to name the token
# it measured, or the row would be retired merely for lacking a `cred` field.
cred_fp() {
  python3 -c 'import hashlib,json,sys
at = (json.load(open(sys.argv[1])).get("claudeAiOauth") or {}).get("accessToken") or ""
print(hashlib.sha256(at.encode()).hexdigest()[:16])' "$1"
}
acct_uuid() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("account_uuid") or "")' "$1"
}
# A live blob whose access token has already expired, so a verdict about it is
# reached from the clock instead of a probe. Reaching Anthropic from the suite
# with a fake token is a bug in the test, not a pass.
write_creds_expired() {
  cat > "$CREDS" <<EOF
{"mcpOAuth":{"notion|abc":{"serverName":"notion","accessToken":"MCP-NOTION"}},
 "claudeAiOauth":{"accessToken":"AT-$1","refreshToken":"RT-$1",
 "expiresAt":$(( ($(date +%s) - 10) * 1000 ))}}
EOF
}
FP_OLD=$(cred_fp "$ADIR/b.json")
write_creds_expired B-repaired
set_identity uuid-B b@example.com "$(( $(date +%s) * 1000 ))"
"$ACCT" --no-color current >/dev/null 2>&1     # banks, so refreshed_at is now
printf '{"b":{"status":"dead","checked_at":%s,"uuid":"%s","cred":"%s"},"a":{"status":"ok","checked_at":%s,"uuid":"%s","cred":"%s","five_hour_percent":7,"seven_day_percent":8}}' \
  "$(( $(date +%s) - 60 ))" "$(acct_uuid "$ADIR/b.json")" "$FP_OLD" \
  "$(( $(date +%s) - 60 ))" "$(acct_uuid "$ADIR/a.json")" "$(cred_fp "$ADIR/a.json")" \
  | rq_put
out=$("$ACCT" --no-color list --json 2>/dev/null)
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
by = {a["name"]: a for a in d["accounts"]}
# b's `dead` predates the token now on file, so it must have been recomputed —
# `stale` proves that. a's `ok` reading is about the account and must survive.
sys.exit(0 if by["b"]["quota"].get("status") == "stale"
         and by["a"]["quota"].get("five_hour_percent") == 7 else 1)
PY
[ $? -eq 0 ] \
  && ok "a re-login verdict measured against a replaced token is retired" \
  || bad "cache supersession" "stale dead verdict served, or a good reading dropped"

# The other direction: a failure still measured against the token on file has to
# survive, or negative caching is gone and every tick re-probes a dead account.
printf '{"b":{"status":"dead","checked_at":%s,"uuid":"%s","cred":"%s"}}' \
  "$(date +%s)" "$(acct_uuid "$ADIR/b.json")" "$(cred_fp "$ADIR/b.json")" \
  | rq_put
out=$("$ACCT" --no-color list --json 2>/dev/null)
python3 - "$out" <<'PY'
import json, sys
by = {a["name"]: a for a in json.loads(sys.argv[1])["accounts"]}
sys.exit(0 if by["b"]["quota"].get("status") == "dead" else 1)
PY
[ $? -eq 0 ] \
  && ok "...while one still measured against that token keeps its cache entry" \
  || bad "cache supersession" "negative caching was discarded wholesale"

# The statusline resolves identity itself rather than shelling out to
# ccd-account (~50ms per render), so the rule is written twice and the two must
# stay the same rule. A tie accepted in one and refused in the other means they
# disagree about who is signed in — and swap_to banks credentials from that.
grep -q 'fetched > pointer_at()' "$ROOT/bin/ccd-statusline" \
  && grep -q 'fetched_at > _active_at()' "$ROOT/bin/ccd-account" \
  && ok "the statusline mirrors ccd-account's identity rule, ties included" \
  || bad "identity mirror" "the two resolvers disagree on a tied timestamp"
# It reads the quota cache directly too, so the row rule is written twice as well.
grep -q 'def row_valid' "$ROOT/bin/ccd-statusline" \
  && grep -q 'if row_valid(r, accounts.get(n) or {})' "$ROOT/bin/ccd-statusline" \
  && ok "...and validates cached rows before showing anyone's quota" \
  || bad "cache mirror" "the statusline trusts cache rows ccd-account would refuse"

# `--force` can point an existing name at a DIFFERENT account. Its cached quota
# describes the account being replaced, and an `ok` row is exempt from the
# credential check, so it would follow the name onto its successor and offer a
# handoff on somebody else's headroom.
OLD_UUID=$(acct_uuid "$ADIR/b.json")
write_creds_expired C-newowner
set_identity uuid-C c@example.com "$(( $(date +%s) * 1000 ))"
"$ACCT" --no-color add --force --name b >/dev/null 2>&1
# Written back AFTER the re-registration, exactly as a writer holding an older
# copy of the whole cache would. Correctness must not rest on having deleted it.
printf '{"b":{"status":"ok","checked_at":%s,"uuid":"%s","cred":"deadbeefdeadbeef","five_hour_percent":3,"seven_day_percent":4}}' \
  "$(date +%s)" "$OLD_UUID" | rq_put
out=$("$ACCT" --no-color list --json 2>/dev/null)
python3 - "$out" <<'PY'
import json, sys
by = {a["name"]: a for a in json.loads(sys.argv[1])["accounts"]}
sys.exit(0 if by["b"]["quota"].get("five_hour_percent") != 3 else 1)
PY
[ $? -eq 0 ] \
  && ok "quota cached for a replaced account is never used, even if written back" \
  || bad "add cache" "a stale reading followed the name onto a different account"

# The same row reaching `pick --no-probe`, which is where it does the most harm:
# that path hands off on a cached `ok` without opening a socket, so a row left by
# a name that now points elsewhere spends an account whose real quota nobody
# checked. Asserted in both directions, or "offers nothing" proves nothing.
seed_pick_row() { # $1=uuid to claim
  printf '{"a":{"status":"ok","checked_at":%s,"uuid":"%s","cred":"%s","five_hour_percent":1,"seven_day_percent":1}}' \
    "$(date +%s)" "$1" "$(cred_fp "$ADIR/a.json")" | rq_put
}
seed_pick_row "$(acct_uuid "$ADIR/a.json")"
[ "$("$ACCT" --no-color pick --no-probe 2>/dev/null)" = "a" ] \
  && ok "--no-probe offers an account whose cached row still matches it" \
  || bad "no-probe" "a valid cached row was not offered"
seed_pick_row "uuid-SOMEONE-ELSE"
[ -z "$("$ACCT" --no-color pick --no-probe 2>/dev/null)" ] \
  && ok "...and refuses one cached under a different account, without probing" \
  || bad "no-probe" "handed off on quota belonging to another account"

# The same replacement with NO identity to bind to. Claude Code did not always
# publish one, and those accounts store no account_uuid, so the credential has to
# answer for the account as well — otherwise an `ok` row skips every check and the
# quota simply follows the name onto its successor.
python3 - "$ADIR/a.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["account_uuid"] = None
json.dump(d, open(sys.argv[1], "w"))
PY
printf '{"a":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":2,"seven_day_percent":2}}' \
  "$(date +%s)" "$(cred_fp "$ADIR/a.json")" | rq_put
[ "$("$ACCT" --no-color pick --no-probe 2>/dev/null)" = "a" ] \
  && ok "an identity-less account is trusted while its credential still matches" \
  || bad "no-uuid" "a valid row was retired for want of a uuid"
python3 - "$ADIR/a.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["accessToken"] = "AT-different-owner"
json.dump(d, open(sys.argv[1], "w"))
PY
[ -z "$("$ACCT" --no-color pick --no-probe 2>/dev/null)" ] \
  && ok "...and refused once the credential under that name changed hands" \
  || bad "no-uuid" "quota followed a name with no identity to bind it"

# The instruction printed beside a dead account has to be the one that works,
# and must not name ANY follow-up ccd command — that was the whole bug.
# Each row names the token it measured, or supersession retires it and `list`
# probes Anthropic for real with fake credentials — a bug in the test, not a pass.
printf '{"a":{"status":"dead","checked_at":%s,"uuid":"%s","cred":"%s"},"b":{"status":"dead","checked_at":%s,"uuid":"%s","cred":"%s"}}' \
  "$(date +%s)" "$(acct_uuid "$ADIR/a.json")" "$(cred_fp "$ADIR/a.json")" \
  "$(date +%s)" "$(acct_uuid "$ADIR/b.json")" "$(cred_fp "$ADIR/b.json")" \
  | rq_put
out=$("$ACCT" --no-color list 2>&1)
hint=$(printf '%s' "$out" | grep -A2 're-login needed for')
case "$hint" in
  *"ccd account"*|*"--force"*) bad "dead-account hint" "still names a ccd follow-up command" ;;
  *"/login"*) ok "the dead-account hint asks for /login and names no follow-up command" ;;
  *) bad "dead-account hint" "got: $(printf '%s' "$hint" | tr '\n' ' ' | head -c 90)" ;;
esac
rm -rf "$RQD"
rm -f "$FAKE/.claude.json"     # later sections exercise the no-identity fallback

head_ "23. multi-account: choosing where to go"
seed_quota() { printf '%s' "$1" | rq_put; }
NOW=$(date +%s)
# These accounts are registered without an identity, so a cached row is bound to
# the credential alone. Omitting `cred` would retire every row and send `pick`
# to Anthropic with fake tokens.
q() { printf '"%s":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":%s,"seven_day_percent":%s}' \
        "$1" "$NOW" "$(cred_fp "$ADIR/$1.json")" "$2" "$3"; }

# Rebuild the store this section talks about instead of inheriting whatever the
# previous one left. Every account here must also have a seeded quota entry: a
# cache miss makes pick probe for real, and these tokens are fake, so the suite
# would sit through HTTP timeouts while quietly calling Anthropic.
rm -rf "$ADIR"
for n in one two; do write_creds "$n"; "$ACCT" --no-color add --name "$n" >/dev/null 2>&1; done
"$ACCT" --no-color use one --force >/dev/null 2>&1   # 'one' is spent, 'two' is the spare
seed_quota "{$(q one 100 100),$(q two 10 20)}"
[ "$("$ACCT" --no-color pick)" = "two" ] \
  && ok "pick returns the spare with room" || bad "pick" "wrong account"

# ── Nobody should have to type a name ccd already knows ─────────────────────
# Every route into a handoff picks the destination itself; the only place a person
# supplied it was the one they typed. `use` with no name is that route for people.
"$ACCT" --no-color use one --force >/dev/null 2>&1
seed_quota "{$(q one 100 100),$(q two 10 20)}"
out=$("$ACCT" --no-color use 2>&1); rc=$?
# The pointer alone is not a swap: a move that updates `.active` without installing
# the target's token leaves the next session authenticating as the spent account.
[ "$rc" -eq 0 ] && [ "$(cat "$ADIR/.active")" = "two" ] && grep -q 'AT-two' "$CREDS" \
  && ok "a bare \`use\` moves to the account a handoff would pick" \
  || bad "bare use" "rc=$rc active=$(cat "$ADIR/.active" 2>/dev/null): $out"
case "$out" in
  *"switched to two"*) ok "...and says which account it chose" ;;
  *) bad "bare use" "did not name the destination: $out" ;;
esac
# The credential, the billing and both rate-limit windows move. The model list, the
# Fable entitlement and the `/status` identity were read once at startup and do not
# (#12) — the one thing about a swap the user should never have to discover alone.
case "$out" in
  *"/status"*"next launch"*) ok "...and what a swap does not move, before it is discovered" ;;
  *) bad "use output" "silent about the half that lags: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac

# Naming one still means that one, even when it is not what pick would choose.
"$ACCT" --no-color use one --force >/dev/null 2>&1
seed_quota "{$(q one 10 10),$(q two 100 100)}"
"$ACCT" --no-color use two --force >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$ADIR/.active")" = "two" ] && grep -q 'AT-two' "$CREDS" \
  && ok "...while a named account is still taken at its word" \
  || bad "bare use" "rc=$rc: an explicit name was overridden or not installed"

# Nowhere to go is an answer, not a swap to something spent — and not a half-swap
# either: the live credentials must still be the ones we came in with.
"$ACCT" --no-color use one --force >/dev/null 2>&1
seed_quota "{$(q one 100 100),$(q two 100 100)}"
out=$("$ACCT" --no-color use 2>&1); rc=$?
[ "$rc" -eq 1 ] && [ "$(cat "$ADIR/.active")" = "one" ] && grep -q 'AT-one' "$CREDS" \
  && ok "...and with every spare spent it stays put and says so" \
  || bad "bare use" "rc=$rc active=$(cat "$ADIR/.active" 2>/dev/null): $out"
case "$out" in
  *room*|*spent*|*exhaust*) ok "...in words that name the reason" ;;
  *) bad "bare use" "gave no reason: $out" ;;
esac

# An empty name is a bad name, not a request to choose one. The difference only
# shows when there IS something to choose, so put a spare back within reach first:
# against an exhausted store both readings refuse, for different reasons.
seed_quota "{$(q one 100 100),$(q two 10 20)}"
out=$("$ACCT" --no-color use "" 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ "$(cat "$ADIR/.active")" = "one" ] \
  && ok "...while an empty name is rejected rather than quietly resolved" \
  || bad "bare use" "rc=$rc: an empty name was treated as 'choose for me': $out"

# The account currently in use is never its own escape route.
seed_quota "{$(q one 10 10),$(q two 10 20)}"
[ "$("$ACCT" --no-color pick)" = "two" ] \
  && ok "the active account is never offered as its own spare" \
  || bad "active exclusion" "picked the account already in use"

# The 7-day window is not optional: an account whose 5h just reset but whose week
# is spent dies again within minutes.
seed_quota "{$(q one 100 100),$(q two 5 100)}"
"$ACCT" --no-color pick >/dev/null 2>&1 \
  && bad "7d gate" "offered an account with a saturated weekly window" \
  || ok "an account with a spent 7-day window is not offered"

# An unreadable account is not an available one. Treating "unknown" as "has room"
# would hand off into a dead end.
seed_quota "{$(q one 100 100),\"two\":{\"status\":\"error\",\"checked_at\":$NOW}}"
"$ACCT" --no-color pick >/dev/null 2>&1 \
  && bad "error handling" "treated an unreadable account as having room" \
  || ok "an unreadable account is never treated as having room"

seed_quota "{$(q one 100 100),\"two\":{\"status\":\"dead\",\"checked_at\":$NOW}}"
"$ACCT" --no-color pick >/dev/null 2>&1 \
  && bad "dead handling" "offered an account that needs re-login" \
  || ok "an account needing re-login is not offered"

# Priority decides, not raw usage: the primary account is preferred while it has
# room, even when a lower-priority one is emptier.
write_creds three
"$ACCT" --no-color add --name three --priority 5 >/dev/null 2>&1
"$ACCT" --no-color use one --force >/dev/null 2>&1
seed_quota "{$(q one 100 100),$(q two 40 40),$(q three 1 1)}"
[ "$("$ACCT" --no-color pick)" = "two" ] \
  && ok "priority wins over lower usage" || bad "priority" "picked by usage instead"
# And a person asking for it gets the same order: with two spares to choose
# between, a bare `use` is the picker, not a shortcut past it.
"$ACCT" --no-color use >/dev/null 2>&1
[ "$(cat "$ADIR/.active")" = "two" ] && grep -q 'AT-two' "$CREDS" \
  && ok "...and a bare \`use\` lands where pick pointed, priority and all" \
  || bad "priority" "a bare use took the emptier spare: $(cat "$ADIR/.active" 2>/dev/null)"
"$ACCT" --no-color use one --force >/dev/null 2>&1   # restore for the checks below

# --no-probe is what the prompt hook uses; it must never open a socket, so stale
# cache entries simply stop counting.
seed_quota "{$(q one 100 100),\"two\":{\"status\":\"ok\",\"checked_at\":1,\"five_hour_percent\":1,\"seven_day_percent\":1}}"
"$ACCT" --no-color pick --no-probe >/dev/null 2>&1 \
  && bad "--no-probe" "used a long-stale cache entry" \
  || ok "--no-probe ignores stale cache instead of reaching for the network"

# Names become filenames. A traversing name must never escape the store.
"$ACCT" --no-color add --name "../../evil" >/dev/null 2>&1 \
  && bad "name validation" "accepted a traversing account name" \
  || ok "a path-traversing account name is refused"

head_ "24. multi-account: the account hop left the launcher"
# Moving to another subscription no longer ends anything (§29), so `to_account` is
# state nothing writes any more and the ladder of accounts it was walked with is
# gone with it. What must not survive the deletion is the reading of it: a stale
# armed file — from an older install, or a hand-written one — must not make the
# launcher install somebody else's credential and relaunch on it.
cp "$ACCT" "$HB/ccd-account"; chmod +x "$HB/ccd-account"
mkdir -p "$FAKE/.claude/projects/-tmp"; : > "$FAKE/.claude/projects/-tmp/sess-m.jsonl"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1

seed_quota "{$(q one 100 100),$(q two 10 20)}"
"$ACCT" --no-color use one --force >/dev/null 2>&1
printf '{"armed":true,"token":"00000000000000000000000000000001","direction":"to_account","account":"two","session_id":"sess-m","cwd":"/tmp","armed_at":1}' > "$HSTATE"
cat > "$FAKE/realbin/claude" <<'EOF'
#!/bin/sh
if [ -f "$HOME/.hopped" ]; then echo "SUB2:$*"; exit 0; fi
: > "$HOME/.hopped"
exit 129
EOF
chmod +x "$FAKE/realbin/claude"
rm -f "$FAKE/.hopped"
out=$(PATH="$SHIMPATH" CCD_CREDENTIALS_BACKEND=file shim_run "$SHIM" 2>&1)
case "$out" in
  *SUB2*) bad "to_account" "the launcher still walks a ladder of accounts" ;;
  *"--resume sess-m"*) ok "an account handoff is a direction the launcher no longer knows" ;;
  *) bad "to_account" "stopped without saying how to carry on: $(printf '%s' "$out" | tr '\n' ' ' | head -c 110)" ;;
esac
grep -q 'AT-one' "$CREDS" \
  && ok "...and it installs no credential on the way out" \
  || bad "to_account" "swapped an account for a direction it refuses to act on"
rm -f "$HSTATE" "$FAKE/.hopped"

# The launcher's per-burst visited set was only ever exported so the hook could
# hand it to the picker as an exclusion list. With no ladder there is nothing to
# exclude, and a variable no writer sets is a variable every reader must lose.
grep -rlF CCD_BURST_VISITED "$ROOT/bin" "$ROOT/scripts" >/dev/null 2>&1 \
  && bad "burst export" "a reader survived the writer" \
  || ok "...and nothing is left reading the ladder's exclusion list"
"$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1

head_ "25. multi-account: a spare must not die in silence"
# The failure this covers happened in production: every keepalive pass failed for
# sixteen days with a 429, the code only reported "dead", and the user met the
# re-login at the moment of the handoff. Nothing here touches the network — the
# refresh endpoint has no shim, and these are the decisions around it.
#
# Nor does anything from here on: a test that wants an endpoint stands one up locally
# and names it, and everything else points at a dead port rather than at Anthropic.
# Relying on a neighbour's probe-backoff marker for that is how a real request slipped
# through before.
export CCD_USAGE_URL="http://127.0.0.1:1/usage" CCD_TOKEN_URL="http://127.0.0.1:1/token"
rm -rf "$ADIR"; mkdir -p "$ADIR"
ka() { HOME="$FAKE" python3 - "$@" <<'PY'
import json, os, sys, time, types
# Grab the arguments before clearing sys.argv: ccd-account parses it at import.
argv = sys.argv[1:]
m = types.ModuleType("m"); sys.argv = ["x"]
# A module loaded from text has no __file__, and the program finds bin/spent-at
# beside itself. Give it the path it would have had.
m.__file__ = os.environ["ROOT"] + "/bin/ccd-account"
src = open(m.__file__).read()
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
elif cmd == "refresh-ok":             # run the real account_refresh, stubbing only HTTP
    # The fixtures carry the refresh token "r", so the exchange cannot succeed
    # against anything real — and a test that reaches the network is a bug in the
    # test. Everything account_refresh does with the result is the code under test.
    name = argv[1]
    m.token_refresh = lambda rt: ({"accessToken": "A2", "refreshToken": "R2",
                                   "expiresAt": int((time.time() + 8 * 3600) * 1000)}, 200)
    acct = m.account_load(name)
    print("ok" if m.account_refresh(name, acct)[0] else "failed")
elif cmd == "quiet":                  # park keepalive so hook runs make no network call
    m.write_json(m.KEEPALIVE_MARK, {"fails": 0}, 0o600)
elif cmd == "warm":                   # ...and park the picker, for the same reason
    # quota_for() serves any row that is valid for the account and inside the TTL
    # without touching the network, so a fresh row per account is what silences the
    # backgrounded `pick` the prompt hook now runs. These accounts carry no uuid, so
    # _cache_row_valid falls back to the credential fingerprint.
    rows = {}
    for name in m.account_names():
        acct = m.account_load(name)
        rows[name] = {"status": "ok", "checked_at": m.now(),
                      "uuid": acct.get("account_uuid"),
                      "cred": m._cred_fingerprint(acct),
                      "five_hour_percent": 5, "seven_day_percent": 5}
    m.quota_cache_save(rows)
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
# ── A refresh that never succeeded is not a refresh ─────────────────────────
# stale_spares() keys on refreshed_at, and bank_live_oauth() and swap_to() both write
# that field on a successful COPY. So every hop reset the staleness clock while the
# refresh path kept failing: on the reporting machine the spare's refreshed_at was
# the exact second of a manual swap, six consecutive keepalive failures were on disk,
# and the warning never fired.
ka mk banked-spare 20 8
python3 - "$ADIR/banked-spare.json" <<'BANKPY'
import json, sys, time
# What banking leaves behind: a fresh refreshed_at against a token nothing has ever
# managed to refresh.
p = sys.argv[1]
d = json.load(open(p))
d["refreshed_at"] = int(time.time())
json.dump(d, open(p, "w"))
BANKPY
case "$(ka stale)" in
  *'"banked-spare"'*) ok "a spare whose token was copied but never refreshed is still stale" ;;
  *) bad "stale detection" "a copy reset the clock: $(ka stale)" ;;
esac

# ...and a refresh that really happened clears it.
ka refresh-ok banked-spare >/dev/null
case "$(ka stale)" in
  *'"banked-spare"'*) bad "stale detection" "a real refresh did not count: $(ka stale)" ;;
  *) ok "...and a refresh that actually succeeded clears it" ;;
esac

# The failure counter is evidence nobody was reading. A manual repair must clear it,
# or the account just proven healthy stays in the backoff keepalive computes from it.
ka_fails() { python3 -c "
import json
try: print((json.load(open('$FAKE/.claude/ccd/accounts-keepalive')) or {}).get('fails'))
except Exception: print('unreadable')"; }

# One account refreshing is not the pass succeeding. The marker carries the SCHEDULE
# as well as the count, so a per-account write postpones the next pass — and with the
# quota warm probing every few minutes, postpones it forever. That silences the
# warning a different, failing spare is waiting for, which is the bug this issue is
# about rather than a new one to introduce.
ka mk lone-success 1 8
printf '{"fails": 6}' > "$FAKE/.claude/ccd/accounts-keepalive"
[ "$(ka refresh-ok lone-success)" = "ok" ] || bad "keepalive counter" "the fixture refresh failed"
[ "$(ka_fails)" = "6" ] \
  && ok "one account's refresh does not reset the whole pass's record" \
  || bad "keepalive counter" "a single success claimed the pass: $(ka_fails)"

# A clean sweep of every spare is a repair, and that is where the counter clears.
printf '{"fails": 6}' > "$FAKE/.claude/ccd/accounts-keepalive"
CCD_TOKEN_URL="http://127.0.0.1:1/x" "$ACCT" --no-color refresh >/dev/null 2>&1
[ "$(ka_fails)" = "6" ] \
  && ok "...and a sweep with a failure in it does not clear it either" \
  || bad "keepalive counter" "cleared on a failed sweep: $(ka_fails)"

# Park keepalive AND the picker: hook runs below must not fire a background token
# refresh or a quota probe. These fixtures carry the refresh token "r" and an
# expired access token, so anything that reaches the network here is a test
# reaching Anthropic for real — a bug in the test, not a slow one.
ka quiet
ka warm
# The signed-in account's reading is parked too: without it the hook goes to measure it.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
  > "$FAKE/.claude/ccd/quota-cache.json"
# Its own clean state, once, before the first tick of this block: an earlier
# backstop may have left a note, a tick shows it, and every assertion below is
# about what a tick says.
rm -f "$FAKE/.claude/ccd/last-stale-warn" "$FAKE/.claude/ccd/swap-note"
out=$("$ROOT/scripts/quota-guard.sh" UserPromptSubmit < /dev/null 2>/dev/null)
case "$out" in
  *stale-spare*"account refresh"*) ok "...and the prompt hook delivers it, with the recovery command" ;;
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

# Nothing above may have gone to the network. These fixtures hold the refresh token
# "r" against a real Anthropic endpoint, so a probe that got through would come back
# an error or dead and overwrite the rows `ka warm` seeded. Their survival is the
# assertion: the prompt hook's backgrounded picker stayed home.
for _ in 1 2 3 4 5 6; do sleep 0.3; done
RQT=$(rq_gather)
left=$(python3 -c "
import json
d = json.load(open('$RQT'))
print(sorted({r.get('status') for r in d.values()}))" 2>/dev/null)
[ "$left" = "['ok']" ] \
  && ok "the prompt hook's quota warm stays off the network in a parked fixture" \
  || bad "test isolation" "a background probe reached out: $left"

# The hook is killed whenever it outruns its timeout, which used to strand its
# tmp file; eight had accumulated in the reporter's CCD_DIR over four weeks.
QDIR="$FAKE/.claude/ccd"
rm -f "$QDIR/quota-cache.json"
: > "$QDIR/quota-cache.json.tmp.999001"; touch -t 202001010000 "$QDIR/quota-cache.json.tmp.999001"
: > "$QDIR/quota-cache.json.tmp.999002"
# The sweep lives on the cache-refresh path, so the cache has to be missing — which
# sends the hook off to measure the signed-in account, at the dead port above.
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

# ── One refresher at a time ─────────────────────────────────────────────────
# keepalive rotates tokens; the quota warm probes, and quota_for() refreshes a token
# on the way when the stored one has expired. Both therefore spend the same one-time
# refresh token. Run as siblings they raced, the loser got `dead`, and the account read
# as logged out — which is the failure this release is about, arriving by a route we
# opened.
#
# Ordering is the property, so measure it where the token is spent. A stand-in for
# both endpoints a refresh reaches logs when each request starts, with how many were in
# flight, and when it ends, holding long enough between for a sibling to overlap.
endpoint_up() { # $1=log $2=seconds each request holds; sets EP_URL and EP_PID
  cat > "$FAKE/endpoint.py" <<'EPY'
import http.server, json, os, socketserver, sys, threading, time
port_file, log, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
lock, live = threading.Lock(), [0]
def note(line):
    with open(log, "a") as f: f.write(line + "\n")
class H(http.server.BaseHTTPRequestHandler):
    def answer(self, kind, reply):
        with lock:
            live[0] += 1; note(f"start {kind} {live[0]}")
        time.sleep(hold)
        with lock:
            live[0] -= 1; note(f"end {kind}")
        body = json.dumps(reply).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_POST(self):                          # a token refresh
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        t = str(time.time())
        self.answer("token", {"access_token": "A" + t, "refresh_token": "R" + t, "expires_in": 28800})
    def do_GET(self):                           # a usage probe
        w = {"utilization": 12, "resets_at": "2099-01-01T00:00:00Z"}
        self.answer("usage", {"five_hour": w, "seven_day": dict(w, utilization=30)})
    def log_message(self, *a): pass
class S(http.server.ThreadingHTTPServer):
    def server_bind(self):                      # skip getfqdn(), see the token server below
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]
srv = S(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.replace(port_file + ".tmp", port_file)
srv.serve_forever()
EPY
  rm -f "$FAKE/.ep-port"
  python3 "$FAKE/endpoint.py" "$FAKE/.ep-port" "$1" "$2" </dev/null >/dev/null 2>&1 &
  EP_PID=$!
  local n=0
  while [ ! -s "$FAKE/.ep-port" ] && [ $n -lt 75 ]; do sleep 0.2; n=$((n+1)); done
  EP_URL="http://127.0.0.1:$(cat "$FAKE/.ep-port" 2>/dev/null)"
  [ -s "$FAKE/.ep-port" ]
}
# A spare due for a keepalive, holding an expired token, behind a stale reading: a
# prompt has both refreshers to run. The signed-in account's reading is current, so
# the hook measures nothing else.
rm -rf "$ADIR"; mkdir -p "$ADIR"
ka mk active-acct 0 8; ka mk race-spare 0 8
printf 'active-acct\n' > "$ADIR/.active"
rm -rf "$FAKE/.claude/ccd/accounts-keepalive" "$RQD" "$FAKE/.race"
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
  > "$FAKE/.claude/ccd/quota-cache.json"
endpoint_up "$FAKE/.race" 0.4 || bad "refresher race" "local endpoint never came up"
CLAUDE_PLUGIN_ROOT="$ROOT" CCD_TOKEN_URL="$EP_URL/token" CCD_USAGE_URL="$EP_URL/usage" \
  CCD_HTTP_TIMEOUT=10 "$ROOT/scripts/quota-guard.sh" UserPromptSubmit </dev/null >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c '^end' "$FAKE/.race" 2>/dev/null)" = "2" ] && break; sleep 0.3
done
sleep 0.5    # long enough for a straggler to show
[ "$(cut -d' ' -f1-2 "$FAKE/.race" 2>/dev/null | tr '\n' ' ')" = "start token end token start usage end usage " ] \
  && ok "a prompt runs the two refreshers in sequence, never at once" \
  || bad "refresher race" "interleaved: $(tr '\n' ' ' < "$FAKE/.race" 2>/dev/null)"
kill "$EP_PID" 2>/dev/null; wait "$EP_PID" 2>/dev/null
rm -f "$FAKE/.race"

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

head_ "26. multi-account: the caches a swap must not leave behind"
# A swap moves the credential. It does not move Claude Code's answer to "what may
# this account run" — that lives in ~/.claude.json, unkeyed by account, and its
# only writer is a startup fetch that never asks whether the account changed.
# `oauthAccount` is the worst of it: the bootstrap merge refuses to update it
# across an identity change, and the profile refetch behind it is on a 24h timer.
# So a swap that leaves these behind sells the incoming account the outgoing
# account's entitlements — Fable reads as credits-only on a plan that includes it.
# The list is Claude Code's own: exactly what it drops when an account changes.
export CCD_CREDENTIALS_BACKEND=file
export CCD_HTTP_TIMEOUT=1
CJSON="$FAKE/.claude.json"
STALE_KEYS='oauthAccount additionalModelOptionsCache additionalModelOptionsAnsweredAt
            additionalModelCostsCache modelAccessCache orgModelDefaultCache
            lastSeenOrgDefaultUpdatedAt clientDataCache clientDataCacheSlots
            autoCompactWindowsCache cachedUsageUtilization
            githubWebConnectionStatusCache startupPrefetchedAt'

# A config shaped like a real one: the account-scoped caches we must drop, sitting
# beside the session and plugin state we must not touch.
write_config() { # $1=path
  python3 - "$1" <<'PY'
import json, os, sys
json.dump({
    "numStartups": 198,
    "userID": "u-1",
    "projects": {"/tmp/work": {"history": ["one", "two"], "allowedTools": ["Bash"]}},
    "mcpServers": {"notion": {"type": "http"}},
    "pluginUsage": {"ccd": 3},
    "skillUsage": {"ccd:doctor": 1},
    "hasCompletedOnboarding": True,
    "subscriptionNoticeCount": 2,
    "oauthAccount": {"accountUuid": "uuid-one", "emailAddress": "first@example.com",
                     "hasExtraUsageEnabled": False, "seatTier": "team_standard",
                     "organizationUuid": "org-A", "profileFetchedAt": 1},
    "additionalModelOptionsCache": [{"value": "claude-fable-5-1",
                                     "label": "Fable", "description": "d"}],
    "additionalModelOptionsAnsweredAt": 1788747338532,
    "additionalModelCostsCache": {"claude-fable-5-1": {}},
    "modelAccessCache": [{"apiName": "claude-fable-5-1", "entitled": False}],
    "orgModelDefaultCache": {"name": "x", "updated_at": "t",
                             "data_source": "s", "override_user_selection": False},
    "lastSeenOrgDefaultUpdatedAt": "t",
    "clientDataCache": {"legacy": 1},
    "clientDataCacheSlots": {"slot-A": {"at": 1}},
    "autoCompactWindowsCache": {"w": 1},
    "cachedUsageUtilization": {"u": 1},
    "githubWebConnectionStatusCache": {"g": 1},
    "startupPrefetchedAt": 1788839142826,
}, open(sys.argv[1], "w"))
os.chmod(sys.argv[1], 0o600)
PY
}

# Present  → the key survived a swap it should not have.
# Absent   → cleared.
stale_left() { # $1=path; prints the keys still there
  python3 - "$1" $STALE_KEYS <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("UNREADABLE"); raise SystemExit(0)
print(" ".join(k for k in sys.argv[2:] if k in d))
PY
}

rm -rf "$ADIR" "$RQD"
write_creds one; "$ACCT" --no-color add --name one --label "first@example.com" >/dev/null 2>&1
write_creds two; "$ACCT" --no-color add --name two --label "second@example.com" >/dev/null 2>&1
"$ACCT" --no-color use one --force >/dev/null 2>&1

# ── The swap that changes account ───────────────────────────────────────────
write_config "$CJSON"
"$ACCT" --no-color use two --force >/dev/null 2>&1
left=$(stale_left "$CJSON")
[ -z "$left" ] \
  && ok "a swap drops every cache that described the account we left" \
  || bad "stale caches" "still present: $left"

# The same write must not cost the user anything else in that file. Conversations
# live outside it, but the per-project history, MCP servers, plugins and skills
# are all in here, and a swap has no business touching any of them.
python3 - "$CJSON" <<'PY' \
  && ok "...and nothing else in the config moves (projects, MCP, plugins, skills)" \
  || bad "config collateral" "a swap changed state it does not own"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["projects"] == {"/tmp/work": {"history": ["one", "two"], "allowedTools": ["Bash"]}}
assert d["mcpServers"] == {"notion": {"type": "http"}}
assert d["pluginUsage"] == {"ccd": 3}
assert d["skillUsage"] == {"ccd:doctor": 1}
assert d["numStartups"] == 198 and d["userID"] == "u-1"
# Onboarding is cleared only by a real logout, and a swap is not one.
assert d["hasCompletedOnboarding"] is True and d["subscriptionNoticeCount"] == 2
PY

perm=$(python3 -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$CJSON" 2>/dev/null)
[ "$perm" = "0o600" ] && ok "...and the config keeps its 600 mode" \
  || bad "config perms" "got $perm"

# ccd reads oauthAccount to tell a manual /login from its own swap. Clearing it is
# safe only because the pointer answers while it is gone — if that fallback ever
# breaks, ccd forgets which account it just installed.
cur=$("$ACCT" --no-color current 2>/dev/null)
case "$cur" in
  *two*) ok "...and ccd still knows which account it just installed" ;;
  *) bad "identity after clear" "current says: $cur" ;;
esac

# ── The swap that changes nothing ───────────────────────────────────────────
# `use` on the account already signed in is the repair path: it reconciles the two
# credential stores and installs nothing. No identity changed, so the caches are
# still this account's own — dropping them would re-run the profile fetch and put
# the additional-model-options prompt back on screen for no reason.
write_config "$CJSON"
# The exit status matters here: without it a command that died before it ever
# reached the config would satisfy the retention assertion by doing nothing.
"$ACCT" --no-color use two --force >/dev/null 2>&1 \
  || bad "same-account swap" "the swap itself failed"
left=$(stale_left "$CJSON")
[ "$(printf '%s' "$left" | wc -w | tr -d ' ')" = "13" ] \
  && ok "re-selecting the active account leaves its caches alone" \
  || bad "same-account swap" "cleared caches that were still valid: kept only [$left]"

# ── A live session must not stop the clear ──────────────────────────────────
# The tempting rule is "a session is running, so leave its file alone". It is
# wrong, and it would miss the reported bug entirely: the user swaps, exits, and
# resumes — and the resumed session reads exactly this file. Skip the clear and
# the restart they were told to do fixes nothing.
#
# It is also safe. Claude Code's own config write re-reads from disk under a lock
# and applies its change to what it finds there, and it watches the file for other
# processes; an external edit is a condition it is built for, not a corruption. A
# torn write is what would hurt, so ours is a temp file and a rename.
cat > "$FAKE/fakebin/pgrep" <<'EOF'
#!/bin/sh
echo 4242
EOF
chmod +x "$FAKE/fakebin/pgrep"
write_config "$CJSON"
"$ACCT" --no-color use one >"$FAKE/use.out" 2>&1
[ -z "$(stale_left "$CJSON")" ] \
  && ok "a swap clears even while a session is running — that session's restart reads it" \
  || bad "live-session clear" "left the caches for the resumed session to trip over"
grep -q 'AT-one' "$CREDS" \
  && ok "...and the credential moves as it always did" \
  || bad "live-session swap" "credential unchanged"
# The swap reaches a live session's requests; what it cannot reach is the model
# list and limits that session read at startup. Naming that is useful. Telling
# the user to restart is not: it sent people out of a session that goes on
# working, which is the one thing this feature exists to avoid.
grep -q -- 'model list and limits' "$FAKE/use.out" \
  && ok "...and the user is told which part lags" \
  || bad "live-session message" "got: $(tr '\n' ' ' < "$FAKE/use.out" | head -c 140)"
grep -q -- '--resume' "$FAKE/use.out" \
  && bad "live-session message" "still sends the user out of a session that keeps working" \
  || ok "...and is not sent out of a session that keeps working"
# The plural wording only ever runs on a real machine with two sessions open, so
# nothing else would catch a typo in that branch. Re-selecting the account that
# is already active exercises it without moving the swap sequence along.
cat > "$FAKE/fakebin/pgrep" <<'EOF'
#!/bin/sh
echo 4242
echo 4243
EOF
chmod +x "$FAKE/fakebin/pgrep"
"$ACCT" --no-color use one >"$FAKE/use.out" 2>&1
grep -q -- '2 other Claude Code sessions are running' "$FAKE/use.out" \
  && ok "...and it counts them correctly when there is more than one" \
  || bad "plural message" "got: $(tr '\n' ' ' < "$FAKE/use.out" | head -c 120)"

# --force is the handoff's path: claude has exited and the relaunch has not
# started. Same clear, no warning to give — there is nobody to warn.
write_config "$CJSON"
"$ACCT" --no-color use two --force >"$FAKE/use.out" 2>&1
[ -z "$(stale_left "$CJSON")" ] \
  && ok "...and --force, the between-sessions path, clears the same way" \
  || bad "forced swap" "left stale caches at the one moment nothing holds the file"
rm -f "$FAKE/fakebin/pgrep"

# ── The file may not be there, or may be junk ───────────────────────────────
# Claude Code owns this file. A swap that has to create or repair it is a swap
# writing state it does not understand, and the credential move must never be
# held hostage to parsing it.
rm -f "$CJSON"
"$ACCT" --no-color use one --force >/dev/null 2>&1 \
  && ok "a swap with no config at all still succeeds" \
  || bad "missing config" "the swap failed"
[ ! -e "$CJSON" ] && ok "...and does not conjure one into existence" \
  || bad "missing config" "created a config Claude Code did not write"

# A lone surrogate parses fine and re-encodes into UnicodeEncodeError on the way
# out. The swap has already committed by then, and ccd-handoff reads a non-zero
# exit as a failed swap and stops relaunching — so this must not be fatal.
python3 -c 'import json,sys; json.dump({"projects":{"/p":{"history":["\ud800"]}},
  "modelAccessCache":[]}, open(sys.argv[1],"w"))' "$CJSON"
"$ACCT" --no-color use two --force >/dev/null 2>&1 \
  && ok "a config carrying an unencodable string does not fail the swap" \
  || bad "surrogate config" "the swap died on a string it could not write back"
grep -q 'AT-two' "$CREDS" \
  && ok "...and the credential still moved" \
  || bad "surrogate config" "the swap was left half done"

printf 'not json {' > "$CJSON"
"$ACCT" --no-color use one --force >/dev/null 2>&1 \
  && ok "a swap with an unparseable config still succeeds" \
  || bad "malformed config" "the swap failed"
[ "$(cat "$CJSON")" = 'not json {' ] \
  && ok "...and leaves the file exactly as it found it" \
  || bad "malformed config" "rewrote a file it could not read"

# ── CLAUDE_CONFIG_DIR ───────────────────────────────────────────────────────
# ccd already reads identity from there first, so that is the copy Claude Code
# loads and the one that has to be cleared. Note the credential store moves with
# it — the whole run has to be coherent under that dir, or the swap fails before
# it ever reaches the config.
mkdir -p "$FAKE/altcfg"
cp "$CREDS" "$FAKE/altcfg/.credentials.json"
write_config "$FAKE/altcfg/.claude.json"
write_config "$CJSON"
CLAUDE_CONFIG_DIR="$FAKE/altcfg" "$ACCT" --no-color use two --force >/dev/null 2>&1
[ -z "$(stale_left "$FAKE/altcfg/.claude.json")" ] \
  && ok "CLAUDE_CONFIG_DIR is where the caches get cleared" \
  || bad "config dir" "cleared the wrong copy"
# The copy left in $HOME goes too, for the reason live_write() keeps both
# credential stores in step: unset the variable one day and a stale file is
# sitting there ready to hand back the account we left.
[ -z "$(stale_left "$CJSON")" ] \
  && ok "...and the copy beside it cannot be left behind to resurrect the old account" \
  || bad "config dir" "left a stale copy in \$HOME"

rm -rf "$ADIR" "$FAKE/altcfg" "$CJSON" "$FAKE/use.out"

head_ "27. multi-account: the statusline's spare row"
# The row that answers "do I have a net?". Its states have to stay distinguishable
# from each other, and none of them may read as "no spare" while one is registered
# — that was the bug: an account merely out of room for the next few minutes was
# reported as an account the user had never set up.
rm -rf "$ADIR" "$RQD" "$FAKE/.claude.json"
mkdir -p "$ADIR"
mk_sl_acct() { # $1=name
  printf '{"name":"%s","label":"%s@example.com","account_uuid":"uuid-%s","priority":1,"claudeAiOauth":{"accessToken":"AT-%s"}}\n' \
    "$1" "$1" "$1" "$1" > "$ADIR/$1.json"
}
mk_sl_acct main; mk_sl_acct backup
printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"

# Cache rows the statusline will actually accept: row_valid() binds an `ok` row to
# the account's uuid and a failure row to its credential too, so both are written.
# Offsets are seconds from now, which is how a reset time is really read — as a
# distance, not a date. "-" leaves a field out entirely.
seed_rows() { # name:status:5h:7d:5h_offset:7d_offset ...
  RQT=$(rq_gather)
  python3 - "$ADIR" "$RQT" "$@" <<'PY'
import datetime, hashlib, json, os, sys
adir, out, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
now = datetime.datetime.now(datetime.timezone.utc)
rows = {}
for s in specs:
    name, status, fh, sd, fr, sr = s.split(":")
    acct = json.load(open(os.path.join(adir, name + ".json")))
    rec = {"status": status, "checked_at": int(now.timestamp()),
           "uuid": acct["account_uuid"],
           "cred": hashlib.sha256(
               acct["claudeAiOauth"]["accessToken"].encode()).hexdigest()[:16]}
    for key, val in (("five_hour_percent", fh), ("seven_day_percent", sd)):
        if val != "-":
            rec[key] = int(val)
    for key, val in (("five_hour_reset", fr), ("seven_day_reset", sr)):
        if val != "-":
            rec[key] = (now + datetime.timedelta(seconds=float(val))).isoformat()
    rows[name] = rec
json.dump(rows, open(out, "w"))
PY
  rq_scatter "$RQT"
}
# Just the account segment, without the colours the assertions do not care about.
sl_spare() {
  printf '%s' '{"model":{"id":"claude-opus-5"}}' \
    | "$ROOT/bin/ccd-statusline" 2>/dev/null \
    | grep 'claude:' | sed $'s/\x1b\\[[0-9;]*m//g'
}

# ── The bug: registered, alive, and out of room is its own state ─────────────
seed_rows main:ok:0:22:18000:600000 backup:ok:98:12:780:518400
row=$(sl_spare)
case "$row" in
  *"spare none"*) bad "spare row" "called a registered account absent: $row" ;;
  *"spare backup 98%"*) ok "a spare with no room is named, not reported as absent" ;;
  *) bad "spare row" "got: $row" ;;
esac
# 98% came from the 5-hour window, so the countdown must be that window's 13
# minutes — not the weekly reset six days out, which would send the user away for
# a week over a wait shorter than a coffee.
case "$row" in
  *"(13m)"*) ok "...counting down the window that is actually spent" ;;
  *) bad "countdown" "wrong window or none: $row" ;;
esac

# The mirror image: when the weekly is the spent one, it is the weekly that gets
# reported. Same code path, opposite answer.
seed_rows main:ok:0:22:18000:600000 backup:ok:10:95:3600:172800
row=$(sl_spare)
case "$row" in
  *"95%"*"(2d0h)"*) ok "the binding window flips to the weekly when that is the spent one" ;;
  *) bad "binding window" "got: $row" ;;
esac

# ── With no room, the countdown is time-to-usable, not time-to-anything ──────
# Both windows spent: the 5-hour turns over in 13 minutes, the weekly in six days,
# and the account is unusable until the LATER one does (has_headroom needs every
# window under the bound). Printing the 13 minutes here promises relief that does
# not arrive — the same lie as reporting the wrong window, pointed the other way.
seed_rows main:ok:0:22:18000:600000 backup:ok:100:100:780:518400
row=$(sl_spare)
case "$row" in
  *"(13m)"*) bad "time to usable" "counted down a window that does not free the account: $row" ;;
  *"backup 100% (6d0h)"*) ok "a spare blocked on both windows is timed by the later one" ;;
  *) bad "time to usable" "got: $row" ;;
esac
# And the ordering follows the same number, or the row names a spare that is six
# days away over one that is back in two hours.
mk_sl_acct sooner
seed_rows main:ok:0:22:18000:600000 backup:ok:100:100:780:518400 sooner:ok:100:12:7200:518400
row=$(sl_spare)
case "$row" in
  *"sooner 100% (2h0m)"*"+1"*) ok "...and outranked by a spare that is actually usable sooner" ;;
  *) bad "time to usable" "got: $row" ;;
esac
rm -f "$ADIR/sooner.json"

# ── Somebody has to keep the file current ───────────────────────────────────
# The checks above make a stale row read as unknown, which is honest and useless on
# its own: before this, nothing refreshed the readings except a user-typed
# `ccd account` command, so the row would simply go quiet instead of going wrong.
# A prompt tick warms it in the background.
# The file appearing is not the point — a failed probe writes one too, and `dead` is
# the silent-failure state #27 is about. What the row needs is a reading it can use,
# so stand up a local usage endpoint and check the verdict, not the filename.
cat > "$FAKE/usageserver.py" <<'USRV'
import http.server, json, os, socketserver, sys
port_file = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({
            "five_hour": {"utilization": 12, "resets_at": "2099-01-01T00:00:00Z"},
            "seven_day": {"utilization": 30, "resets_at": "2099-01-01T00:00:00Z"},
        }).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
class S(http.server.ThreadingHTTPServer):
    def server_bind(self):                      # skip getfqdn(), see the token server
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]
srv = S(("127.0.0.1", 0), H)
with open(port_file + ".tmp", "w") as f: f.write(str(srv.server_address[1]))
os.replace(port_file + ".tmp", port_file)
srv.serve_forever()
USRV
rm -f "$FAKE/.uport"
python3 "$FAKE/usageserver.py" "$FAKE/.uport" </dev/null >/dev/null 2>&1 &
usrv_pid=$!
n=0; while [ ! -s "$FAKE/.uport" ] && [ $n -lt 75 ]; do sleep 0.2; n=$((n+1)); done
if [ -s "$FAKE/.uport" ]; then
  # A live access token, so probe_account goes straight to the usage endpoint instead
  # of trying to refresh a fixture that has no refresh token — `dead` is what that
  # produces, and `dead` is the silent-failure state this assertion must not accept.
  python3 - "$ADIR/backup.json" <<'LIVEPY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["claudeAiOauth"]["expiresAt"] = int((time.time() + 8 * 3600) * 1000)
json.dump(d, open(p, "w"))
LIVEPY
  rm -rf "$RQD"
  # Its OWN live reading. `use --force` a few cases up deletes the cache, so this run
  # used to go and fetch one — from a stand-in that a later edit of mine had left
  # saying 100% — and then moved the session to the spare it had just warmed,
  # whenever the background pick won the race (Linux always, macOS never).
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
    > "$FAKE/.claude/ccd/quota-cache.json"
  printf '{"session_id":"sess-warm","cwd":"/tmp"}' \
    | CCD_USAGE_URL="http://127.0.0.1:$(cat "$FAKE/.uport")/usage" \
      CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(ls "$RQD" 2>/dev/null)" ] && break; sleep 0.3; done
  verdict=$(python3 -c "
import json, sys, time
try: d = json.load(open('$(rq_gather)'))
except Exception: print('unreadable'); raise SystemExit
rows = [r for r in d.values() if isinstance(r, dict)]
if not rows: print('empty'); raise SystemExit
r = rows[0]
fresh = isinstance(r.get('checked_at'), (int, float)) and time.time() - r['checked_at'] < 60
print(f\"{r.get('status')}:{'fresh' if fresh else 'stale'}:{r.get('five_hour_percent')}\")")
  case "$verdict" in
    ok:fresh:12) ok "a prompt warms the cache with a reading the row can actually use" ;;
    *) bad "quota warm" "wrote something, but not a usable reading: $verdict" ;;
  esac
else
  bad "quota warm" "local usage endpoint never came up"
fi
kill "$usrv_pid" 2>/dev/null; wait "$usrv_pid" 2>/dev/null

# ── A window that has turned over is not a reading about now ─────────────────
# A reset in the past means the cache predates it. The row used to print the
# percentage anyway and merely withhold the countdown, which is the half-measure
# this fixes: 98% of a window that no longer exists is not a smaller claim than
# 98% with a clock beside it, it is the same wrong claim with less to argue with.
# The OTHER window is still a reading, so the row shows that one.
seed_rows main:ok:0:22:18000:600000 backup:ok:98:12:-60:518400
row=$(sl_spare)
case "$row" in
  *"backup 98%"*) bad "expired window" "served a percentage whose window had turned over: $row" ;;
  *"backup 12%"*) ok "a window that has already reset is dropped, not shown without its clock" ;;
  *) bad "expired window" "got: $row" ;;
esac

# With every window turned over there is nothing left to report. That is "?", the
# state the row already has for an account it has never measured — not a number,
# and not "none", which would deny the account exists.
seed_rows main:ok:0:22:18000:600000 backup:ok:98:95:-60:-120
row=$(sl_spare)
case "$row" in
  *"backup"*%*) bad "expired window" "invented a number from two dead windows: $row" ;;
  *"spare ?"*) ok "...and an account with no live window reads as unknown" ;;
  *) bad "expired window" "got: $row" ;;
esac

# Staleness has a ceiling of its own. The reset check above is the sharp instrument;
# this is the backstop for a row whose resets cannot be parsed, or that predates a
# reset it never recorded. The reporter's machine served a four-day-old row as
# current for exactly this reason.
seed_rows main:ok:0:22:18000:600000 backup:ok:8:12:18000:518400
RQT=$(rq_gather)
python3 - "$RQT" <<'AGEPY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["backup"]["checked_at"] = int(time.time()) - 4 * 86400
json.dump(d, open(p, "w"))
AGEPY
rq_scatter "$RQT"
row=$(sl_spare)
case "$row" in
  *"backup 12%"*) bad "stale row" "served a four-day-old reading as current: $row" ;;
  *"spare ?"*) ok "a row too old to be a reading is not shown as one" ;;
  *) bad "stale row" "got: $row" ;;
esac
seed_rows main:ok:0:22:18000:600000 backup:ok:98:12:-:-
row=$(sl_spare)
case "$row" in
  *"backup 98%"*"("*) bad "absent reset" "invented a countdown: $row" ;;
  *"backup 98%"*) ok "...and a missing reset leaves the percentage to stand alone" ;;
  *) bad "absent reset" "got: $row" ;;
esac
# Both windows over the bound, only one of them timed. The untimed one still has
# to turn over, so there is no honest number for when the account comes back —
# and the other window's 13 minutes is not it. (Without the guard this is also
# where `max()` meets a None and takes the whole row down with it.)
seed_rows main:ok:0:22:18000:600000 backup:ok:100:100:780:-
row=$(sl_spare)
case "$row" in
  *"backup 100%"*"("*) bad "half-timed spare" "timed the account by a window that does not free it: $row" ;;
  *"backup 100%"*) ok "...and one blocked window we cannot time leaves the whole account untimed" ;;
  *) bad "half-timed spare" "got: $row" ;;
esac

# ── Where the ready/full line falls, and what it costs to be on each side ────
# A dead spare needs the user to do something and this row is the only place it
# says so, so it outranks a spare that is merely full. That makes precedence the
# test for which side of the bound an account landed on — no colour matching.
mk_sl_acct broken
seed_rows main:ok:0:22:18000:600000 backup:ok:99:12:780:518400 broken:dead:-:-:-:-
# The countdown belongs on this side of the bound too: a spare at 99% with
# thirteen minutes left is a net that is about to have a hole in it. And it IS
# this side: there is no reserve under "spent" — 99% is somewhere to go.
case "$(sl_spare)" in
  *"backup 99% (13m)"*) ok "one point under spent still counts as a spare with room, timed" ;;
  *) bad "spent bound" "99% did not read as ready, or lost its countdown: $(sl_spare)" ;;
esac
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:780:518400 broken:dead:-:-:-:-
case "$(sl_spare)" in
  *"needs re-login"*) ok "...and at 100% the row goes to the spare needing a re-login" ;;
  *) bad "spent bound" "100% still read as ready: $(sl_spare)" ;;
esac
# The bound has to mean the same thing to both halves of the row: an account AT
# the bound is classified as having no room, so the window holding it there is
# what has to turn over before it is usable.
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:780:518400
case "$(sl_spare)" in
  *"backup 100% (13m)"*) ok "...and a spare exactly at the bound is timed by the window holding it there" ;;
  *) bad "spent bound" "the bound means two different things: $(sl_spare)" ;;
esac
# "Spent" is not a knob any more. The old one, set in somebody's shell, must not
# move this row away from where the swap and the proof draw the same line.
seed_rows main:ok:0:22:18000:600000 backup:ok:60:12:780:518400 broken:dead:-:-:-:-
case "$(CCD_HEADROOM=50 sl_spare)" in
  *"backup 60%"*) ok "...and the retired CCD_HEADROOM moves nothing: there is one meaning of spent" ;;
  *) bad "spent bound" "an environment variable redrew the line: $(CCD_HEADROOM=50 sl_spare)" ;;
esac
rm -f "$ADIR/broken.json"

# ── Among spares with no room, the one that comes back first ─────────────────
# Not by percentage — every one of them is at 100 — but by the clock: resetting in
# two hours is no use to someone whose next command is now, and in three minutes is.
mk_sl_acct later
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:180:518400 later:ok:100:12:7200:518400
row=$(sl_spare)
case "$row" in
  *"backup 100% (3m)"*"+1"*) ok "the full spare named is the soonest to reset, with the rest as +N" ;;
  *) bad "full ordering" "got: $row" ;;
esac
# A spare we cannot time loses to one we can, whatever their percentages: an
# unknown wait is not a shorter wait.
seed_rows main:ok:0:22:18000:600000 backup:ok:100:12:180:518400 later:ok:100:12:-:-
row=$(sl_spare)
case "$row" in
  *"backup 100% (3m)"*"+1"*) ok "...and a full spare with no timing sorts behind one with it" ;;
  *) bad "full ordering" "got: $row" ;;
esac
rm -f "$ADIR/later.json"

# ── Never probed is not the same as never registered ────────────────────────
seed_rows main:ok:0:22:18000:600000 backup:stale:-:-:-:-
row=$(sl_spare)
case "$row" in
  *"spare none"*) bad "unprobed spare" "called an unmeasured account absent: $row" ;;
  *"spare ?"*) ok "an unprobed spare is a question mark, never a denial" ;;
  *) bad "unprobed spare" "got: $row" ;;
esac

# The claim itself must be unsayable, not merely unsaid: every arrangement of
# registered accounts above reaches a state, so the string has no branch left to
# live in. If it comes back, so does the bug.
if [ ! -r "$ROOT/bin/ccd-statusline" ]; then
  bad "no-spare claim" "could not read the statusline to check"   # absent must not pass
elif grep -q 'spare none' "$ROOT/bin/ccd-statusline"; then
  bad "no-spare claim" "the statusline can still say a registered spare is absent"
else
  ok "...and the row has no way left to answer \"no spare\" at a registered one"
fi

rm -rf "$ADIR" "$RQD"

head_ "27b. the escape hatch fires on a reading, not on a memory"
# The loudest thing ccd puts on screen, in bold red, was the least qualified: it read
# one number out of quota-cache.json with no age check, no window check, and no check
# that the reading was even usable. The arming path next door applies all three, and
# for the same reason — "a 96% sample taken before a reset still reads 96%
# afterwards" (scripts/quota-guard.sh:275).
WDIR="$FAKE/.claude/ccd"
mkdir -p "$WDIR"
rm -rf "$FAKE/.claude/ccd/accounts"
warn_row() {
  printf '%s' '{"model":{"id":"claude-fable-5"}}' \
    | "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'
}
# Just the warning. The account segment shares the row and legitimately names the
# spare there, so matching on the whole line cannot tell the two apart. Cut from the
# ⚠ to the end rather than splitting on the box-drawing separator: `tr` works on
# bytes, so a multi-byte separator makes it mangle the row instead of dividing it,
# which is green on macOS and empty in both containers.
hatch() { warn_row | grep -o '⚠.*' || true; }
wcache() { # $1=5h $2=7d $3=5h reset $4=7d reset [$5=age seconds]
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":%s,"sevenDayPercent":%s,"fiveHourReset":"%s","sevenDayReset":"%s"}}\n' \
    "$1" "$2" "$3" "$4" > "$WDIR/quota-cache.json"
  [ -n "${5:-}" ] && python3 -c "
import os, sys, time
t = time.time() - float(sys.argv[2])
os.utime(sys.argv[1], (t, t))" "$WDIR/quota-cache.json" "$5"
  return 0
}
iso() { python3 -c "
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc)
       + datetime.timedelta(seconds=float(sys.argv[1]))).isoformat())" "$1"; }

# The baseline the rest of this section moves away from.
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
case "$(warn_row)" in
  *"quota 99%"*) ok "a fresh reading over the threshold still warns" ;;
  *) bad "escape hatch" "no warning on a good reading: $(warn_row)" ;;
esac

# Age. The cache keeps its last good sample when a refresh fails, so a reading can
# outlive the window it measured.
wcache 99 40 "$(iso 3600)" "$(iso 500000)" 3600
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "warned from an hour-old reading: $(warn_row)" ;;
  *) ok "a reading too old to describe now does not raise the alarm" ;;
esac

# The window itself. 99% of a five-hour window that reset twenty minutes ago is not a
# claim about the window running now, however fresh the file is.
wcache 99 40 "$(iso -1200)" "$(iso 500000)"
case "$(warn_row)" in
  *"quota 99%"*) bad "escape hatch" "warned on a window that had already turned over: $(warn_row)" ;;
  *) ok "a window that has already reset is not counted against the user" ;;
esac
# ...while the OTHER window still counts. Same file, same age, weekly over the bound.
wcache 20 97 "$(iso -1200)" "$(iso 500000)"
case "$(warn_row)" in
  *"quota 97%"*) ok "...and a live window over the bound still warns" ;;
  *) bad "escape hatch" "dropped a live window with the dead one: $(warn_row)" ;;
esac

# Usable. The dashboard reports its own failures as valid JSON with error=true, and
# the arming path already refuses those. Each flag is checked on its own: set both at
# once and an `or` that should have been an `and` passes anyway.
wflags() { # $1=available $2=error
  printf '{"claude":{"available":%s,"error":%s,"fiveHourPercent":99,"sevenDayPercent":99,"fiveHourReset":"%s","sevenDayReset":"%s"}}\n' \
    "$1" "$2" "$(iso 3600)" "$(iso 500000)" > "$WDIR/quota-cache.json"
}
wflags false true
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "warned from a failed reading: $(warn_row)" ;;
  *) ok "a reading that reports itself unusable raises nothing" ;;
esac
wflags true true
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "error=true alone was not enough to silence it" ;;
  *) ok "...error=true alone is enough" ;;
esac
wflags false false
case "$(warn_row)" in
  *"quota"*) bad "escape hatch" "available=false alone was not enough to silence it" ;;
  *) ok "...and so is available=false" ;;
esac

# A reset we cannot read says nothing either way, so its percentage still counts.
# Silence there would be the worse failure: a user at 99% seeing nothing.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":99,"sevenDayPercent":40,"fiveHourReset":"R1","sevenDayReset":"D1"}}\n' \
  > "$WDIR/quota-cache.json"
case "$(warn_row)" in
  *"quota 99%"*) ok "an unreadable reset does not disqualify its window" ;;
  *) bad "escape hatch" "went silent on a window it could not time: $(warn_row)" ;;
esac

# A swap makes the cache about somebody else. Leaving it in place is what put a red
# 99% beside a dashboard row reading 3% on the reporter's screen.
rm -rf "$FAKE/.claude/ccd/accounts"; mkdir -p "$ADIR"
mk_sl_acct one; mk_sl_acct two
printf 'one' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
HOME="$FAKE" "$ACCT" --no-color use two --force >/dev/null 2>&1 \
  && ok "the swap itself succeeds" || bad "swap cache" "the swap failed, so absence proves nothing"
[ ! -f "$WDIR/quota-cache.json" ] \
  && ok "a swap drops the reading that was about the account it left" \
  || bad "swap cache" "kept a reading about the previous account"
rm -rf "$ADIR"

head_ "27c. the warning names the move that actually applies"
# `ccd -c` is the paid last resort. Offering it while a registered subscription sits
# there with room gets the order backwards — the plugin's own description is "hop to
# your other Claude subscription first, OpenRouter as the last resort", and the
# handoff path already agrees ("Prefer another subscription over paying").
mkdir -p "$ADIR"
rm -rf "$RQD"
mk_sl_acct here; mk_sl_acct roomyspare
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
KEYF="$FAKE/.claude/ccd/providers/keys.env"
mkdir -p "$(dirname "$KEYF")"

# A spare with room: name it, and do not send anyone to a paid backbone.
seed_rows here:ok:99:40:18000:518400 roomyspare:ok:8:12:18000:518400
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → !ccd account use" ] \
  && ok "with a spare that has room, the warning is exactly the command to run" || bad "warning target" "got: $row"
# ...and the row still carries the two numbers that make it a decision (#16): how
# much of that spare is spent, and when its window turns over. The warning has its
# own line, so naming the account in both places costs nothing.
full=$(warn_row)
case "$full" in
  *"ccd -c"*) bad "warning target" "named the paid route anywhere on a row about a free hop: $full" ;;
  *"spare roomyspare "*%*\(*\)*) ok "...and the row keeps the spare's name, percentage and countdown" ;;
  *) bad "warning target" "dropped the numbers that make the row a decision: $full" ;;
esac

# Every subscription spent, key configured: the paid hop is the answer again.
seed_rows here:ok:99:40:18000:518400 roomyspare:ok:100:100:18000:518400
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → /exit then ccd -c" ] \
  && ok "...and with every subscription spent it is ccd -c again" || bad "warning target" "got: $row"

# Nothing registered at all is the same answer by a different route.
rm -rf "$ADIR" "$RQD"; mkdir -p "$ADIR"
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → /exit then ccd -c" ] \
  && ok "...as is having registered no spare in the first place" || bad "warning target" "got: $row"

# No spare with room AND no key: there is nowhere to go, and knowing that before the
# quota hits zero is the whole point of putting it on screen.
mv "$KEYF" "$KEYF.bak" 2>/dev/null || true
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → no spare with room, no OpenRouter key" ] \
  && ok "with no spare and no key it says so, and names nothing it cannot deliver" || bad "warning target" "got: $row"

# Measured-and-none is not the same as never-measured. The row says "spare ?" for the
# second, and the warning must not turn not knowing into a claim. Registered accounts
# with no rows at all is what "never measured" looks like — in a cache written just now,
# since a missing one sends the render off to measure them (#54).
mk_sl_acct here; mk_sl_acct unseen
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
printf '{}' | rq_put
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → no known spare, no OpenRouter key" ] \
  && ok "...and with nothing measured it says it does not know" || bad "warning target" "got: $row"
mv "$KEYF.bak" "$KEYF" 2>/dev/null || true

# The threshold is a floor, not a fence: exactly at it must warn. `>=` and `>` are
# one character apart and every other case in this section passes under either.
rm -rf "$ADIR"; mkdir -p "$ADIR"
wcache 95 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 95% → /exit then ccd -c" ] \
  && ok "a reading exactly at the threshold warns" || bad "warning target" "got: $row"
wcache 94 40 "$(iso 3600)" "$(iso 500000)"
[ -z "$(hatch)" ] \
  && ok "...and one below it does not" || bad "warning target" "warned under the bound: $(hatch)"

# The command carries no name, so no name can be clipped into a different account,
# whatever the account is called (#47). The row still names it, bounded as always.
LONGNAME=$(python3 -c "print('n' * 56)")
mk_sl_acct here; mk_sl_acct "$LONGNAME"
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows "here:ok:99:40:18000:518400" "$LONGNAME:ok:8:12:18000:518400"
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → !ccd account use" ] \
  && ok "a name too long for the row cannot reach the command at all" \
  || bad "warning target" "got: $row"
case "$(warn_row)" in
  *"spare nnn"*) ok "...and the row keeps naming it, bounded the way it always was" ;;
  *) bad "warning target" "dropped the row's own mention as well: $(warn_row)" ;;
esac
rm -rf "$ADIR"; mkdir -p "$ADIR"

# A spare that needs a re-login is not a spare with room.
mk_sl_acct here; mk_sl_acct broken
printf 'here' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows here:ok:99:40:18000:518400 broken:dead:-:-:-:-
wcache 99 40 "$(iso 3600)" "$(iso 500000)"
row=$(hatch)
[ "$row" = "⚠ quota 99% → /exit then ccd -c" ] \
  && ok "a spare that needs a re-login is not offered as the escape" || bad "warning target" "got: $row"
rm -rf "$ADIR"; mkdir -p "$ADIR"

head_ "27d. a session that cannot hand off says so where you are looking"
# The whole of #21 was an install that sat inert for four days while every surface
# except `ccd doctor` reported success. doctor is the command nobody runs BEFORE the
# thing they installed fails to happen; this row is the one people actually read, and
# it already carries "needs re-login" for the same reason.
rm -rf "$ADIR" "$RQD"; mkdir -p "$ADIR"
mk_sl_acct main; mk_sl_acct backup
printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows main:ok:0:22:18000:600000 backup:ok:20:30:18000:600000
# Below the threshold: this section is about supervision, not about the warning.
# (CCDD is not defined until section 28; WDIR from 27b names the same directory.)
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20,"fiveHourReset":"R1","sevenDayReset":"D1"}}\n' \
  > "$WDIR/quota-cache.json"
SHIMD="$FAKE/.claude/ccd/bin"
sl_env() { env -u CCD_HANDOFF "$@" HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null \
             | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:'; }
# A launcher is only needed by the hop that is authorised here. With the paid hop
# on, an unsupervised session cannot take it — which is what these cases are about.
paid_optin_on
mkdir -p "$FAKE/.claude/ccd/providers"
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"

# Nothing installed: there is no launcher, so no session can hand off.
rm -rf "$SHIMD"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "with no launcher the row says the handoff cannot fire" ;;
  *) bad "supervision" "said nothing about it: $row" ;;
esac

# Installed but unreachable — the exact state that stranded the reporter.
mkdir -p "$SHIMD"; printf '#!/bin/sh\n' > "$SHIMD/claude"; chmod +x "$SHIMD/claude"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "...and an installed launcher that is not on PATH is the same answer" ;;
  *) bad "supervision" "counted an unreachable launcher as working: $row" ;;
esac

# On PATH but with no token: this session started before the launcher did, and
# nothing here can hand off either.
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | PATH="$SHIMD:$PATH" sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "a session that predates the launcher is not called supervised" ;;
  *) bad "supervision" "got: $row" ;;
esac

# A token the hook would refuse must not read as supervision here. launcher_present()
# wants 32 lowercase hex and the state path that token implies; anything weaker calls
# a session supervised that the hook will then decline to signal.
HST="$FAKE/.claude/ccd/handoff-00000000000000000000000000000001.json"
for bad_tok in "x" "0000000000000000000000000000000" "0000000000000000000000000000000G"; do
  row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' \
          | CCD_HANDOFF="$bad_tok" CCD_HANDOFF_STATE="$HST" HOME="$FAKE" \
            "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:')
  case "$row" in
    *"OpenRouter handoff will not happen"*) : ;;
    *) bad "supervision" "a token the hook rejects read as supervised: '$bad_tok' -> $row" ;;
  esac
done
ok "a malformed token is not supervision"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' \
        | CCD_HANDOFF=00000000000000000000000000000001 CCD_HANDOFF_STATE="$FAKE/elsewhere.json" \
          HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:')
case "$row" in
  *"OpenRouter handoff will not happen"*) ok "...and neither is a good token with the wrong state path" ;;
  *) bad "supervision" "accepted a mismatched state path: $row" ;;
esac

# Supervised: say nothing. A row that warns when everything is fine is a row people
# learn not to read.
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' \
        | CCD_HANDOFF=00000000000000000000000000000001 CCD_HANDOFF_STATE="$HST" \
          PATH="$SHIMD:$PATH" HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null \
        | sed $'s/\x1b\\[[0-9;]*m//g' | grep 'claude:')
case "$row" in
  *"OpenRouter handoff will not happen"*) bad "supervision" "warned a supervised session: $row" ;;
  *"spare backup"*) ok "a session holding the hook's own contract is told nothing" ;;
  *) bad "supervision" "got: $row" ;;
esac

# Neither is a session that needs no launcher at all. Without the paid opt-in the
# only hop this install can make happens inside the session, and warning about
# supervision there marks a correct, complete install as broken.
paid_optin_off
rm -rf "$SHIMD"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) bad "supervision" "warned an install whose only hop needs no launcher: $row" ;;
  *"spare backup"*) ok "...and an install with no paid hop is not warned about a launcher it does not need" ;;
  *) bad "supervision" "got: $row" ;;
esac
paid_optin_on
mkdir -p "$SHIMD"; printf '#!/bin/sh\n' > "$SHIMD/claude"; chmod +x "$SHIMD/claude"

# The note and the warning no longer compete: the warning takes its own line, so both
# can say their piece without either being truncated away.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":99,"sevenDayPercent":40,"fiveHourReset":"%s","sevenDayReset":"%s"}}\n' \
  "$(iso 3600)" "$(iso 500000)" > "$WDIR/quota-cache.json"
both=$(printf '%s' '{"model":{"id":"claude-fable-5"}}' \
         | env -u CCD_HANDOFF HOME="$FAKE" "$ROOT/bin/ccd-statusline" 2>/dev/null \
         | sed $'s/\\x1b\\[[0-9;]*m//g')
case "$both" in
  *"OpenRouter handoff will not happen"*"quota 99%"*) ok "the note and the warning both survive, on their own lines" ;;
  *) bad "supervision" "one crowded the other out: $(printf '%s' "$both" | tr '\n' '/')" ;;
esac
[ "$(printf '%s' "$both" | grep -c 'quota 99%')" = "1" ] \
  && ok "...and the warning is on a line of its own" \
  || bad "supervision" "the warning did not get its own line"

# The opt-in alone is not paid auto mode: without a key the hop cannot happen for a
# reason no launcher fixes, and the row is not where that is said.
mv "$FAKE/.claude/ccd/providers/keys.env" "$FAKE/.claude/ccd/providers/keys.env.off"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*) bad "supervision" "warned an install with no key: $row" ;;
  *) ok "an opt-in with no key stored is not warned about supervision" ;;
esac
mv "$FAKE/.claude/ccd/providers/keys.env.off" "$FAKE/.claude/ccd/providers/keys.env"

# One account is where the paid hop matters MOST — no spare is itself the proof —
# so it is warned exactly like the rest, and names the fix.
rm -f "$ADIR/backup.json"
row=$(printf '%s' '{"model":{"id":"claude-opus-5"}}' | sl_env)
case "$row" in
  *"OpenRouter handoff will not happen"*"claude"*) ok "with one account the warning still shows, and says what to do" ;;
  *) bad "supervision" "one account, paid auto on, unsupervised, and the row said: '$row'" ;;
esac
rm -f "$FAKE/.claude/ccd/providers/keys.env"
paid_optin_off
rm -rf "$ADIR" "$SHIMD"; mkdir -p "$ADIR"

head_ "27e. the spare's reading keeps pace with the row"
# #54. The row is only as current as the readings on file, and only a typed prompt
# refreshed it: an autonomous turn fires tool uses and assistant messages, never a
# prompt, so a healthy spare aged into `spare ?` exactly while quota burned fastest.
# The reading has to move on the row's own cadence (prompt, tool use, render, and a
# timer for an idle session), a fresh one must cost no process, and no refresh may
# overlap another, because keepalive and a pick can both spend a one-time refresh token.
#
# Every trigger runs from a copy of the plugin whose ccd-account logs, then execs the
# real one. The log tells "nothing needed refreshing" apart from "nothing was started";
# the local endpoint (section 25) says whether a refresh landed, and how many overlapped.
SPD="$FAKE/.claude/ccd"
SPROOT="$FAKE/spareroot"; SPLOG="$FAKE/.spare-calls"; SPHITS="$FAKE/.spare-hits"
rm -rf "$SPROOT"; mkdir -p "$SPROOT"
cp -R "$ROOT/bin" "$ROOT/scripts" "$SPROOT/"
cat > "$SPROOT/bin/ccd-account" <<EOF
#!/bin/sh
echo "\$*" >> "$SPLOG"
exec "$ROOT/bin/ccd-account" "\$@"
EOF
chmod +x "$SPROOT/bin/ccd-account"
endpoint_up "$SPHITS" 3 || bad "spare refresh" "local endpoint never came up"

sp_env() { env CCD_USAGE_URL="$EP_URL/usage" CCD_TOKEN_URL="$EP_URL/token" CCD_HTTP_TIMEOUT=10 "$@"; }
sp_hook() { sp_env CLAUDE_PLUGIN_ROOT="$SPROOT" "$SPROOT/scripts/quota-guard.sh" "$1" </dev/null >/dev/null 2>&1; }
# Claude Code hands the statusline no plugin root, so neither does this.
sp_render() {
  printf '%s' '{"model":{"id":"claude-opus-5"}}' \
    | sp_env env -u CLAUDE_PLUGIN_ROOT "$SPROOT/bin/ccd-statusline" 2>/dev/null
}
spare_fixture() { # $1 = age of every reading on file, in seconds; $2 = "due" for a spare
                  # whose keepalive is due and whose access token has expired
  rm -rf "$ADIR" "$RQD" "$SPLOG" "$SPHITS" "$FAKE/.claude.json"; mkdir -p "$ADIR"
  RQT=$(rq_gather)
  python3 - "$ADIR" "$RQT" "$1" "${2:-}" <<'PY'
import datetime, hashlib, json, os, sys, time
adir, qfile, age, due = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "due"
now = time.time()
iso = lambda s: datetime.datetime.fromtimestamp(now + s, datetime.timezone.utc).isoformat()
rows = {}
for name in ("main", "backup"):
    at = "AT-" + name
    expires = now - 3600 if due and name == "backup" else now + 8 * 3600
    json.dump({"name": name, "label": name, "account_uuid": "uuid-" + name, "priority": 1,
               "claudeAiOauth": {"accessToken": at, "refreshToken": "RT-" + name,
                                 "expiresAt": int(expires * 1000)}},
              open(os.path.join(adir, name + ".json"), "w"))
    rows[name] = {"status": "ok", "checked_at": int(now - age), "uuid": "uuid-" + name,
                  "cred": hashlib.sha256(at.encode()).hexdigest()[:16],
                  "five_hour_percent": 50, "seven_day_percent": 50,
                  "five_hour_reset": iso(3600), "seven_day_reset": iso(3 * 86400)}
json.dump(rows, open(qfile, "w"))
os.utime(qfile, (now - age, now - age))
PY
  rq_scatter "$RQT"
  printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
  # The hook's own reading of the signed-in account is not what this section measures.
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20}}\n' \
    > "$SPD/quota-cache.json"
  if [ "${2:-}" = "due" ]; then rm -f "$SPD/accounts-keepalive"; else printf '{"fails": 0}' > "$SPD/accounts-keepalive"; fi
}
sp_reading() {
  RQT=$(rq_gather)
  python3 - "$RQT" <<'PY'
import json, sys, time
try: r = json.load(open(sys.argv[1]))["backup"]
except Exception: print("unreadable"); raise SystemExit
t = r.get("checked_at")
fresh = isinstance(t, (int, float)) and time.time() - t < 60
print(f"{r.get('status')}:{'fresh' if fresh else 'stale'}:{r.get('five_hour_percent')}")
PY
  rm -f "$RQT"            # read only: nothing to publish
}
sp_landed() { # the endpoint's reading, on file
  n=0; while [ "$(sp_reading)" != "ok:fresh:12" ] && [ $n -lt 60 ]; do sleep 0.25; n=$((n+1)); done
  [ "$(sp_reading)" = "ok:fresh:12" ]
}

# ── A tool use refreshes, not only a typed prompt ───────────────────────────
spare_fixture 600
sp_hook PostToolUse
sp_landed \
  && ok "a tool-use tick brings a stale spare reading current" \
  || bad "tool-use refresh" "only a typed prompt refreshes the spare: $(sp_reading)"
sleep 1

# ── A fresh reading costs no process ────────────────────────────────────────
# Judged before anything is spawned. A pick that starts only to find the cache warm is
# exactly the process ruled out: the hook fires on every tool use. The bare keepalive
# every tick already ran is the one call allowed.
spare_fixture 10
sp_hook UserPromptSubmit; sp_hook PostToolUse
sleep 2
started=$(grep -vxF -- '--no-color keepalive --detach' "$SPLOG" 2>/dev/null)
[ -z "$started" ] \
  && ok "a fresh reading starts no refresh, on a prompt or a tool use" \
  || bad "fresh reading" "started for a reading seconds old: $(printf '%s' "$started" | tr '\n' '/')"

# ── An idle session still ticks ─────────────────────────────────────────────
# Event triggers go quiet while the session idles, so the row needs a timer of its own.
# Seeded with today's wiring, which is what a re-run of setup meets.
SPH="$FAKE/home54"; rm -rf "$SPH"; mkdir -p "$SPH/.claude"
printf '{"statusLine":{"type":"command","command":"bash ~/.claude/ccd/statusline-launcher.sh"}}\n' \
  > "$SPH/.claude/settings.json"
HOME="$SPH" SHELL=/bin/zsh "$ROOT/bin/ccd" setup --no-auto >/dev/null 2>&1
sl=$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get('statusLine'),sort_keys=True))" \
       "$SPH/.claude/settings.json" 2>/dev/null)
[ "$sl" = '{"command": "bash ~/.claude/ccd/statusline-launcher.sh", "refreshInterval": 60, "type": "command"}' ] \
  && ok "setup gives the statusline a 60s tick, beside the command it already wires" \
  || bad "refreshInterval" "statusLine: $sl"

# Nothing reruns setup after an update, so an install wired before the tick existed gets
# it at session start, through the hook as hooks.json registers it. Only ccd's own
# statusline, exactly as setup writes it: never a wrapper around it, never one whose
# interval the user already chose, never a statusline where there was none. The last
# three pass against a hook that does nothing, so they ride with the first.
ss_out=$(HOME="$SPH" CLAUDE_PLUGIN_ROOT="$ROOT" python3 - "$SPH/.claude/settings.json" "$ROOT/hooks/hooks.json" 2>&1 <<'PY'
import json, subprocess, sys
settings, hooks = sys.argv[1], sys.argv[2]
ours = json.load(open(settings))["statusLine"]
ours.pop("refreshInterval", None)                      # what an older setup wrote
cmds = [h["command"] for g in json.load(open(hooks))["hooks"].get("SessionStart", [])
        for h in g.get("hooks", [])]
if not cmds:
    print("no SessionStart hook is registered")
for seed, want in ((ours, dict(ours, refreshInterval=60)),
                   (dict(ours, command=ours["command"] + " --wrapped"), None),
                   (dict(ours, refreshInterval=5), None),
                   ("absent", None)):
    with open(settings, "w") as f:
        json.dump({} if seed == "absent" else {"statusLine": seed}, f)
    before = open(settings).read()
    out = "".join(subprocess.run(["bash", "-c", c], stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True).stdout for c in cmds)
    got = json.load(open(settings)).get("statusLine", "absent")
    if (got != want if want else open(settings).read() != before) or out:
        print(f"{seed} became {got}" + (f", printing {out.strip()}" if out else ""))
print("checked")                                       # reached only if nothing above threw
PY
)
[ "$ss_out" = "checked" ] \
  && ok "...and a session start gives it to an older install's statusline, and to nothing else" \
  || bad "statusline upgrade" "$(printf '%s' "$ss_out" | tr '\n' '/')"

# Several sessions start at once and Claude Code writes settings.json itself, so a write
# that lands between our read and our replace must not be discarded — including one that
# stops the statusline being ours. The interleave is staged from outside the hook: a
# sitecustomize makes the foreign write happen as the hook opens its temp file.
mkdir -p "$FAKE/pysite54"
cat > "$FAKE/pysite54/sitecustomize.py" <<'SCEOF'
import json, os, tempfile
_target = os.environ.get("CCD_TEST_INTERLEAVE")
if _target:
    _mkstemp = tempfile.mkstemp

    def mkstemp(*a, **k):                    # after the hook's read, before its replace
        d = json.load(open(_target))
        d["theirs"] = "kept"
        with open(_target, "w") as f:
            json.dump(d, f)
        tempfile.mkstemp = _mkstemp          # once is enough to open the window
        return _mkstemp(*a, **k)

    tempfile.mkstemp = mkstemp
SCEOF
cas_state() {
  python3 -c "import json,sys
d = json.load(open(sys.argv[1]))
print(d.get('theirs'), (d.get('statusLine') or {}).get('refreshInterval'))" "$SPH/.claude/settings.json" 2>&1
}
printf '{"statusLine":{"type":"command","command":"bash ~/.claude/ccd/statusline-launcher.sh"}}\n' \
  > "$SPH/.claude/settings.json"
HOME="$SPH" CLAUDE_PLUGIN_ROOT="$ROOT" CCD_TEST_INTERLEAVE="$SPH/.claude/settings.json" \
  PYTHONPATH="$FAKE/pysite54${PYTHONPATH:+:$PYTHONPATH}" \
  "$ROOT/scripts/quota-guard.sh" SessionStart </dev/null >/dev/null 2>&1
raced=$(cas_state)
# Standing down is only safe because the next session start tries again.
HOME="$SPH" CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/scripts/quota-guard.sh" SessionStart </dev/null >/dev/null 2>&1
retried=$(cas_state)
[ "$raced" = "kept None" ] && [ "$retried" = "kept 60" ] \
  && ok "...and stands down on a settings write that lands mid-flight, then retries" \
  || bad "settings race" "during: $raced · after: $retried"
rm -rf "$SPH" "$FAKE/pysite54"

# ── A render refreshes too, and waits for none of it ────────────────────────
# The statusline re-runs on each assistant message and on that timer, which makes it the
# trigger an idle session still has. Claude Code cancels a run still in flight, so the
# refresh must leave the render behind. Paired with the fresh case: on its own that
# half passes against a statusline that never refreshes anything.
spare_fixture 10
sp_render >/dev/null; sleep 2
fresh_started=$(cat "$SPLOG" 2>/dev/null)
spare_fixture 600
sl_start=$(date +%s)
row=$(sp_render)
sl_elapsed=$(( $(date +%s) - sl_start ))
# Waited for whatever the verdict, or a refresh still in flight lands in the next case.
sp_landed && landed=1 || landed=0
if [ -n "$fresh_started" ]; then
  bad "render refresh" "a render started ccd-account for a reading seconds old: $fresh_started"
elif [ "$landed" -eq 0 ]; then
  bad "render refresh" "a render left a stale spare reading stale: $(sp_reading)"
elif [ "$sl_elapsed" -gt 2 ]; then
  bad "render refresh" "the render waited ${sl_elapsed}s for the refresh"
else
  ok "a render refreshes a stale reading behind itself, and leaves a fresh one alone"
fi
sleep 1

# ── ...and outlives the trigger being cancelled ─────────────────────────────
# Claude Code cancels a render that is still running when the next update arrives, and
# kills a hook that outruns its timeout — both by process group. A refresh caught there
# mid token-exchange loses a refresh token the server has already rotated: the spare
# dies, which is the failure ccd exists to prevent.
sp_cancelled() { # run a trigger in a session of its own, then kill that session
  sp_env python3 - "$@" >/dev/null 2>&1 <<'PY'
import os, signal, subprocess, sys, time
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
p.communicate(b'{"model":{"id":"claude-opus-5"}}')
time.sleep(0.5)                              # the refresh is at the endpoint by now
os.killpg(p.pid, signal.SIGKILL)
PY
}
spare_fixture 600
sp_cancelled env -u CLAUDE_PLUGIN_ROOT "$SPROOT/bin/ccd-statusline"
sp_landed && cancel_render=yes || cancel_render="no ($(sp_reading))"
sleep 1
spare_fixture 600
sp_cancelled env CLAUDE_PLUGIN_ROOT="$SPROOT" "$SPROOT/scripts/quota-guard.sh" PostToolUse
sp_landed && cancel_tick=yes || cancel_tick="no ($(sp_reading))"
[ "$cancel_render" = yes ] && [ "$cancel_tick" = yes ] \
  && ok "...and a refresh outlives the render or the tick that started it being killed" \
  || bad "detached refresh" "render: $cancel_render · tick: $cancel_tick"
sleep 1

# ── The only registered account is a spare too ──────────────────────────────
# An unregistered login beside one registered account: that account IS the spare (#41),
# so its reading has to keep moving like any other — on a tick and on a render.
solo_fixture() {
  spare_fixture 600
  rm -f "$ADIR/main.json" "$ADIR/.active"
  printf '{"oauthAccount":{"accountUuid":"uuid-nobody","emailAddress":"nobody@example.com","profileFetchedAt":%s}}\n' \
    "$(( $(date +%s) * 1000 ))" > "$FAKE/.claude.json"
}
solo_fixture
sp_hook PostToolUse
sp_landed && solo_hook=yes || solo_hook="no ($(sp_reading))"
sleep 1
solo_fixture
sp_render >/dev/null
sp_landed && solo_render=yes || solo_render="no ($(sp_reading))"
[ "$solo_hook" = yes ] && [ "$solo_render" = yes ] \
  && ok "the only registered account is measured too, by a tick and by a render" \
  || bad "single spare" "tick: $solo_hook · render: $solo_render"
sleep 1

# ── ...and an exclusion list nothing writes any more excludes nothing ───────
# The row used to drop the launcher's per-burst visited set before deciding whether
# a refresh was worth starting. That set left with the account ladder, so a stale
# `CCD_BURST_VISITED` in some long-lived shell must not be able to silence the one
# spare there is — a reading that stops moving is exactly how a spare dies unseen.
solo_fixture
CCD_BURST_VISITED=earlier-hop,backup sp_render >/dev/null
sp_landed && stale_env=yes || stale_env="no ($(sp_reading))"
[ "$stale_env" = yes ] \
  && ok "...and a leftover burst variable no longer stops the only spare being measured" \
  || bad "stale exclusion" "an unwritten variable still excluded the spare: $stale_env"
rm -f "$FAKE/.claude.json"
sleep 1

# ── However many triggers, one refresh at a time ────────────────────────────
# Three sessions' prompts, tool uses and renders landing together, which the new
# triggers make routine, against a spare with a keepalive due and an expired token: every
# job would spend a refresh token. Whatever the lock, the endpoint sees any overlap.
spare_fixture 600 due
sp_pids=""
for _ in 1 2 3; do
  sp_hook UserPromptSubmit & sp_pids="$sp_pids $!"
  sp_hook PostToolUse & sp_pids="$sp_pids $!"
  sp_render >/dev/null & sp_pids="$sp_pids $!"
done
wait $sp_pids
# A refresh queued behind the first arrives within one more hold of the endpoint.
sp_landed && landed=1 || landed=0
sleep 4
peak=$(grep '^start' "$SPHITS" 2>/dev/null | cut -d' ' -f3 | sort -n | tail -n 1)
kinds=$(grep '^start' "$SPHITS" 2>/dev/null | cut -d' ' -f2 | sort -u | tr '\n' ' ')
# Both halves have to have run, or "one at a time" is satisfied by doing almost nothing.
if [ "$landed" -eq 0 ]; then
  bad "single-flight" "no refresh landed at all: $(sp_reading)"
elif [ "$kinds" != "token usage " ]; then
  bad "single-flight" "the job did not both refresh and measure: ${kinds:-nothing ran}"
elif [ "${peak:-0}" != "1" ]; then
  bad "single-flight" "peak refreshes in flight at the endpoint: $peak"
else
  ok "prompts, tool uses and renders at once never run two refreshes together"
fi

kill "$EP_PID" 2>/dev/null; wait "$EP_PID" 2>/dev/null
rm -rf "$SPROOT" "$ADIR" "$RQD" "$SPLOG" "$SPHITS" "$SPD/accounts-keepalive"
mkdir -p "$ADIR"
unset -f sp_env sp_hook sp_render sp_cancelled solo_fixture spare_fixture sp_reading sp_landed cas_state

head_ "28. no claude-dashboard installed"
# ccd reads Claude quota to do three things: warn before exhaustion, notice a
# reset, and corroborate a rate_limit before arming a handoff. claude-dashboard
# is one source for that reading, not the only one there could be, and an install
# without it used to lose all three in silence: the statusline said nothing, the
# handoff never fired, and nothing anywhere said why. ccd already talks to the
# same Anthropic usage endpoint for its spare accounts, so it can measure the
# account this session is signed in as and answer for itself.
#
# Every assertion below runs with no dashboard anywhere on disk.
rm -rf "$FAKE/.claude/plugins/cache/claude-dashboard" \
       "$FAKE/.claude/plugins/data/claude-dashboard-claude-dashboard" \
       "$FAKE/.claude/ccd/.dashboard-row" "$FAKE/.claude/ccd/.dashboard-row.lock"

export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json"
export CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
# Reset timestamps are generated relative to now. Hardcoded dates would quietly
# expire: once they pass, the reading is correctly rejected as belonging to a
# window that already turned over, and every positive assertion here starts
# failing on a calendar date rather than on a code change. Expired timestamps
# belong only in the reset-crossing test, which builds its own.
# The hook as the plugin runs it, with the dashboard gone.
nd_hook() { CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/scripts/quota-guard.sh" "$@"; }
# Move the file into the past rather than the clock into the future: production
# only ever compares against a real now. (Section 17b's age_file is unset by the
# time this section runs.)
nd_age() { python3 -c "import os,sys,time;t=time.time()-float(sys.argv[2]);os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
CCDD="$FAKE/.claude/ccd"

# ── The reading ─────────────────────────────────────────────────────────────
write_creds nodash
stage_usage 58 96
usage_out=$("$ACCT" --no-color usage --json 2>/dev/null)
case "$usage_out" in
  *'"fiveHourPercent": 58'*|*'"fiveHourPercent":58'*)
    ok "ccd measures the signed-in account with no dashboard installed" ;;
  *) bad "self-measured quota" "got: ${usage_out:0:120}" ;;
esac
case "$usage_out" in
  *'"sevenDayPercent": 96'*|*'"sevenDayPercent":96'*) ok "...both windows, in the shape the cache already speaks" ;;
  *) bad "self-measured 7d window" "got: ${usage_out:0:120}" ;;
esac

# ── What the user sees ──────────────────────────────────────────────────────
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
nd_hook UserPromptSubmit >/dev/null 2>&1
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "96" ] && ok "the hook fills the quota cache from ccd's own reading" \
  || bad "cache without a dashboard" "got: $got"

rm -f "$CCDD/last-warn" "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
out=$(nd_hook UserPromptSubmit 2>/dev/null)
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "...so the near-exhaustion warning still reaches the user" ;;
  *) bad "warning without a dashboard" "got: ${out:0:120}" ;;
esac

# ── The statusline ──────────────────────────────────────────────────────────
rm -rf "$ADIR" "$RQD"; mkdir -p "$ADIR"
mk_sl_acct main; mk_sl_acct backup
printf 'main' > "$ADIR/.active"; date +%s > "$ADIR/.active-at"
seed_rows main:ok:0:22:18000:600000 backup:ok:20:30:18000:600000
# Below the warning threshold on purpose: this section is about the row surviving a
# missing dashboard, and above it the row hands its spare to the warning instead of
# naming it twice (27c), which would be a different thing being tested.
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"sevenDayPercent":20,"fiveHourReset":"R1","sevenDayReset":"D1"}}\n' \
  > "$CCDD/quota-cache.json"
row=$(sl_spare)
case "$row" in
  *"spare backup"*) ok "the spare row still names the account to hop to" ;;
  *) bad "spare row without a dashboard" "got: $row" ;;
esac
ccdrow=$(printf '%s' '{"model":{"id":"openai/gpt-5.6-luna:floor"}}' | CCD_ACTIVE=1 "$ROOT/bin/ccd-statusline" 2>/dev/null)
case "$ccdrow" in
  *ccd*luna*) ok "...and the ccd row renders with no dashboard to render above" ;;
  *) bad "ccd row without a dashboard" "got: ${ccdrow:0:80}" ;;
esac

# ── The handoff ─────────────────────────────────────────────────────────────
# The whole point of the reading. Without one, arming is impossible by design
# (see quota_peak), so this is what an install with no dashboard used to lose.
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$CCDD/providers/keys.env"
paid_optin_on
set +m 2>/dev/null
# A fresh stand-in per arm. Arming signals the claude process, so the one that
# armed is gone by the next call — and a dead pid fails the readiness check for
# a reason that has nothing to do with what these assertions are about.
nd_arm() { # $1=session id ; leaves the hook's exit code in $ND_RC
  "$FAKE/sigbin/claude" 8 2>/dev/null & NDPID=$!
  sleep 0.3
  stopfail "$1" rate_limit \
    | CCD_HANDOFF=00000000000000000000000000000002 \
      CCD_HANDOFF_STATE="$CCDD/handoff-00000000000000000000000000000002.json" \
      CLAUDE_PID=$NDPID CCD_STANDIN_PID=$NDPID CLAUDE_PLUGIN_ROOT="$ROOT" \
      CCD_SWAP_SETTLE=0 env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
  ND_RC=$?
  sleep 0.3
  kill -9 $NDPID 2>/dev/null; wait $NDPID 2>/dev/null
}

# Nothing registered: the only place left to go is OpenRouter.
rm -rf "$ADIR" "$RQD"
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_arm sess-nd1
[ "$(hf_get armed)" = "True" ] && ok "rate_limit + a self-measured 100% arms the handoff" \
  || bad "arming without a dashboard" "armed=$(hf_get armed)"
[ "$(hf_get direction)" = "to_fallback" ] && ok "...toward OpenRouter when no subscription is registered" \
  || bad "direction" "got: $(hf_get direction)"

# Without the opt-in the same situation arms nothing. A key configured at some point
# in the past says the paid backbone is reachable; it does not say the user agreed
# that quota exhaustion may start billing while they are not at the keyboard.
paid_optin_off
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_arm sess-nd1b
[ -z "$(hf_get armed)" ] \
  && ok "...and not at all when the paid hop was never opted into" \
  || bad "paid opt-in" "armed $(hf_get direction) on a configured key alone"

# Two subscriptions: the spare wins, and nothing is billed. The opt-in stays OFF
# through this one, because that is the whole point — the free hop is the product
# and it must not need a flag. Section 29 owns what the hop now looks like; what
# is being checked here is that a self-measured reading is enough to reach it.
rm -rf "$ADIR"
for n in nd_one nd_two; do write_creds "$n"; "$ACCT" --no-color add --name "$n" >/dev/null 2>&1; done
"$ACCT" --no-color use nd_one --force >/dev/null 2>&1
# Rows the picker will accept whichever way these accounts registered:
# _cache_row_valid asks for the uuid when an account has one and for the
# credential when it does not, so carry both. A row it retires sends pick to the
# network, and there it would read the signed-in account's numbers for every
# account, which is a fixture bug that looks exactly like a product bug.
nd_seed_rows() { # name:5h:7d ...
  RQT=$(rq_gather)
  python3 - "$ADIR" "$RQT" "$@" <<'NDEOF'
import hashlib, json, os, sys, time
adir, out, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
rows = {}
for spec in specs:
    name, fh, sd = spec.split(":")
    acct = json.load(open(os.path.join(adir, name + ".json")))
    token = (acct.get("claudeAiOauth") or {}).get("accessToken") or ""
    rows[name] = {
        "status": "ok",
        "checked_at": int(time.time()),
        "uuid": acct.get("account_uuid"),
        "cred": hashlib.sha256(token.encode()).hexdigest()[:16],
        "five_hour_percent": int(fh),
        "seven_day_percent": int(sd),
    }
json.dump(rows, open(out, "w"))
NDEOF
  rq_scatter "$RQT"
}
nd_seed_rows nd_one:100:100 nd_two:10:20
paid_optin_off
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
nd_arm sess-nd2
grep -q 'AT-nd_two' "$CREDS" && ok "...and onto the other subscription when one has room" \
  || bad "backstop swap" "the credential never moved"
[ "$ND_RC" = "2" ] && ok "...waking the parked session rather than arming a relaunch" \
  || bad "wake" "exit code $ND_RC, and a handoff of $(hf_get direction)"
[ ! -f "$CCDD/paid-handoff" ] \
  && ok "...and it needed no paid opt-in to get there" \
  || bad "free hop" "the fixture left an opt-in behind, so this proved nothing"
paid_optin_on

# ── Fails closed ────────────────────────────────────────────────────────────
# No dashboard AND no reading is the same as no reading: a bare rate_limit can be
# transient throttling, and arming on one would end a session on a guess.
rm -rf "$ADIR" "$RQD"
hf_reset; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100 500
nd_arm sess-nd3
[ -z "$(hf_get armed)" ] && ok "an unmeasurable account still refuses to arm" \
  || bad "armed on no reading" "armed=$(hf_get armed)"
[ ! -f "$CCDD/quota-cache.json" ] && ok "...and no unusable reading is cached as if it were one" \
  || bad "cached a failed probe" "cache: $(cat "$CCDD/quota-cache.json" 2>/dev/null | head -c 80)"

# The hook fires on every prompt and every tool use, and a failed probe leaves the
# cache exactly as stale as it found it. Without a backoff that is a python3 spawn
# and a socket several times a minute for an account that is offline or signed out.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
: > "$CCD_FAKE_USAGE_LOG"
nd_hook UserPromptSubmit >/dev/null 2>&1
n1=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
nd_hook UserPromptSubmit >/dev/null 2>&1
n2=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "${n1:-0}" -ge 1 ] && ok "a missing cache is probed once" \
  || bad "probe never ran" "calls: ${n1:-0}"
[ "${n2:-0}" = "${n1:-0}" ] && ok "...and a failed probe backs off instead of running on every tick" \
  || bad "no backoff" "calls went $n1 → $n2"

# ── A reading can be too old to mean anything ───────────────────────────────
# The cache keeps its last good sample when a refresh fails, so a 96% reading
# survives the reset it was taken before. Arming on that hands off a session
# whose quota is fine, on a rate_limit that was only ever transient.
"$FAKE/sigbin/claude" 8 2>/dev/null & NDPID=$!
sleep 0.3
kill -9 $NDPID 2>/dev/null; wait $NDPID 2>/dev/null
rm -rf "$ADIR" "$RQD"
hf_reset; rm -f "$CCDD/.usage-probe-backoff"
quota 58 100                      # a good reading...
nd_age "$CCDD/quota-cache.json" 5400     # ...taken an hour and a half ago
stage_usage 58 100 500            # and every refresh since has failed
nd_arm sess-nd4
[ -z "$(hf_get armed)" ] && ok "a reading too old to describe now does not arm" \
  || bad "armed on a stale reading" "armed=$(hf_get armed)"
# ...and so does a YOUNG one, when the re-read at the wall fails. The last good
# reading stays on file for the row to show; it has no authority here. Letting it
# corroborate is how a quota that had since reset, plus one transient rate_limit,
# plus one 429 on the re-read, added up to a paid hop.
hf_reset; quota 58 100
nd_age "$CCDD/quota-cache.json" 240
stage_usage 58 100 429
nd_arm sess-nd5
[ -z "$(hf_get armed)" ] && ok "a re-read that fails at the wall fires nothing, whatever the cache still says" \
  || bad "armed on a failed re-read" "armed=$(hf_get armed)"
# Codex's case exactly: nothing registered, a cached 100% whose reset is unknown.
hf_reset
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"sevenDayPercent":40}}\n' > "$CCDD/quota-cache.json"
stage_usage 58 100 429
nd_arm sess-nd5b
[ -z "$(hf_get armed)" ] && ok "...including a cached 100% with no reset time and nobody registered" \
  || bad "armed on a failed re-read" "armed=$(hf_get armed)"
# A re-read that SUCCEEDS is what a working install has, and it is what arms.
hf_reset; quota 58 40
stage_usage 58 100
nd_arm sess-nd5c
[ "$(hf_get armed)" = "True" ] && ok "...while a re-read that succeeds and says spent still arms" \
  || bad "rejected a fresh reading" "armed=$(hf_get armed)"

# A reading can be young and still describe a window that no longer exists. Four
# minutes old passes every age bound, and if its 5-hour window reset three minutes
# ago then 96% is a fact about quota the user no longer has.
hf_reset; rm -f "$CCDD/.usage-probe-backoff"
past=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=3)).isoformat())")
future=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2)).isoformat())")
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"fiveHourReset":"%s","sevenDayPercent":40,"sevenDayReset":"%s"}}\n' \
  "$past" "$future" > "$CCDD/quota-cache.json"
nd_age "$CCDD/quota-cache.json" 240
stage_usage 58 100 500
nd_arm sess-nd6
[ -z "$(hf_get armed)" ] && ok "a window that has already reset does not corroborate" \
  || bad "armed across a reset" "armed=$(hf_get armed)"
# The same reading before its reset is exactly what a real handoff runs on.
hf_reset
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"fiveHourReset":"%s","sevenDayPercent":40,"sevenDayReset":"%s"}}\n' \
  "$future" "$future" > "$CCDD/quota-cache.json"
nd_age "$CCDD/quota-cache.json" 240
stage_usage 100 40
nd_arm sess-nd7
[ "$(hf_get armed)" = "True" ] && ok "...while one whose window is still open, re-read at the wall, does" \
  || bad "rejected a live window" "armed=$(hf_get armed)"

# ── One probe, not one per hook ─────────────────────────────────────────────
# UserPromptSubmit and PostToolUse overlap constantly. Recording the attempt only
# after a failure let every sibling pass the backoff check and open its own
# socket, which is the shape that turns one slow endpoint into a stalled session.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
: > "$CCD_FAKE_USAGE_LOG"
stage_usage 58 100 500
for _ in 1 2 3 4 5 6; do nd_hook PostToolUse >/dev/null 2>&1 & done; wait
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "${calls:-0}" -eq 1 ] && ok "six concurrent hooks make exactly one request" \
  || bad "probe stampede" "6 concurrent hooks made $calls requests, expected 1"

# The same contention on the path that succeeds. A failed probe leaves a backoff
# marker behind, which would hide a lease released too early; a successful one
# leaves nothing until the cache is installed, so only the lease can hold the
# gap between the request returning and the reading being published.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
rm -rf "$CCDD/.usage-probe.lock"
: > "$CCD_FAKE_USAGE_LOG"
stage_usage 58 100
for _ in 1 2 3 4 5 6; do nd_hook PostToolUse >/dev/null 2>&1 & done; wait
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "${calls:-0}" -eq 1 ] && ok "...and exactly one when the request succeeds" \
  || bad "probe stampede on success" "6 concurrent hooks made $calls requests, expected 1"
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "100" ] && ok "...with the reading published exactly once" \
  || bad "publication" "cache holds: $got"
[ ! -d "$CCDD/.usage-probe.lock" ] && ok "...and the lease released after publication" \
  || bad "lease leak" "the lock outlived the probe"

# An installed dashboard that cannot reach Anthropic reports that as valid JSON
# and exits 0. Treating the exit code as the answer published its error payload
# over the last good reading and skipped the fallback, so a machine that could
# measure itself perfectly well lost its handoffs to a broken neighbour.
DASHD="$FAKE/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
mkdir -p "$DASHD"
cat > "$DASHD/check-usage.js" <<'DJS'
// contents are irrelevant; the stub node below decides what it prints
DJS
cp "$FAKE/fakebin/node" "$FAKE/node.before-nodash"
cat > "$FAKE/fakebin/node" <<'NEOF'
#!/bin/sh
echo '{"claude":{"available":false,"error":true}}'
exit 0
NEOF
chmod +x "$FAKE/fakebin/node"
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"; rm -rf "$CCDD/.usage-probe.lock"
: > "$CCD_FAKE_USAGE_LOG"
stage_usage 58 100
nd_hook UserPromptSubmit >/dev/null 2>&1
[ "$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')" -ge 1 ] \
  && ok "a dashboard that answers with an error still falls through to ccd" \
  || bad "fallback suppressed" "the dashboard's error payload was taken as an answer"
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "100" ] && ok "...and the reading that lands is the usable one" \
  || bad "unusable publication" "cache holds: $got"
# ...and when neither producer can answer, the last good reading is left alone.
quota 58 91
stage_usage 58 100 500
nd_age "$CCDD/quota-cache.json" 900
rm -f "$CCDD/.usage-probe-backoff"; rm -rf "$CCDD/.usage-probe.lock"
nd_hook UserPromptSubmit >/dev/null 2>&1
got=$(python3 -c "import json;print((json.load(open('$CCDD/quota-cache.json')).get('claude') or {}).get('sevenDayPercent'))" 2>/dev/null)
[ "$got" = "91" ] && ok "...and neither producer answering leaves the last good one in place" \
  || bad "clobbered a good reading" "cache holds: $got"
cp "$FAKE/node.before-nodash" "$FAKE/fakebin/node"; chmod +x "$FAKE/fakebin/node"
rm -rf "$FAKE/.claude/plugins/cache/claude-dashboard"

# ── What doctor says about it ───────────────────────────────────────────────
# A reading that stops coming is invisible everywhere else: the warnings simply
# never appear again and the handoff quietly stops arming. doctor is the one view
# whose job is to answer "is this working?", so it has to name the state.
doctor_out() {
  OPENROUTER_API_KEY=sk-or-v1-smoketest CLAUDE_PLUGIN_ROOT="$ROOT" \
    "$ROOT/bin/ccd" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
}
rm -f "$CCDD/quota-cache.json" "$CCDD/refresh-failed" "$CCDD/.usage-probe-backoff"
stage_usage 58 100 500
nd_hook UserPromptSubmit >/dev/null 2>&1      # probe fails, leaves the breadcrumb
out=$(doctor_out)
case "$out" in
  *"Quota readings"*) ok "doctor reports the quota reading as its own state" ;;
  *) bad "doctor quota section" "no Quota readings section in doctor output" ;;
esac
case "$out" in
  *"✗ none"*) ok "...and says so plainly when there is no reading to arm on" ;;
  *) bad "doctor with no reading" "got: $(printf '%s' "$out" | grep -A2 'Quota readings' | head -3)" ;;
esac
case "$out" in
  *"could not be measured"*) ok "...carrying the reason the hook already recorded" ;;
  *) bad "doctor breadcrumb" "the recorded reason never reached the user" ;;
esac

rm -f "$CCDD/quota-cache.json" "$CCDD/refresh-failed" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_hook UserPromptSubmit >/dev/null 2>&1
out=$(doctor_out)
case "$out" in
  *"5h 58%"*"7d 100%"*) ok "...and reports the numbers once a reading lands" ;;
  *) bad "doctor with a reading" "got: $(printf '%s' "$out" | grep -A2 'Quota readings' | head -3)" ;;
esac

# doctor and the arming gate must draw the line in the same place. A green check
# on a reading the handoff has already stopped trusting is the exact failure this
# section exists to end.
nd_age "$CCDD/quota-cache.json" 1799
inside=$(doctor_out)
case "$inside" in
  # Absence of the warning is not evidence on its own: doctor failing outright
  # would also lack the string. Require the row it is supposed to print.
  *"Too old to arm"*) bad "doctor freshness" "called a 1799s reading too old" ;;
  *"✓ 5h 58%"*) ok "doctor still trusts a reading one second inside the arming bound" ;;
  *) bad "doctor freshness" "no healthy quota row: ${inside:0:120}" ;;
esac
nd_age "$CCDD/quota-cache.json" 1801
case "$(doctor_out)" in
  *"Too old to arm"*) ok "...and says so the second it falls outside" ;;
  *) bad "doctor freshness" "a 1801s reading still read as healthy" ;;
esac

# doctor and the gate must also agree about a window that has already reset. A
# young sample whose window turned over is evidence about quota nobody has any
# more, and a green check on it is exactly the false healthy this section exists
# to end.
gone=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=3)).isoformat())")
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":100,"fiveHourReset":"%s"}}\n' \
  "$gone" > "$CCDD/quota-cache.json"
nd_age "$CCDD/quota-cache.json" 240
case "$(doctor_out)" in
  *"none usable"*) ok "...and calls a reading whose windows have all reset unusable" ;;
  *) bad "doctor expiry" "reported an expired window as a reading: $(doctor_out | grep -A1 'Quota readings' | tail -1)" ;;
esac
# The same shape with a recorded failure behind it is not the benign case. A
# reading whose windows reset two days ago is not waiting for the next prompt.
printf 'the signed-in Claude account could not be measured (login, token, or network)\n' \
  > "$CCDD/refresh-failed"
nd_age "$CCDD/quota-cache.json" 172800
case "$(doctor_out)" in
  *"Refreshes have stopped"*) ok "...and names the cause when one was recorded" ;;
  *) bad "doctor expiry" "offered reassurance over a recorded failure" ;;
esac
case "$(doctor_out)" in
  *"could not be measured"*) ok "...carrying the recorded reason through" ;;
  *) bad "doctor expiry" "the reason never reached the user" ;;
esac
rm -f "$CCDD/refresh-failed"

# Termination while the lease is held must not strand it. A hook killed during
# validation used to leave the lock behind, and every later hook then had to wait
# out the stale-lock reaper before it could refresh at all.
rm -rf "$CCDD/.usage-probe.lock"; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
stage_usage 58 100
nd_hook UserPromptSubmit >/dev/null 2>&1
[ ! -d "$CCDD/.usage-probe.lock" ] && ok "a completed refresh leaves no lease behind" \
  || bad "lease leak" "the lock outlived a normal refresh"
# Termination while the lease is held must not strand it: the EXIT/INT/TERM traps
# release it, and a hook killed mid-refresh would otherwise make every later one
# wait out the reaper before it could refresh at all.
rm -rf "$CCDD/.usage-probe.lock"; rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
# Signal the hook itself, not a wrapper subshell around it: TERM on a wrapper
# kills the wrapper while the hook runs to completion, and the assertion then
# passes without the trap ever firing. And hold the probe open, so the kill
# lands while the lease is actually held rather than before or after it.
mkdir -p "$FAKE/slowplug/bin"
printf '#!/bin/sh\nsleep 5\n' > "$FAKE/slowplug/bin/ccd-account"
chmod +x "$FAKE/slowplug/bin/ccd-account"
CLAUDE_PLUGIN_ROOT="$FAKE/slowplug" "$ROOT/scripts/quota-guard.sh" UserPromptSubmit \
  >/dev/null 2>&1 < /dev/null & HKPID=$!
held=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -d "$CCDD/.usage-probe.lock" ] && { held=1; break; }
  sleep 0.1
done
[ "$held" -eq 1 ] && ok "the lease is held for the length of the request" \
  || bad "lease never taken" "nothing to clean up, so the next assertion proves nothing"
kill -TERM $HKPID 2>/dev/null; wait $HKPID 2>/dev/null
[ ! -d "$CCDD/.usage-probe.lock" ] && ok "...and a hook killed mid-request releases it" \
  || bad "lease leak" "a TERMed hook stranded the lock"
rm -rf "$FAKE/slowplug"

# And if one survives anyway, it still cannot block the event that matters:
# StopFailure takes no lease, so an armed handoff fires straight through it.
rm -f "$CCDD/quota-cache.json" "$CCDD/.usage-probe-backoff"
mkdir -p "$CCDD/.usage-probe.lock"          # as a killed hook would leave it
stage_usage 58 100
hf_reset
nd_arm sess-nd8
[ "$(hf_get armed)" = "True" ] && ok "...and a stranded lease never blocks a handoff" \
  || bad "lease blocks arming" "armed=$(hf_get armed)"
rm -rf "$CCDD/.usage-probe.lock"

# Publication that fails must not look like one that succeeded: clearing the
# markers there would advertise a fresh reading the cache never received.
rm -rf "$CCDD/.usage-probe.lock"; rm -f "$CCDD/quota-cache.json" "$CCDD/refresh-failed"
: > "$CCDD/.usage-probe-backoff"; nd_age "$CCDD/.usage-probe-backoff" 400
stage_usage 58 100
# Fail the move itself. A directory at the cache path does not do it: `mv file
# dir` moves the file into the directory and reports success.
cat > "$FAKE/fakebin/mv" <<'MVEOF'
#!/bin/sh
exit 1
MVEOF
chmod +x "$FAKE/fakebin/mv"
nd_hook UserPromptSubmit >/dev/null 2>&1
rm -f "$FAKE/fakebin/mv"
grep -q "could not be written" "$CCDD/refresh-failed" 2>/dev/null \
  && ok "a reading that cannot be written is recorded as a publication failure" \
  || bad "silent publication failure" "got: $(cat "$CCDD/refresh-failed" 2>&1 | head -1)"
[ -f "$CCDD/.usage-probe-backoff" ] && ok "...and the retry protection is left in place" \
  || bad "backoff cleared" "a failed publication cleared the marker"
[ ! -f "$CCDD/quota-cache.json" ] && ok "...and no half-written reading is left at the cache path" \
  || bad "publication" "a failed move still produced a cache file"

# Subscription-only users are the ones this whole path is for, and they have no
# OpenRouter key. doctor used to exit at the top without one, which put the
# accounts, handoff and quota sections behind a paid fallback nobody needs yet.
mv "$CCDD/providers/keys.env" "$CCDD/providers/keys.env.bak"
nokey_out=$(env -u OPENROUTER_API_KEY CLAUDE_PLUGIN_ROOT="$ROOT" \
  "$ROOT/bin/ccd" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')
mv "$CCDD/providers/keys.env.bak" "$CCDD/providers/keys.env"
case "$nokey_out" in
  *"Quota readings"*) ok "doctor diagnoses the subscription path with no OpenRouter key" ;;
  *) bad "doctor without a key" "got: ${nokey_out:0:160}" ;;
esac
case "$nokey_out" in
  *"Automatic handoff"*) ok "...including the handoff section it used to exit before" ;;
  *) bad "doctor without a key" "no handoff section" ;;
esac
case "$nokey_out" in
  *"no key configured"*) ok "...and names the fallback as the one thing missing" ;;
  *) bad "doctor without a key" "never mentioned the missing key" ;;
esac

unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG
rm -rf "$ADIR" "$RQD"

head_ "29. the swap that happens inside the session"
# Ending a session to change account was always the expensive half of the hop: the
# turn dies, a launcher relaunches it, and the user waits through a cold start. The
# measurements in #57 say none of that is needed — the credential ccd writes is the
# one Claude Code's very next request reads, and a swap held for 16.9 hours across
# two token refreshes in one live process. So the primary path swaps where the
# session already is, off the reading ccd was taking anyway, ten minutes before the
# wall; StopFailure stays as the backstop for what that reading cannot see, and
# wakes the parked session itself instead of asking the user to type.
SWD="$FAKE/.claude/ccd"
# Nothing in this section may reach Anthropic: a swap is a real side effect and the
# tokens here are fixtures. Both endpoints point at a closed port, so a call that
# escaped fails in milliseconds instead of spending a real account's quota.
export CCD_USAGE_URL="http://127.0.0.1:1/usage" CCD_TOKEN_URL="http://127.0.0.1:1/token"
# The free hop needs no opt-in; leaving the paid one armed would let a fallthrough
# end the stand-in and make these assertions about the wrong thing.
paid_optin_off
# The plugin root is passed explicitly. Without it the hook resolves ccd-account
# through the plugin cache, where an older copy is staged — and the section would
# test that copy instead of the tree.
# A run at the wall re-reads the account, so it always gets the stand-in endpoint;
# a tick gets whatever the section exported, as before.
sw_hook() {
  if [ "${1:-}" = StopFailure ]; then
    CLAUDE_PLUGIN_ROOT="${SW_ROOT:-$ROOT}" CCD_SWAP_SETTLE="${SW_SETTLE:-0}" env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" "$@"
  else
    CLAUDE_PLUGIN_ROOT="${SW_ROOT:-$ROOT}" CCD_SWAP_SETTLE="${SW_SETTLE:-0}" "$ROOT/scripts/quota-guard.sh" "$@"
  fi
}
# Its own store, every time. Two accounts, the signed-in one spent and the other
# with room, plus the reading that corroborates it. Seeded per case rather than
# inherited: a case that ran on the previous one's leftovers would have nothing to
# distinguish a swap that happened from one that already had.
sw_fixture() { # $1=signed-in 5h  $2=signed-in 7d  [$3=spare 5h  $4=spare 7d]
  # No canned endpoint answer left over from the case before: each case stages its own.
  rm -f "${CCD_FAKE_USAGE:-/nonexistent}"
  rm -rf "$ADIR" "$RQD" "$SWD/swapped-windows" "$FAKE/.claude.json" \
         "$SWD/handoff-00000000000000000000000000000002.json"
  mkdir -p "$ADIR"
  write_creds spent; "$ACCT" --no-color add --name spent --label "spent@example.com" >/dev/null 2>&1
  write_creds spare; "$ACCT" --no-color add --name spare --label "spare@example.com" >/dev/null 2>&1
  "$ACCT" --no-color use spent --force >/dev/null 2>&1
  printf '{"spent":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":100,"seven_day_percent":100},"spare":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":%s,"seven_day_percent":%s}}' \
    "$(date +%s)" "$(cred_fp "$ADIR/spent.json")" \
    "$(date +%s)" "$(cred_fp "$ADIR/spare.json")" "${3:-10}" "${4:-20}" | rq_put
  # Nothing here may spend a one-time refresh token, so keepalive is not due.
  printf '{"fails":0}' > "$SWD/accounts-keepalive"
  quota "$1" "$2"          # written last: the swap above deletes this file
  rm -f "$SWD/last-warn" "$SWD/accounts-stale" "$SWD/last-stale-warn" "$SWD/refresh-failed"
}
sw_prompt() { # $1=event  $2=session id ; stdout is the hook's own
  printf '{"session_id":"%s","cwd":"/tmp/w"}' "$2" \
    | CCD_HANDOFF=00000000000000000000000000000002 \
      CCD_HANDOFF_STATE="$SWD/handoff-00000000000000000000000000000002.json" \
      CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID sw_hook "$1" 2>/dev/null
}

# ── Before the wall: the turn never has to end ──────────────────────────────
# The whole launcher contract is handed to the hook on purpose. A swap that needs
# none of it must be seen not to use it.
set +m 2>/dev/null
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
out=$(sw_prompt UserPromptSubmit sess-sw1)
grep -q 'AT-spare' "$CREDS" \
  && ok "a corroborated 96% with a spare in reach swaps the session in place" \
  || bad "in-session swap" "the credential never moved"
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  && ok "...and the active pointer follows it" \
  || bad "in-session swap" "pointer: $(cat "$ADIR/.active" 2>/dev/null)"
python3 - "$out" <<'PY' \
  && ok "...saying so in one line the user sees, and telling the model why" \
  || bad "swap message" "got: ${out:0:200}"
import json, sys
d = json.loads(sys.argv[1])
msg = d.get("systemMessage") or ""
ctx = (d.get("hookSpecificOutput") or {}).get("additionalContext") or ""
assert "spare" in msg, f"systemMessage does not name the account: {msg!r}"
assert "spare" in ctx, f"additionalContext does not name the account: {ctx!r}"
PY
if kill -0 "$SWPID" 2>/dev/null; then ok "...and the session is never signalled — the turn keeps going"
else bad "in-session swap" "ended the session it was supposed to keep"; fi
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and nothing is armed for a launcher to relaunch" \
  || bad "in-session swap" "armed a handoff for a swap that had already happened"

# An autonomous turn fires tool uses and never a prompt, and that is exactly the
# turn that burns the last of the quota.
sw_fixture 58 100
sw_prompt PostToolUse sess-sw2 >/dev/null
grep -q 'AT-spare' "$CREDS" \
  && ok "a tool-use tick swaps too, not only a typed prompt" \
  || bad "tool-use swap" "the credential never moved"

# ── ...but only when the reading actually says so ───────────────────────────
sw_fixture 58 90
sw_prompt UserPromptSubmit sess-sw3 >/dev/null
grep -q 'AT-spent' "$CREDS" \
  && ok "a reading below the arm threshold swaps nothing" \
  || bad "threshold" "swapped on a reading that corroborates nothing"

sw_fixture 58 100 100 100
out=$(sw_prompt UserPromptSubmit sess-sw4)
grep -q 'AT-spent' "$CREDS" \
  && ok "...and neither does a spare with no room left" \
  || bad "no room" "swapped onto an account that is spent too"
case "$out" in
  *"QUOTA NEARLY EXHAUSTED"*) ok "...while the warning that was always there still arrives" ;;
  *) bad "warning preempted" "got: ${out:0:140}" ;;
esac
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── The account a swap just left is not where the next one goes ─────────────
# The ordinary case cannot repeat, because the swap deletes the reading that
# caused it. What can is a cached row claiming room for an account that has none:
# the session would walk back and forth between two spent accounts. The rule that
# stops it cannot be "refuse to leave" — a stale row lands you back on a spent
# account, and refusing to leave it again strands you there while a healthy one is
# registered. So a swap records where it came FROM, and that account stops being a
# destination while the record is live. Leaving is never blocked.
sw_fixture3() { # three accounts; the signed-in one is the most attractive row of all
  sw_fixture 58 100
  write_creds spare2; "$ACCT" --no-color add --name spare2 --label "spare2@example.com" >/dev/null 2>&1
  "$ACCT" --no-color use spent --force >/dev/null 2>&1
  printf '{"spent":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":1,"seven_day_percent":1,"five_hour_reset":"R1","seven_day_reset":"D1"},"spare":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":10,"seven_day_percent":20,"five_hour_reset":"R1","seven_day_reset":"D1"},"spare2":{"status":"ok","checked_at":%s,"cred":"%s","five_hour_percent":30,"seven_day_percent":40,"five_hour_reset":"R1","seven_day_reset":"D1"}}' \
    "$(date +%s)" "$(cred_fp "$ADIR/spent.json")" \
    "$(date +%s)" "$(cred_fp "$ADIR/spare.json")" \
    "$(date +%s)" "$(cred_fp "$ADIR/spare2.json")" | rq_put
  quota "$1" "$2"
}
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture3 58 100
sw_prompt UserPromptSubmit sess-sw5 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "flap guard" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
quota 58 100                        # the account it landed on is spent too
sw_prompt UserPromptSubmit sess-sw6 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "the account a swap just left is not offered as the next destination" \
  || bad "flap guard" "went to $(cat "$ADIR/.active" 2>/dev/null) — back onto an account it had just left as spent"

# A reading that names no window at all is the same situation, not a hole in the
# rule: without a record there, one unreadable reading walks the session through
# every account it owns.
sw_fixture3 58 100
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"sevenDayPercent":100}}\n' \
  > "$SWD/quota-cache.json"
sw_prompt UserPromptSubmit sess-sw5b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "no-window guard" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"sevenDayPercent":100}}\n' \
  > "$SWD/quota-cache.json"
sw_prompt UserPromptSubmit sess-sw6b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "...and a reading with no reset timestamp records the departure all the same" \
  || bad "no-window guard" "went to $(cat "$ADIR/.active" 2>/dev/null) on a reading that names no window"

# Bounded by time, not by how many entries fit: an account left long enough ago is
# a destination again, whatever else has been recorded since.
sw_fixture3 58 100
export CCD_SWAP_GUARD_TTL=1
sw_prompt UserPromptSubmit sess-sw7 >/dev/null
quota 58 100
sw_prompt UserPromptSubmit sess-sw7b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  || bad "guard ttl" "the second hop went to $(cat "$ADIR/.active" 2>/dev/null)"
sleep 2
quota 58 100
sw_prompt UserPromptSubmit sess-sw7c >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spent" ] \
  && ok "...and a record that has aged out stops excluding anything" \
  || bad "guard ttl" "still excluded an account left longer ago than the bound: $(cat "$ADIR/.active" 2>/dev/null)"
unset CCD_SWAP_GUARD_TTL
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── After the wall: swap, then wake the session that parked ─────────────────
# Claude Code never resumes a parked session by itself — every recovery in the
# transcripts was a human typing. So the backstop does not just swap and fall
# silent: it confirms the credential landed and exits 2, which is the one thing an
# asyncRewake entry acts on.
sw_stopfail() { # $1=session id ; prints the hook's exit code
  printf '{"session_id":"%s","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"rate_limit"}' "$1" \
    | CCD_HANDOFF=00000000000000000000000000000002 \
      CCD_HANDOFF_STATE="$SWD/handoff-00000000000000000000000000000002.json" \
      CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID sw_hook StopFailure \
      >"$FAKE/.sw-out" 2>"$FAKE/.sw-err"
  printf '%s' "$?"
}
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rc=$(sw_stopfail sess-sw8)
grep -q 'AT-spare' "$CREDS" \
  && ok "a limit that arrived before the reading could see it still swaps in place" \
  || bad "backstop swap" "the credential never moved"
[ "$rc" = "2" ] \
  && ok "...and exits 2, the only code an asyncRewake hook wakes on" \
  || bad "wake" "exit code $rc"
grep -q 'spare' "$FAKE/.sw-err" \
  && ok "...naming the account in the text the wake carries" \
  || bad "wake text" "stderr: $(head -c 140 "$FAKE/.sw-err")"
grep -qi 'do not repeat work' "$FAKE/.sw-err" \
  && ok "...and telling the model to continue rather than start the task over" \
  || bad "wake text" "stderr: $(head -c 180 "$FAKE/.sw-err")"
if kill -0 "$SWPID" 2>/dev/null; then ok "...without signalling the session it just repaired"
else bad "backstop" "ended the session instead of waking it"; fi
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and without arming a relaunch it no longer needs" \
  || bad "backstop" "armed a launcher handoff for a swap it had performed itself"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# A wake that lands on the account we just left is a wasted turn: it fails the same
# way and parks again. The swap writes the live store, but a keychain that refused
# — or this session writing its own refreshed blob back over ours — leaves that
# store holding the credential we meant to leave. Only the credential's own
# identity can settle that: a plan is not an account, and two accounts on one plan
# (which is what this fixture is) agree about every plan field there is.
#
# The write-back has to land in one window: after the swap wrote the store, and
# before the confirmation read it. A background `sleep 0.7` guessed at that
# window off the clock and lost it twice in CI (#88) — the hook is three Python
# starts away from the swap, and on a runner that takes longer over them the
# revert lands INSIDE the swap and is overwritten, which confirms and wakes.
# So the revert is not timed at all: the ccd-account the hook resolves does it,
# at the one point in the sequence where it belongs. `swap` records that the
# credential moved; the `current --json` that confirms it puts the outgoing blob
# back first and then hands the read to the real ccd-account, which still
# decides the question on the store's actual contents. Ordering by construction,
# on any machine, at any speed.
mkdir -p "$FAKE/revertroot/bin"
cat > "$FAKE/revertroot/bin/ccd-account" <<'REOF'
#!/bin/sh
for a in "$@"; do
  [ "$a" = swap ] && { "$CCD_REAL_ACCOUNT" "$@"; rc=$?; : > "$HOME/.swap-done"; exit "$rc"; }
done
case " $* " in
  *" current --json "*)
    [ -e "$HOME/.swap-done" ] && cp "$HOME/.creds-before" "$SW_LIVE_CREDS" ;;
esac
exec "$CCD_REAL_ACCOUNT" "$@"
REOF
chmod +x "$FAKE/revertroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT" SW_LIVE_CREDS="$CREDS"
# Long-lived on purpose: `kill -0` below means "nothing signalled it", and only
# a stand-in that cannot age out mid-block says that rather than how long the
# block took. At `claude 8` the check ran with 2.1s to spare here and 1.1s under
# load — the second half of #88's CI failure.
"$FAKE/sigbin/claude" 60 2>/dev/null & SWPID=$!
sw_fixture 58 100
cp "$CREDS" "$FAKE/.creds-before"            # the outgoing account's live blob
rm -f "$FAKE/.swap-done"
rc=$(SW_ROOT="$FAKE/revertroot" sw_stopfail sess-sw9)
[ "$rc" != "2" ] \
  && ok "a live store that no longer holds the credential we installed wakes nothing" \
  || bad "unconfirmed wake" "woke the session into the account it had just left"

# ...and a swap it cannot confirm is not a reason to start spending money. The
# credential, the pointer and the guard record have all moved by then; arming the
# paid hop on top of that bills the user for a swap that may well have worked.
paid_optin_on
sw_fixture 58 100
cp "$CREDS" "$FAKE/.creds-before"
rm -f "$FAKE/.swap-done"
rc=$(SW_ROOT="$FAKE/revertroot" sw_stopfail sess-sw9b)
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and arms no paid hop off a confirmation that failed" \
  || bad "unconfirmed paid hop" "armed $(hf_get direction) after a swap it could not confirm"
if kill -0 "$SWPID" 2>/dev/null; then ok "...nor ends the session over one"
else bad "unconfirmed paid hop" "signalled a session whose swap had already happened"; fi
paid_optin_off
unset SW_LIVE_CREDS
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── The wake has to be registered, and has to read like something ccd said ──
python3 - "$ROOT/hooks/hooks.json" "$ROOT/scripts/quota-guard.sh" <<'PY' \
  && ok "the StopFailure entry is registered as an asyncRewake hook" \
  || bad "hooks.json" "the exit 2 above would wake nothing"
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["StopFailure"]
entry = [e for g in groups for e in g["hooks"]][0]
assert entry.get("asyncRewake") is True, "asyncRewake is not set on the command hook"
# Section 30 owns the arithmetic: a timeout that clears the settle alone says
# nothing about the pick that runs before it.
assert isinstance(entry.get("timeout"), int), f"timeout is {entry.get('timeout')!r}"
PY
python3 - "$ROOT/hooks/hooks.json" <<'PY' \
  && ok "...carrying wake text of its own, not the blocking-error default" \
  || bad "hooks.json" "the user would read 'Stop hook blocking error from command …'"
import json, sys
entry = [e for g in json.load(open(sys.argv[1]))["hooks"]["StopFailure"] for e in g["hooks"]][0]
msg = entry.get("rewakeMessage") or ""
summary = entry.get("rewakeSummary") or ""
assert "usage limit" in msg, f"rewakeMessage: {msg!r}"
assert "do not repeat work" in msg.lower(), f"rewakeMessage: {msg!r}"
assert summary, "rewakeSummary is unset, so the default stands in for it"
for s in (msg, summary):
    assert "blocking error" not in s.lower(), f"default phrasing left in: {s!r}"
PY

# ── Coming back off OpenRouter is the one hop that still ends a session ─────
# While the session runs on OpenRouter its backbone is an environment variable, so
# writing a credential reaches nothing — leaving really does take a relaunch, and
# that is what the launcher is still for. What changed is that it is no longer told
# WHICH account to install: the hook swaps to the spare in place first and arms the
# plain return, so the relaunch simply lands on whatever is live.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
printf '{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5}\n' > "$SWD/run-state.json"
hf_reset
out=$(printf '{"session_id":"sess-sw10","cwd":"/tmp/w"}' \
  | CCD_ACTIVE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_AUTH_TOKEN=x \
    CCD_HANDOFF=00000000000000000000000000000002 \
    CCD_HANDOFF_STATE="$SWD/handoff-00000000000000000000000000000002.json" \
    CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID sw_hook UserPromptSubmit 2>/dev/null)
grep -q 'AT-spare' "$CREDS" \
  && ok "a spare with room takes the session off the paid backbone, credential first" \
  || bad "return hop" "armed a relaunch onto an account it never installed"
[ "$(hf_get direction)" = "to_subscription" ] \
  && ok "...arming the plain return, not an account the launcher would have to install" \
  || bad "return direction" "got: $(hf_get direction)"
[ -z "$(hf_get account)" ] \
  && ok "...naming no account, because the live store already is one" \
  || bad "return state" "still carries an account field: $(hf_get account)"
case "$out" in
  *spare*) ok "...and says where the session is going, in the user's own screen" ;;
  *) bad "return message" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 140)" ;;
esac
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
rm -f "$SWD/run-state.json"

head_ "30. the swap is one transaction, under one lock"
# Deciding where to go and installing the credential were two processes and no
# lock: the account was read before anything was held, so the background keepalive
# could rotate that account's one-time token in between and the swap would install
# the copy it read — a dead spare, handed to a session that has just run out.

# ── The token that is installed is the token the store holds NOW ────────────
# Held against the STORE lock, which is what every writer of a credential takes.
# The swap takes no other lock: the single-flight one is for background passes,
# and waiting on it was how a prompt tick ended up waiting on somebody else's
# HTTP request.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
# The background job's own single-flight lock, held while it rotates the spare —
# exactly what `ccd-account keepalive` does behind REFRESH_LOCK.
python3 - "$ADIR/.lock" "$ADIR/spare.json" "$RQD/spare.json" <<'PY' &
import fcntl, hashlib, json, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
d = json.load(open(sys.argv[2]))
d["claudeAiOauth"]["accessToken"] = "AT-spare-rotated"
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
# The pass re-measures what it rotated, exactly as `keepalive --pick` does: a
# verdict that still named the retired token would be discarded as somebody
# else's, and this test would pass for the wrong reason.
q = json.load(open(sys.argv[3]))
q["cred"] = hashlib.sha256(b"AT-spare-rotated").hexdigest()[:16]
q["checked_at"] = int(time.time())
with open(sys.argv[3], "w") as f:
    json.dump(q, f)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
ROT=$!
sleep 0.4
sw_prompt UserPromptSubmit sess-tx1 >/dev/null
wait "$ROT" 2>/dev/null
grep -q 'AT-spare-rotated' "$CREDS" \
  && ok "a swap installs the credential the store holds when it takes the lock" \
  || bad "rotation race" "installed a snapshot read before the lock — a spent one-time token"

# The same race one lock deeper. `ccd account refresh` takes the store lock and
# not the single-flight, so holding the single-flight is not enough: the account
# has to be READ inside the store lock too, or the swap installs a copy that was
# already stale when it got there.
sw_fixture 58 100
python3 - "$ADIR/.lock" "$ADIR/spare.json" "$RQD/spare.json" <<'PY' &
import fcntl, hashlib, json, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
d = json.load(open(sys.argv[2]))
d["claudeAiOauth"]["accessToken"] = "AT-spare-rotated"
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
q = json.load(open(sys.argv[3]))
q["cred"] = hashlib.sha256(b"AT-spare-rotated").hexdigest()[:16]
q["checked_at"] = int(time.time())
with open(sys.argv[3], "w") as f:
    json.dump(q, f)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
ROT=$!
sleep 0.4
sw_prompt UserPromptSubmit sess-tx1b >/dev/null
wait "$ROT" 2>/dev/null
grep -q 'AT-spare-rotated' "$CREDS" \
  && ok "...read inside that lock too, so a refresh beside it cannot be lost" \
  || bad "rotation race" "installed the copy it read before the store lock"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── A decision about an account we are no longer on does nothing ────────────
# Two sessions can reach the same reading and both decide to leave the same
# account. The second one has to notice the store moved while it was deciding, or
# one reading walks the session through two accounts.
sw_fixture3 58 100
out=$("$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --no-probe 2>/dev/null); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | cut -f1)" = "spare" ]; } \
  && ok "a swap names where it went, and the credential it installed" \
  || bad "swap command" "rc=$rc out='$(printf '%s' "$out" | tr '\t' ' ')'"
[ -n "$(printf '%s' "$out" | cut -f2)" ] \
  && ok "...as an identity the confirmation can check later" \
  || bad "swap command" "named no credential: '$(printf '%s' "$out" | tr '\t' ' ')'"
out2=$("$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --no-probe 2>/dev/null); rc2=$?
{ [ "$rc2" -ne 0 ] && [ "$(cat "$ADIR/.active")" = "spare" ]; } \
  && ok "...and a second decision about the account we already left does nothing" \
  || bad "stale decision" "rc=$rc2, now on $(cat "$ADIR/.active")"

# Both departures stay on the record. Count-based eviction threw away entries that
# were still current; time is the only bound now.
"$ACCT" --no-color swap --from spare --window "5h=R1;7d=D1" --no-probe >/dev/null 2>&1
recs=$(python3 - "$SWD/swapped-windows" <<'PY'
import sys
try:
    lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
except OSError:
    lines = []
print(" ".join(sorted(l.split("\t")[1] for l in lines if len(l.split("\t")) >= 2)))
PY
)
[ "$recs" = "spare spent" ] \
  && ok "every account a swap left stays on the record while it is current" \
  || bad "guard record" "recorded: '$recs'"

# ── The pick gets a deadline, and the hook's budget covers what follows it ──
# best_target() probes candidates one after another and a refresh tries two
# endpoints; nine expired spares ahead of a usable one can eat the whole hook
# timeout, and a hook killed there wakes nobody.
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
sw_fixture3 58 100
stage_usage 5 5          # after the fixture: it clears the canned answer of the case before
rm -rf "$RQD"        # nothing measured: every candidate needs a probe
: > "$CCD_FAKE_USAGE_LOG"
"$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --deadline 0 >/dev/null 2>&1; rc=$?
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
{ [ "$rc" -ne 0 ] && [ "${calls:-0}" -eq 0 ]; } \
  && ok "a pick with no budget left probes nothing rather than overrunning the hook" \
  || bad "pick deadline" "rc=$rc after ${calls:-0} probes"
: > "$CCD_FAKE_USAGE_LOG"
"$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" --deadline 30 >/dev/null 2>&1
[ "$(cat "$ADIR/.active")" != "spent" ] \
  && ok "...while a budget that allows one measures and moves" \
  || bad "pick deadline" "measured nothing with 30s of budget ($(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ') probes)"
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

python3 - "$ROOT/hooks/hooks.json" "$ROOT/scripts/quota-guard.sh" <<'PY' \
  && ok "the hook's timeout covers the pick's budget, the settle and the wake" \
  || bad "hook budget" "the backstop can be killed before it wakes anything"
import json, re, sys
src = open(sys.argv[2]).read()
def env_default(name):
    m = re.search(rf"{name}:-(\d+)", src)
    assert m, f"{name} has no default in quota-guard.sh"
    return int(m.group(1))
settle = env_default("CCD_SWAP_SETTLE")
budget = env_default("CCD_SWAP_PICK_BUDGET")
entry = [e for g in json.load(open(sys.argv[1]))["hooks"]["StopFailure"] for e in g["hooks"]][0]
t = entry.get("timeout")
assert isinstance(t, int), f"timeout is {t!r}"
# The pick may spend its whole budget, the settle runs after it, and the swap,
# the confirm and the wake all have to fit in what is left.
assert t >= budget + settle + 30, \
    f"timeout {t} leaves {t - budget - settle}s for a swap, a confirm and a wake"
PY

# ── Nothing rotates a stored credential outside the store lock ─────────────
# Reading inside a lock only protects against writers that take it. `ccd account
# pick` refreshes an expired token on its way to a reading, and it used to do that
# holding neither lock: a swap could read an account, the pick could rotate it,
# and the swap would install the copy it had — a one-time token the server had
# already retired, which is a dead spare handed to a session that has just run out.
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
sw_fixture 58 100
stage_usage 5 5 200 0 AT-spare-rotated
# Expire the spare's stored token and age its verdict, so the pick has to rotate
# before it can measure.
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
# Another writer owns the store for the next second and a half, and changes a
# field of the very account the pick is about to rotate before it lets go.
python3 - "$ADIR/.lock" "$ADIR/spare.json" <<'PY' &
import fcntl, json, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(1.5)
d = json.load(open(sys.argv[2]))
d["label"] = "relabelled-under-the-lock"
with open(sys.argv[2], "w") as f:
    json.dump(d, f)
time.sleep(0.3)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
"$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 1
mid=$(python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$ADIR/spare.json")
wait "$PICKPID" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$mid" = "AT-spare" ] \
  && ok "a rotation waits for the store lock instead of writing beside it" \
  || bad "unlocked rotation" "rotated to '$mid' while another writer held the lock"
python3 - "$ADIR/spare.json" <<'PY' \
  && ok "...and re-reads there, so the change made while it waited is not lost" \
  || bad "unlocked rotation" "wrote a copy read before the lock"
import json, sys
d = json.load(open(sys.argv[1]))
assert (d.get("claudeAiOauth") or {}).get("accessToken") == "AT-spare-rotated", \
    "the fixture never rotated, so this proved nothing"
assert d.get("label") == "relabelled-under-the-lock", f"label: {d.get('label')!r}"
PY

# ── Operational failure is not "every subscription is spent" ────────────────
# Only the second answer may reach a backbone that bills. A tool that cannot
# answer at all is the first, and buying OpenRouter on it is the one mistake here
# that costs money.
mkdir -p "$FAKE/brokenroot/bin"
printf '#!/bin/sh\nexit 3\n' > "$FAKE/brokenroot/bin/ccd-account"
chmod +x "$FAKE/brokenroot/bin/ccd-account"
paid_optin_on
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rc=$(SW_ROOT="$FAKE/brokenroot" sw_stopfail sess-f2)
[ ! -f "$SWD/handoff-00000000000000000000000000000002.json" ] \
  && ok "an account tool that cannot answer never reaches the paid hop" \
  || bad "paid gate" "armed $(hf_get direction) on a tool failure"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
paid_optin_off

# ── The decision is checked against the account the READING was about ───────
# The hook reads a quota, and only then asks which account it is on. Between the
# two another session can swap; the stale verdict then reads as if it were about
# the account we are now on, and moves the session a second time.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture3 58 100
f3_reading() {  # the shape ccd's own probe writes: the reading names its account
  printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"fiveHourReset":"R1","sevenDayPercent":100,"sevenDayReset":"D1"},"account":"%s"}\n' "$1" \
    > "$SWD/quota-cache.json"
}
"$ACCT" --no-color use spare --force >/dev/null 2>&1   # another session got there first
f3_reading spent                                        # ...and this reading predates it
sw_prompt UserPromptSubmit sess-f3 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  && ok "a reading about an account we have already left moves nothing" \
  || bad "stale reading" "swapped again, onto $(cat "$ADIR/.active" 2>/dev/null)"
# ...and the refusal is about staleness, not about refusing: the same tick on a
# reading that does name the account we are on moves the session.
f3_reading spare
sw_prompt UserPromptSubmit sess-f3b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" != "spare" ] \
  && ok "...while a reading about the account we are on still moves it" \
  || bad "stale reading" "refused a current reading too"

# ── A window that has turned over is a new situation ────────────────────────
# The record carries the windows it was written in. An account whose own reading
# now names different resets has had a reset since; keeping it excluded on the
# name alone strands a two-account install for the rest of the TTL.
sw_fixture3 58 100
sw_prompt UserPromptSubmit sess-f4 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "window release" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1]))
q["spent"]["five_hour_reset"] = "R2"      # the window we left it in has turned over
q["spent"]["seven_day_reset"] = "D2"
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
quota 58 100
sw_prompt UserPromptSubmit sess-f4b >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spent" ] \
  && ok "an account whose windows have turned over is a destination again" \
  || bad "window release" "still excluded on the name alone: $(cat "$ADIR/.active" 2>/dev/null)"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── One registered account beside an unregistered login ─────────────────────
# A supported install (#41): the one registered account IS the spare. Refusing
# because ccd cannot name the account we are on makes the escape unreachable for
# exactly the people who need it most.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rm -f "$ADIR/spent.json" "$ADIR/.active" "$ADIR/.active-at"
sw_prompt UserPromptSubmit sess-f7 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  && ok "an unregistered login can still reach the one account that is registered" \
  || bad "solo spare" "went nowhere: $(cat "$ADIR/.active" 2>/dev/null)"

# ── A rotation during the settle is not a failed swap ───────────────────────
# Twelve seconds is long enough for Claude Code to renew the credential ccd just
# installed. ccd never rotates a live account itself, but the next ccd-account
# command banks what Claude Code rotated into that account's own file — so both
# halves end up holding it, the credential is still provably the target's, and
# byte equality would be the only thing calling that a failure.
sw_fixture 58 100
( sleep 0.7; python3 - "$CREDS" "$ADIR/spare.json" <<'PY'
import json, sys
for path in sys.argv[1:3]:
    d = json.load(open(path))
    d["claudeAiOauth"]["accessToken"] = "AT-spare-refreshed"
    json.dump(d, open(path, "w"))
PY
) &
ROT=$!
rc=$(SW_SETTLE=2 sw_stopfail sess-f6)
wait "$ROT" 2>/dev/null
[ "$rc" = "2" ] \
  && ok "a rotation of the installed credential during the settle still wakes the turn" \
  || bad "settle rotation" "exit $rc — a legitimate refresh read as a failed swap"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── The budget reaches the socket, and the prompt path never waits on it ────
sw_fixture3 58 100
rm -rf "$RQD"
stage_usage 5 5
: > "$CCD_FAKE_USAGE_LOG"
# A ten-second per-request bound against a three-second budget: the bound that
# reaches the socket has to be the budget, or the hook is killed mid-probe.
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" \
  --deadline 3 >/dev/null 2>&1
worst_timeout=$(awk -F'\t' '{if ($2+0 > m) m=$2+0} END {print m+0}' "$CCD_FAKE_USAGE_LOG")
python3 -c "import sys; sys.exit(0 if 0 < float(sys.argv[1]) <= 3 else 1)" "${worst_timeout:-0}" \
  && ok "the decision's remaining budget is what bounds each request" \
  || bad "request budget" "a request was given ${worst_timeout}s of a 3s budget"

# A prompt tick fires several times a minute. Waiting on a background pass there
# is a frozen prompt, and the next tick can decide just as well.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
python3 - "$ADIR/.refresh.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(8)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
start=$(date +%s)
sw_prompt UserPromptSubmit sess-f5b >/dev/null
waited=$(( $(date +%s) - start ))
kill -9 "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$waited" -le 5 ] \
  && ok "...and a prompt tick gives up on a busy background pass rather than blocking" \
  || bad "prompt wait" "the tick held the prompt for ${waited}s"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

# ── Paying is proved, never inferred ────────────────────────────────────────
# Every way a swap can fail that is not "there is measurably nowhere free to go"
# used to end at the same fork, and one branch of that fork spends the user's
# money. The paid arm asks its own question now, and only a fresh successful
# measurement of every registered account can answer it yes.
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
paid_optin_on
# Each case seeds its own store, stand-in, consent and key: a case that ran on the
# last one's leftovers could not tell a hop that was refused from one that had
# already been made.
PROOF="every-subscription-measured-spent"
pay_case() { # $1=spare 5h  $2=spare 7d
  kill -9 "${SWPID:-0}" 2>/dev/null; wait "${SWPID:-0}" 2>/dev/null
  "$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
  sleep 0.3
  rm -f "$SWD/store-split" "$SWD/swap-note"
  sw_fixture 58 100 "$1" "$2"
  RQT=$(rq_gather)
  python3 - "$RQT" <<'PY'
import datetime, json, sys
ahead = lambda h: (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=h)).isoformat()
q = json.load(open(sys.argv[1]))
for row in q.values():
    row["five_hour_reset"], row["seven_day_reset"] = ahead(2), ahead(72)
json.dump(q, open(sys.argv[1], "w"))
PY
  rq_scatter "$RQT"
  hf_reset
  paid_optin_on
  mkdir -p "$SWD/providers"
  printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$SWD/providers/keys.env"
}
age_spare_row() { age_row spare; }
age_row() { RQT=$(rq_gather); python3 - "$RQT" "$1" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1])); q[sys.argv[2]]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
}
note_text() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["message"])' "$SWD/swap-note" 2>/dev/null; }
unpaid() { # $1=what was missing  [$2=nonote]
  if [ -n "$(hf_get direction)" ]; then bad "paid without proof: $1" "armed $(hf_get direction)"
  elif ! kill -0 "$SWPID" 2>/dev/null; then bad "paid without proof: $1" "ended the session"
  elif [ "${2:-}" != nonote ] && [ ! -f "$SWD/swap-note" ]; then bad "paid without proof: $1" "stopped and said nothing"
  else ok "no paid hop: $1"; fi
}

# The two proofs.
pay_case 100 100
sw_stopfail sess-p1 >/dev/null
{ [ "$(hf_get direction)" = "to_fallback" ] && died_within "$SWPID" 5; } \
  && ok "every spare freshly measured and spent, a key, the opt-in and a launcher: the paid hop fires" \
  || bad "paid proof" "direction=$(hf_get direction), note: $(note_text | head -c 120)"
pay_case 100 100
"$ACCT" --no-color rm spare >/dev/null 2>&1
sw_stopfail sess-p2 >/dev/null
{ [ "$(hf_get direction)" = "to_fallback" ] && died_within "$SWPID" 5; } \
  && ok "...and so does no spare registered at all" \
  || bad "paid proof" "direction=$(hf_get direction), note: $(note_text | head -c 120)"

# EVERY registered account has to prove itself — the one the store is on included.
# Excluding "the active account" made the proof depend on who is active, and that
# is not this session's to decide: another session swaps the store onto B, this
# session's proof then skips B as "active", finds A's fresh 99%, and pays past a
# subscription with room. Codex's interleaving, as it happens:
pay_case 10 20                          # B (spare) has room
"$ACCT" --no-color use spare --force >/dev/null 2>&1   # ...and another session moved the store onto it
quota 58 100                             # this session's cached reading still says: spent
stage_usage 10 20                        # ...but the wall measures the account the store is on NOW
hf_reset; rm -f "$SWD/swap-note" "$SWD"/wake-*
sw_stopfail sess-p2b >/dev/null
[ -z "$(hf_get direction)" ] \
  && ok "no paid hop: the store moved onto an account with room while this session hit the wall" \
  || bad "paid without proof: the store moved" "armed $(hf_get direction)"
rm -f "$SWD"/wake-*

# The wall's re-read IS the active account's measurement, so with one account
# registered it is the whole proof — and it never touches the token Claude Code owns.
pay_case 100 100; "$ACCT" --no-color rm spare >/dev/null 2>&1
age_row spent; stage_usage 100 100
: > "$CCD_FAKE_USAGE_LOG"
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p2c >/dev/null
{ [ "$(hf_get direction)" = "to_fallback" ] && [ -s "$CCD_FAKE_USAGE_LOG" ]; } \
  && ok "one registered account, measured spent at the wall, is proof" \
  || bad "paid proof" "direction=$(hf_get direction), measured $(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ') times"
pay_case 100 100; "$ACCT" --no-color rm spare >/dev/null 2>&1
stage_usage 5 5 503
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p2d >/dev/null
unpaid "the re-read at the wall failed, with a fresh 100% reading on file for every account" nonote
[ ! -f "$SWD/swap-note" ] && ok "...and nothing else fires either: no swap, no wake, no note" \
  || bad "acted on a failed re-read" "left a note: $(note_text | head -c 100)"
# The live token is the SESSION'S. An expired one is simply not measured — there is
# no refresh path in the wall's measurement at all — and an unmeasured wall fires nothing.
pay_case 100 100; "$ACCT" --no-color rm spare >/dev/null 2>&1
python3 - "$CREDS" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
PY
stage_usage 100 100 200 0 AT-spent-rotated               # an exchange WOULD rotate, and would show
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p2e >/dev/null
unpaid "the live token has expired, so the wall could not be measured" nonote
{ grep -q '"AT-spent"' "$CREDS" && ! grep -q 'rotated' "$ADIR/spent.json" "$CREDS"; } \
  && ok "...and nothing is exchanged to find out: that token belongs to the running session" \
  || bad "spent the live token" "a token was rotated from the wall's measurement"

# ONE meaning of "spent", and it is 100%. The 90% reserve used to decide two things
# at once — "not worth hopping to" and "spent enough to pay" — so a spare at 90%
# was skipped by the swap AND proved spent, and ccd paid with a tenth of a
# subscription left. A spare is a destination while it is under 100; ccd pays only
# when every registered account is AT 100; and a session moves when its own
# account gets there, not before.
moved_to_spare() { grep -q 'AT-spare' "$CREDS" && [ -z "$(hf_get direction)" ]; }
pay_case 90 90
sw_stopfail sess-s1 >/dev/null
moved_to_spare && ok "a spare at 90% is a destination: the session moves there and nothing is billed" \
  || bad "paid past a spare with room" "direction=$(hf_get direction), credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1)"
pay_case 99 99
sw_stopfail sess-s2 >/dev/null
moved_to_spare && ok "...and so is a spare at 99%" \
  || bad "paid past a spare with room" "direction=$(hf_get direction), credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1)"
pay_case 100 100
sw_stopfail sess-s3 >/dev/null
[ "$(hf_get direction)" = "to_fallback" ] && ok "...while every registered account at 100% is what paying takes" \
  || bad "paid proof" "direction=$(hf_get direction), note: $(note_text | head -c 120)"
pay_case 10 20; quota 58 97
sw_prompt UserPromptSubmit sess-s4 >/dev/null
grep -q 'AT-spent' "$CREDS" && ok "a tick at 97% moves nothing: the account still answers" \
  || bad "moved before the wall" "the session left an account with quota still on it"
pay_case 10 20; quota 58 100
sw_prompt UserPromptSubmit sess-s5 >/dev/null
grep -q 'AT-spare' "$CREDS" && ok "...and a tick at 100% moves it" \
  || bad "did not move at the wall" "credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1)"

# "Spent" is written down once. Every program that decides on it reads that file;
# none carries a number of its own, and the two knobs that used to disagree are gone.
{ [ "$(cat "$ROOT/bin/spent-at")" = "100" ] \
  && grep -q 'spent-at' "$ROOT/bin/ccd-account" && grep -q 'spent-at' "$ROOT/scripts/quota-guard.sh" \
  && grep -q 'spent-at' "$ROOT/bin/ccd-statusline" \
  && ! grep -qE 'HEADROOM|ARM_THRESHOLD' "$ROOT/bin/ccd-account" "$ROOT/bin/ccd-statusline" "$ROOT/bin/ccd" \
         "$ROOT/bin/ccd-handoff" "$ROOT/scripts/quota-guard.sh"; } \
  && ok "one definition of spent, read by the hook, the account tool and the statusline alike" \
  || bad "spent is defined twice" "a program carries its own threshold again"
# ...and nothing in somebody's shell moves it for the swap, as nothing moves it for the row.
pay_case 95 95
CCD_HEADROOM=50 "$ACCT" --no-color pick >/dev/null 2>&1 \
  && ok "...and the retired CCD_HEADROOM cannot make a spare with room look spent" \
  || bad "spent is a knob again" "an environment variable took a destination away"
# The hook fails closed without it: a hook that cannot tell "spent" moves nothing.
rm -rf "$FAKE/nospent"; mkdir -p "$FAKE/nospent"; cp -R "$ROOT/bin" "$ROOT/scripts" "$FAKE/nospent/"; rm -f "$FAKE/nospent/bin/spent-at"
pay_case 10 20
printf '{"session_id":"sess-ns","cwd":"/tmp/w"}' \
  | CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID CLAUDE_PLUGIN_ROOT="$ROOT" CCD_SWAP_SETTLE=0 \
    "$FAKE/nospent/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
grep -q 'AT-spent' "$CREDS" && ok "...and a hook that cannot read it acts on no guess of its own" \
  || bad "guessed at spent" "the hook moved a session without knowing what spent means"
rm -rf "$FAKE/nospent"

# A reading belongs to its account for as long as the account is registered.
pay_case 10 20
{ [ -f "$RQD/spare.json" ] && "$ACCT" --no-color rm spare >/dev/null 2>&1 && [ ! -e "$RQD/spare.json" ] && [ -f "$RQD/spent.json" ]; } \
  && ok "removing an account removes its reading, and only its reading" \
  || bad "orphaned reading" "readings on file: $(ls "$RQD" 2>/dev/null | tr '\n' ' ')"
# The shared cache is gone for good: no reader, no migration, and the file itself
# goes the first time a command sets up the store.
printf '{"spare":{"status":"ok","five_hour_percent":1}}' > "$SWD/accounts-quota.json"
"$ACCT" --no-color current >/dev/null 2>&1
[ ! -e "$SWD/accounts-quota.json" ] && ok "the old shared cache is deleted where it is found, not read" \
  || bad "old cache survives" "accounts-quota.json is still on disk"

# At the wall the reading is taken AGAIN. It is cached for ten minutes, so the one on
# file can say 96 while the account is at 100 — and with spent meaning 100, a
# backstop that trusted it would sit beside a spare with room and do nothing, on
# exactly the turn it exists for.
pay_case 10 20
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":58,"fiveHourReset":"R1","sevenDayPercent":96,"sevenDayReset":"D1"}}\n' \
  > "$SWD/quota-cache.json"            # what the cache still says (not staged behind it)
stage_usage 100 100                     # what the account says now
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-s6)
{ [ "$rc" = "2" ] && grep -q 'AT-spare' "$CREDS"; } \
  && ok "a turn that dies on rate_limit re-reads the account rather than trust a reading that lags it" \
  || bad "stale reading at the wall" "rc=$rc, credential $(grep -o 'AT-[a-z]*' "$CREDS" | head -1): the backstop believed a cached 96%"

# A reading is published by whoever measured it, and by nobody else. The active
# account's measurement used to load every account's row, wait on the network, and
# write every row back — putting a spare's stale 503 back over the healthy reading a
# background prober had recorded in the meantime, and stranding the turn beside a
# subscription that had just been measured free. One file per account: a prober can
# only ever publish the account it measured.
pay_case 10 20
python3 - "$RQD" <<'PY'
import json, os, sys, time
d = sys.argv[1]
sp = json.load(open(os.path.join(d, "spare.json")))
json.dump({"status": "error", "http_status": 503, "checked_at": int(time.time()),
           "cred": sp["cred"], "uuid": sp.get("uuid")}, open(os.path.join(d, "spare.json"), "w"))
me = json.load(open(os.path.join(d, "spent.json")))
me["checked_at"] = int(time.time()) - 99999          # so the active account IS measured
json.dump(me, open(os.path.join(d, "spent.json"), "w"))
PY
stage_usage 100 100 200 3
( sleep 1.2
  python3 - "$RQD/spare.json" "$ADIR/spare.json" <<'PY'
import datetime, hashlib, json, os, sys, time
ahead = lambda h: (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=h)).isoformat()
at = json.load(open(sys.argv[2]))["claudeAiOauth"]["accessToken"]
row = {"status": "ok", "checked_at": int(time.time()), "cred": hashlib.sha256(at.encode()).hexdigest()[:16],
       "uuid": None, "five_hour_percent": 10, "seven_day_percent": 20,
       "five_hour_reset": ahead(2), "seven_day_reset": ahead(72)}
tmp = sys.argv[1] + ".bg"
json.dump(row, open(tmp, "w")); os.replace(tmp, sys.argv[1])
PY
) & BGP=$!
# The measurement in flight is the wall's own: three seconds on the wire for the
# active account, while a background prober records the spare.
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color usage --json --deadline 30 >/dev/null 2>&1
wait "$BGP" 2>/dev/null
spare_row() { python3 -c 'import json,sys
try: r = json.load(open(sys.argv[1]))
except Exception: r = {}
print(str(r.get("status")) + ":" + str(r.get("five_hour_percent")))' "$RQD/spare.json"; }
[ "$(spare_row)" = "ok:10" ] \
  && ok "a measurement in flight does not write back over another account's newer reading" \
  || bad "lost update" "the spare's reading is now $(spare_row)"
stage_token AT-spare 10 20
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window none --deadline 30 >/dev/null 2>&1
grep -q 'AT-spare' "$CREDS" && ok "...so the next attempt finds the spare and moves there" \
  || bad "lost update" "the healthy spare was never reached"
# ...and "check, then replace" has to be ONE step. Writer A passes the check with
# 99%@T and is descheduled before its rename; writer B publishes 100%@T+10; A
# resumes and puts 99% back. Nothing bounds that pause, so it is closed with a lock
# per account — two processes, because the lock is reentrant inside one.
cat > "$FAKE/.lockrace.py" <<'PY'
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("ccdrace", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
who, t = sys.argv[2], int(sys.argv[3])
if who == "A":
    real = m.write_json
    def slow(p, obj, mode=0o600):
        if str(p).endswith("race2.json"):
            time.sleep(2.0)             # past the check, not yet renamed
        return real(p, obj, mode)
    m.write_json = slow
    m.reading_save("race2", {"status": "ok", "checked_at": t, "five_hour_percent": 99})
else:
    time.sleep(0.7)                     # A is inside its pause by now
    m.reading_save("race2", {"status": "ok", "checked_at": t + 10, "five_hour_percent": 100})
PY
rm -f "$RQD/race2.json"; mkdir -p "$RQD"
T0=$(date +%s)
PYTHONDONTWRITEBYTECODE=1 HOME="$FAKE" python3 "$FAKE/.lockrace.py" "$ROOT/bin/ccd-account" A "$T0" & RA=$!
PYTHONDONTWRITEBYTECODE=1 HOME="$FAKE" python3 "$FAKE/.lockrace.py" "$ROOT/bin/ccd-account" B "$T0" & RB=$!
wait "$RA" "$RB" 2>/dev/null
got=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("five_hour_percent"))' "$RQD/race2.json" 2>/dev/null)
[ "$got" = "100" ] \
  && ok "a writer paused between its check and its rename cannot put an older reading back" \
  || bad "lost update" "the account's reading ended at ${got:-nothing}% — the older writer won"
ls "$RQD" | grep -v '\.json$' | grep -q . \
  && { ls -A "$RQD" | grep -q '^\.' || bad "lock in the way" "a non-dot file sits beside the readings: $(ls "$RQD" | tr '\n' ' ')"; } || true
rm -f "$RQD/race2.json" "$RQD"/.race2.* "$FAKE/.lockrace.py"

# Two probers of the SAME account can finish out of order. The later look wins.
PYTHONDONTWRITEBYTECODE=1 HOME="$FAKE" python3 - "$ROOT/bin/ccd-account" <<'PY' \
  && ok "an older measurement of an account never replaces a newer one" \
  || bad "stale reading published" "a slow probe overwrote the reading a faster one had already recorded"
import importlib.machinery, importlib.util, sys, time
loader = importlib.machinery.SourceFileLoader("ccdread", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
t = int(time.time())
m.reading_save("race", {"status": "ok", "checked_at": t, "five_hour_percent": 10})
m.reading_save("race", {"status": "error", "checked_at": t - 5})          # asked earlier, answered later
assert m.reading_load("race")["status"] == "ok", m.reading_load("race")
m.reading_save("race", {"status": "ok", "checked_at": t + 1, "five_hour_percent": 11})
assert m.reading_load("race")["five_hour_percent"] == 11, "a newer reading was refused"
m.reading_save("race", {"status": "ok", "checked_at": t + 99999, "five_hour_percent": 12})   # a wrong clock
m.reading_save("race", {"status": "ok", "checked_at": t + 2, "five_hour_percent": 13})
assert m.reading_load("race")["five_hour_percent"] == 13, "a reading from the future blocked every later one"
# "Later stamp wins" only means "later look wins" if the stamp is when the ANSWER
# arrived. A probe stamps itself when it starts; quota_for re-stamps on the way out.
m.probe_account = lambda n, a, allow_refresh=True: {"status": "ok", "checked_at": t - 50, "five_hour_percent": 1}
rec = m.quota_for("stamp", {"claudeAiOauth": {"accessToken": "AT-stamp"}})
assert rec["checked_at"] >= t, "stamped when the question was asked, not when it was answered"
assert m.reading_load("stamp")["checked_at"] >= t, "the reading on file carries the asking time"
m.reading_drop("stamp")
import os, stat
assert stat.S_IMODE(os.stat(m.reading_path("race")).st_mode) == 0o600
assert stat.S_IMODE(os.stat(m.READINGS_DIR).st_mode) == 0o700
# One freshness rule for every reader: a reading from the FUTURE is a wrong clock,
# not a fresh reading. After a backward clock step it would otherwise pin a spent
# verdict in place and keep a usable account from being measured again.
probed = []
m.probe_account = lambda n, a, allow_refresh=True: (probed.append(n), {"status": "ok", "checked_at": t, "five_hour_percent": 1})[1]
acct = {"claudeAiOauth": {"accessToken": "AT-fut"}}
m.write_json(m.reading_path("fut"), {"status": "ok", "checked_at": t + 9999, "cred": m._cred_fingerprint(acct), "five_hour_percent": 100}, 0o600)
m.quota_for("fut", acct)
assert probed == ["fut"], "a future-dated reading was served as fresh instead of being re-measured"
m.reading_drop("fut")
# ...and a readings directory that already existed with loose permissions is put right.
os.chmod(m.READINGS_DIR, 0o755)
m.reading_save("perm", {"status": "ok", "checked_at": t})
assert stat.S_IMODE(os.stat(m.READINGS_DIR).st_mode) == 0o700, oct(stat.S_IMODE(os.stat(m.READINGS_DIR).st_mode))
m.reading_drop("perm")
m.reading_drop("race")
assert not [f for f in os.listdir(m.READINGS_DIR) if "race" in f or "perm" in f or "fut" in f], os.listdir(m.READINGS_DIR)
PY

# What the wall just measured is what the proof sees. The re-read used to land only
# in the hook's own cache, so an account reading taken 30 seconds earlier at 99%
# went on speaking for an account the wall had just measured at 100 — and the turn
# stayed parked with every condition for paying met.
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1]))
q["spent"].update({"five_hour_percent": 99, "seven_day_percent": 99, "checked_at": int(time.time()) - 30})
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
stage_usage 100 100
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-w1 >/dev/null
[ "$(hf_get direction)" = "to_fallback" ] \
  && ok "the wall's own measurement of the active account is the one the proof reads" \
  || bad "wall reading lost" "direction=$(hf_get direction), spent's reading: $(head -c 140 "$RQD/spent.json" 2>/dev/null)"

# ...but only under a name ccd can PROVE. The pointer says `spent`; the login in the
# store is somebody ccd never registered (a /login it has had no chance to bank, and
# no profile to bank it by). Those numbers are about a stranger, and filing them as
# spent's reading would let a stranger's quota speak in the proof for spent's.
pay_case 100 100
rm -f "$RQD/spent.json"
write_creds stranger
stage_usage 100 100
CCD_HTTP_TIMEOUT=5 "$ACCT" --no-color usage --json >/dev/null 2>&1
[ ! -e "$RQD/spent.json" ] \
  && ok "...and a measurement of a login ccd cannot tie to the account is filed under nobody's name" \
  || bad "reading filed under the wrong account" "spent's reading now says: $(head -c 120 "$RQD/spent.json")"

# A turn can die on rate_limit while the account the store is ON has room: the tick
# installed a spare a second ago and the request still went out on the old
# credential; another session moved the store; the throttle was transient. There is
# nothing to swap and nothing to pay for — and a turn left parked. It is woken, once.
pay_case 10 20
"$ACCT" --no-color use spare --force >/dev/null 2>&1      # the store is on the healthy account
stage_usage 10 20                                        # ...and the wall measures exactly that
rm -f "$SWD"/wake-* "$SWD/swap-note"; hf_reset
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-k1)
{ [ "$rc" = "2" ] && [ -z "$(hf_get direction)" ] && grep -q 'AT-spare' "$CREDS"; } \
  && ok "a turn that died on rate_limit beside an account with room is woken to retry" \
  || bad "left parked" "rc=$rc, direction=$(hf_get direction)"
case "$(cat "$FAKE/.sw-err")" in
  *"switched this session to"*) bad "wake message" "claimed a swap that did not happen: $(head -c 140 "$FAKE/.sw-err")" ;;
  *"has quota"*|*"has room"*) ok "...in words that are true: the account has quota and the turn is retried, no swap claimed" ;;
  *) bad "wake message" "got: $(head -c 140 "$FAKE/.sw-err")" ;;
esac
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-k1)
{ [ "$rc" != "2" ] && [ -f "$SWD/swap-note" ]; } \
  && ok "...once: a second failure inside the interval wakes nothing and leaves a note instead" \
  || bad "wake loop" "rc=$rc on the second failure, note: $(note_text | head -c 100)"
rc=$(CCD_HTTP_TIMEOUT=5 sw_stopfail sess-k2)
[ "$rc" = "2" ] && ok "...and the bound is per session, not a gag on every other one" \
  || bad "wake bound" "a different session was refused its one retry (rc=$rc)"
rm -f "$SWD"/wake-* "$SWD/swap-note"

# The user's three conditions, one missing at a time.
pay_case 100 100; rm -f "$SWD/providers/keys.env"
sw_stopfail sess-p3 >/dev/null; unpaid "no key stored"
pay_case 100 100; paid_optin_off
sw_stopfail sess-p4 >/dev/null; unpaid "no opt-in"
case "$(note_text)" in
  *"ccd -c"*) ok "...and the note still names the way there by hand" ;;
  *) bad "stop note" "got: $(note_text | head -c 140)" ;;
esac

# The mechanical one: the hop is a relaunch, and only a launcher can relaunch.
pay_case 100 100
printf '{"session_id":"sess-p5","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"rate_limit"}' \
  | env -u CCD_HANDOFF -u CCD_HANDOFF_STATE CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID \
      CLAUDE_PLUGIN_ROOT="$ROOT" CCD_SWAP_SETTLE=0 env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure >/dev/null 2>&1
unpaid "no launcher supervising the session"
case "$(note_text)" in
  *"launcher"*"claude"*) ok "...and the note says the opt-in is on but this session cannot take it, and what fixes that" ;;
  *) bad "launcher note" "got: $(note_text | head -c 160)" ;;
esac
pay_case 100 100
CCD_HANDOFF_HEADLESS=1 sw_stopfail sess-p6 >/dev/null; unpaid "a headless run"

# What is NOT proof. Each of these once reached the paying branch, or could have.
pay_case 10 20                          # the spare HAS room; the store is just busy
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(6)
PY
HOLD=$!; sleep 0.4
CCD_SWAP_PICK_BUDGET=3 sw_stopfail sess-p7 >/dev/null
kill -9 "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
unpaid "a store lock that timed out"

pay_case 100 100; age_spare_row; stage_usage 100 100; stage_token AT-spare 5 5 503
CCD_HTTP_TIMEOUT=5 sw_stopfail sess-p8 >/dev/null; unpaid "a spare that answered 503"

pay_case 100 100; age_spare_row
CCD_SWAP_PICK_BUDGET=0 sw_stopfail sess-p9 >/dev/null; unpaid "a deadline that expired before anything was measured" nonote

pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1])); q["spare"] = {"status": "unknown", "checked_at": int(time.time())}
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
stage_token AT-spare 5 5 500            # ...and it cannot be measured now either
sw_stopfail sess-p10 >/dev/null; unpaid "a spare whose reading is not a measurement"

pay_case 100 100
printf '{"detail":"x","stores":["file","keychain"]}' > "$SWD/store-split"
sw_stopfail sess-p11 >/dev/null; unpaid "credential stores that disagree"
rm -f "$SWD/store-split"

pay_case 10 20                          # room to go to, and a swap that cannot get there
mkdir -p "$FAKE/failroot/bin"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = swap ] && { echo "could not act" >&2; exit 4; }; done\nexec "$CCD_REAL_ACCOUNT" "$@"\n' \
  > "$FAKE/failroot/bin/ccd-account"
chmod +x "$FAKE/failroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
SW_ROOT="$FAKE/failroot" sw_stopfail sess-p12 >/dev/null; unpaid "a swap that was attempted and failed"

mkdir -p "$FAKE/unconfroot/bin"
cat > "$FAKE/unconfroot/bin/ccd-account" <<'UEOF'
#!/bin/sh
case " $* " in *" current --json "*) [ -e "$HOME/.unconf-swapped" ] && { echo '{}'; exit 0; } ;; esac
for a in "$@"; do
  [ "$a" = swap ] && { "$CCD_REAL_ACCOUNT" "$@"; rc=$?; : > "$HOME/.unconf-swapped"; exit "$rc"; }
done
exec "$CCD_REAL_ACCOUNT" "$@"
UEOF
chmod +x "$FAKE/unconfroot/bin/ccd-account"
pay_case 10 20; rm -f "$FAKE/.unconf-swapped"
SW_ROOT="$FAKE/unconfroot" sw_stopfail sess-p13 >/dev/null; unpaid "a swap that landed but could not be confirmed"
rm -f "$FAKE/.unconf-swapped"

# chmod cannot stage this: every ccd-account command re-asserts 0700 on its own
# directory, which heals it. A store that cannot be listed is staged where the
# listing happens, and as a path that is not a directory at all.
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE/proof-unlistable" <<'PY' \
  && ok "no paid hop: an accounts directory that could not be read" \
  || bad "paid without proof: unreadable accounts directory" "a listing that failed read as no spare registered"
import importlib.machinery, importlib.util, os, sys
os.makedirs(sys.argv[2] + "/.claude", exist_ok=True)
os.environ["HOME"] = sys.argv[2]; os.environ["CCD_CREDENTIALS_BACKEND"] = "file"
loader = importlib.machinery.SourceFileLoader("ccdproof", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m); m.ensure_dirs()
real = os.listdir
def denied(p):
    if str(p) == m.ACCOUNTS_DIR:
        raise PermissionError(13, "Permission denied", p)
    return real(p)
m.os.listdir = denied
try:
    verdict = m.subscriptions_proved_spent()
except OSError:
    verdict = "raised"
finally:
    m.os.listdir = real
assert verdict is not True, "an unlistable store was proof that nothing is registered"
PY
pay_case 100 100; mv "$ADIR" "$ADIR.real"; : > "$ADIR"
sw_stopfail sess-p14 >/dev/null
rm -f "$ADIR"; mv "$ADIR.real" "$ADIR"
unpaid "an accounts path that is not a directory" nonote

# ccd does not start billing while the subscription still answers.
pay_case 100 100
sw_prompt UserPromptSubmit sess-p15 >/dev/null
unpaid "the tick before the wall, with everything else in place" nonote

# The verdict is one positive answer. A caller that inferred it from an exit code,
# or from there being no output, is how an operational failure used to pay.
for shape in silent-success wrong-word right-word-but-failed crashed; do
  mkdir -p "$FAKE/proofroot-$shape/bin"
  case "$shape" in
    silent-success)        body='exit 0' ;;
    wrong-word)            body='echo yes; exit 0' ;;
    right-word-but-failed) body="echo $PROOF; exit 1" ;;
    crashed)               body='echo "Traceback (most recent call last):" >&2; exit 1' ;;
  esac
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = exhausted ] && { %s; }; done\nexec "$CCD_REAL_ACCOUNT" "$@"\n' "$body" \
    > "$FAKE/proofroot-$shape/bin/ccd-account"
  chmod +x "$FAKE/proofroot-$shape/bin/ccd-account"
  pay_case 100 100
  SW_ROOT="$FAKE/proofroot-$shape" sw_stopfail "sess-p16-$shape" >/dev/null
  unpaid "an answer that is not the proof ($shape)"
done
{ [ "$(grep -c "\"$PROOF\"" "$ROOT/bin/ccd-account")" = "1" ] \
  && [ "$(grep -c 'print(EXHAUSTED_PROOF)' "$ROOT/bin/ccd-account")" = "1" ] \
  && grep -q "= \"$PROOF\" \]" "$ROOT/scripts/quota-guard.sh"; } \
  && ok "the proof is one word, printed in one place, and compared for equality" \
  || bad "proof mechanism" "the verdict can be produced or accepted some other way"

# The question itself, asked directly. It reads what the measurement left behind
# and opens no socket of its own, so nothing in it can time out into a yes.
proves() { [ "$("$ACCT" --no-color exhausted 2>/dev/null)" = "$PROOF" ]; }
pay_case 100 100
: > "$CCD_FAKE_USAGE_LOG"
{ proves && [ ! -s "$CCD_FAKE_USAGE_LOG" ]; } \
  && ok "every spare measured, fresh and spent is proof, read without a network call" \
  || bad "proof" "refused proof in hand, or went to the network for it"
pay_case 10 100
proves && ok "...one window spent is an account spent" || bad "proof" "a spare at 99% weekly was called free"
pay_case 10 20
proves && bad "proof" "a spare with room was called spent" || ok "...and a spare with room is not"
# The same line the swap draws, from the other side: whatever is still a destination
# is not spent. Through the hook this cannot be seen — a spare under 100 is swapped
# TO and the proof is never asked — so it is asked here.
for pct in 90 99; do
  pay_case "$pct" "$pct"
  proves && bad "proof" "a spare at ${pct}% counted as spent" || ok "...nor is a spare at ${pct}%: only 100 is spent"
done
pay_case 100 100; age_spare_row
proves && bad "proof" "a reading past its TTL was proof" || ok "...nor is a reading too old to describe now"
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1])); q["spare"]["status"] = "error"
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "a failed measurement was proof" || ok "...nor a measurement that failed"
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1])); del q["spare"]
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "an unmeasured spare was proof" || ok "...nor a spare nobody measured"
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import datetime, json, sys
past = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1)).isoformat()
q = json.load(open(sys.argv[1])); q["spare"]["five_hour_reset"] = past; q["spare"]["seven_day_reset"] = past
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "a window that has since reset was proof" || ok "...nor a window that has reset since it was read"
set_resets() { # $1=account  $2=python expression for the value
  RQT=$(rq_gather)
  python3 - "$RQT" "$1" "$2" <<'PY'
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
q = json.load(open(sys.argv[1])); v = eval(sys.argv[3])
for k in ("five_hour_reset", "seven_day_reset"):
    if v is None: q[sys.argv[2]].pop(k, None)
    else: q[sys.argv[2]][k] = v
json.dump(q, open(sys.argv[1], "w"))
PY
  rq_scatter "$RQT"
}
# A window is spent only while it is KNOWN to still be open. 99% with no usable
# reset can have reset a second later, and the row stays "fresh" for five minutes.
for shape in 'missing:None' 'malformed:"soon"' 'naive:(now + datetime.timedelta(hours=48)).replace(tzinfo=None).isoformat()'; do
  pay_case 100 100; set_resets spare "${shape#*:}"
  proves && bad "proof" "a ${shape%%:*} reset time was proof" \
    || ok "...nor a spent window whose reset time is ${shape%%:*}"
done
pay_case 100 100; set_resets spare '(now + datetime.timedelta(hours=2)).isoformat().replace("+00:00", "Z")'
proves && ok "...while a reset written with Z is as good as one written with an offset" \
  || bad "proof" "a valid future reset in Z form was refused"
# The active account is a registered account. Its row counts like any other.
pay_case 100 100
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1])); q["spent"]["five_hour_percent"] = 10; q["spent"]["seven_day_percent"] = 20
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
proves && bad "proof" "the account the store is on was left out of the proof" \
  || ok "...nor anything while the account the store is on shows room"
# Asking is not acting: no directory made, no credential banked, no pointer moved.
rm -rf "$FAKE/proof-ro"; mkdir -p "$FAKE/proof-ro/.claude"
out=$(HOME="$FAKE/proof-ro" "$ACCT" --no-color exhausted 2>/dev/null); rc=$?
{ [ "$out" = "$PROOF" ] && [ "$rc" -eq 0 ] && [ ! -e "$FAKE/proof-ro/.claude/ccd" ]; } \
  && ok "a store that was never created is an honest zero, and asking does not create it" \
  || bad "proof is not read-only" "out=$out rc=$rc, made: $(ls -A "$FAKE/proof-ro/.claude")"
pay_case 100 100; printf 'not json' > "$ADIR/spare.json"
proves && bad "proof" "an account that cannot be read was skipped" || ok "...nor a store with an account file it cannot read"
# Naming a store this suite cannot see, so the stop cannot lift itself first.
pay_case 100 100; printf '{"detail":"x","stores":["file","keychain"]}' > "$SWD/store-split"
proves && bad "proof" "proved over a standing stop" || ok "...nor anything at all while the credential stores disagree"
rm -f "$SWD/store-split"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
rm -f "$SWD/providers/keys.env" "$SWD/swap-note"
paid_optin_off

# ── stdout is the protocol; stderr is not ───────────────────────────────────
# A swap can succeed and still have something to say — the cached account config
# it could not drop, for one. Folding that into the result made the warning the
# account name and left no fingerprint, so the parked turn was never woken.
mkdir -p "$FAKE/warnroot/bin"
cat > "$FAKE/warnroot/bin/ccd-account" <<'WEOF'
#!/bin/sh
for a in "$@"; do
  [ "$a" = swap ] && echo "ccd account: warning: could not drop the cached account config" >&2
done
exec "$CCD_REAL_ACCOUNT" "$@"
WEOF
chmod +x "$FAKE/warnroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rc=$(SW_ROOT="$FAKE/warnroot" sw_stopfail sess-w1)
{ [ "$rc" = "2" ] && grep -q 'switched this session to spare,' "$FAKE/.sw-err"; } \
  && ok "a swap that warned still wakes the turn, naming the account it moved to" \
  || bad "warning read as the result" "rc=$rc: $(tr '\n' ' ' < "$FAKE/.sw-err" | head -c 160)"
sw_fixture 58 100
out=$(SW_ROOT="$FAKE/warnroot" sw_prompt UserPromptSubmit sess-w2)
case "$out" in
  *warning*) bad "warning read as the result" "the tick announced: ${out:0:160}" ;;
  *spare*) ok "...and the tick before the wall announces the account, not the warning" ;;
  *) bad "warning read as the result" "nothing announced: ${out:0:160}" ;;
esac

# A swap refused by a standing stop has a remedy, and 120 characters of stderr do
# not reach it. One fixed line that points at doctor, which carries all of it.
sw_fixture 58 100
printf '{"detail":"keychain took b, file kept a","stores":["file","keychain"]}' > "$SWD/store-split"
rm -f "$SWD/swap-note"
sw_stopfail sess-w3 >/dev/null
grep -q 'stores disagree.*ccd doctor' "$SWD/swap-note" 2>/dev/null \
  && ok "a backstop stopped by disagreeing stores sends the user to ccd doctor" \
  || bad "remedy cut off" "note: $(head -c 200 "$SWD/swap-note" 2>/dev/null)"
rm -f "$SWD/swap-note"
# The same tick that writes the note may be the one that shows it, so look at both.
out=$(sw_prompt UserPromptSubmit sess-w4)
# "ccd doctor" alone proves nothing here — the quota warning says it too.
{ case "$out" in *"stores disagree"*"ccd doctor"*) true ;; *) false ;; esac \
  || grep -q 'stores disagree.*ccd doctor' "$SWD/swap-note" 2>/dev/null; } \
  && ok "...and so does the tick before the wall, which used to say nothing" \
  || bad "remedy cut off" "the proactive path said: ${out:0:120} / left: $(head -c 80 "$SWD/swap-note" 2>/dev/null)"
rm -f "$SWD/store-split" "$SWD/swap-note"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── A swap that happened, over stores not yet seen to agree ─────────────────
# The swap is a success and stays one — it wakes, it announces — but the stop it
# left standing has a remedy, and the hook threw the only mention of it away.
mkdir -p "$FAKE/splitroot/bin"
cat > "$FAKE/splitroot/bin/ccd-account" <<'SEOF'
#!/bin/sh
# The real swap, followed by what a verify that could not see leaves behind. With
# SPLIT_UNCONFIRMED set, the confirmation read AFTER the swap finds nothing to
# confirm either — only after: the same command feeds the decision to swap at all.
case " $* " in
  *" current --json "*)
    [ -n "${SPLIT_UNCONFIRMED:-}" ] && [ -e "$HOME/.split-swapped" ] && { echo '{}'; exit 0; } ;;
esac
for a in "$@"; do
  if [ "$a" = swap ]; then
    "$CCD_REAL_ACCOUNT" "$@"; rc=$?
    [ "$rc" -eq 0 ] && { printf '{"detail":"x","stores":["file","keychain"]}' > "$HOME/.claude/ccd/store-split"
                         : > "$HOME/.split-swapped"; }
    exit "$rc"
  fi
done
exec "$CCD_REAL_ACCOUNT" "$@"
SEOF
chmod +x "$FAKE/splitroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
for shape in wakes unconfirmed tick; do
  # Before the fixture, not after: the stop the last shape left standing would
  # refuse the fixture's own `use`, and this shape would start on the wrong account.
  rm -f "$SWD/swap-note" "$SWD/store-split" "$FAKE/.split-swapped"
  sw_fixture 58 100
  case "$shape" in
    wakes)       rc=$(SW_ROOT="$FAKE/splitroot" sw_stopfail sess-s1); want=2 ;;
    unconfirmed) rc=$(SPLIT_UNCONFIRMED=1 SW_ROOT="$FAKE/splitroot" sw_stopfail sess-s2); want=0 ;;
    tick)        out=$(SW_ROOT="$FAKE/splitroot" sw_prompt UserPromptSubmit sess-s3)
                 case "$out" in *"spare 계정으로 갈아탔습니다"*) rc=0 ;; *) rc=1 ;; esac; want=0 ;;
  esac
  { [ "$rc" = "$want" ] && grep -q 'AT-spare' "$CREDS" \
      && grep -q 'spare.*stores disagree.*ccd doctor' "$SWD/swap-note" 2>/dev/null; } \
    && ok "a swap over a standing stop still succeeds ($shape), and says where the remedy is" \
    || bad "advisory lost ($shape)" "rc=$rc want=$want, note: $(head -c 140 "$SWD/swap-note" 2>/dev/null)"
done
rm -f "$SWD/store-split" "$SWD/swap-note"

# A hook killed mid-swap must not strand its stderr capture. bash defers a trap
# until the child returns, so the fake swap is short; without a trap the TERM
# kills the hook on the spot and the file stays for ever.
mkdir -p "$FAKE/slowroot/bin"
cat > "$FAKE/slowroot/bin/ccd-account" <<'LEOF'
#!/bin/sh
for a in "$@"; do [ "$a" = swap ] && { : > "$HOME/.swap-started"; sleep 2; echo "too slow" >&2; exit 4; }; done
exec "$CCD_REAL_ACCOUNT" "$@"
LEOF
chmod +x "$FAKE/slowroot/bin/ccd-account"
sw_fixture 58 100
rm -f "$FAKE/.swap-started" "$SWD"/.swap-err.*
printf '{"session_id":"sess-k1","cwd":"/tmp/w","hook_event_name":"StopFailure","error":"rate_limit"}' > "$FAKE/.k1-in"
# exec, so that $! is the hook itself: a signal sent to a wrapping subshell kills
# the wrapper and proves nothing about the script inside it.
( exec env CLAUDE_PID=$SWPID CCD_STANDIN_PID=$SWPID CLAUDE_PLUGIN_ROOT="$FAKE/slowroot" \
    env "${WALLENV[@]}" "$ROOT/scripts/quota-guard.sh" StopFailure < "$FAKE/.k1-in" >/dev/null 2>&1 ) & HKPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -e "$FAKE/.swap-started" ] && break; sleep 0.25; done
started=$(ls "$SWD"/.swap-err.* 2>/dev/null | wc -l | tr -d ' ')
kill -TERM "$HKPID" 2>/dev/null; wait "$HKPID" 2>/dev/null
left=$(ls "$SWD"/.swap-err.* 2>/dev/null | wc -l | tr -d ' ')
{ [ "${started:-0}" -ge 1 ] && [ "${left:-1}" -eq 0 ]; } \
  && ok "a hook killed mid-swap takes its stderr capture with it" \
  || bad "stranded capture" "in flight: $started, left behind: $left"
rm -f "$SWD"/.swap-err.* "$FAKE/.swap-started"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── Three attempts, then stop ───────────────────────────────────────────────
# An operational failure is worth retrying briefly — a store that moved, a lock
# someone else held — and worth nothing after that.
mkdir -p "$FAKE/countroot/bin"
cat > "$FAKE/countroot/bin/ccd-account" <<'CEOF'
#!/bin/sh
# Counts swap attempts and refuses each one the way an operational failure does;
# everything else is the real tool.
for a in "$@"; do
  [ "$a" = swap ] && { echo x >> "$HOME/.swap-tries"; echo "could not act" >&2; exit 4; }
done
exec "$CCD_REAL_ACCOUNT" "$@"
CEOF
chmod +x "$FAKE/countroot/bin/ccd-account"
export CCD_REAL_ACCOUNT="$ACCT"
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
rm -f "$FAKE/.swap-tries"
SW_ROOT="$FAKE/countroot" sw_prompt UserPromptSubmit sess-r1 >/dev/null
tries=$(grep -c . "$FAKE/.swap-tries" 2>/dev/null || echo 0)
[ "${tries:-0}" -eq 3 ] \
  && ok "an operational failure is retried three times and then let go" \
  || bad "retries" "the swap was attempted ${tries:-0} times"

# ── A failure the user hears about once, without a doomed wake ──────────────
# The spare is spent as well, so the ticks that follow have nothing to swap to
# and the note is the only thing they can have to say.
sw_fixture 58 100 100 100
rm -f "$SWD/swap-note" "$FAKE/.swap-tries"
SW_ROOT="$FAKE/countroot" sw_stopfail sess-r2 >/dev/null
[ -f "$SWD/swap-note" ] \
  && ok "a backstop that could not swap leaves the reason behind" \
  || bad "breadcrumb" "the turn died with nothing to say for it"
note=$(SW_ROOT="$FAKE/countroot" sw_prompt UserPromptSubmit sess-r3)
case "$note" in
  *"Nothing was billed"*) ok "...and the next prompt says it once, naming the cost that was not paid" ;;
  *) bad "breadcrumb" "got: $(printf '%s' "$note" | tr '\n' ' ' | head -c 160)" ;;
esac
again=$(SW_ROOT="$FAKE/countroot" sw_prompt UserPromptSubmit sess-r4)
case "$again" in
  *"Nothing was billed"*) bad "breadcrumb" "said it twice" ;;
  *) ok "...and only once" ;;
esac
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset CCD_REAL_ACCOUNT
rm -f "$SWD/providers/keys.env"

# ── The exchange holds the lock; a probe does not ───────────────────────────
# A probe is a read: it measures somebody's quota and can wait outside any lock.
# An exchange is a write — it consumes a one-time credential — so it holds the
# store lock across the request and the write it produces, as one step. Anything
# else can land on a record that was re-registered while it was in flight.
sw_fixture 58 100
stage_usage 5 5 200 2 AT-spare-rotated
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)   # needs a rotation
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999                # and a measurement
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
lock_free() {  # is the store lock takeable right now?
  python3 - "$ADIR/.lock" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("free")
except OSError:
    print("held")
PY
}
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.8
[ "$(lock_free)" = "held" ] \
  && ok "a token exchange holds the store lock for as long as it takes" \
  || bad "exchange outside the lock" "the store was writable mid-exchange"
wait "$PICKPID" 2>/dev/null

# ...and the read-only half takes nothing: a spare whose token is fine is simply
# measured, and every other writer carries on while that request is open.
sw_fixture 58 100
stage_usage 5 5 200 2
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys, time
q = json.load(open(sys.argv[1]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.8
[ "$(lock_free)" = "free" ] \
  && ok "...while a measurement that rotates nothing blocks nobody" \
  || bad "probe under the lock" "a read-only probe held the store lock"
wait "$PICKPID" 2>/dev/null
unset -f lock_free

# ── The confirmation proves ownership, not change ───────────────────────────
# "different from what we replaced" is satisfied by a third account's token, by
# the outgoing account's next rotation, by anything at all that moved.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100
# A token belonging to neither account: not the one the swap installs, not the
# one it replaces. "Different from what we replaced" says yes to this.
python3 - "$CREDS" "$FAKE/.creds-third" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["accessToken"] = "AT-interloper"
json.dump(d, open(sys.argv[2], "w"))
PY
( sleep 0.7; cp "$FAKE/.creds-third" "$CREDS" ) &
ROT=$!
rc=$(SW_SETTLE=2 sw_stopfail sess-c1)
wait "$ROT" 2>/dev/null
[ "$rc" != "2" ] \
  && ok "a credential that is nobody's in particular does not confirm a swap" \
  || bad "confirmation" "woke on a token belonging to neither account"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null

# ── A probe never rotates the credential Claude Code is holding ─────────────
# The live token belongs to the running session. An account can BECOME the live
# one while a probe is mid-exchange, and finishing that rotation consumes a
# one-time token the session is still carrying — with the replacement landing in
# the account file and nowhere else.
sw_fixture 58 100
stage_usage 5 5 200 2 AT-spare-rotated
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.5
"$ACCT" --no-color use spare --force >/dev/null 2>&1    # it is the live one now
wait "$PICKPID" 2>/dev/null
tok() { python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$1"; }
[ "$(tok "$CREDS")" = "$(tok "$ADIR/spare.json")" ] \
  && ok "a probe leaves the signed-in account's credential to Claude Code" \
  || bad "live rotation" "live $(tok "$CREDS") vs stored $(tok "$ADIR/spare.json")"

# ── A decision installed only where it was still true ───────────────────────
# Measuring takes time, and a person can run `ccd account use` inside it. The
# check that the store has not moved belongs with the install, under the lock.
sw_fixture3 58 100
rm -rf "$RQD"
stage_usage 5 5 200 2
( sleep 0.7; "$ACCT" --no-color use spare2 --force >/dev/null 2>&1 ) &
RACE=$!
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" \
  --deadline 30 >/dev/null 2>&1
wait "$RACE" 2>/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "a swap whose ground moved while it measured installs nothing" \
  || bad "install cas" "overwrote a swap made while it was measuring: $(cat "$ADIR/.active" 2>/dev/null)"

# ── A reading is labelled with the account it measured ──────────────────────
sw_fixture 58 100
stage_usage 5 5 200 2
( CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color usage --json > "$FAKE/.usage-out" 2>/dev/null ) &
USAGEPID=$!
sleep 0.7
"$ACCT" --no-color use spare --force >/dev/null 2>&1
wait "$USAGEPID" 2>/dev/null
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("account") == "spent" else 1)' "$FAKE/.usage-out" \
  && ok "a reading names the account whose credential it measured" \
  || bad "reading label" "named $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("account"))' "$FAKE/.usage-out" 2>/dev/null)"

# ── Partial information holds the exclusion ─────────────────────────────────
# One window in common and one missing is not a reset; it is half an answer.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture3 58 100
sw_prompt UserPromptSubmit sess-w1 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare" ] \
  || bad "partial window" "the fixture's first swap went to $(cat "$ADIR/.active" 2>/dev/null)"
RQT=$(rq_gather)
python3 - "$RQT" <<'PY'
import json, sys
q = json.load(open(sys.argv[1]))
q["spent"].pop("five_hour_reset", None)     # only half the windows can be named
json.dump(q, open(sys.argv[1], "w"))
PY
rq_scatter "$RQT"
quota 58 100
sw_prompt UserPromptSubmit sess-w2 >/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" = "spare2" ] \
  && ok "half a window is not a reset, and the exclusion holds" \
  || bad "partial window" "released on partial information: $(cat "$ADIR/.active" 2>/dev/null)"

# ── One budget, end to end, on the prompt path ──────────────────────────────
sw_fixture 58 100
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(8)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
start=$(date +%s)
sw_prompt UserPromptSubmit sess-b1 >/dev/null
waited=$(( $(date +%s) - start ))
kill -9 "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
[ "$waited" -le 4 ] \
  && ok "a prompt tick is bounded by its own budget, whoever holds the store lock" \
  || bad "tick budget" "the tick held the prompt for ${waited}s"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"

# ── A swap queues behind an exchange, and installs what it produced ─────────
# The old refresh token is spent the moment the server answers, so the exchange
# holds the store lock across it. A `use` arriving mid-exchange therefore waits,
# and what it then installs is the credential the exchange wrote — not the one it
# read before.
sw_fixture 58 100
stage_usage 5 5 200 2 AT-spare-rotated
RQT=$(rq_gather)
python3 - "$ADIR/spare.json" "$RQT" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
q = json.load(open(sys.argv[2]))
q["spare"]["checked_at"] = int(time.time()) - 99999
json.dump(q, open(sys.argv[2], "w"))
PY
rq_scatter "$RQT"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color pick >/dev/null 2>&1 &
PICKPID=$!
sleep 0.5
"$ACCT" --no-color use spare --force >/dev/null 2>&1    # queues behind the exchange
wait "$PICKPID" 2>/dev/null
tok() { python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$1"; }
[ "$(tok "$ADIR/spare.json")" = "AT-spare-rotated" ] \
  && ok "a refresh that succeeded is written down, whatever was waiting behind it" \
  || bad "lost refresh" "the exchange was discarded: store holds $(tok "$ADIR/spare.json")"
[ "$(tok "$CREDS")" = "$(tok "$ADIR/spare.json")" ] \
  && ok "...and the swap that waited installs that credential, not the one it read" \
  || bad "stale install" "live $(tok "$CREDS") vs stored $(tok "$ADIR/spare.json")"

# ── The departure record is read where the install happens ──────────────────
# Measuring takes time; another swap can record a departure inside it, and a
# target that was free when we looked may be the account somebody just left.
sw_fixture3 58 100
rm -rf "$RQD" "$SWD/swapped-windows"
stage_usage 5 5 200 2
# Recorded with no window of its own, which is the case that holds whatever the
# candidate's own reading says: this is about WHEN the record is read, not about
# which windows it names.
( sleep 0.7; printf '%s\tspare\tnone\n' "$(date +%s)" > "$SWD/swapped-windows" ) &
RACE=$!
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color swap --from spent --window "5h=R1;7d=D1" \
  --deadline 30 >/dev/null 2>&1
wait "$RACE" 2>/dev/null
[ "$(cat "$ADIR/.active" 2>/dev/null)" != "spare" ] \
  && ok "a target recorded as just-left while we measured is not installed" \
  || bad "guard revalidation" "installed the account another swap had just left"

# ── Two writers, one note, and it still parses ──────────────────────────────
# A fixed temp path is a second writer's truncation, and the consumer drops a
# note it cannot read — the explanation disappearing exactly when there is one.
"$FAKE/sigbin/claude" 8 2>/dev/null & SWPID=$!
sleep 0.3
sw_fixture 58 100 100 100
rm -f "$SWD/swap-note"
mkdir -p "$SWD/swap-note.tmp"          # the one name a careless writer would take
# The stand-in forwards everything but `swap` to the real tool, and says where that
# is through this variable — which an earlier section unsets on its way out. Without
# it the wall's re-read goes nowhere, nothing fires, and there is no note to parse.
CCD_REAL_ACCOUNT="$ACCT" SW_ROOT="$FAKE/countroot" sw_stopfail sess-n5 >/dev/null
rmdir "$SWD/swap-note.tmp" 2>/dev/null
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$SWD/swap-note" 2>/dev/null \
  && ok "the note is published through a name of its own, so it always parses" \
  || bad "note temp" "no readable note was left: $(head -c 80 "$SWD/swap-note" 2>/dev/null)"

# ── The note says what actually went wrong ──────────────────────────────────
note=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["message"])' "$SWD/swap-note" 2>/dev/null)
case "$note" in
  *"reason unknown"*) bad "note reason" "the reason was lost on the way out of the subshell" ;;
  *"could not act"*) ok "...and carries the reason the swap itself gave" ;;
  *) bad "note reason" "got: $(printf '%s' "$note" | head -c 140)" ;;
esac
rm -f "$SWD/swap-note"
kill -9 "$SWPID" 2>/dev/null; wait "$SWPID" 2>/dev/null
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG

# ── The status screen promises only what this path does ─────────────────────
# The subscription hop fires when the reading says the account is spent. It does
# not come back on its own — nothing measures the account you left while you are
# not on it — and a promise of a return is a promise the user would wait for.
out=$(HOME="$FAKE" "$ROOT/bin/ccd" 2>&1 | sed -n '/When quota runs out/,/Other commands/p')
case "$out" in
  *"back when the window resets"*)
    bad "status promise" "promised a return the subscription path does not make" ;;
  *"registered account has room"*)
    ok "the status screen promises the hop it makes, and no return it does not" ;;
  *) bad "status promise" "said neither: $(printf '%s' "$out" | tr '\n' ' ' | head -c 140)" ;;
esac

rm -rf "$ADIR" "$RQD" "$SWD/swapped-windows" "$SWD/accounts-keepalive" \
       "$FAKE/.sw-out" "$FAKE/.sw-err" "$FAKE/.creds-before" "$FAKE/.swap-done"
hf_reset
unset CCD_USAGE_URL CCD_TOKEN_URL
unset -f sw_hook sw_fixture sw_fixture3 sw_prompt sw_stopfail

head_ "32. the exchange belongs under the lock"
# A probe is a read: it measures somebody's quota and can wait outside any lock.
# A token exchange is a WRITE — it consumes a one-time credential — and it has to
# happen inside the store lock with the write it produces, as one step. Outside
# it, the store can be re-registered, re-swapped or replaced while the exchange
# is in flight, and the result then lands on whatever is sitting in that file.
TXD="$FAKE/.claude/ccd"
export PYTHONPATH="$FAKE/pysite${PYTHONPATH:+:$PYTHONPATH}"
export CCD_FAKE_USAGE="$FAKE/.stage-usage.json" CCD_FAKE_USAGE_LOG="$FAKE/.usage-calls"
tx_fixture() {  # one registered account, its stored token expired and due a refresh
  rm -rf "$ADIR" "$RQD" "$FAKE/.claude.json"
  mkdir -p "$ADIR"
  write_creds tx_b; "$ACCT" --no-color add --name tx_b --label B-original >/dev/null 2>&1
  write_creds tx_c; "$ACCT" --no-color add --name tx_c --label C-other >/dev/null 2>&1
  python3 - "$ADIR/tx_b.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)
json.dump(d, open(sys.argv[1], "w"))
PY
  printf '{"fails":0}' > "$TXD/accounts-keepalive"
}
tx_tok() { python3 -c 'import json,sys;print(((json.load(open(sys.argv[1])).get("claudeAiOauth")) or {}).get("accessToken",""))' "$1"; }
tx_uuid() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("account_uuid") or "")' "$1"; }

# ── A completed exchange never lands on another account's record ────────────
# `account add --name B --force` points that name at a different account. If the
# exchange is outside the lock, the merge writes B's brand-new refresh token into
# the record that now belongs to C — and the live write lands on top of it.
tx_fixture
stage_usage 5 5 200 2 AT-tx-rotated       # a two-second exchange
( sleep 0.6; write_creds tx_c_again
  "$ACCT" --no-color add --name tx_b --force --label C-registered >/dev/null 2>&1 ) &
RACE=$!
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh tx_b >/dev/null 2>&1
wait "$RACE" 2>/dev/null
python3 - "$ADIR/tx_b.json" <<'PY' \
  && ok "a record never ends up holding a credential minted for another account" \
  || bad "cross-contaminated record" "the exchange landed on a re-registered name"
import json, sys
d = json.load(open(sys.argv[1]))
tok = (d.get("claudeAiOauth") or {}).get("accessToken") or ""
# Either the refresh won the name and the record is still its own, or the
# re-registration won and the record is wholly the new account's. What must not
# exist is a record wearing one account's identity and another's credential.
assert not (tok == "AT-tx-rotated" and d.get("label") == "C-registered"), \
    f"label={d.get('label')!r} token={tok}"
PY

# ── An exchange that could not take the lock never happened ─────────────────
# Nothing to lose is the whole point: a completed exchange has spent a token that
# cannot be minted again, so the exchange must not START unless its result can be
# written the moment it lands. A store held past the wait is the case — the lock
# is worth a few seconds' patience and nothing beyond that.
tx_fixture
stage_usage 5 5 200 0 AT-tx-rotated
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(6)                       # longer than any caller will wait for it
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.3
: > "$CCD_FAKE_USAGE_LOG"
"$ACCT" --no-color refresh tx_b >/dev/null 2>&1
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
wait "$HOLD" 2>/dev/null
[ "${calls:-0}" -eq 0 ] \
  && ok "a store that cannot be locked means no token is spent at all" \
  || bad "spent under a held lock" "${calls:-0} exchanges ran with the store locked"
[ "$(tx_tok "$ADIR/tx_b.json")" = "AT-tx_b" ] \
  && ok "...and the stored credential is exactly the one nobody touched" \
  || bad "lost exchange" "store holds $(tx_tok "$ADIR/tx_b.json")"

# ── A half-written credential is not a written one ──────────────────────────
# Two backends, one refusal: the file takes the new blob and the keychain keeps
# the old. Reporting that as success is how a later bank copies the stale one
# back over the new — the successor destroyed by the very next swap.
rm -f "$FAKE/.claude/ccd/store-split"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE" <<'PY' \
  && ok "a write only one backend took is reported as the failure it is" \
  || bad "partial write" "live_write called a split-brain store a success"
import importlib.machinery, importlib.util, os, sys
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdacct", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

m.use_keychain = lambda: True
m._keychain_write = lambda blob: False          # the keychain refuses
ok, failed, written = m.live_write({"claudeAiOauth": {"accessToken": "AT-new"}},
                                   ["keychain", "file"])
assert ok is False, "a refused backend was reported as a successful write"
assert "keychain" in failed, f"the refusing backend is not named: {failed!r}"
assert written == ["file"], f"the backend that took it is not named: {written!r}"

m._keychain_write = lambda blob: True
ok, failed, written = m.live_write({"claudeAiOauth": {"accessToken": "AT-new"}},
                                   ["keychain", "file"])
assert ok is True and not failed, f"a complete write was reported as partial: {failed!r}"
assert set(written) == {"keychain", "file"}, f"written: {written!r}"
PY

# ...and the caller has to act on it rather than carry on.
rm -f "$FAKE/.claude/ccd/store-split"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE" <<'PY' \
  && ok "...and a swap that cannot write both stores fails instead of claiming a move" \
  || bad "partial write" "the swap reported a credential it had not installed"
import importlib.machinery, importlib.util, os, sys
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdacct2", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

m.use_keychain = lambda: True
m._keychain_write = lambda blob: False
m.live_read = lambda: ({"claudeAiOauth": {"accessToken": "AT-old", "refreshToken": "RT-old"}},
                       ["keychain", "file"])
m.active_name = lambda: "someone_else"
m.account_load = lambda n: ({"name": n, "claudeAiOauth":
                             {"accessToken": "AT-target", "refreshToken": "RT-target"}}
                            if n == "target" else None)
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
else:
    raise AssertionError("swap_to returned success on a half-written credential store")
PY

# ── An account that goes live while the refresh waits is left alone ─────────
# The pre-check says "not the live account" before the lock is taken, and cannot
# say anything about the world after it. Claude Code publishing its profile is
# enough to make that account live while we wait — and consuming its refresh
# token then leaves the running session holding one that can never be renewed.
r1_fixture() {
  rm -rf "$ADIR" "$RQD"; rm -rf "$FAKE/.claude.json"
  mkdir -p "$ADIR"
  write_creds r1_b; "$ACCT" --no-color add --name r1_b >/dev/null 2>&1
  write_creds r1_other; "$ACCT" --no-color add --name r1_other >/dev/null 2>&1
  "$ACCT" --no-color use r1_other --force >/dev/null 2>&1   # the pointer says r1_other
  python3 - "$ADIR/r1_b.json" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
d["account_uuid"] = "uuid-r1"                                     # who the profile names
d["claudeAiOauth"]["expiresAt"] = int((time.time() - 60) * 1000)  # and it is due a refresh
json.dump(d, open(sys.argv[1], "w"))
PY
  printf '{"fails":0}' > "$TXD/accounts-keepalive"
}
r1_go_live() {  # Claude Code signs in as r1_b: its credential, and its profile
  python3 - "$ADIR/r1_b.json" "$CREDS" "$FAKE/.claude.json" <<'PY'
import json, sys, time
acct = json.load(open(sys.argv[1]))
live = json.load(open(sys.argv[2]))
live["claudeAiOauth"] = acct["claudeAiOauth"]
json.dump(live, open(sys.argv[2], "w"))
json.dump({"oauthAccount": {"accountUuid": "uuid-r1", "emailAddress": "r1@example.com",
                            "profileFetchedAt": int((time.time() + 5) * 1000)}},
          open(sys.argv[3], "w"))
PY
}
r1_fixture
stage_usage 5 5 200 0 AT-r1-rotated
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.2
: > "$CCD_FAKE_USAGE_LOG"
start=$(date +%s)
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh r1_b > "$FAKE/.r1-out" 2>&1 &
REFPID=$!
sleep 0.5
r1_go_live                       # r1_b is the live account from here on
wait "$HOLD" 2>/dev/null
wait "$REFPID" 2>/dev/null; rc=$?
waited=$(( $(date +%s) - start ))
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
# The interleaving itself, asserted rather than assumed: a refresh that did not
# queue behind the lock never met the publication and would prove nothing.
[ "$waited" -ge 1 ] \
  && ok "the refresh queued behind the lock, so it met the account going live" \
  || bad "no interleaving" "the refresh finished in ${waited}s without waiting"
{ [ "${calls:-0}" -eq 0 ] && [ "$rc" -ne 0 ]; } \
  && ok "an account that went live while we waited is not refreshed behind its session" \
  || bad "refreshed the live account" "${calls:-0} exchanges, rc=$rc"
grep -q "signed in here" "$FAKE/.r1-out" \
  && ok "...and says why, rather than reporting an unreachable account" \
  || bad "wrong refusal" "got: $(tr '\n' ' ' < "$FAKE/.r1-out" | head -c 100)"
[ "$(tx_tok "$ADIR/r1_b.json")" = "AT-r1_b" ] \
  && ok "...with its stored credential still the one that session is holding" \
  || bad "refreshed the live account" "store holds $(tx_tok "$ADIR/r1_b.json")"
rm -f "$FAKE/.claude.json" "$FAKE/.r1-out"

# ── An account removed while we waited is not brought back ──────────────────
r1_fixture
stage_usage 5 5 200 0 AT-r1-rotated
python3 - "$ADIR/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(2)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
HOLD=$!
sleep 0.2
: > "$CCD_FAKE_USAGE_LOG"
start=$(date +%s)
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh r1_b > "$FAKE/.r5-out" 2>&1 &
REFPID=$!
sleep 0.5
rm -f "$ADIR/r1_b.json"          # `ccd account rm` landing while we wait
wait "$HOLD" 2>/dev/null
wait "$REFPID" 2>/dev/null; rc=$?
waited=$(( $(date +%s) - start ))
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
[ "$waited" -ge 1 ] \
  && ok "the refresh queued behind the lock, so it met the removal" \
  || bad "no interleaving" "the refresh finished in ${waited}s without waiting"
{ [ ! -e "$ADIR/r1_b.json" ] && [ "${calls:-0}" -eq 0 ] && [ "$rc" -ne 0 ]; } \
  && ok "a refresh does not re-register an account somebody removed" \
  || bad "resurrected account" "exists=$([ -e "$ADIR/r1_b.json" ] && echo yes || echo no) calls=${calls:-0} rc=$rc"
grep -q "no longer registered" "$FAKE/.r5-out" \
  && ok "...and says so, rather than reporting it unreachable" \
  || bad "wrong refusal" "got: $(tr '\n' ' ' < "$FAKE/.r5-out" | head -c 100)"
rm -f "$FAKE/.claude.json" "$FAKE/.r5-out"

# ── A partial install puts back what it managed to write ────────────────────
# The rollback has to be about what was actually WRITTEN, not about how many
# sources happened to be readable: a keychain that cannot be read still gets
# written, so counting readable sources skips the restore exactly when both
# stores have been left disagreeing.
rm -f "$FAKE/.claude/ccd/store-split"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/bin/ccd-account" "$FAKE" <<'PY' \
  && ok "a half-installed credential is rolled back to what the session still holds" \
  || bad "no rollback" "the stores were left disagreeing about who is signed in"
import importlib.machinery, importlib.util, json, os, sys
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdacct3", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

OLD = {"claudeAiOauth": {"accessToken": "AT-old", "refreshToken": "RT-old"}}
writes = []
m.use_keychain = lambda: True
m._keychain_write = lambda blob: False          # the keychain refuses every write
# A keychain that could not be READ: the source list names the file alone, while
# the write still has to reach both.
m.live_read = lambda: (OLD, ["file"])
m.write_json = lambda p, obj, mode=0o600: writes.append((str(p), obj))
m.active_name = lambda: "someone_else"
m.account_load = lambda n: ({"name": n, "claudeAiOauth":
                             {"accessToken": "AT-target", "refreshToken": "RT-target"}}
                            if n == "target" else None)
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
else:
    raise AssertionError("swap_to reported success on a half-written store")
creds = [obj for path, obj in writes if path.endswith(".credentials.json")]
assert creds, "the credential file was never written, so this proved nothing"
last = (creds[-1].get("claudeAiOauth") or {}).get("accessToken")
assert last == "AT-old", f"the file was left holding {last!r} while the keychain kept AT-old"
PY

# ── A batch job is never ended for a return it cannot make ─────────────────
# The launcher is the only one that knows there is no terminal to come back to.
# Discovering it after the session has been signalled means the work was killed
# for a relaunch that then does not happen.
"$FAKE/sigbin/claude" 8 2>/dev/null & BPID=$!
sleep 0.3
cat > "$TXD/run-state.json" <<'RSEOF'
{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"last_seven_day_percent":97,"last_seven_day_reset":"D1"}
RSEOF
printf '{"claude":{"available":true,"error":false,"fiveHourPercent":10,"fiveHourReset":"R1","sevenDayPercent":3,"sevenDayReset":"D2"}}\n' \
  > "$TXD/quota-cache.json"
rm -f "$TXD/handoff-00000000000000000000000000000002.json"
printf '{"session_id":"sess-batch","cwd":"/tmp/w","hook_event_name":"UserPromptSubmit"}' \
  | CCD_ACTIVE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_AUTH_TOKEN=x \
    CCD_HANDOFF=00000000000000000000000000000002 \
    CCD_HANDOFF_STATE="$TXD/handoff-00000000000000000000000000000002.json" \
    CCD_HANDOFF_HEADLESS=1 CLAUDE_PID=$BPID CCD_STANDIN_PID=$BPID \
    "$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
sleep 0.4
if kill -0 "$BPID" 2>/dev/null; then ok "a run that cannot be relaunched is never signalled"
else bad "killed a batch job" "the hook ended a session the launcher would refuse to bring back"; fi
[ ! -f "$TXD/handoff-00000000000000000000000000000002.json" ] \
  && ok "...and nothing is armed for a relaunch that would be refused" \
  || bad "armed for a batch job" "armed a return a headless run cannot take"
kill -9 "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
rm -f "$TXD/run-state.json"

# ── The token decides, not the name ─────────────────────────────────────────
# What an exchange can hurt is the CREDENTIAL a session is holding, and a name is
# only a guess at that. Here the pointer names another account entirely, while the
# live blob is carrying r1_b's refresh token — spend it and the running session is
# left with one it can never renew.
r1_fixture
stage_usage 5 5 200 0 AT-r1-rotated
python3 - "$ADIR/r1_b.json" "$CREDS" <<'PY'
import json, sys
acct = json.load(open(sys.argv[1]))
live = json.load(open(sys.argv[2]))
live["claudeAiOauth"] = dict(acct["claudeAiOauth"])   # the session holds r1_b's token
json.dump(live, open(sys.argv[2], "w"))
PY
: > "$CCD_FAKE_USAGE_LOG"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh r1_b > "$FAKE/.rtok-out" 2>&1; rc=$?
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
{ [ "${calls:-0}" -eq 0 ] && [ "$rc" -ne 0 ]; } \
  && ok "a token the live session is holding is never spent, whatever the pointer says" \
  || bad "spent the live token" "${calls:-0} exchanges, rc=$rc"
[ "$(tx_tok "$ADIR/r1_b.json")" = "AT-r1_b" ] \
  && ok "...and the stored copy still matches what that session has" \
  || bad "spent the live token" "store holds $(tx_tok "$ADIR/r1_b.json")"

# ── A store that disagrees with itself stops everything, and ccd never repairs it ─
# One backend took the new credential and the other kept the old, and putting it
# back failed too. The next swap's outgoing backup would read the half the
# keychain answers with and file it under the registration the pointer names —
# one account's credential saved as another's. Nothing may move until the stores
# agree again, and the only thing that can put them back in step is /login:
# Claude Code writes every backend itself, which is more authoritative than
# anything ccd could reconstruct from what it happens to have on file.
split_home() { # $1=case name -> a HOME of this case's own
  rm -rf "$FAKE/split-$1"; mkdir -p "$FAKE/split-$1/.claude"; printf '%s' "$FAKE/split-$1"
}
SPLIT_PRE='
import importlib.machinery, importlib.util, json, os, sys, time
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
loader = importlib.machinery.SourceFileLoader("ccdsplit", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.ensure_dirs()
# The fake sits at the subprocess boundary, not on ccd functions: whatever a
# revision calls its keychain reader, it ends in `security`, and that is where a
# test has to stand to be about behaviour. Anything not staged ends the test —
# and as a BaseException, because the code under test swallows Exception.
import types
class Unstaged(BaseException):
    pass
class Ran:
    def __init__(self, rc, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""
STAGED = {}
def fake_run(argv, *a, **k):
    if list(argv[:2]) == ["security", "find-generic-password"] and "find" in STAGED:
        return STAGED["find"]()
    raise Unstaged("unstaged external call: " + " ".join(argv[:2]))
m.subprocess = types.SimpleNamespace(run=fake_run)
def kc(fn=None, rc=0):                    # what `security find-generic-password` answers
    STAGED["find"] = lambda: Ran(rc, json.dumps(fn()) if rc == 0 else "")
OLD = {"claudeAiOauth": {"accessToken": "AT-old", "refreshToken": "RT-old"}}
TARGET = {"name": "target", "claudeAiOauth":
          {"accessToken": "AT-target", "refreshToken": "RT-target"}}
def only_target(n):
    return dict(TARGET) if n == "target" else None
'

PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
try:
    os.unlink(m.STORE_SPLIT)
except OSError:
    pass
# The keychain takes the install and then refuses the rollback; the file refuses
# throughout. That is the state with no good half left to copy from.
calls = {"n": 0}
def keychain_write(blob):
    calls["n"] += 1
    return calls["n"] == 1
m.use_keychain = lambda: True
m._keychain_write = keychain_write
m.live_read = lambda: (OLD, ["keychain", "file"])
real_write = m.write_json
def selective(p, obj, mode=0o600):
    if str(p).endswith(".credentials.json"):
        raise OSError("read-only")          # the file backend, and only it
    return real_write(p, obj, mode)
m.write_json = selective
m.active_name = lambda: "someone_else"
m.account_load = only_target
m.account_save = lambda n, o: None
err = None
try:
    m.swap_to("target", force=True)
except SystemExit as e:
    err = str(e)
assert err is not None, "swap_to reported success on a store it could not repair"
rec = json.load(open(m.STORE_SPLIT))
# The record has to say what each half is holding — it is what doctor prints —
# and which stores the stop is about, which is what lets it be re-tested later.
note = rec.get("detail") or ""
assert "keychain" in note and "file" in note, f"the record says too little: {note!r}"
assert rec.get("stores") == ["file", "keychain"], f"the stop names no stores: {rec!r}"
' "$ROOT/bin/ccd-account" "$(split_home rollback)" \
  && ok "a rollback that fails too is recorded as a store that cannot be trusted" \
  || bad "unrecorded split" "the swap left the stores disagreeing and said nothing"

# A rollback that PUT EVERYTHING BACK is not a split, however loudly the install
# failed. The backend that refused the new credential refuses the redundant
# restore too, and it never moved: recording that as a split stops a machine that
# is perfectly consistent.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
m._keychain_write = lambda blob: False   # refuses the install AND the restore
m.live_read = lambda: (OLD, ["keychain", "file"])
m.active_name = lambda: "someone_else"
m.account_load = only_target
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
assert not os.path.exists(m.STORE_SPLIT), \
    "a store that ends up consistent was stopped anyway: " + open(m.STORE_SPLIT).read()
live = json.load(open(m.credentials_file()))
assert live["claudeAiOauth"]["accessToken"] == "AT-old", \
    "the rollback did not put the file back: " + json.dumps(live["claudeAiOauth"])
' "$ROOT/bin/ccd-account" "$(split_home consistent)" \
  && ok "a rollback that put every backend back is not recorded as a split" \
  || bad "false split" "a consistent store was stopped over a refused redundant write"

# Write-ahead, not best-effort. If the intent cannot be recorded, the credential
# is not written at all: an unwritable state directory would otherwise disable
# the protection silently, and the next command banks one account's credential
# under another's name with nothing left to stop it.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
touched = []
m.use_keychain = lambda: True
m._keychain_write = lambda blob: (touched.append("keychain"), True)[1]
m.live_read = lambda: (OLD, ["keychain", "file"])
real_write = m.write_json
def selective(p, obj, mode=0o600):
    if os.path.basename(str(p)) == "store-split":
        raise OSError("read-only state directory")
    touched.append(os.path.basename(str(p)))
    return real_write(p, obj, mode)
m.write_json = selective
m.active_name = lambda: "someone_else"
m.account_load = only_target
m.account_save = lambda n, o: None
err = None
try:
    m.swap_to("target", force=True)
except SystemExit as e:
    err = str(e)
assert err is not None, "the swap went ahead with no way to record what it was doing"
assert touched == [], f"a credential backend was written anyway: {touched!r}"
' "$ROOT/bin/ccd-account" "$(split_home noroom)" \
  && ok "a state directory that cannot hold the record means no credential is written" \
  || bad "unrecorded write" "the swap wrote credentials it could not record"

# The stop is re-tested, never repaired. /login makes Claude Code write every
# backend itself, and the moment they agree again there is nothing left to stop.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
held = {"kc": {"accessToken": "AT-old", "refreshToken": "RT-old"}}
m.use_keychain = lambda: True
kc(lambda: {"claudeAiOauth": held["kc"]})
m.write_json(m.credentials_file(),
             {"claudeAiOauth": {"accessToken": "AT-new", "refreshToken": "RT-new"}})
m.write_json(m.STORE_SPLIT, {"detail": "keychain kept the old credential",
                             "stores": ["file", "keychain"]})
assert m.store_split_now() is not None, "the stop lifted while the stores disagreed"
held["kc"] = {"accessToken": "AT-new", "refreshToken": "RT-new"}   # signed in again
assert m.store_split_now() is None, "the stop stood after the stores were put back in step"
assert not os.path.exists(m.STORE_SPLIT), "the record outlived the disagreement"
' "$ROOT/bin/ccd-account" "$(split_home login)" \
  && ok "the stop lifts by itself once every store it names agrees again" \
  || bad "no way out" "/login put the stores back in step and ccd stayed stopped"

# Banking re-checks the record under the lock. The pre-check describes the world
# we saw; the record can land while we queue, and copying between stores that
# disagree is exactly how one account's credential gets filed under another's.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
saved = []
m.use_keychain = lambda: False
m.account_save = lambda n, o: saved.append(n)
m.account_load = lambda n: {"name": n}
m._bank_target = lambda: ("acct", {"accessToken": "AT-live", "refreshToken": "RT-live"})
RealLock = m.Lock
class MarkingLock(RealLock):
    def __enter__(self):
        got = RealLock.__enter__(self)
        m.write_json(m.STORE_SPLIT, {"detail": "another ccd stopped mid-write",
                                     "stores": ["file", "keychain"]})
        return got
m.Lock = MarkingLock
m.bank_live_oauth()
assert saved == [], f"banked across a store that started disagreeing while it waited: {saved!r}"
' "$ROOT/bin/ccd-account" "$(split_home banklock)" \
  && ok "banking re-reads the stop under the lock, not only before it" \
  || bad "banked on a split" "the record landed while banking waited and it copied anyway"

# The gate that decides whether a stored token is safe to spend has to look at
# EVERY backend. Preferring one drops the other's credential from the comparison,
# and a running session may well be carrying the one that was dropped.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
spent = []
m.use_keychain = lambda: True
kc(lambda: {"claudeAiOauth": {"accessToken": "AT-a", "refreshToken": "RT-a"}})
m.write_json(m.credentials_file(),
             {"claudeAiOauth": {"accessToken": "AT-b", "refreshToken": "RT-b"}})
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [], f"spent a token the other backend is holding: {spent!r}"
assert okd is False and st == "stale", f"got {okd!r}/{st!r}"
' "$ROOT/bin/ccd-account" "$(split_home bothbackends)" \
  && ok "a token any readable backend is holding is never spent" \
  || bad "spent a live token" "the gate looked at one backend and missed the other"

# And a backend it cannot read is unknown, not absent. An empty answer is what
# let the exchange proceed when nothing could be read at all.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
spent = []
m.use_keychain = lambda: True
kc(rc=1)                                # the keychain will not answer
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [], f"spent a token with no idea what the session is holding: {spent!r}"
assert okd is False, f"got {okd!r}/{st!r}"
' "$ROOT/bin/ccd-account" "$(split_home blind)" \
  && ok "a credential store that cannot be read refuses the exchange, it does not permit it" \
  || bad "spent a token blind" "an unreadable backend was treated as an empty one"

# Absence of evidence is not agreement. A credential only has to carry an access
# token for ccd to register and install it, so two backends can hold DIFFERENT
# logins that both lack a refresh token — and a stop lifted on that pair hands the
# next swap a live blob belonging to the other account.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kcb = {"blob": {"claudeAiOauth": {"accessToken": "AT-b"}}}         # B, no refresh token
kc(lambda: kcb["blob"])
m.write_json(m.credentials_file(), {"claudeAiOauth": {"accessToken": "AT-a"}})
m.write_json(m.STORE_SPLIT, {"detail": "keychain took b, file kept a",
                             "stores": ["file", "keychain"]})
assert m.store_split_now() is not None, \
    "two different logins compared equal because neither had a refresh token"
# ...and a store where nothing can be identified at all is not an agreeing store.
kcb["blob"] = {"claudeAiOauth": {}}
m.write_json(m.credentials_file(), {"claudeAiOauth": {}})
assert m.store_split_now() is not None, "a store with no identity anywhere lifted the stop"
' "$ROOT/bin/ccd-account" "$(split_home noident)" \
  && ok "two credentials that cannot be told apart are not the same credential" \
  || bad "absence read as agreement" "the stop lifted on a store that is still divided"

# Codex's scenario end to end: the install takes the keychain and the rollback
# cannot put it back, so keychain=B, file=A, pointer=A — every credential carrying
# an access token and nothing else. The retry must find the stop, and must not
# bank the keychain half into A on its way past.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
store = {"a": {"name": "a", "claudeAiOauth": {"accessToken": "AT-a"}},
         "b": {"name": "b", "claudeAiOauth": {"accessToken": "AT-b"}}}
m.account_load = lambda n: json.loads(json.dumps(store[n])) if n in store else None
m.account_save = lambda n, o: store.__setitem__(n, json.loads(json.dumps(o)))
m.active_name = lambda: "a"
m.active_set = lambda n, stamp=True: None
m.drop_account_scoped_config = lambda: None
back = {"keychain": {"claudeAiOauth": {"accessToken": "AT-a"}},
        "file": {"claudeAiOauth": {"accessToken": "AT-a"}}}
m.use_keychain = lambda: True
kcalls = {"n": 0}
def kwrite(blob):
    kcalls["n"] += 1
    if kcalls["n"] == 1:
        back["keychain"] = json.loads(json.dumps(blob))
        return True
    return False                      # refuses the rollback
m._keychain_write = kwrite
kc(lambda: back["keychain"])
m.live_read = lambda: (json.loads(json.dumps(back["keychain"])), ["keychain", "file"])
m.write_json(m.credentials_file(), {"claudeAiOauth": {"accessToken": "AT-a"}})
real_write = m.write_json
def selective(p, obj, mode=0o600):
    if str(p).endswith(".credentials.json"):
        raise OSError("read-only")     # the file backend keeps A throughout
    return real_write(p, obj, mode)
m.write_json = selective
first = None
try:
    m.swap_to("b", force=True)
except SystemExit as e:
    first = str(e)
assert first is not None, "the divided write reported success"
assert os.path.exists(m.STORE_SPLIT), "nothing recorded the divided store"
try:
    m.swap_to("b", force=True)         # the retry
except SystemExit as e:
    second = str(e)
else:
    raise AssertionError("the retry ran on a store that is still divided")
assert store["a"]["claudeAiOauth"]["accessToken"] == "AT-a", \
    "a retry filed b credential under a: " + json.dumps(store["a"]["claudeAiOauth"])
' "$ROOT/bin/ccd-account" "$(split_home retry)" \
  && ok "a retry over a divided store neither swaps nor rewrites the outgoing account" \
  || bad "retry corrupts the store" "the second swap moved something it should not have"

# ccd does not infer absence. The stop lifts only when every store the record names
# ANSWERS, with a credential, and they all carry the same identity. Each of the
# three below once counted as "that backend is gone", and each was a way to lift
# the stop on a store nobody had actually seen agree.
HEALTHY='{"claudeAiOauth": {"accessToken": "AT-new", "refreshToken": "RT-new"}}'
RECORD='m.write_json(m.STORE_SPLIT, {"detail": "keychain took b, file kept a", "stores": ["file", "keychain"]})'

# A file that is not there. It may have been removed for good — and the user has
# an explicit exit for that — but ccd cannot tell that from a file it cannot reach.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
exec(sys.argv[4])
assert m.store_split_now() is not None, "a missing file was read as a store that agrees"
' "$ROOT/bin/ccd-account" "$(split_home nofile)" "$HEALTHY" "$RECORD" \
  && ok "a named store that does not answer keeps the stop, even when the file is simply missing" \
  || bad "absence inferred" "a store that did not answer was counted as agreeing"

# A file that is there and cannot be reached. os.path.exists() answers False for a
# permission error as readily as for a missing file, which is how an unreadable
# credential was classed as no credential at all.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
exec(sys.argv[4])
creds = m.credentials_file()
real_open, real_exists = open, os.path.exists
def denied(p, *a, **k):
    if str(p) == creds:
        raise PermissionError(13, "Permission denied", creds)
    return real_open(p, *a, **k)
m.open = denied
m.os.path.exists = lambda p: False if str(p) == creds else real_exists(p)
assert m.store_split_now() is not None, "a file ccd was refused was read as a file that is gone"
' "$ROOT/bin/ccd-account" "$(split_home denied)" "$HEALTHY" "$RECORD" \
  && ok "a credentials file ccd is refused is unknown, not absent" \
  || bad "absence inferred" "a permission error lifted the stop"

# A keychain that says it found nothing. `security` exits 44 out of failed searches
# too, so it cannot prove the item is absent.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(rc=44)                               # exit 44, staged as itself
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
exec(sys.argv[4])
assert m.store_split_now() is not None, "a keychain that found nothing was read as an empty one"
' "$ROOT/bin/ccd-account" "$(split_home kc44)" "$HEALTHY" "$RECORD" \
  && ok "a keychain search that comes back empty does not prove the keychain is" \
  || bad "absence inferred" "exit 44 lifted the stop"

# A keychain holding no Claude login at all. Lifting the stop here is what let the
# same-account branch copy that blob over the healthy file login and erase it.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: {"mcpOAuth": {"notion|abc": {"accessToken": "MCP"}}})
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
exec(sys.argv[4])
assert m.store_split_now() is not None, "a store holding no login was read as one that agrees"
' "$ROOT/bin/ccd-account" "$(split_home nologin)" "$HEALTHY" "$RECORD" \
  && ok "a named store holding no Claude login keeps the stop" \
  || bad "absence inferred" "a credential-free backend lifted the stop"

# ...and that branch does not need a lifted stop to do the damage: with no record
# at all it still copies whatever live_read() prefers over every backend. A blob
# with no login in it is not something to even the stores WITH.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
wrote = []
m.use_keychain = lambda: True
m.live_read = lambda: ({"mcpOAuth": {"notion|abc": {"accessToken": "MCP"}}}, ["keychain", "file"])
m.live_write = lambda blob, sources: (wrote.append(blob), (True, [], []))[1]
m.active_name = lambda: "target"
m.account_load = only_target
m.account_save = lambda n, o: None
try:
    m.swap_to("target", force=True)
except SystemExit:
    pass
assert wrote == [], "a blob holding no login was copied over every backend: " + json.dumps(wrote)
' "$ROOT/bin/ccd-account" "$(split_home sameacct)" \
  && ok "evening the stores never copies a blob that holds no login" \
  || bad "login erased" "the same-account branch overwrote the stores with a credential-free blob"

# The gate that protects a live token looks at every refresh token any backend
# holds — identifiable or not. A blob with a refresh token and no access token is
# nothing ccd would install, and it is still something a session may be carrying.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
spent = []
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
m.write_json(m.credentials_file(), {"claudeAiOauth": {"refreshToken": "RT-b"}})
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [], f"spent a token a backend is holding: {spent!r}"
' "$ROOT/bin/ccd-account" "$(split_home unidentified)" "$HEALTHY" \
  && ok "a refresh token is protected even in a credential ccd cannot identify" \
  || bad "spent a live token" "a backend with no access token was dropped from the gate"

# For the gate the two kinds of silence are NOT the same as an empty store: a
# backend that gave no answer may be holding the very token about to be spent,
# however healthy the other one looks.
GATE='
spent = []
m.token_refresh = lambda rt: (spent.append(rt), (None, 500))[1]
m.active_name = lambda: None
far = int((time.time() + 8 * 86400) * 1000)
m.account_load = lambda n: {"name": "b", "claudeAiOauth":
                            {"accessToken": "AT-b", "refreshToken": "RT-b",
                             "refreshTokenExpiresAt": far}}
okd, st = m.account_refresh("b", {})
assert spent == [] and okd is False, f"exchanged with a backend unaccounted for: {spent!r} {st!r}"
'
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(lambda: json.loads(sys.argv[3]))
creds = m.credentials_file()
real_open = open
def denied(p, *a, **k):
    if str(p) == creds:
        raise PermissionError(13, "Permission denied", creds)
    return real_open(p, *a, **k)
m.open = denied
'"$GATE" "$ROOT/bin/ccd-account" "$(split_home gatedenied)" "$HEALTHY" \
  && ok "a credentials file ccd is refused stops the exchange, healthy keychain or not" \
  || bad "spent a token blind" "an unreadable file was treated as holding nothing"

PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: True
kc(rc=1)
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
'"$GATE" "$ROOT/bin/ccd-account" "$(split_home gatesilent)" "$HEALTHY" \
  && ok "a keychain that gives no answer stops the exchange, healthy file or not" \
  || bad "spent a token blind" "a silent keychain was treated as an empty one"

# Two writes that both succeed prove only that ccd wrote twice. Claude Code shares
# no lock with ccd, and a refresh of the outgoing account can land on one backend
# between them. So the record goes away on what the stores are SEEN to hold, not
# on what the writes returned. (This narrows that race; it cannot close it.)
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
A = {"claudeAiOauth": {"accessToken": "AT-a", "refreshToken": "RT-a"}}
back = {"kc": json.loads(json.dumps(A))}
m.write_json(m.credentials_file(), A)
m.use_keychain = lambda: True
kc(lambda: back["kc"])
def kwrite(blob):
    # ccd write lands, and then the refresh Claude Code had in flight for the
    # outgoing account lands on top of it — before ccd reaches the file.
    back["kc"] = {"claudeAiOauth": {"accessToken": "AT-a2", "refreshToken": "RT-a2"}}
    return True
m._keychain_write = kwrite
moved = []
m.active_set = lambda n, stamp=True: moved.append(n)
m.active_name = lambda: "a"
m.account_load = lambda n: only_target(n) or ({"name": "a", **A} if n == "a" else None)
m.account_save = lambda n, o: None
m.drop_account_scoped_config = lambda: None
m.swap_to("target", force=True)
assert os.path.exists(m.STORE_SPLIT), "two successful writes cleared the stop on stores that disagree"
rec = json.load(open(m.STORE_SPLIT))
# Ownership follows the writes, as it always did: both succeeded, and that is the
# best knowledge there is of whose credential is live. Only the RECORD waits.
assert moved == ["target"], f"the pointer did not follow the install: {moved!r}"
assert "interrupted" not in rec["detail"], "the record still tells the write-ahead story: " + rec["detail"]
' "$ROOT/bin/ccd-account" "$(split_home foreign)" 2> "$FAKE/.foreign-err" \
  && ok "two successful writes do not clear the stop when the stores are seen to disagree" \
  || bad "cleared on write success" "$(tail -1 "$FAKE/.foreign-err")"
grep -q 'ccd/store-split' "$FAKE/.foreign-err" \
  && ok "...and the refusal names the record, as every other one does" \
  || bad "no way out" "got: $(tr '\n' ' ' < "$FAKE/.foreign-err" | head -c 160)"

# The verify decides about the RECORD and about nothing else. When it also gated
# the pointer, one failed read left B installed under a pointer still saying A —
# and once reads recovered, the next command lifted the stop and the retry banked
# live B into A. No foreign writer needed; the hook's own retry did it. So: real
# files, real account_save, and the whole sequence.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
A = {"accessToken": "AT-a", "refreshToken": "RT-a"}
B = {"accessToken": "AT-b", "refreshToken": "RT-b"}
m.use_keychain = lambda: False
m.account_save("a", {"name": "a", "claudeAiOauth": A})
m.account_save("b", {"name": "b", "claudeAiOauth": B})
m.active_set("a", stamp=False)
m.write_json(m.credentials_file(), {"claudeAiOauth": A})
creds, real_open, real_live_write = m.credentials_file(), open, m.live_write
state = {"blind": False}
def flaky(p, *a, **k):
    if state["blind"] and str(p) == creds:
        raise PermissionError(13, "Permission denied", creds)
    return real_open(p, *a, **k)
m.open = flaky
def then_blind(blob, sources):
    got = real_live_write(blob, sources)
    state["blind"] = True             # every write landed; the read after it does not
    return got
m.live_write = then_blind
said = []
m.warn = lambda msg: said.append(msg)
try:
    installed = m.swap_to("b", force=True)[1]
except SystemExit:
    installed = None                  # judged last: what it corrupts comes first
assert os.path.exists(m.STORE_SPLIT), "an unverified install cleared its own record"
state["blind"] = False                # reads recover
m.live_write = real_live_write
m.bank_live_oauth()                   # what every next command starts with
m.swap_to("b", force=True)            # and the retry the hook would make
stored = json.load(real_open(m.account_path("a")))["claudeAiOauth"]
assert stored["accessToken"] == "AT-a", "the outgoing account now holds: " + json.dumps(stored)
assert m._pointer_name() == "b", "the pointer says " + repr(m._pointer_name())
assert not os.path.exists(m.STORE_SPLIT), "the stop outlived stores that agree"
assert installed, "a swap that happened was reported as one that did not"
assert said and "store-split" in " ".join(said), f"the standing stop went unmentioned: {said!r}"
' "$ROOT/bin/ccd-account" "$(split_home sequence)" \
  && ok "a verify that cannot see leaves the pointer right, and the retry banks nothing into the wrong account" \
  || bad "outgoing snapshot corrupted" "a transient read failure ended with one account filed under another"

# A record ccd cannot make sense of is still a record. Each of these used to fail
# open: no stores named meant nothing had to answer, and an empty one read as
# "no stop" to every caller that tested it for truth.
for bad_rec in '{}' '{"detail":"x"}' '{"detail":"x","stores":[]}' '{"detail":"x","stores":["floppy"]}' 'not json at all'; do
  BAD_REC="$bad_rec" PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: False
m.write_json(m.credentials_file(), json.loads(sys.argv[3]))
open(m.STORE_SPLIT, "w").write(os.environ["BAD_REC"])
assert m.store_split(), "the record reads as no stop at all"
assert m.store_split_now(), "one healthy backend lifted a stop that names nothing it can check"
assert os.path.exists(m.STORE_SPLIT), "the record was deleted"
' "$ROOT/bin/ccd-account" "$(split_home malformed)" "$HEALTHY" 2>/dev/null \
    && ok "a malformed stop still stops: $bad_rec" \
    || bad "malformed record fails open" "$bad_rec"
done

# The outgoing backup and the evening of the stores ask the same question — does
# the blob live_read() prefers hold a login at all — and must get the same answer.
# Banking a refresh-only blob overwrites a healthy snapshot with something ccd
# itself would refuse to install.
PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: False
m.write_json(m.credentials_file(), {"claudeAiOauth": {"refreshToken": "RT-only"}})
saved, warned = [], []
m.account_save = lambda n, o: saved.append((n, o.get("claudeAiOauth")))
m.warn = lambda msg: warned.append(msg)
m.active_name = lambda: "target"
m.account_load = only_target
m.swap_to("target", force=True)
assert saved == [], "a blob holding no login was banked over the snapshot: " + json.dumps(saved)
assert warned, "nothing was done and nothing was said"
' "$ROOT/bin/ccd-account" "$(split_home nobank)" \
  && ok "a live blob holding no login is neither banked nor copied, and ccd says so" \
  || bad "snapshot overwritten" "the outgoing backup banked a credential-free blob"

PYTHONDONTWRITEBYTECODE=1 python3 -c "$SPLIT_PRE"'
m.use_keychain = lambda: False
m.write_json(m.credentials_file(), {"claudeAiOauth": {"refreshToken": "RT-only"}})
saved = []
m.account_save = lambda n, o: saved.append(n)
m.active_name = lambda: "a"
m.account_load = lambda n: only_target(n) or ({"name": "a", "claudeAiOauth": {"accessToken": "AT-a"}} if n == "a" else None)
m.active_set = lambda n, stamp=True: None
m.drop_account_scoped_config = lambda: None
m.swap_to("target", force=True)
assert "a" not in saved, "the outgoing account was overwritten with a blob holding no login"
assert not os.path.exists(m.STORE_SPLIT), "a clean single-store install left its record behind"
' "$ROOT/bin/ccd-account" "$(split_home nobank2)" \
  && ok "...nor banked on the way out to another account, and a one-store install still clears its record" \
  || bad "snapshot overwritten" "a swap away banked a credential-free blob"

# ...and while the stop stands, nothing else may touch the credential stores. The
# record names both backends; this suite can only see the file one, so it cannot
# be re-tested here — which is exactly the shape of "ccd cannot see that they
# agree", and the stop has to hold.
mkdir -p "$ADIR"
printf '{"detail":"keychain kept AT-old, file holds AT-new","stores":["file","keychain"]}' \
  > "$TXD/store-split"
write_creds split_b; "$ACCT" --no-color add --name split_b >/dev/null 2>&1
write_creds split_a; "$ACCT" --no-color add --name split_a >/dev/null 2>&1
out=$("$ACCT" --no-color use split_b --force 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q 'AT-split_b' "$CREDS"; } \
  && ok "a swap refuses to run on a store that is known to disagree with itself" \
  || bad "swapped on a split store" "rc=$rc, credential $(tx_tok "$CREDS")"
: > "$CCD_FAKE_USAGE_LOG"
CCD_HTTP_TIMEOUT=10 "$ACCT" --no-color refresh split_b >/dev/null 2>&1; rrc=$?
calls=$(wc -l < "$CCD_FAKE_USAGE_LOG" | tr -d ' ')
{ [ "${calls:-0}" -eq 0 ] && [ "$rrc" -ne 0 ]; } \
  && ok "...and no stored token is spent while a store the stop names cannot be seen" \
  || bad "spent a token on a split store" "${calls:-0} exchanges, rc=$rrc"
case "$out" in
  *"/login"*) ok "...and sends the user to /login, which replaces the credential in use" ;;
  *) bad "no way out" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
case "$out" in
  *"writes every credential store"*)
    bad "overclaims" "ccd promises Claude Code writes both stores; it writes one and falls back" ;;
  *"stale"*|*"other half"*)
    bad "overclaims" "ccd says which half is stale; it does not know" ;;
  *".claude/ccd/store-split"*)
    ok "...and names the record to delete once the user is satisfied the login works" ;;
  *) bad "no second exit" "nothing says what to do when signing in does not lift it" ;;
esac
case "$out" in
  *reconcile*) bad "still offering a repair" "ccd offered to rebuild the store itself" ;;
  *) ok "...and never offers to rebuild the store itself" ;;
esac
out=$(HOME="$FAKE" CLAUDE_PLUGIN_ROOT="$ROOT" "$ROOT/bin/ccd" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' \
      | sed -n '/Credential stores/,/^$/p')
case "$out" in
  *"stale"*|*"other half"*) bad "doctor overclaims" "doctor says which half is stale; ccd does not know" ;;
  *"disagree"*"/login"*"ccd/store-split"*) ok "...and doctor says it, exit included, where somebody would go looking" ;;
  *) bad "doctor blind" "doctor never sends the user to /login over the split store" ;;
esac
"$ACCT" --no-color reconcile split_a >/dev/null 2>&1 \
  && bad "repair command survives" "ccd account reconcile still runs" \
  || ok "...and there is no ccd command that claims to repair a credential store"
rm -f "$TXD/store-split"

# Write-ahead, on the real filesystem and not a stubbed one: the state directory
# stops taking new files while everything the swap reads stays readable. A
# protection that cannot be recorded is none at all, so the credential must not
# move either. Root writes through a read-only directory, so containers skip it.
if [ "$(id -u)" -ne 0 ]; then
  write_creds split_a
  chmod 500 "$TXD"
  out=$("$ACCT" --no-color use split_b --force 2>&1); rc=$?
  chmod 700 "$TXD"
  { [ "$rc" -ne 0 ] && [ "$(tx_tok "$CREDS")" = "AT-split_a" ]; } \
    && ok "a record ccd cannot write means the credential is not written either" \
    || bad "wrote what it could not record" "rc=$rc, credential $(tx_tok "$CREDS")"
  case "$out" in
    *"refusing to touch the credential stores"*) ok "...and says so instead of swapping quietly" ;;
    *) bad "silent unrecorded write" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
  esac
fi

write_creds split_a
"$ACCT" --no-color use split_b --force >/dev/null 2>&1 \
  && grep -q 'AT-split_b' "$CREDS" \
  && [ ! -e "$TXD/store-split" ] \
  && ok "...after which a swap works again, and clears its own record on a one-store machine" \
  || bad "still blocked" "the store stayed unusable once the stop was gone"
rm -rf "$FAKE"/split-*

# ── The launcher is the one that knows a run is headless ────────────────────
# A test that sets the flag itself proves only that the hook reads it. What has
# to be true is that the launcher publishes it, because it is the only party that
# can see there is no terminal to come back to.
mkdir -p "$FAKE/hlbin"
printf '#!/bin/sh\nprintf "HEADLESS=[%%s]\\n" "${CCD_HANDOFF_HEADLESS:-}"\n' > "$FAKE/hlbin/claude"
chmod +x "$FAKE/hlbin/claude"
out=$(PATH="$FAKE/hlbin:$PATH" "$ROOT/bin/ccd-handoff" -p hi 2>&1)
case "$out" in
  *"HEADLESS=[1]"*) ok "the launcher tells the hook when a run cannot be relaunched" ;;
  *) bad "no headless flag" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 100)" ;;
esac
out=$(PATH="$FAKE/hlbin:$PATH" shim_run "$ROOT/bin/ccd-handoff" 2>&1)
case "$out" in
  *"HEADLESS=[]"*) ok "...and says nothing of the sort about an interactive one" ;;
  *) bad "headless flag leaked" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 100)" ;;
esac

# ── A leftover shim that cannot run is not a route ──────────────────────────
# is_ccd_shim() answers "ours", not "runnable". Committing to an unexecutable one
# breaks every ccd launch on a machine with a perfectly good claude on PATH.
rm -rf "$FAKE/.claude/ccd/bin"
mkdir -p "$FAKE/.claude/ccd/bin"
{ printf '#!/usr/bin/env bash\n'; printf '# ccd-auto-handoff-shim v1 (managed by: ccd setup --auto)\n'; } \
  > "$FAKE/.claude/ccd/bin/claude"
chmod -x "$FAKE/.claude/ccd/bin/claude"
fake_real '#!/bin/sh
printf "REAL reached=%s\n" "$*"'
out=$(PATH="$SHIMPATH" HOME="$FAKE" shim_run "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"REAL reached="*) ok "a shim that cannot be executed is stepped over, not exec'd" ;;
  *) bad "unrunnable shim" "ccd could not start claude at all: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
rm -rf "$FAKE/.claude/ccd/bin"

# ── The return has an entrance ──────────────────────────────────────────────
# `--auto` installs a launcher whose only job is bringing a ccd run back to the
# subscription. A ccd run that does not START under it can never come back, so
# ccd itself has to go through it when one is installed.
rm -rf "$FAKE/.claude/ccd/bin"
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
fake_real '#!/bin/sh
printf "REAL supervised=[%s]\n" "${CCD_HANDOFF:+yes}"'
out=$(PATH="$SHIMPATH" HOME="$FAKE" shim_run "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"supervised=[yes]"*) ok "an interactive ccd run starts under the launcher that can bring it back" ;;
  *) bad "no entrance" "the launcher installed by --auto never sees the session: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
# ...and a redirected one does not: no terminal, nothing to return to.
out=$(PATH="$SHIMPATH" HOME="$FAKE" "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"supervised=[]"*) ok "...while a run with nowhere to come back to is left alone" ;;
  *"supervised=[yes]"*) bad "no entrance" "a redirected run was put under a launcher" ;;
  *) bad "no entrance" "never reached the real claude: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac

# ── A batch job never inherits somebody else's supervision ──────────────────
# `ccd -p` run from inside a supervised session inherits CCD_HANDOFF and the
# state path that goes with it. Declining the launcher is only half the job: the
# child still claims to be watched, so the hook arms and signals it on the
# parent's contract — and the work dies for a relaunch nobody will make.
out=$(PATH="$SHIMPATH" HOME="$FAKE" OPENROUTER_API_KEY=sk-or-v1-smoketest \
      CCD_HANDOFF=00000000000000000000000000000001 \
      CCD_HANDOFF_STATE="$FAKE/.claude/ccd/handoff-00000000000000000000000000000001.json" \
      "$ROOT/bin/ccd" -p hi 2>&1)
case "$out" in
  *"supervised=[]"*) ok "a batch run started inside a supervised session claims no supervision" ;;
  *"supervised=[yes]"*) bad "inherited supervision" "the batch child carried its parent's launcher contract" ;;
  *) bad "inherited supervision" "never reached the real claude: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac
# ...but never two of them: a session already supervised must not gain a second
# launcher underneath the first.
# A second launcher would mint a token of its own, so the one that arrives is the
# proof: the same token means nothing was nested underneath it.
fake_real '#!/bin/sh
printf "REAL token=%s\n" "${CCD_HANDOFF:-none}"'
out=$(PATH="$SHIMPATH" HOME="$FAKE" CCD_HANDOFF=00000000000000000000000000000001 \
      shim_run "$ROOT/bin/ccd" off 2>&1)
case "$out" in
  *"token=00000000000000000000000000000001"*)
    bad "inherited supervision" "the child kept a contract minted for its parent" ;;
  *"token=none"*) ok "...and a session that inherits a contract does not keep it" ;;
  *) bad "nested launcher" "got: $(printf '%s' "$out" | tr '\n' ' ' | head -c 120)" ;;
esac

rm -rf "$ADIR" "$TXD/accounts-keepalive"
unset PYTHONPATH CCD_FAKE_USAGE CCD_FAKE_USAGE_LOG
unset -f tx_fixture tx_tok tx_uuid

# Reported, not yet asserted. The rejecting stub is what guarantees nothing leaves
# the machine; making this a failure means staging an answer in every section
# that probes OpenRouter, which is its own piece of work. Until then the number
# stays in plain sight instead of being a request nobody knew the suite made.
if [ -s "$FAKE/.unstaged-curl" ]; then
  printf '\n  note: %s curl calls had no staged answer and were REJECTED by the default stub:\n' \
    "$(wc -l < "$FAKE/.unstaged-curl" | tr -d ' ')"
  sed -E 's#.*(https?://[^ ]+).*#\1#; s#/models/[^ ]*/endpoints#/models/<slug>/endpoints#' "$FAKE/.unstaged-curl" \
    | sort | uniq -c | sort -rn | sed 's/^/    /'
fi

head_ "33. the container gate checks the image's architecture"
# A tag is one name for several per-architecture images, and the last pull wins.
# One `docker pull --platform linux/amd64 alpine:3.20` on an arm64 Mac left the
# local tag pointing at amd64, and every Alpine gate after it ran under qemu:
# 16 failures that were carried as "known" for five days and were never real.
#
# The docker here is a double in this section's own directory, never the shared
# fakebin: it answers the two questions docker.sh asks from files each case
# stages, and records a `run` instead of starting anything. docker.sh execs
# `docker run`, so the double's exit is the script's exit.
DG="$FAKE/dockergate"
mkdir -p "$DG/bin"
cat > "$DG/bin/docker" <<'DGEOF'
#!/bin/sh
case "$1 ${2:-}" in
  "image inspect") [ -f "$DG/image-arch" ] || { echo "Error response from daemon: No such image" >&2; exit 1; }
                   cat "$DG/image-arch" ;;
  "version "*)     [ -f "$DG/server-arch" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
                   cat "$DG/server-arch" ;;
  "run "*)         printf '%s\n' "$*" > "$DG/ran" ;;
esac
DGEOF
chmod +x "$DG/bin/docker"
dg_gate() { # $1=image arch $2=server arch ('-' = that question fails); rest = env
  rm -f "$DG/ran" "$DG/err" "$DG/image-arch" "$DG/server-arch"
  [ "$1" = - ] || printf '%s\n' "$1" > "$DG/image-arch"
  [ "$2" = - ] || printf '%s\n' "$2" > "$DG/server-arch"
  shift 2
  env -u CCD_DOCKER_EMULATE DG="$DG" PATH="$DG/bin:$PATH" "$@" \
    bash "$ROOT/test/docker.sh" alpine:3.20 >/dev/null 2>"$DG/err"
}

dg_gate amd64 arm64; dg_rc=$?
[ "$dg_rc" -ne 0 ] && ok "a cached image of the wrong architecture stops the gate" \
  || bad "wrong-architecture image" "docker.sh exited 0"
[ ! -f "$DG/ran" ] && ok "...before any container is started" \
  || bad "wrong-architecture image" "docker run was called: $(head -c 120 "$DG/ran")"
grep -q "docker pull --platform linux/arm64 alpine:3.20" "$DG/err" \
  && ok "...and names the pull that fixes it" \
  || bad "the fix is not named" "stderr: $(head -c 160 "$DG/err")"
grep -q "CCD_DOCKER_EMULATE=1" "$DG/err" && ok "...and the way to run emulated on purpose" \
  || bad "the override is not named" "stderr: $(head -c 160 "$DG/err")"

dg_gate arm64 arm64; dg_rc=$?
[ "$dg_rc" -eq 0 ] && [ -f "$DG/ran" ] && [ ! -s "$DG/err" ] \
  && ok "a native image runs, and says nothing" \
  || bad "native image" "rc=$dg_rc stderr: $(head -c 160 "$DG/err")"

dg_gate amd64 arm64 CCD_DOCKER_EMULATE=1; dg_rc=$?
[ "$dg_rc" -eq 0 ] && [ -f "$DG/ran" ] && ok "CCD_DOCKER_EMULATE=1 runs the wrong architecture on purpose" \
  || bad "CCD_DOCKER_EMULATE=1" "rc=$dg_rc stderr: $(head -c 160 "$DG/err")"

# The check must never be the reason a gate cannot run: an answer it cannot read
# is a warning, not a mismatch.
dg_gate amd64 -; dg_rc=$?
[ "$dg_rc" -eq 0 ] && [ -f "$DG/ran" ] && ok "a Docker whose architecture cannot be read still runs" \
  || bad "unreadable server architecture" "rc=$dg_rc stderr: $(head -c 160 "$DG/err")"
[ "$(wc -l < "$DG/err" | tr -d ' ')" = 1 ] && ok "...with a one-line warning" \
  || bad "unreadable server architecture" "stderr: $(head -c 160 "$DG/err")"
dg_gate "" arm64; dg_rc=$?
[ "$dg_rc" -eq 0 ] && [ -f "$DG/ran" ] && [ "$(wc -l < "$DG/err" | tr -d ' ')" = 1 ] \
  && ok "...and so does an image that reports none" \
  || bad "empty image architecture" "rc=$dg_rc stderr: $(head -c 160 "$DG/err")"

# Not cached: nothing to compare, and Docker pulls the native image by itself.
dg_gate - arm64; dg_rc=$?
[ "$dg_rc" -eq 0 ] && [ -f "$DG/ran" ] && [ ! -s "$DG/err" ] \
  && ok "an image that is not cached runs, and says nothing" \
  || bad "uncached image" "rc=$dg_rc stderr: $(head -c 160 "$DG/err")"
rm -rf "$DG"

head_ "34. the suite leaves no bytecode in the product"
# The suite imports bin/ccd-account as a module in many places, and Python writes
# its bytecode next to the source unless told not to. One such file was committed
# and shipped in v0.8.0 (#77). Whatever the suite runs, bin/ and scripts/ must come
# out of it holding only what was put there.
pyc=$(find "$ROOT/bin" "$ROOT/scripts" \( -name __pycache__ -o -name '*.pyc' \) 2>/dev/null | head -3)
[ -z "$pyc" ] && ok "no __pycache__ or .pyc under bin/ or scripts/" \
  || bad "bytecode in the product" "$pyc"

head_ "35. a pointer repair cannot undo a swap"
# active_name() heals the pointer after a /login: the profile names a, the pointer
# still says b. A heal decided outside the store lock can land AFTER a swap that
# finished meanwhile — the pointer goes back to the account the swap just left,
# and the next swap's backup files the live credential, b's, under a (#73).
# Process 1 has read the identity and stops before its repair; process 2 swaps
# a → b; process 1 resumes. Two processes, because the lock is reentrant in one.
PH="$FAKE/ptr-race"
rm -rf "$PH"; mkdir -p "$PH/.claude/ccd/accounts"
python3 - "$PH" <<'PY'
import json, os, sys, time
h = sys.argv[1]
d = os.path.join(h, ".claude", "ccd", "accounts")
ms = int(time.time() * 1000)
def put(p, text):
    with open(p, "w") as f:
        f.write(text)
    os.chmod(p, 0o600)
def oauth(tag):
    return {"accessToken": "AT-" + tag, "refreshToken": "RT-" + tag,
            "expiresAt": ms + 3600000, "subscriptionType": "max"}
for i, n in enumerate(("a", "b")):
    put(os.path.join(d, n + ".json"), json.dumps({
        "name": n, "account_uuid": "uuid-" + n, "priority": i + 1, "storage": "file",
        "claudeAiOauth": oauth(n + "-stored"), "added_at": ms // 1000}))
# ccd installed b a minute ago; the user signed in as a with /login since.
put(os.path.join(d, ".active"), "b\n")
put(os.path.join(d, ".active-at"), f"{ms - 60000}\n")
put(os.path.join(h, ".claude", ".credentials.json"),
    json.dumps({"claudeAiOauth": oauth("a-live")}))
put(os.path.join(h, ".claude.json"), json.dumps({"oauthAccount": {
    "accountUuid": "uuid-a", "emailAddress": "a@example.com",
    "profileFetchedAt": ms - 30000}}))
PY
cat > "$PH/.p1.py" <<'PY'
import importlib.machinery, importlib.util, os, sys, time
loader = importlib.machinery.SourceFileLoader("ccdptr", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
home, real, paused = os.environ["HOME"], m._active_at, []
def held():
    # The profile has been read and judged newer than ccd's last install: the
    # heal is decided. Hold here while another process swaps.
    t = real()
    if not paused:
        paused.append(1)
        open(os.path.join(home, ".paused"), "w").close()
        end = time.time() + 30
        while not os.path.exists(os.path.join(home, ".go")) and time.time() < end:
            time.sleep(0.05)
    return t
m._active_at = held
print(m.active_name())
PY
PYTHONDONTWRITEBYTECODE=1 HOME="$PH" CCD_CREDENTIALS_BACKEND=file \
  python3 "$PH/.p1.py" "$ROOT/bin/ccd-account" > "$PH/.p1-out" 2>&1 & P1=$!
n=0; while [ ! -e "$PH/.paused" ] && kill -0 "$P1" 2>/dev/null && [ $n -lt 100 ]; do
  sleep 0.1; n=$((n+1)); done
HOME="$PH" CCD_CREDENTIALS_BACKEND=file "$ROOT/bin/ccd-account" --no-color use b --force \
  >/dev/null 2>&1; p2=$?
: > "$PH/.go"; wait "$P1" 2>/dev/null
{ [ -e "$PH/.paused" ] && [ "$p2" -eq 0 ] && grep -q 'AT-b-stored' "$PH/.claude/.credentials.json"; } \
  || bad "race not staged" "paused=$([ -e "$PH/.paused" ] && echo yes || echo no) swap rc=$p2 p1: $(head -c 160 "$PH/.p1-out")"
[ "$(cat "$PH/.claude/ccd/accounts/.active" 2>/dev/null)" = "b" ] \
  && ok "a pointer repair decided before a swap cannot undo it" \
  || bad "pointer repair undid a swap" "the pointer says $(cat "$PH/.claude/ccd/accounts/.active" 2>/dev/null) with b's credential live"
HOME="$PH" CCD_CREDENTIALS_BACKEND=file "$ROOT/bin/ccd-account" --no-color use a --force >/dev/null 2>&1
grep -q 'RT-b-' "$PH/.claude/ccd/accounts/a.json" \
  && bad "tokens filed under the wrong account" "the next swap banked b's credential into a.json" \
  || ok "...and the next swap does not bank b's credential under a"
rm -rf "$PH"

head_ "36. the keychain write keeps the credential off the command line"
# `security add-generic-password -w <blob>` put both tokens in argv, readable by any
# process on the machine for as long as it ran (#78). `security -i` reads the same
# command from stdin, which is how Claude Code writes this item itself. The fake
# stands where the others do, at subprocess.run, and reads a command the way the
# real tool does (Apple's SecurityTool/macOS: readline.c, security.c,
# keychain_add.c), so a line that would break there breaks here too.
cat > "$FAKE/kcw-fake.py" <<'PYEOF'
import importlib.machinery, importlib.util, json, os, sys, types
os.environ["HOME"] = sys.argv[2]
os.environ.pop("CCD_CREDENTIALS_BACKEND", None)
os.environ["USER"] = "ccd-test"
loader = importlib.machinery.SourceFileLoader("ccdkcw", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.use_keychain = lambda: True
SVC, ME = m.KEYCHAIN_SERVICE, "ccd-test"
OLD = b'{"claudeAiOauth": {"accessToken": "AT-old"}}'
ITEMS = {(SVC, ME): OLD}   # the login this write replaces
CALLS = []                 # (argv, stdin) of every exec
REFUSE = []                # a status staged here refuses the next add
BLOB = {"claudeAiOauth": {"accessToken": "AT-kcw-secret", "refreshToken": "RT-kcw-secret"},
        "mcpOAuth": {"notion|x": {"accessToken": "MCP-kcw-secret",
                                  "note": 'a "quoted" \\ \u00fcn\u00ef value'}}}
class Unstaged(BaseException):
    pass
class Ran:
    def __init__(self, rc, err):
        self.returncode, self.stdout, self.stderr = rc, "", err
def lines(text):
    # readline(buffer, 4096): a line ends at a newline or after 4095 bytes, the rest
    # is read as the next line, and a last line with no newline is never run.
    out, cur = [], b""
    for b in text.encode():
        if len(cur) == 4095:
            out.append(cur); cur = b""
        if b == 10:
            out.append(cur); cur = b""
        else:
            cur += bytes([b])
    if len(cur) == 4095:
        out.append(cur)
    return [l.decode("utf-8", "replace") for l in out]
def split_line(s):
    # Words split on whitespace; one that opens with " or ' runs to the same quote;
    # a backslash takes the next character as it is, inside quotes or not.
    words, cur, state, q = [], "", "ws", ""
    for ch in s:
        if state == "ws":
            if ch.isspace():
                continue
            cur, state = "", "w"
            if ch in "\"'":
                q, state = ch, "q"
                continue
        if state.endswith("\\"):
            cur, state = cur + ch, state[0]
        elif ch == "\\":
            state += "\\"
        elif ch.isspace() if state == "w" else ch == q:
            words.append(cur); state = "ws"
        else:
            cur += ch
    if state != "ws":
        words.append(cur)
    return words
def add(args, err):
    # getopt stops at the first word that is not an option; a word left over is a
    # keychain name to the real tool, and ccd never names one.
    o, i = {}, 0
    while i < len(args) and args[i].startswith("-"):
        if args[i] == "-U":
            o["U"], i = True, i + 1
        elif args[i][1:] in ("a", "s", "w", "X") and i + 1 < len(args):
            o[args[i][1:]], i = args[i + 1], i + 2
        else:
            break
    if i < len(args):
        err.append("Usage: add-generic-password ...")
        return 2
    try:
        data = bytes.fromhex(o["X"]) if "X" in o else o.get("w", "").encode()
    except ValueError:
        err.append("security: Unable to convert password data (-X must specify valid hex digits)")
        return 2
    if REFUSE:
        status = REFUSE.pop(0)
        err.append("security: SecKeychainItemCreateFromContent (<default>): %d" % status)
        return status
    key = (o.get("s"), o.get("a"))
    if key in ITEMS and "U" not in o:
        err.append("security: The specified item already exists in the keychain.")
        return -25299
    ITEMS[key] = data
    return 0
def execute(words, err):
    if not words:
        return 0
    if words[0] != "add-generic-password":
        err.append('security: unknown command "%s"' % words[0])
        return 1
    return add(words[1:], err)
def fake_run(argv, *a, input=None, **k):
    argv = list(argv)
    CALLS.append((argv, input))
    if argv[:1] != ["security"]:
        raise Unstaged("unstaged external call: " + " ".join(argv[:2]))
    err = []
    if argv[1:] == ["-i"]:
        # The exit status is the LAST line's, cut to one byte; every line that
        # failed says so on stderr, whole.
        rc = 0
        for line in lines(input or ""):
            words = split_line(line)
            rc = execute(words, err)
            if rc:
                err.append("%s: returned %d" % (words[0], rc))
    else:
        rc = execute(argv[1:], err)
    return Ran(rc & 0xFF, "".join(e + "\n" for e in err))
m.subprocess = types.SimpleNamespace(run=fake_run)
PYEOF
kcw() { # $1=the case -> the assertion it failed, if any
  rm -rf "$FAKE/kcw"; mkdir -p "$FAKE/kcw/.claude"
  python3 -c "$(cat "$FAKE/kcw-fake.py")$1" "$ROOT/bin/ccd-account" "$FAKE/kcw" 2>&1 | tail -1
}

out=$(kcw '
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert ok and written == ["keychain"], f"the write did not land: failed={failed}"
seen = " ".join(" ".join(argv) for argv, _ in CALLS)
for s in ("AT-kcw-secret", "RT-kcw-secret", "MCP-kcw-secret"):
    for form in (s, s.encode().hex()):
        assert form not in seen, f"{s} is on the command line: {seen[:100]}"
') && ok "no token from the credential reaches argv, as itself or as hex" \
  || bad "the credential is on the command line" "$out"

out=$(kcw '
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert any(stdin for _, stdin in CALLS), f"nothing came in on stdin: {[a[:2] for a, _ in CALLS]}"
got = json.loads(ITEMS[(SVC, ME)].decode("utf-8"))
assert got == BLOB, f"the item holds something else: {got!r}"
') && ok "the write goes in on stdin, and the item decodes to exactly the blob written" \
  || bad "the stdin write" "$out"

out=$(kcw '
REFUSE.append(-25308)      # errSecInteractionNotAllowed: a locked keychain
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert not ok and failed == ["keychain"] and written == [], f"reported {ok, failed, written}"
') && ok "a keychain that refuses the write inside security -i is a failed write" \
  || bad "refused write" "$out"

# The exit status carries the status modulo 256, and -67072 (errSecCSUnimplemented)
# is a multiple of it: a refusal that exits 0. Only the "returned" line says so.
out=$(kcw '
REFUSE.append(-67072)
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert not ok and failed == ["keychain"] and written == [], f"reported {ok, failed, written}"
') && ok "...even when the refusal's status comes out as exit 0" \
  || bad "a refusal that exits 0" "$out"

# Past what one interactive line holds, argv is the only way left, as it is for
# Claude Code. An mcpOAuth with enough servers is all it takes.
out=$(kcw '
BLOB["mcpOAuth"] = {"s%d" % i: {"accessToken": "x" * 40} for i in range(50)}
ok, failed, written = m.live_write(BLOB, ["keychain"])
assert ok, f"the write failed: {failed}"
assert [a[1] for a, _ in CALLS] == ["add-generic-password"], f"calls: {[a[:2] for a, _ in CALLS]}"
got = json.loads(ITEMS[(SVC, ME)].decode("utf-8"))
assert got == BLOB, "the item holds something else"
') && ok "a credential too long for one line falls back to argv, and still lands whole" \
  || bad "oversized write" "$out"

# A quote, backslash or newline in the account would change the -a word or cut the
# command short, writing another account's item or one with no password.
out=$(kcw '
for name in ("ccd\"test", "ccd\\test", "ccd\ntest"):
    os.environ["USER"] = name
    ok, failed, written = m.live_write(BLOB, ["keychain"])
    assert not ok and failed == ["keychain"], f"reported {ok, failed} for {name!r}"
assert CALLS == [] and ITEMS == {(SVC, ME): OLD}, f"security ran: {[a[:2] for a, _ in CALLS]}"
') && ok "an account name the line cannot carry is refused before security runs" \
  || bad "unsafe account name" "$out"
rm -rf "$FAKE/kcw" "$FAKE/kcw-fake.py"
unset -f kcw

head_ "37. a swap waits for Claude Code's own credential locks"
# Claude Code refreshes a token under locks of its own — directories, in this
# order: <cfg>/.oauth_refresh.lock, <realpath(cfg)>.lock, and <cfg>/.storage-write.lock
# around the save — and the save is a compare-and-swap: if the stored refresh token
# is no longer the one it spent, it writes nothing. A swap that banks the outgoing
# credential mid-refresh banks the token the server has just retired, installs the
# next account, and Claude Code then throws the rotated one away: the account comes
# back needing /login (#67). Every case has a HOME of its own, where a is signed in
# (by the pointer) and b is a spare with a fresh reading.
cl_home() { # $1=case -> its HOME
  local h="$FAKE/cl-$1"
  rm -rf "$h"; mkdir -p "$h/.claude/ccd/accounts" "$h/.claude/ccd/readings"
  python3 - "$h" <<'PY'
import json, os, sys, time
h = sys.argv[1]
cfg = os.path.join(h, ".claude")
ms = int(time.time() * 1000)
def put(p, obj):
    with open(p, "w") as f:
        f.write(obj if isinstance(obj, str) else json.dumps(obj))
    os.chmod(p, 0o600)
def oauth(tag):
    return {"accessToken": "AT-" + tag, "refreshToken": "RT-" + tag,
            "expiresAt": ms + 3600000, "subscriptionType": "max"}
for i, n in enumerate(("a", "b")):
    put(os.path.join(cfg, "ccd", "accounts", n + ".json"), {
        "name": n, "account_uuid": "uuid-" + n, "priority": i + 1, "storage": "file",
        "claudeAiOauth": oauth(n + "-stored"), "added_at": ms // 1000})
put(os.path.join(cfg, "ccd", "accounts", ".active"), "a\n")
put(os.path.join(cfg, "ccd", "accounts", ".active-at"), f"{ms}\n")
put(os.path.join(cfg, ".credentials.json"), {"claudeAiOauth": oauth("a-live")})
put(os.path.join(cfg, "ccd", "readings", "b.json"), {
    "status": "ok", "checked_at": ms // 1000, "uuid": "uuid-b",
    "five_hour_percent": 10, "seven_day_percent": 10})
PY
  printf '%s' "$h"
}
# Its three locks, placed as a stand-in would leave them: $2..$4 are the ages in
# seconds of refresh, legacy and write ("-" for none; negative is the future).
cl_locks() { # $1=HOME $2 $3 $4
  python3 - "$@" <<'PY'
import os, sys, time
cfg = os.path.join(sys.argv[1], ".claude")
paths = (os.path.join(cfg, ".oauth_refresh.lock"), os.path.realpath(cfg) + ".lock",
         os.path.join(cfg, ".storage-write.lock"))
now = time.time()
for p, age in zip(paths, sys.argv[2:]):
    if age != "-":
        os.mkdir(p)
        os.utime(p, (now - float(age), now - float(age)))
PY
}
# ccd-account with a HOME and a hard limit: prints "<exit code|timeout> <seconds>",
# and leaves its stderr in $HOME/.err.
cl_run() { # $1=HOME $2=seconds allowed, then the arguments
  python3 - "$ROOT/bin/ccd-account" "$@" <<'PY'
import os, subprocess, sys, time
acct, home, limit, args = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4:]
t = time.time()
with open(os.path.join(home, ".err"), "w") as err:
    try:
        rc = subprocess.run([acct, "--no-color"] + args, env=dict(os.environ, HOME=home),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=err, timeout=limit).returncode
    except subprocess.TimeoutExpired:
        rc = "timeout"
print(rc, round(time.time() - t, 1))
PY
}
# Assertions about a HOME's end state -> the one that failed, if any.
cl_py() { # $1=HOME $2=python; RC and SECS are cl_run's answer
  RC="${rc:-}" SECS="${secs:-0}" python3 -c '
import json, os, sys, time
H = sys.argv[1]
RC, SECS = os.environ["RC"], float(os.environ["SECS"])
cfg = os.path.join(H, ".claude")
REFRESH, LEGACY = os.path.join(cfg, ".oauth_refresh.lock"), os.path.realpath(cfg) + ".lock"
WRITE = os.path.join(cfg, ".storage-write.lock")
def rt(n):
    return json.load(open(os.path.join(cfg, "ccd", "accounts", n + ".json")))["claudeAiOauth"]["refreshToken"]
def live():
    return json.load(open(os.path.join(cfg, ".credentials.json")))["claudeAiOauth"]["accessToken"]
def err():
    return open(os.path.join(H, ".err")).read().replace("\n", " ")
def untouched():
    assert live() == "AT-a-live", f"the live store moved to {live()}"
    a = rt("a")
    assert a == "RT-a-stored", f"a was banked: {a}"
    assert not os.path.exists(os.path.join(cfg, "ccd", "store-split")), "a stop was recorded"
def age(p):
    return time.time() - os.lstat(p).st_mtime
'"$2" "$1" 2>&1 | tail -1
}
# In-process, for what only a spy can see: every mkdir of a lock, in order, with
# the locks that already existed at that moment.
CL_PRE='
import importlib.machinery, importlib.util, json, os, sys, threading, time
H = os.environ["HOME"] = sys.argv[2]
loader = importlib.machinery.SourceFileLoader("ccdcl", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(m)
def canon(p):              # one spelling per place: the legacy lock is named by a realpath
    return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))
def cc_locks(cfg):
    return [canon(os.path.join(cfg, ".oauth_refresh.lock")), canon(os.path.realpath(cfg) + ".lock"),
            canon(os.path.join(cfg, ".storage-write.lock"))]
DEFAULT = cc_locks(os.path.join(H, ".claude"))
TOOK, TRIED = [], []
real_mkdir = os.mkdir
def spy(p, *a, **k):
    c = canon(os.fspath(p))
    lock = c.endswith(".lock")
    if lock:
        TRIED.append((c, [q for q in DEFAULT if os.path.isdir(q)]))
    real_mkdir(p, *a, **k)
    if lock:
        TOOK.append(c)
os.mkdir = spy
def live():
    return json.load(open(m.credentials_file()))["claudeAiOauth"]["accessToken"]
'

# The regression. A stand-in Claude Code is mid-refresh of a: it holds the refresh
# locks, and when its request answers it saves a′ under the write lock — only if the
# store still holds the token it spent, as Claude Code does. `use b` arrives while it
# waits on the server.
H=$(cl_home race)
cat > "$H/.standin.py" <<'PY'
import json, os, sys, time
h = sys.argv[1]
cfg = os.path.join(h, ".claude")
refresh, legacy = os.path.join(cfg, ".oauth_refresh.lock"), os.path.realpath(cfg) + ".lock"
write, creds = os.path.join(cfg, ".storage-write.lock"), os.path.join(cfg, ".credentials.json")
os.mkdir(refresh); os.mkdir(legacy)
open(os.path.join(h, ".cc-holds"), "w").close()
time.sleep(1.5)                                  # the server rotates a's refresh token
end = time.time() + 10
while True:
    try:
        os.mkdir(write); break
    except FileExistsError:
        if time.time() > end:
            sys.exit("the write lock never came free")
        time.sleep(0.05)
blob = json.load(open(creds))
if blob["claudeAiOauth"]["refreshToken"] == "RT-a-live":
    blob["claudeAiOauth"] = {"accessToken": "AT-a-rotated", "refreshToken": "RT-a-rotated",
                             "expiresAt": int(time.time() * 1000) + 3600000}
    with open(creds + ".tmp", "w") as f:
        json.dump(blob, f)
    os.replace(creds + ".tmp", creds)
    print("saved")
else:
    print("adopted")                             # somebody else's login is there: keep it
os.rmdir(write); os.rmdir(legacy); os.rmdir(refresh)
PY
python3 "$H/.standin.py" "$H" > "$H/.cc-out" 2>&1 & CC=$!
n=0; while [ ! -e "$H/.cc-holds" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
read -r rc secs <<< "$(cl_run "$H" 15 use b --force)"
wait "$CC" 2>/dev/null
out=$(cl_py "$H" '
assert live() == "AT-b-stored", f"the swap did not happen: {err()[:160]}"
a = rt("a")
assert a == "RT-a-rotated", f"a was banked as {a}; the rotated token was thrown away"
left = [p for p in (REFRESH, LEGACY, WRITE) if os.path.lexists(p)]
assert not left, f"left behind: {left}"
') && ok "a refresh in flight finishes first, and the swap banks the token it produced" \
  || bad "banked a spent token" "$out (stand-in: $(cat "$H/.cc-out"))"

# The order is Claude Code's, and nothing is held while the refresh lock is awaited:
# a write lock held there would make Claude Code's own save fail, and lose a′.
H=$(cl_home order)
out=$(python3 -c "$CL_PRE"'
R, L, W = DEFAULT
real_mkdir(R)                                    # Claude Code is mid-refresh
def done():
    time.sleep(0.5)
    os.rmdir(R)
threading.Thread(target=done).start()
m.swap_to("b", force=True)
assert live() == "AT-b-stored", "the swap did not happen"
names = {R: "refresh", L: "legacy", W: "write"}
assert [names.get(c, c) for c in TOOK] == ["refresh", "legacy", "write"], \
    f"took {[names.get(c, c) for c in TOOK]}"
waits = [held for c, held in TRIED if c == R]
assert len(waits) > 1, f"never waited on the refresh lock: {TRIED}"
assert not [h for h in waits if L in h or W in h], "held a lock while waiting on the refresh lock"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "the locks are taken in Claude Code's order, none held while the refresh lock is awaited" \
  || bad "lock order" "$out"

# A lock is abandoned once older than its window: 60s for the refresh pair, 15s for
# the write lock. One taken over is released like any other.
H=$(cl_home stale)
cl_locks "$H" 90 90 20
read -r rc secs <<< "$(cl_run "$H" 15 use b --force)"
out=$(cl_py "$H" '
assert live() == "AT-b-stored", f"the swap did not happen: {err()[:160]}"
left = [p for p in (REFRESH, LEGACY, WRITE) if os.path.lexists(p)]
assert not left, f"left behind: {left}"
') && ok "stale locks are taken over, by each one's own window, and the swap proceeds" \
  || bad "stale locks" "$out"

# Held past the caller's deadline: nothing is written and the attempt fails, in time
# for the hook's retry. A 20s-old refresh lock is fresh by its own 60s window.
H=$(cl_home held)
cl_locks "$H" 20 - -
read -r rc secs <<< "$(cl_run "$H" 10 swap --from a --window x --no-probe --deadline 1)"
out=$(cl_py "$H" '
assert RC == "4", f"exit {RC} after {SECS}s: {err()[:160]}"
assert SECS <= 4, f"took {SECS}s on a 1s deadline"
untouched()
assert os.path.isdir(REFRESH) and age(REFRESH) > 15, "the held lock was removed or touched"
assert not os.path.lexists(LEGACY) and not os.path.lexists(WRITE), "a lock was left behind"
assert ".oauth_refresh.lock" in err(), f"the reason names no lock: {err()[:160]}"
') && ok "a lock held past the deadline fails the attempt in time, having written nothing" \
  || bad "deadline" "$out"

# A failure after the locks were taken still releases every one of them, and the
# write it failed was made under all three.
H=$(cl_home fail)
out=$(python3 -c "$CL_PRE"'
under = []
real_write = m.write_json
def failing(p, obj, mode=0o600):
    if str(p) == m.credentials_file():
        under.append([os.path.isdir(q) for q in DEFAULT])
        raise OSError("disk full")
    return real_write(p, obj, mode)
m.write_json = failing
try:
    m.swap_to("b", force=True)
    raise AssertionError("a failed write reported success")
except SystemExit:
    pass
assert under == [[True, True, True]], f"the write was made under {under}"
left = [q for q in DEFAULT if os.path.lexists(q)]
assert not left, f"left behind: {left}"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "the live store is written under all three, and they are released when it fails" \
  || bad "locks after a failure" "$out"

# Claude Code's own lock bugs are not ccd's to repair. A lock dated in the future
# never goes stale for Claude Code (anthropics/claude-code#95739), so it is held
# here too; a lock left as a FILE (#95425) is nobody's lock, and the swap refuses at
# once rather than wait out a lock that cannot be taken. Neither is deleted.
H=$(cl_home future)
cl_locks "$H" -3600 - -
read -r rc secs <<< "$(cl_run "$H" 10 swap --from a --window x --no-probe --deadline 1)"
out=$(cl_py "$H" '
assert RC == "4", f"exit {RC} after {SECS}s: {err()[:160]}"
untouched()
assert os.path.isdir(REFRESH) and age(REFRESH) < -3000, "the future-dated lock was removed or touched"
assert ".oauth_refresh.lock" in err() and "future" in err(), f"the reason: {err()[:200]}"
') && ok "a lock dated in the future is held, not deleted, and the reason says so" \
  || bad "future-dated lock" "$out"

H=$(cl_home file)
printf 'not a lock' > "$H/.claude/.storage-write.lock"
read -r rc secs <<< "$(cl_run "$H" 15 use b --force)"
out=$(cl_py "$H" '
assert RC not in ("0", "timeout"), f"exit {RC}"
assert SECS < 4, f"waited {SECS}s on a lock that can never be taken"
untouched()
assert open(WRITE).read() == "not a lock", "the file was changed or removed"
assert not os.path.lexists(REFRESH) and not os.path.lexists(LEGACY), "a lock was left behind"
assert ".storage-write.lock" in err(), f"the reason names no path: {err()[:160]}"
') && ok "a lock left as a file refuses the swap at once, naming it, and stays as it was" \
  || bad "lock left as a file" "$out"

# The locks live where Claude Code keeps its credentials:
# CLAUDE_SECURESTORAGE_CONFIG_DIR, then CLAUDE_CONFIG_DIR, then ~/.claude — and the
# legacy one is named after the realpath. A directory that does not exist holds no
# store to guard, and ccd does not create it.
H=$(cl_home dirs)
mkdir -p "$H/real" "$H/sec"; ln -s "$H/real" "$H/link"
out=$(python3 -c "$CL_PRE"'
def case(env, want):
    for k in ("CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"):
        os.environ.pop(k, None)
    os.environ.update(env)
    with open(m.credentials_file(), "w") as f:
        json.dump({"claudeAiOauth": {"accessToken": "AT-a-live", "refreshToken": "RT-a-live"}}, f)
    with open(os.path.join(m.ACCOUNTS_DIR, ".active"), "w") as f:
        f.write("a\n")
    del TOOK[:]
    m.swap_to("b", force=True)
    assert live() == "AT-b-stored", f"{env}: the swap did not happen"
    if want is not None:
        assert TOOK == want, f"{env}: took {TOOK}, not {want}"
    left = [q for q in set(TOOK) | set(want or []) if os.path.lexists(q)]
    assert not left, f"{env}: left behind {left}"
case({"CLAUDE_CONFIG_DIR": H + "/link"}, cc_locks(H + "/link"))
assert canon(os.path.realpath(H + "/link") + ".lock") in TOOK, "the legacy lock ignored the realpath"
case({"CLAUDE_CONFIG_DIR": H + "/real", "CLAUDE_SECURESTORAGE_CONFIG_DIR": H + "/sec"}, cc_locks(H + "/sec"))
case({"CLAUDE_CONFIG_DIR": H + "/real", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""}, DEFAULT)
case({"CLAUDE_CONFIG_DIR": H + "/real", "CLAUDE_SECURESTORAGE_CONFIG_DIR": H + "/nowhere"}, None)
assert not os.path.lexists(H + "/nowhere"), "created a config directory"
' "$ROOT/bin/ccd-account" "$H" 2>&1 | tail -1) \
  && ok "the locks follow CLAUDE_SECURESTORAGE_CONFIG_DIR, then CLAUDE_CONFIG_DIR, as Claude Code's do" \
  || bad "lock location" "$out"
rm -rf "$FAKE"/cl-*
unset -f cl_home cl_locks cl_run cl_py

# ── setup reports what it verified, not what it attempted ───────────────────
head_ "38. setup reports what it verified, not what it attempted"
# One habit, two halves.
#
# The shim: mkdir, the heredoc and chmod were all unchecked, so a read-only
# ~/.claude/ccd — or a chmod that did not take — ended with "✓ OpenRouter handoff
# installed" printed over an empty directory. Nothing then shadows `claude`,
# exec_claude has no launcher, and a `ccd -c` session never returns from OpenRouter
# by itself: the meter keeps running on the user's own key (#29).
#
# The PATH line: "already in" was answered by OUR marker comment rather than by the
# export that does the work. A marker whose line had been deleted read as success,
# and a line the user wrote themselves got a second copy under --yes (#51). The
# marker exists so REMOVAL never touches a line we did not write; presence is a
# different question, and this call site was asking the wrong one.
#
# Every case seeds its own HOME and its own rc file. These assertions are about what
# ONE run leaves on disk, and an inherited fixture would answer for it.

# A foreign `claude` ahead of everything, so shim_leads_path() is decidedly false and
# the PATH branch is the branch under test wherever this suite runs.
S38_BIN=$(mktemp -d "$FAKE/s38bin.XXXXXX")
printf '#!/bin/sh\nexit 0\n' > "$S38_BIN/claude"; chmod +x "$S38_BIN/claude"
S38_PATH="$S38_BIN:$PATH"
S38_EXPORT='export PATH="$HOME/.claude/ccd/bin:$PATH"'
S38_MARKER='# ccd-auto-handoff-path v1 (managed by: ccd setup --auto)'
s38_home() {   # a fresh HOME whose .zshrc is the user's own; prints its path
  local h; h=$(mktemp -d "$FAKE/s38.XXXXXX")
  mkdir -p "$h/.claude"
  printf '# my own file\n' > "$h/.zshrc"
  printf '%s' "$h"
}
s38_setup() {  # `setup --auto --yes` in HOME=$1 → S38_OUT, S38_ST
  S38_OUT=$(HOME="$1" SHELL=/bin/zsh PATH="${2:-$S38_PATH}" \
              "$ROOT/bin/ccd" setup --auto --yes 2>&1); S38_ST=$?
}
s38_claimed() { case "$S38_OUT" in *"OpenRouter handoff installed"*) return 0 ;; esac; return 1; }
s38_brief()   { printf '%s' "$S38_OUT" | tr '\n' ' ' | head -c 140; }

# (a) A file where the shim's directory goes: mkdir cannot make it, so nothing is
# written and there is nothing to report.
h=$(s38_home); mkdir -p "$h/.claude/ccd"; : > "$h/.claude/ccd/bin"
s38_setup "$h"
s38_claimed \
  && bad "shim dir" "claimed an install with a file where the shim directory goes" \
  || ok "a shim directory that cannot be created is not reported as an install"
[ "$S38_ST" -ne 0 ] \
  && ok "...and setup exits non-zero (got $S38_ST)" \
  || bad "shim dir" "exited 0 with no launcher on disk"
case "$S38_OUT" in
  *"ccd setup --auto"*) ok "...and names the command to re-run once it is fixed" ;;
  *) bad "shim dir" "no remedy: $(s38_brief)" ;;
esac

# (b) The directory is there but refuses the write. Only meaningful as a non-root
# user — root writes through a read-only directory.
if [ "$(id -u)" -ne 0 ]; then
  h=$(s38_home); mkdir -p "$h/.claude/ccd/bin"; chmod 500 "$h/.claude/ccd/bin"
  s38_setup "$h"
  chmod 700 "$h/.claude/ccd/bin"
  [ ! -e "$h/.claude/ccd/bin/claude" ] \
    && ok "an unwritable shim directory really does leave no launcher" \
    || bad "shim write" "the fixture wrote one anyway — this case proves nothing"
  s38_claimed \
    && bad "shim write" "claimed an install the write never made: $(s38_brief)" \
    || ok "...and setup does not claim it installed one"
  [ "$S38_ST" -ne 0 ] \
    && ok "...and exits non-zero (got $S38_ST)" \
    || bad "shim write" "exited 0 after a failed shim write"
fi

# (c) The bytes land but the executable bit does not. A shim the shell will not run
# is not a launcher, however right its contents are.
h=$(s38_home)
S38_NOP=$(mktemp -d "$FAKE/s38nop.XXXXXX")
printf '#!/bin/sh\nexit 0\n' > "$S38_NOP/chmod"; chmod +x "$S38_NOP/chmod"
s38_setup "$h" "$S38_NOP:$S38_PATH"
{ [ -f "$h/.claude/ccd/bin/claude" ] && [ ! -x "$h/.claude/ccd/bin/claude" ]; } \
  && ok "a chmod that does not take really does leave the shim non-executable" \
  || bad "shim chmod" "the fixture did not produce a non-executable shim"
s38_claimed \
  && bad "shim chmod" "called a non-executable file an installed launcher: $(s38_brief)" \
  || ok "...and setup does not call it an installed launcher"
[ "$S38_ST" -ne 0 ] \
  && ok "...and exits non-zero (got $S38_ST)" \
  || bad "shim chmod" "exited 0 with a launcher the shell cannot run"

# (d) The marker outliving the line it marks. Someone tidying their dotfiles keeps
# the comment and deletes the export under it; the wiring is gone, and only the
# export can say so.
h=$(s38_home)
printf '# my own file\n%s\n' "$S38_MARKER" > "$h/.zshrc"
s38_setup "$h"
grep -qxF "$S38_EXPORT" "$h/.zshrc" \
  && ok "a marker whose export was deleted gets the export put back" \
  || bad "orphan marker" "left the rc file with our marker and no line that does the work"
case "$S38_OUT" in
  *"already in"*) bad "orphan marker" "reported a PATH line that was not there: $(s38_brief)" ;;
  *) ok "...instead of reporting a line that was not there" ;;
esac
[ "$S38_ST" -eq 0 ] \
  && ok "...and the repaired run reports success" \
  || bad "orphan marker" "exited $S38_ST: $(s38_brief)"

# (e) The other direction: the export is already there, written by the user, so it
# carries no marker of ours. --yes must not take that as permission to add a second.
h=$(s38_home)
printf '# my own file\n%s\n' "$S38_EXPORT" > "$h/.zshrc"
s38_setup "$h"; s38_setup "$h"
n=$(grep -cxF "$S38_EXPORT" "$h/.zshrc")
[ "$n" = "1" ] \
  && ok "--yes twice over a line the user wrote adds no second copy" \
  || bad "duplicate export" "the export now appears $n times"
grep -q 'ccd-auto-handoff-path' "$h/.zshrc" \
  && bad "duplicate export" "claimed their line by marking it as ours" \
  || ok "...and their line is still theirs, unmarked"
[ "$S38_ST" -eq 0 ] \
  && ok "...and neither run is reported as a failed install" \
  || bad "duplicate export" "exited $S38_ST although the wiring was done"

# (f) And the install that works still says so — the point is not to report failure,
# it is to report what is on disk.
h=$(s38_home)
s38_setup "$h"
{ [ "$S38_ST" -eq 0 ] && [ -x "$h/.claude/ccd/bin/claude" ]; } \
  && ok "a complete install exits 0 with an executable launcher on disk" \
  || bad "happy path" "exited $S38_ST with shim=$([ -x "$h/.claude/ccd/bin/claude" ] && echo x || echo none)"
s38_claimed \
  && ok "...and reports the launcher it verified" \
  || bad "happy path" "installed it and said nothing: $(s38_brief)"
grep -qxF "$S38_EXPORT" "$h/.zshrc" \
  && ok "...and the export it wrote is in the rc file" \
  || bad "happy path" "reported success with no export in the rc file"
s38_setup "$h"
n=$(grep -cxF "$S38_EXPORT" "$h/.zshrc")
{ [ "$S38_ST" -eq 0 ] && [ "$n" = "1" ]; } \
  && ok "...and a second --yes run neither fails nor writes the line twice" \
  || bad "happy path" "exited $S38_ST with $n copies of the export"

rm -rf "$FAKE"/s38.* "$FAKE"/s38bin.* "$FAKE"/s38nop.*
unset -f s38_home s38_setup s38_claimed s38_brief

head_ "39. the return from OpenRouter waits for every window"
# v0.8.0 gave "spent" one meaning — bin/spent-at, on every window a reading
# reports — for moving a session, for choosing where to move it and for deciding
# to pay. The automatic return from the paid backbone was left behind on the old
# per-window rule: one window that had turned over was enough. So a 5-hour reset
# while the weekly window is still at 100% bought a relaunch out and a relaunch
# back to arrive at the same wall within minutes, and with a short
# HOP_RESET_SECONDS the launcher's `visited` guard can strand the session there.
S39D="$FAKE/.claude/ccd"
S39_HF="$S39D/handoff-00000000000000000000000000000002.json"
S39_FUT=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=2)).isoformat())")
S39_PAST=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=3)).isoformat())")
# Every case seeds the whole world it is decided on. Nothing is registered, so the
# escape-to-a-spare arm above this one never runs and what is armed here can only
# have come from the recovery arm; and no refresh may replace the reading the case
# is about, so the dashboard is gone and the probe is already backing off.
s39_fixture() { # $1=reading  $2=run-state  [$3=seconds to age the reading by]
  rm -rf "$S39D/accounts" "$S39D/readings" "$S39_HF" \
         "$FAKE/.claude/plugins/cache/claude-dashboard"
  mkdir -p "$S39D"
  printf '%s\n' "$1" > "$S39D/quota-cache.json"
  printf '%s\n' "$2" > "$S39D/run-state.json"
  : > "$S39D/.usage-probe-backoff"
  [ -n "${3:-}" ] && python3 -c '
import os, sys, time
t = time.time() - int(sys.argv[2])
os.utime(sys.argv[1], (t, t))' "$S39D/quota-cache.json" "$3"
  return 0
}
# A supervised session on the paid backbone, one prompt tick. The stand-in is what
# a return would end, so whether it is still alive is the relaunch pair itself. It
# is started outside s39_run because a case that reads the hook's stdout runs that
# in a subshell, and a pid recorded there would not survive it.
s39_start() { "$FAKE/sigbin/claude" 8 2>/dev/null & S39_PID=$!; sleep 0.3; }
s39_run() { # $1=session id ; stdout is the hook's own
  printf '{"session_id":"%s","cwd":"/tmp/w","hook_event_name":"UserPromptSubmit"}' "$1" \
    | CCD_ACTIVE=1 ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_AUTH_TOKEN=x \
      CCD_HANDOFF=00000000000000000000000000000002 CCD_HANDOFF_STATE="$S39_HF" \
      CLAUDE_PID=$S39_PID CCD_STANDIN_PID=$S39_PID \
      "$ROOT/scripts/quota-guard.sh" UserPromptSubmit 2>/dev/null
  sleep 0.3
}
s39_done() { kill -9 "$S39_PID" 2>/dev/null; wait "$S39_PID" 2>/dev/null; }
set +m 2>/dev/null

# (a) The bug. The 5-hour window has reset and the weekly one is still spent, so
# the subscription cannot take this session: returning to it lands back here.
s39_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S39_FUT\",\"sevenDayPercent\":100,\"sevenDayReset\":\"$S39_FUT\"}}" \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"recovery_notified_window\":\"five_hour\",\"recovery_notified_reset\":\"$S39_FUT\",\"last_five_hour_percent\":100,\"last_five_hour_reset\":\"$S39_FUT\",\"last_seven_day_percent\":100,\"last_seven_day_reset\":\"$S39_FUT\"}"
s39_start
S39_OUT=$(s39_run sess-s39a)
[ -z "$(hf_get armed)" ] \
  && ok "a 5-hour reset beside a weekly window that is still spent arms no return" \
  || bad "returned to a spent subscription" "armed=$(hf_get armed) direction=$(hf_get direction)"
if kill -0 "$S39_PID" 2>/dev/null; then ok "...and the session is not ended for a relaunch pair that lands at the same wall"
else bad "wasted relaunch" "ended the session to go back to an account with no room"; fi
case "$S39_OUT" in
  *"usable again"*) bad "premature recovery notice" "told the user the subscription is usable: $(printf '%s' "$S39_OUT" | tr '\n' ' ' | head -c 140)" ;;
  *) ok "...and never says the subscription is usable again while a window is spent" ;;
esac
s39_done

# (b) Both windows below the one number: this is what the return is for.
s39_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S39_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S39_FUT\"}}" \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"recovery_notified_window\":\"five_hour\",\"recovery_notified_reset\":\"$S39_FUT\",\"last_five_hour_percent\":4,\"last_five_hour_reset\":\"$S39_FUT\",\"last_seven_day_percent\":31,\"last_seven_day_reset\":\"$S39_FUT\"}"
s39_start
s39_run sess-s39b >/dev/null
[ "$(hf_get direction)" = "to_subscription" ] \
  && ok "every window below spent-at still arms the plain return" \
  || bad "return never armed" "armed=$(hf_get armed) direction=$(hf_get direction)"
s39_done

# ...and the bar is spent-at, not a reserve below it. 99% is still somewhere to
# come back to (has_headroom), and a return that waited for more would keep the
# session on a paid backbone with a subscription sitting there unused.
s39_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S39_FUT\",\"sevenDayPercent\":99,\"sevenDayReset\":\"$S39_FUT\"}}" \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"recovery_notified_window\":\"five_hour\",\"recovery_notified_reset\":\"$S39_FUT\",\"last_five_hour_percent\":4,\"last_five_hour_reset\":\"$S39_FUT\",\"last_seven_day_percent\":99,\"last_seven_day_reset\":\"$S39_FUT\"}"
s39_start
s39_run sess-s39b2 >/dev/null
[ "$(hf_get direction)" = "to_subscription" ] \
  && ok "...and one point short of spent is still a destination, not a reserve" \
  || bad "reserve crept back" "armed=$(hf_get armed) direction=$(hf_get direction)"
s39_done

# (c) A window whose reset time has passed says nothing about the quota that
# replaced it — the rule `expired()` already applies to the peak the hook decides
# everything else on. 100% under a reset that is in the past must not hold the
# session on the paid backbone.
s39_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S39_FUT\",\"sevenDayPercent\":100,\"sevenDayReset\":\"$S39_PAST\"}}" \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"recovery_notified_window\":\"five_hour\",\"recovery_notified_reset\":\"$S39_FUT\",\"last_five_hour_percent\":4,\"last_five_hour_reset\":\"$S39_FUT\",\"last_seven_day_percent\":100,\"last_seven_day_reset\":\"$S39_PAST\"}"
s39_start
s39_run sess-s39c >/dev/null
[ "$(hf_get direction)" = "to_subscription" ] \
  && ok "...and a window that has already turned over is not counted against it" \
  || bad "held by an expired window" "armed=$(hf_get armed) direction=$(hf_get direction)"
s39_done

# (d) No reading is not a reading that says yes. A recovery recorded on an earlier
# tick outlives the reading it came from, so the arm has to be checked against a
# reading that is there, usable and young enough to describe now.
s39_fixture \
  '{"claude":{"available":false,"error":true}}' \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"recovery_notified_window\":\"five_hour\",\"recovery_notified_reset\":\"$S39_FUT\",\"last_five_hour_percent\":4,\"last_five_hour_reset\":\"$S39_FUT\",\"last_seven_day_percent\":31,\"last_seven_day_reset\":\"$S39_FUT\"}"
s39_start
s39_run sess-s39d >/dev/null
[ -z "$(hf_get armed)" ] \
  && ok "a reading that cannot be read arms nothing" \
  || bad "returned on no reading" "armed=$(hf_get armed) direction=$(hf_get direction)"
s39_done

s39_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S39_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S39_FUT\"}}" \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"recovery_notified_window\":\"five_hour\",\"recovery_notified_reset\":\"$S39_FUT\",\"last_five_hour_percent\":4,\"last_five_hour_reset\":\"$S39_FUT\",\"last_seven_day_percent\":31,\"last_seven_day_reset\":\"$S39_FUT\"}" \
  7200
s39_start
s39_run sess-s39e >/dev/null
[ -z "$(hf_get armed)" ] \
  && ok "...and neither does one too old to describe the quota now" \
  || bad "returned on a stale reading" "armed=$(hf_get armed) direction=$(hf_get direction)"
s39_done

rm -f "$S39_HF" "$S39D/run-state.json" "$S39D/.usage-probe-backoff"
unset -f s39_fixture s39_start s39_run s39_done

head_ "40. the recovery banner reads every window"
# #94. The banner is a promise — end this session and ccd takes you back — and it
# was decided from recovery_notified_window alone: one window that had turned
# over, with no reference to bin/spent-at and no look at the other window. Since
# #93 the hook returns only when EVERY reported, unexpired window is below that
# number, so a 5-hour reset beside a weekly window still at 100% had the row
# promising a return the hook correctly declines — and the user ending a session
# for nothing. The banner asks the hook's question, of the hook's own reading.
S40D="$FAKE/.claude/ccd"
S40_FUT=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=2)).isoformat())")
S40_PAST=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=3)).isoformat())")
S40_BANNER="✓ Claude recovered → 종료하면 구독으로 자동 복귀"
# Each case seeds the whole world its row is drawn from: the reading, the record
# beside it, and no dashboard at all — the dashboard's row is printed above ours,
# and one left on disk by an earlier section would be read as this one's output.
s40_fixture() { # $1=reading (empty: none on disk)  $2=run-state  [$3=age the reading by]
  rm -rf "$FAKE/.claude/plugins/cache/claude-dashboard" \
         "$FAKE/.claude/plugins/data/claude-dashboard-claude-dashboard" \
         "$S40D/.dashboard-row" "$S40D/.dashboard-row.lock"
  mkdir -p "$S40D"
  rm -f "$S40D/quota-cache.json"
  [ -n "$1" ] && printf '%s\n' "$1" > "$S40D/quota-cache.json"
  printf '%s\n' "$2" > "$S40D/run-state.json"
  [ -n "${3:-}" ] && python3 -c '
import os, sys, time
t = time.time() - int(sys.argv[2])
os.utime(sys.argv[1], (t, t))' "$S40D/quota-cache.json" "$3"
  return 0
}
# The row a ccd session renders. No model id in the payload: nothing here is about
# the price half of the row, and naming a slug sends a price fetch out. CCD_HANDOFF
# selects the supervised wording, the one that promises the return outright; the
# unsupervised wording is checked once, in (a).
s40_row() {
  printf '%s' '{}' \
    | CCD_ACTIVE=1 CCD_HANDOFF=00000000000000000000000000000002 HOME="$FAKE" \
      "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g'
}
# The run-state of a recovered 5-hour window, as update_ccd_state leaves it. Only
# the seven-day number differs between the cases below, and the reading beside it
# is what the row must actually decide on.
s40_state() { # $1=seven-day percent
  printf '{"started_at":"t","baseline_usage_usd":0,"ccd_spend_usd":0.5,"recovery_notified_window":"five_hour","recovery_notified_reset":"%s","last_five_hour_percent":4,"last_five_hour_reset":"%s","last_seven_day_percent":%s,"last_seven_day_reset":"%s"}' \
    "$S40_FUT" "$S40_FUT" "$1" "$S40_FUT"
}

# (a) The bug. The 5-hour window reset; the weekly one is still spent, so there is
# nothing to go back to and the hook will not take this session back.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":100,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 100)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) bad "promised a return the hook declines" "5-hour reset, weekly at 100%, row: $row" ;;
  *"Claude recovered"*) bad "promised a return the hook declines" "in some other wording: $row" ;;
  *) ok "a 5-hour reset beside a weekly window still at 100% promises no return" ;;
esac
# Withholding the promise is not blanking the row: everything else it carries is
# still the only thing on screen during an outage.
case "$row" in
  *"run \$0.5000"*) ok "...and the rest of the row is untouched" ;;
  *) bad "the row went with it" "got: $row" ;;
esac
row=$(printf '%s' '{}' | env -u CCD_HANDOFF CCD_ACTIVE=1 HOME="$FAKE" \
        "$ROOT/bin/ccd-statusline" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')
case "$row" in
  *"Claude recovered"*) bad "promised a return the hook declines" "unsupervised wording: $row" ;;
  *) ok "...and neither does the wording that tells an unsupervised user to walk back by hand" ;;
esac

# (b) Every window below spent-at: this is the state the banner exists for.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 31)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) ok "every window below spent-at still shows the banner, word for word" ;;
  *) bad "the banner stopped appearing" "got: $row" ;;
esac
# ...and the reading is a second condition, not a replacement for the first: room
# with no reset recorded is not a recovery, and saying so would announce one on
# every tick of an outage the subscription simply had headroom during.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "{\"started_at\":\"t\",\"baseline_usage_usd\":0,\"ccd_spend_usd\":0.5,\"last_five_hour_percent\":4,\"last_five_hour_reset\":\"$S40_FUT\",\"last_seven_day_percent\":31,\"last_seven_day_reset\":\"$S40_FUT\"}"
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "a reading with room is not a reset" "announced one with nothing recorded: $row" ;;
  *) ok "...and room with no reset recorded still announces nothing" ;;
esac

# (c) The bar is spent-at, not a reserve below it (#57). 99% is still somewhere to
# come back to, and a banner that waited for more would keep the user paying
# beside a subscription they could be using.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":99,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 99)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) ok "one point short of spent is still a place to come back to" ;;
  *) bad "a reserve crept in below spent-at" "got: $row" ;;
esac

# (d) A window whose reset has passed says nothing about the quota that replaced
# it — the same call expired() already makes everywhere else. 100% under a reset
# in the past must not hold the promise back.
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":100,\"sevenDayReset\":\"$S40_PAST\"}}" \
  "$(s40_state 100)"
row=$(s40_row)
case "$row" in
  *"$S40_BANNER"*) ok "...and a window that has already turned over is not counted against it" ;;
  *) bad "held back by an expired window" "got: $row" ;;
esac

# (e) A promise needs a reading that is there, usable, and young enough to
# describe now. The record beside it outlives the reading it came from, and the
# last_*_percent written next to it carries no age bound at all (#94) — so a
# memory of room is exactly what must not be enough. Each of these seeds one.
s40_fixture "" "$(s40_state 31)"
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "promised a return on no reading" "got: $row" ;;
  *) ok "with no reading on disk the row promises nothing" ;;
esac
s40_fixture '{"claude":{"available":false,"error":true}}' "$(s40_state 31)"
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "promised a return on an unusable reading" "got: $row" ;;
  *) ok "...nor on one that could not be taken" ;;
esac
s40_fixture \
  "{\"claude\":{\"available\":true,\"error\":false,\"fiveHourPercent\":4,\"fiveHourReset\":\"$S40_FUT\",\"sevenDayPercent\":31,\"sevenDayReset\":\"$S40_FUT\"}}" \
  "$(s40_state 31)" 7200
row=$(s40_row)
case "$row" in
  *"Claude recovered"*) bad "promised a return on a stale reading" "got: $row" ;;
  *) ok "...nor on one too old to describe the quota now" ;;
esac

rm -f "$S40D/run-state.json" "$S40D/quota-cache.json"
unset -f s40_fixture s40_row s40_state

printf '\n──────────\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
