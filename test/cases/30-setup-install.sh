#!/usr/bin/env bash
# 30-setup-install — what `ccd setup` installs, and what it reports.
# Sections: §6, §7, §14, §18c, §38, §43
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

head_ "6. ccd setup / statusline / uninstall"
# §2–§5 left a 58%/96% reading on file and the warning row below reads it.
mkdir -p "$FAKE/.claude/ccd"
stub_usage 58 96
"$ROOT/scripts/quota-guard.sh" UserPromptSubmit >/dev/null 2>&1
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


head_ "18c. an install that leaves handoff inert must not report success"
shim_fixture
ttyask_fixture
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
# Asked of the final path, not of a file at it: since §43 the bytes go to a sibling
# and a chmod that did not take stops them being moved over, so there is nothing
# there at all. Either way the stand-in is what put it that way — the real chmod
# would have left an executable shim — so this still says the fixture worked.
[ ! -x "$h/.claude/ccd/bin/claude" ] \
  && ok "a chmod that does not take really does leave no runnable shim" \
  || bad "shim chmod" "the fixture produced a runnable shim anyway"
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


head_ "43. a launcher is installed whole, or not at all"
# §38 made setup verify the launcher before printing ✓: is_ccd_shim plus the
# executable bit. On a REINSTALL both can be true over a file that cannot run. The
# bytes go straight to the final path, so a short write — a full disk, a filesystem
# going read-only mid-write — keeps the signature, which is the second line, while
# the body is gone, and the executable bit survives from the file that was there
# before. `cat`'s own exit status was never asked. Setup then prints ✓ over a
# `claude` that does nothing: exec_claude hands the session to it, a `ccd -c` run
# never comes back from OpenRouter by itself, and the meter keeps running on the
# user's own key — #29 again, through the door #92 left open (#97).
#
# One habit, three files: ~/.claude/ccd/bin/claude, ~/.local/bin/ccd and
# ~/.claude/ccd/statusline-launcher.sh are each a heredoc into the final path
# followed by an unchecked chmod. So each is asked the same two questions: a write
# that stops partway, and a chmod that refuses.
#
# A short write IS `cat` stopping partway and exiting non-zero — that is what ENOSPC
# and an EIO on a dying filesystem hand it. So the stand-in below is a `cat` that
# copies the first bytes of the real heredoc and then fails. It fires only for the
# file a case names, keeps what it was handed, and records that it fired: a fix that
# stopped writing with `cat` would leave the log empty and every case here would say
# so rather than pass on nothing. Each case seeds its own HOME, and every variable
# that outranks HOME for where ccd writes is severed for the run.
S43=$(mktemp -d "$FAKE/s43.XXXXXX")
S43_SIG='# ccd-auto-handoff-shim v1 (managed by: ccd setup --auto)'
S43_REAL_CAT=$(command -v cat); S43_REAL_CHMOD=$(command -v chmod)

# A `claude` that is decidedly not ours, and the only one these fixtures can reach:
# it makes shim_leads_path() false wherever this suite runs, and it is what a whole
# launcher falls through to when no plugin is installed — so "REAL-CLAUDE" on stdout
# is proof that a launcher ran all the way to its last line.
S43_BIN="$S43/bin"; mkdir -p "$S43_BIN"
printf '#!/bin/sh\necho REAL-CLAUDE\n' > "$S43_BIN/claude"; chmod +x "$S43_BIN/claude"

S43_TOOLS="$S43/tools"; mkdir -p "$S43_TOOLS"
cat > "$S43_TOOLS/cat" <<'S43_CAT'
#!/bin/sh
# Only the heredoc form is ours; `cat FILE` passes straight through.
R=${CCD_T_CAT:-/bin/cat}
[ $# -eq 0 ] && [ -n "${CCD_T_TRUNC:-}" ] || exec "$R" "$@"
b="$CCD_T_LOG.buf"
"$R" > "$b"
if grep -qF "$CCD_T_TRUNC" "$b"; then
  cp "$b" "$CCD_T_LOG.kept"
  head -c "${CCD_T_BYTES:-100}" "$b"
  echo truncated >> "$CCD_T_LOG"
  exit 1
fi
exec "$R" "$b"
S43_CAT
cat > "$S43_TOOLS/chmod" <<'S43_CHMOD'
#!/bin/sh
# A chmod that refuses the path a case names, and is the real one everywhere else.
R=${CCD_T_CHMOD:-/bin/chmod}
if [ -n "${CCD_T_CHMOD_FAIL:-}" ]; then
  for a in "$@"; do
    case "$a" in *"$CCD_T_CHMOD_FAIL"*)
      echo "refused $a" >> "$CCD_T_LOG"
      echo "chmod: $a: Read-only file system" >&2
      exit 1 ;;
    esac
  done
