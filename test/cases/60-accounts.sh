#!/usr/bin/env bash
# 60-accounts — the multi-account store.
# Sections: §21, §22, §23, §26, §35
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "21. multi-account: the store"
mkdir -p "$HB"   # shim_fixture makes this; §21 only puts the real ccd-account in it
# No test may reach the real network. If one does, fail in ~1s rather than
# stalling for the full timeout on every account.
export CCD_HTTP_TIMEOUT=1
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

finish
