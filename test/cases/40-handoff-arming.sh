#!/usr/bin/env bash
# 40-handoff-arming — arming the automatic handoff, and the signal that ends the turn.
# Sections: §16, §17, §19, §20, §24, §39
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "16. automatic handoff: arming predicate + hook stdin"
wall_login
mkdir -p "$FAKE/.claude/ccd/providers"

# Arming requires the full readiness set, so these run as a supervised session
# would: a launcher marker, a key, and a resolvable claude process. Section 19
# covers what happens when each of those is missing.
printf 'OPENROUTER_API_KEY="sk-or-v1-smoketest"\n' > "$FAKE/.claude/ccd/providers/keys.env"
paid_optin_on
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


head_ "19. automatic handoff: readiness gates"
shim_fixture
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

head_ "24. multi-account: the account hop left the launcher"
# §23 registered these two and pointed at the spent one; q reads their files.
rm -rf "$ADIR"; mkdir -p "$ADIR"
for n in one two; do write_creds "$n"; "$ACCT" --no-color add --name "$n" >/dev/null 2>&1; done
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

finish