fi
exec "$R" "$@"
S43_CHMOD
chmod +x "$S43_TOOLS/cat" "$S43_TOOLS/chmod"

s43_home() {   # a fresh HOME with a .zshrc of the user's own; prints its path
  local h; h=$(mktemp -d "$S43/h.XXXXXX")
  mkdir -p "$h/.claude" "$h/.local/bin" "$h/.claude/ccd/bin"
  printf '# my own file\n' > "$h/.zshrc"
  printf '%s' "$h"
}
# The launcher that is already there when setup runs again — complete, executable
# and saying which one it is. The shim carries our signature or setup would refuse
# to touch it at all.
s43_seed() {   # $1=HOME $2=shim|cmd|sl
  local p
  case "$2" in
    shim) p="$1/.claude/ccd/bin/claude"
          printf '#!/bin/sh\n%s\necho PREVIOUS-SHIM\n' "$S43_SIG" > "$p" ;;
    cmd)  p="$1/.local/bin/ccd";                printf '#!/bin/sh\necho PREVIOUS-CCD\n' > "$p" ;;
    sl)   p="$1/.claude/ccd/statusline-launcher.sh"; printf '#!/bin/sh\necho PREVIOUS-SL\n' > "$p" ;;
  esac
  chmod +x "$p"
}
s43_setup() {  # $1=HOME $2=heredoc to truncate $3=path chmod refuses → S43_OUT, S43_ST
  S43_LOG="$1/.tool-log"; : > "$S43_LOG"; rm -f "$S43_LOG.kept" "$S43_LOG.buf"
  S43_OUT=$(env -u ZDOTDIR -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR \
              HOME="$1" SHELL=/bin/zsh PATH="$S43_TOOLS:$S43_BIN:$PATH" \
              CCD_T_CAT="$S43_REAL_CAT" CCD_T_CHMOD="$S43_REAL_CHMOD" \
              CCD_T_LOG="$S43_LOG" CCD_T_TRUNC="${2:-}" CCD_T_CHMOD_FAIL="${3:-}" \
              "$ROOT/bin/ccd" setup --auto --yes 2>&1); S43_ST=$?
}
# Run an installed launcher where the only `claude` reachable is the stand-in: a
# broken one must never be able to reach the developer's real Claude Code.
s43_run()   { local h="$1"; shift
              env -u ZDOTDIR HOME="$h" PATH="$S43_BIN:/usr/bin:/bin" "$@" 2>&1; }
s43_said()  { case "$S43_OUT" in *"$1"*) return 0 ;; esac; return 1; }
s43_brief() { printf '%s' "$S43_OUT" | tr '\n' ' ' | head -c 140; }

# (a) The reinstall in the issue: a launcher of ours is already there, and the new
# write stops in the middle of the body.
h=$(s43_home); s43_seed "$h" shim
s43_setup "$h" "$S43_SIG"
grep -q truncated "$S43_LOG" \
  && ok "a write that stops partway really does stop partway" \
  || bad "short write" "the stand-in never fired — this case proves nothing"
head -c 100 "$S43_LOG.kept" 2>/dev/null | grep -qxF "$S43_SIG" \
  && ok "...and the bytes that landed still carry the signature is_ccd_shim looks for" \
  || bad "short write" "the truncation dropped the signature, so this is not #97's case"
[ "$(s43_run "$h" "$h/.claude/ccd/bin/claude")" = "PREVIOUS-SHIM" ] \
  && ok "...and the launcher that was there is untouched, and still runs" \
  || bad "short write" "the previous launcher is gone: $(s43_run "$h" "$h/.claude/ccd/bin/claude" | tr '\n' ' ' | head -c 60)"
