#!/usr/bin/env bash
# Portable smoke test — runs the real scripts against a throwaway HOME.
# Intended to run on both macOS and Linux (see test/docker.sh for the Linux run).
# No network, no real key, no writes outside $HOME.
#
# This is the runner. Every assertion lives in test/cases/*.sh, one file per
# product area, each run in its own process with its own throwaway HOME — so an
# export or a fixture can only outlive the section that set it inside one file,
# where a reviewer can see it (#76).
#
#   bash test/smoke.sh                 every case file, in filename order
#   bash test/smoke.sh statusline      only the files whose name contains that word
#   bash test/smoke.sh swap 60         several words, several files
#   bash test/cases/50-statusline.sh   one file on its own, with its own tally
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# §41 re-runs this file to prove that a fixture setup writes nothing outside its
# HOME. The canary itself lives in lib/common.sh, beside the unsets it exists to
# police: a copy here would go on passing after one of them was deleted.
if [ "${1:-}" = --setup-canary ]; then
  # shellcheck source=test/lib/common.sh
  . "$ROOT/test/lib/common.sh"     # $1 and $2 are still ours; the canary exits
  exit 0
fi

# Nothing in this suite reads stdin, and a live terminal on fd 0 has hung it: a
# case that drives `ccd setup` reaches past a piped stdin to /dev/tty (#17).
exec </dev/null

files=()
for f in "$ROOT"/test/cases/*.sh; do
  [ -f "$f" ] || continue
  if [ "$#" -eq 0 ]; then files+=("$f"); continue; fi
  for w in "$@"; do
    case "${f##*/}" in *"$w"*) files+=("$f"); break ;; esac
  done
done
if [ "${#files[@]}" -eq 0 ]; then
  echo "smoke.sh: no case file matches $*" >&2
  exit 2
fi

# A case file's ok/bad mutate its own pass/fail, so it reports them here rather
# than through a subshell that would always say zero (#65's correction).
TALLY=$(mktemp)
trap 'rm -f "$TALLY"' EXIT
pass=0 fail=0
for f in "${files[@]}"; do
  printf '\n════ %s ════\n' "${f##*/}"
  : > "$TALLY"
  CCD_TALLY_OUT="$TALLY" bash "$f" </dev/null
  rc=$?
  read -r p q < "$TALLY" || true
  if [ -z "${p:-}" ] || [ -z "${q:-}" ]; then
    printf '  ✗ %s stopped without reporting a tally (exit %s)\n' "${f##*/}" "$rc"
    fail=$((fail + 1))
  else
    pass=$((pass + p)); fail=$((fail + q))
  fi
done

printf '\n──────────\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
