#!/usr/bin/env bash
# 31-setup-path — the launcher shim and its PATH line.
# Sections: §18, §18b, §18d, §18e
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "18. automatic handoff: launcher shim"
shim_fixture
"$ROOT/bin/ccd" setup --auto --yes >/dev/null 2>&1
[ -x "$SHIM" ] && ok "setup --auto installs the claude shim" \
  || bad "shim install" "not executable"
"$ROOT/bin/ccd" setup >/dev/null 2>&1
[ -x "$SHIM" ] && ok "bare setup leaves the shim alone" || bad "bare setup removed the shim"


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
ttyask_fixture
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

ttyask_fixture

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

finish