s43_said "OpenRouter handoff installed" \
  && bad "short write" "claimed an install the write never finished: $(s43_brief)" \
  || ok "...and setup does not claim it installed one"
[ "$S43_ST" -ne 0 ] \
  && ok "...and exits non-zero (got $S43_ST)" \
  || bad "short write" "exited 0 over a launcher that was never written whole"
s43_said "ccd setup --auto" \
  && ok "...and names the command that repairs it" \
  || bad "short write" "no remedy: $(s43_brief)"

# (b) The same short write with nothing there before. Nothing may be left at the
# final path: a half-written file with our signature on it is one every later run —
# and uninstall, and the handoff — reads as a launcher of ours.
h=$(s43_home)
s43_setup "$h" "$S43_SIG"
[ ! -e "$h/.claude/ccd/bin/claude" ] \
  && ok "a first install that fails mid-write leaves nothing behind" \
  || bad "short write" "left $(wc -c < "$h/.claude/ccd/bin/claude" | tr -d ' ') bytes that is_ccd_shim calls ours"
s43_said "OpenRouter handoff installed" \
  && bad "short write" "claimed a launcher that is only a header: $(s43_brief)" \
  || ok "...and reports no launcher, because there is none"

# (c) The bytes all land, and the chmod refuses. A launcher is not installed until
# it is runnable, and the executable bit of the file it replaces does not count.
h=$(s43_home); s43_seed "$h" shim
s43_setup "$h" "" "/.claude/ccd/bin/"
grep -q '^refused ' "$S43_LOG" \
  && ok "a chmod that refuses really was asked" \
  || bad "shim chmod fails" "the stand-in never fired — this case proves nothing"
[ "$(s43_run "$h" "$h/.claude/ccd/bin/claude")" = "PREVIOUS-SHIM" ] \
  && ok "...and the launcher that was there is untouched, and still runs" \
  || bad "shim chmod fails" "replaced a working launcher with one it could not make runnable"
s43_said "OpenRouter handoff installed" \
  && bad "shim chmod fails" "counted the old file's executable bit as this install's: $(s43_brief)" \
  || ok "...and setup does not claim it installed one"
[ "$S43_ST" -ne 0 ] \
  && ok "...and exits non-zero (got $S43_ST)" \
  || bad "shim chmod fails" "exited 0 after a chmod that failed"

# (d) And the clean run still installs a whole launcher — the point is not to report
# failure, it is that what ✓ is printed over can be run.
h=$(s43_home); s43_seed "$h" shim
s43_setup "$h"
{ [ "$S43_ST" -eq 0 ] && [ -x "$h/.claude/ccd/bin/claude" ]; } \
  && ok "a clean run exits 0 with an executable launcher on disk" \
  || bad "happy path" "exited $S43_ST: $(s43_brief)"
grep -qF 'CCD_SHIM_PATH="$self" exec' "$h/.claude/ccd/bin/claude" \
  && ok "...whose last line is there, so the body is whole" \
  || bad "happy path" "the installed launcher stops short of its last line"
[ "$(s43_run "$h" "$h/.claude/ccd/bin/claude")" = "REAL-CLAUDE" ] \
  && ok "...and it runs: with no plugin installed it hands over to the real claude" \
  || bad "happy path" "the installed launcher does not run: $(s43_run "$h" "$h/.claude/ccd/bin/claude" | tr '\n' ' ' | head -c 60)"
s43_said "OpenRouter handoff installed" \
  && ok "...and setup says so" \
  || bad "happy path" "installed it and said nothing: $(s43_brief)"

# (e) ~/.local/bin/ccd is written the same way, and it is the whole command: a
# header with no body is a `ccd` that exits 0 without doing anything, so `ccd -c`
# stops being a way out at all.
h=$(s43_home); s43_seed "$h" cmd
s43_setup "$h" "# ccd launcher "
grep -q truncated "$S43_LOG" \
  && ok "the ccd command's write stops partway too" \
  || bad "ccd command" "the stand-in never fired — this case proves nothing"
[ "$(s43_run "$h" "$h/.local/bin/ccd")" = "PREVIOUS-CCD" ] \
  && ok "...and the ccd command that was there is untouched, and still runs" \
  || bad "ccd command" "the previous command is gone: $(s43_run "$h" "$h/.local/bin/ccd" | tr '\n' ' ' | head -c 60)"
