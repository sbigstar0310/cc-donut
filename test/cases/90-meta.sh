#!/usr/bin/env bash
# 90-meta — the suite, and the gate that runs it.
# Sections: §33, §34, §41
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

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


head_ "41. a fixture setup writes nothing outside its HOME"
# `ccd setup` resolves the zsh startup file as ${ZDOTDIR:-$HOME}/.zshrc, so HOME is
# not the only variable that decides where it writes. A suite that replaces HOME and
# inherits the rest appends its PATH line to the developer's REAL rc file (#100) —
# and only on a machine that sets ZDOTDIR, which is why no run here ever showed it.
# So stage that machine: every variable that can name a directory for a ccd writer
# points at a canary that must stay empty, and the run's own HOME is the only place
# anything may land. The receipt matters as much as the canary — a run that edited
# no startup file at all would leave the canary clean and prove nothing.
S41C="$FAKE/s41-canary"
rm -rf "$S41C"; mkdir -p "$S41C"
s41=$(env ZDOTDIR="$S41C" XDG_CONFIG_HOME="$S41C" XDG_DATA_HOME="$S41C" \
          XDG_STATE_HOME="$S41C" XDG_CACHE_HOME="$S41C" \
          CLAUDE_CONFIG_DIR="$S41C" CLAUDE_SECURESTORAGE_CONFIG_DIR="$S41C" \
          CCD_HANDOFF=00000000000000000000000000000002 \
          CCD_HANDOFF_STATE="$S41C/handoff.json" \
          bash "$ROOT/test/smoke.sh" --setup-canary "$S41C" 2>&1)
[ "$s41" = "wrote .zshrc" ] \
  && ok "setup --yes writes its PATH line inside the fixture HOME and nowhere else" \
  || bad "a fixture setup escaped its HOME" \
         "expected 'wrote .zshrc', got: $(printf '%s' "$s41" | tr '\n' '|')"
rm -rf "$S41C"

# ── a swap stops when its hold on Claude Code's locks lapses ────────────────

head_ "45. every case file reaches the fixture HOME before anything else"
# lib/common.sh is what replaces HOME, unsets the variables that outrank it and
# forces the file credential backend. A file that sourced it second would pass its
# own assertions and write somewhere real on the way to them — the real ~/.claude, a
# real rc file, the keychain. So it has to be the first thing every one of them does.
s45=
for f in "$ROOT"/test/cases/*.sh; do
  first=$(grep -vE '^[[:space:]]*(#|$)' "$f" | head -1)
  case "$first" in
    *lib/common.sh*) ;;
    *) s45="$s45 ${f##*/}:[$first]" ;;
  esac
done
[ -z "$s45" ] \
  && ok "every file under test/cases/ sources lib/common.sh as its first executable line" \
  || bad "a case file could reach the real HOME" "$s45"

finish