s43_said "ccd command installed" \
  && bad "ccd command" "claimed a command the write never finished: $(s43_brief)" \
  || ok "...and setup does not claim it installed one"
[ "$S43_ST" -ne 0 ] \
  && ok "...and exits non-zero (got $S43_ST)" \
  || bad "ccd command" "exited 0 over a half-written ccd command"

h=$(s43_home); s43_seed "$h" cmd
s43_setup "$h" "" "/.local/bin/"
[ "$(s43_run "$h" "$h/.local/bin/ccd")" = "PREVIOUS-CCD" ] \
  && ok "a chmod that refuses leaves the ccd command that was there" \
  || bad "ccd command chmod" "replaced a working command with one it could not make runnable"
{ ! s43_said "ccd command installed" && [ "$S43_ST" -ne 0 ]; } \
  && ok "...and setup reports the failure instead of the ✓ (exit $S43_ST)" \
  || bad "ccd command chmod" "exited $S43_ST: $(s43_brief)"

# (f) The statusline launcher, last of the three. Truncated, it prints nothing, the
# status line goes blank, and the quota warning the whole product turns on is the
# thing that stops being shown.
h=$(s43_home); s43_seed "$h" sl
s43_setup "$h" "# ccd statusline launcher"
grep -q truncated "$S43_LOG" \
  && ok "the statusline launcher's write stops partway too" \
  || bad "statusline launcher" "the stand-in never fired — this case proves nothing"
[ "$(s43_run "$h" bash "$h/.claude/ccd/statusline-launcher.sh")" = "PREVIOUS-SL" ] \
  && ok "...and the statusline launcher that was there is untouched, and still runs" \
  || bad "statusline launcher" "the previous launcher is gone: $(s43_run "$h" bash "$h/.claude/ccd/statusline-launcher.sh" | tr '\n' ' ' | head -c 60)"
s43_said "statusline wired" \
  && bad "statusline launcher" "claimed a launcher the write never finished: $(s43_brief)" \
  || ok "...and setup does not claim it wired one"
[ "$S43_ST" -ne 0 ] \
  && ok "...and exits non-zero (got $S43_ST)" \
  || bad "statusline launcher" "exited 0 over a half-written statusline launcher"

# (g) Both of those installed clean by the same run that installs the shim, and no
# half-written sibling left lying next to any of the three.
h=$(s43_home)
s43_setup "$h"
{ [ "$S43_ST" -eq 0 ] && [ -x "$h/.local/bin/ccd" ] \
  && [ -x "$h/.claude/ccd/statusline-launcher.sh" ]; } \
  && ok "a clean run installs all three, executable, and exits 0" \
  || bad "happy path" "exited $S43_ST with ccd=$([ -x "$h/.local/bin/ccd" ] && echo x || echo none) statusline=$([ -x "$h/.claude/ccd/statusline-launcher.sh" ] && echo x || echo none)"
case "$(s43_run "$h" "$h/.local/bin/ccd")" in
  *"plugin not found"*) ok "...and the ccd command runs its own body to the end" ;;
  *) bad "happy path" "the installed ccd command does nothing: $(s43_run "$h" "$h/.local/bin/ccd" | tr '\n' ' ' | head -c 60)" ;;
esac
# Named by what belongs there rather than by what a temporary file is called, so
# this keeps its meaning whatever the sibling is named.
left="$(ls -A "$h/.local/bin" | grep -vx ccd)$(ls -A "$h/.claude/ccd/bin" | grep -vx claude)$(ls -A "$h/.claude/ccd" | grep '^statusline-launcher\.sh\.')"
[ -z "$left" ] \
  && ok "...and leaves no half-written sibling beside any of them" \
  || bad "happy path" "left behind: $(printf '%s' "$left" | tr '\n' ' ')"

rm -rf "$S43"
unset -f s43_home s43_seed s43_setup s43_run s43_said s43_brief
unset S43 S43_SIG S43_REAL_CAT S43_REAL_CHMOD S43_BIN S43_TOOLS S43_LOG S43_OUT S43_ST

# ── one freshness rule, on both sides of the reading ─────────────────────────

finish
