#!/usr/bin/env python3
"""Walk the whole user scenario automatically, against a real claude.

Not part of test/smoke.sh: this needs a real `claude` binary and takes minutes.
Run it before handing the feature to someone to try by hand.

Everything is genuine — the shim, the launcher, the hook, the claude process,
the relaunch. Only the quota reading is stubbed, because a subscription cannot
be exhausted on demand, and the sandbox HOME has no credentials so the model
never answers. That is fine: what is under test is the machinery around the
conversation, not the conversation.

Run:  python3 roundtrip.py
"""
import json, os, pty, re, select, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
E    = os.environ.get("CCD_ROUNDTRIP_DIR") or tempfile.mkdtemp(prefix="ccd-roundtrip.")
HOME = f"{E}/home"
PROJ = f"{E}/proj"
SECRET = "도넛"

passed, failed = [], []
def ok(msg):  passed.append(msg); print(f"  \033[32m✓\033[0m {msg}")
def bad(msg, detail=""):
    failed.append(msg); print(f"  \033[31m✗\033[0m {msg}")
    if detail: print(f"      {detail[:300]}")
def head(msg): print(f"\n\033[1m{msg}\033[0m")

# ── sandbox ────────────────────────────────────────────────────────────────
shutil.rmtree(E, ignore_errors=True)
os.makedirs(f"{HOME}/.claude/ccd/providers", exist_ok=True)
os.makedirs(f"{PROJ}/.claude", exist_ok=True)
os.makedirs(f"{E}/bin", exist_ok=True)

PLUG = f"{HOME}/.claude/plugins/cache/cc-donut/ccd/0.2.2"
os.makedirs(f"{PLUG}/bin", exist_ok=True)
os.makedirs(f"{PLUG}/scripts", exist_ok=True)
for f in ("ccd", "ccd-handoff", "ccd-statusline", "ccd-price-fetch"):
    shutil.copy(f"{ROOT}/bin/{f}", f"{PLUG}/bin/{f}")
    os.chmod(f"{PLUG}/bin/{f}", 0o755)
shutil.copy(f"{ROOT}/scripts/quota-guard.sh", f"{PLUG}/scripts/quota-guard.sh")
os.chmod(f"{PLUG}/scripts/quota-guard.sh", 0o755)

with open(f"{HOME}/.claude/ccd/providers/keys.env", "w") as f:
    f.write('OPENROUTER_API_KEY="sk-or-v1-roundtrip-not-a-real-key"\n')
os.chmod(f"{HOME}/.claude/ccd/providers/keys.env", 0o600)
with open(f"{HOME}/.zshrc", "w") as f:
    f.write("# sandbox zshrc\n")

# Stub the dashboard: `node <check-usage.js>` prints whatever we stage.
DASH = f"{HOME}/.claude/plugins/cache/claude-dashboard/claude-dashboard/1.0.0/dist"
os.makedirs(DASH, exist_ok=True)
open(f"{DASH}/check-usage.js", "w").close()
with open(f"{E}/bin/node", "w") as f:
    f.write('#!/bin/sh\ncat "$HOME/.stub-usage.json"\n')
os.chmod(f"{E}/bin/node", 0o755)

def stage_quota(pct, reset="R-window-1"):
    with open(f"{HOME}/.stub-usage.json", "w") as f:
        json.dump({"claude": {"available": True, "error": False,
                              "fiveHourPercent": pct, "fiveHourReset": reset,
                              "sevenDayPercent": 20, "sevenDayReset": "D1"}}, f)
    # The guard caches for 10 minutes; drop the cache so the stub is re-read.
    for p in (f"{HOME}/.claude/ccd/quota-cache.json",):
        if os.path.exists(p): os.remove(p)

stage_quota(99)

# Skip first-run onboarding so sessions start immediately.
seed = {"hasCompletedOnboarding": True, "theme": "dark",
        "projects": {os.path.realpath(PROJ): {"hasTrustDialogAccepted": True,
                                              "projectOnboardingSeenCount": 3}}}
with open(f"{HOME}/.claude.json", "w") as f:
    json.dump(seed, f)

def run(cmd, env_extra=None, cwd=None, shim_on_path=True):
    base = f"{HOME}/.claude/ccd/bin:" if shim_on_path else ""
    env = dict(os.environ, HOME=HOME, SHELL="/bin/zsh",
               PATH=base + f"{E}/bin:" + os.environ["PATH"])
    for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
              "CCD_ACTIVE", "CCD_HANDOFF", "CCD_HANDOFF_STATE", "CLAUDECODE",
              "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
              # This harness runs INSIDE a Claude Code session; leaking its
              # markers makes the sandbox session think it is a child, and hooks
              # stop firing. That is what swallowed the return trip.
              "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PLUGIN_DATA", "CLAUDE_EFFORT",
              "CLAUDE_CODE_EXECPATH", "AI_AGENT", "CODEX_COMPANION_TRANSCRIPT_PATH"):
        env.pop(k, None)
    if env_extra: env.update(env_extra)
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                       env=env, cwd=cwd or E)
    return p.returncode, p.stdout + p.stderr

# ── 1. install ─────────────────────────────────────────────────────────────
head("1. ccd setup --auto")
rc, out = run(f"{PLUG}/bin/ccd setup --auto --yes", shim_on_path=False)
if "automatic handoff installed" in out: ok("installs the launcher")
else: bad("install", out)
plain = re.sub(r"\x1b\[[0-9;]*m", "", out).strip()
if plain.splitlines()[-1].strip().startswith("Open a new terminal"):
    ok("the remaining step is the last line")
else: bad("ordering", out.strip().splitlines()[-1])
zshrc = open(f"{HOME}/.zshrc").read()
if "ccd-auto-handoff-path" in zshrc and 'ccd/bin:$PATH' in zshrc:
    ok("the PATH line lands in ~/.zshrc, with its marker")
else: bad("PATH line", zshrc)

head("2. a new shell finds the launcher first")
rc, out = run("command -v claude")
if out.strip().endswith("/.claude/ccd/bin/claude"): ok(f"which claude → {out.strip()[-30:]}")
else: bad("PATH order", out)

head("3. ccd doctor tells the truth about readiness")
rc, out = run(f"{PLUG}/bin/ccd doctor 2>&1 | sed -n '/Automatic handoff/,/^$/p'")
if "active in this shell" in out and "not active" not in out:
    ok("doctor: active in this shell")
else: bad("doctor", out)
rc, out = run(f"{PLUG}/bin/ccd doctor 2>&1 | sed -n '/Automatic handoff/,/^$/p'",
              env_extra={"CLAUDECODE": "1", "PATH": os.environ["PATH"]})
if "not active in this shell" in out and "NOT supervised" in out:
    ok("doctor: an unsupervised session is called out")
else: bad("doctor (unsupervised)", out)

# ── the session itself ─────────────────────────────────────────────────────
def session(probe, seconds=45, typed=None, on_marker=None):
    """Start claude through the real shim under a pty; return what the terminal showed."""
    with open(f"{E}/probe.sh", "w") as f:
        f.write(probe)
    os.chmod(f"{E}/probe.sh", 0o755)
    with open(f"{PROJ}/.claude/settings.local.json", "w") as f:
        json.dump({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": f"{E}/probe.sh"}]}],
            "UserPromptSubmit": [{"hooks": [{"type": "command",
                "command": f"{PLUG}/scripts/quota-guard.sh UserPromptSubmit"}]}],
            "StopFailure": [{"matcher": "rate_limit", "hooks": [{"type": "command",
                "command": f"{PLUG}/scripts/quota-guard.sh StopFailure"}]}],
            "SessionEnd": [{"hooks": [{"type": "command",
                "command": f"{PLUG}/scripts/quota-guard.sh SessionEnd"}]}],
        }}, f)
    env = dict(os.environ, HOME=HOME, SHELL="/bin/zsh",
               PATH=f"{HOME}/.claude/ccd/bin:{E}/bin:" + os.environ["PATH"])
    for k in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
              "CCD_ACTIVE", "CCD_HANDOFF", "CCD_HANDOFF_STATE", "CLAUDECODE",
              "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
              # This harness runs INSIDE a Claude Code session; leaking its
              # markers makes the sandbox session think it is a child, and hooks
              # stop firing. That is what swallowed the return trip.
              "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PLUGIN_DATA", "CLAUDE_EFFORT",
              "CLAUDE_CODE_EXECPATH", "AI_AGENT", "CODEX_COMPANION_TRANSCRIPT_PATH"):
        env.pop(k, None)
    shim = f"{HOME}/.claude/ccd/bin/claude"
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(PROJ)
        os.execvpe(shim, [shim], env)
    buf = b""
    sent = False
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            p, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if p: break
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try: chunk = os.read(fd, 8192)
            except OSError: break
            if not chunk: break
            buf += chunk
            if on_marker and not sent and on_marker[0].encode() in buf:
                time.sleep(3.0); on_marker[1]()
                time.sleep(1.0); os.write(fd, on_marker[2].encode() + b"\r"); sent = True
            elif typed and not sent and b"\xe2\x9d\xaf" in buf[-4000:]:
                time.sleep(2.0); os.write(fd, typed.encode() + b"\r"); sent = True
        if b"trust this folder" in buf:
            os.write(fd, b"\r")
    else:
        os.kill(pid, 9)
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    return re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", buf).decode("utf-8", "replace")

# ── 4. nothing happens when the quota is fine ──────────────────────────────
head("4. a healthy quota is invisible")
stage_quota(40)
quiet = session("#!/bin/sh\nexit 0\n", seconds=25)
if "도넛" not in quiet and "쿼타 소진" not in quiet and "OpenRouter" not in quiet:
    ok("no banner, no handoff, nothing said")
else: bad("invisible", quiet[-300:])

# ── 5. the handoff ─────────────────────────────────────────────────────────
head("5. quota exhausted → handoff")
stage_quota(99)
# Fabricate a transcript for the live session so the resume path is exercised —
# the sandbox has no credentials, so claude never writes one of its own.
probe = f'''#!/bin/bash
IN=$(cat 2>/dev/null)
SID=$(printf '%s' "$IN" | python3 -c 'import json,sys;print((json.load(sys.stdin) or {{}}).get("session_id",""))' 2>/dev/null)

if [ -n "$CCD_ACTIVE" ]; then
  # The ccd leg. Stage the recovered window, then fire the hook a prompt would.
  python3 - "$HOME/.claude/ccd/run-state.json" "$HOME/.stub-usage.json" <<'PYX'
import json, os, sys
run, stub = sys.argv[1], sys.argv[2]
if os.path.exists(run):
    st = json.load(open(run))
    st["last_five_hour_percent"] = 99
    st["last_five_hour_reset"] = "R-window-1"
    json.dump(st, open(run, "w"))
json.dump({{"claude": {{"available": True, "error": False,
                       "fiveHourPercent": 12, "fiveHourReset": "R-window-2",
                       "sevenDayPercent": 20, "sevenDayReset": "D1"}}}},
          open(stub, "w"))
PYX
  rm -f "$HOME/.claude/ccd/quota-cache.json"
  echo "probe: ccd leg, firing UserPromptSubmit with a recovered window" >> {E}/probe.log
  printf '{{"session_id":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit"}}' "$SID" "{PROJ}" \\
    | {PLUG}/scripts/quota-guard.sh UserPromptSubmit >> {E}/probe.log 2>&1
  exit 0
fi

# The subscription leg. Give it a transcript, then fire the rate_limit.
echo "$SID" > {E}/sid
SLUG=$(printf '%s' "{PROJ}" | sed 's/[^a-zA-Z0-9]/-/g')
mkdir -p "$HOME/.claude/projects/$SLUG"
printf '{{"type":"user","message":{{"role":"user","content":"내 비밀 단어는 {SECRET}이야"}}}}\\n' \\
  > "$HOME/.claude/projects/$SLUG/$SID.jsonl"
echo "probe: subscription leg, firing StopFailure" >> {E}/probe.log
printf '{{"session_id":"%s","cwd":"%s","hook_event_name":"StopFailure","error_type":"rate_limit"}}' "$SID" "{PROJ}" \\
  | {PLUG}/scripts/quota-guard.sh StopFailure >> {E}/probe.log 2>&1
exit 0
'''
out = session(probe, seconds=100)
sid = open(f"{E}/sid").read().strip() if os.path.exists(f"{E}/sid") else ""
for needle, what in [("🍩 Claude 쿼타 소진", "says WHY it happened"),
                     ("(유료)", "discloses the cost"),
                     ("자동 복귀", "promises the return trip"),
                     ("▶ OpenRouter: haiku", "ccd took over, naming the models")]:
    if needle in out: ok(what)
    else: bad(what, out[-400:])
if "같은 대화를 OpenRouter에서 이어갑니다" in out:
    ok("took the resume path, not a fresh session")
else: bad("resume path", "banner said it started fresh — the transcript was not found")
if sid and f"--resume {sid}" in out or "이어갑니다" in out:
    ok(f"relaunched the same conversation (session {sid[:8]}…)")
else: bad("resume", f"sid={sid}")

lines = [l for l in out.splitlines() if l.strip()]
banner = [i for i, l in enumerate(lines) if "🍩 Claude 쿼타 소진" in l]
if banner:
    span = lines[banner[0]:banner[0] + 6]
    n = sum(1 for l in span if l.strip().startswith("▶") or "/model 로" in l or "회복되면" in l)
    if n <= 4: ok(f"the announcement is {n} lines, not a paragraph")
    else: bad("verbosity", "\n".join(span))

head("6. quota recovers → back on the subscription")
if "Claude 쿼타 회복" in out:
    ok("the return trip fires by itself")
    if "과금 종료" in out: ok("and says the OpenRouter charge stopped")
    else: bad("recovery wording", out[-300:])
    if "구독으로 이어갑니다" in out or "구독으로 돌아왔습니다" in out:
        ok("back on the subscription, same conversation")
else:
    rs = f"{HOME}/.claude/ccd/run-state.json"
    state = json.load(open(rs)) if os.path.exists(rs) else {}
    diag = {k: state.get(k) for k in
            ("last_five_hour_percent", "last_five_hour_reset",
             "recovery_notified_window", "recovery_notified_reset")}
    bad("return trip", f"run-state: {diag}\n      tail: {out[-200:]}")

head("7. cleanup takes everything back")
rc, out = run(f"{PLUG}/bin/ccd setup --no-auto", shim_on_path=False)
zshrc = open(f"{HOME}/.zshrc").read()
if "ccd-auto-handoff-path" not in zshrc and "ccd/bin:$PATH" not in zshrc:
    ok("the PATH line is gone")
else: bad("cleanup", zshrc)
if zshrc.strip() == "# sandbox zshrc":
    ok("the startup file is byte-identical to before the install")
else: bad("cleanup", repr(zshrc))
if not os.path.exists(f"{HOME}/.claude/ccd/bin/claude"):
    ok("the launcher is gone")
else: bad("cleanup", "launcher survived")
import glob
left = glob.glob(f"{HOME}/.claude/ccd/handoff-*.json")
if not left: ok("no handoff state left behind")
else: bad("cleanup", str(left))

print("\n" + "─" * 60)
print(f"\033[1m{len(passed)} passed, {len(failed)} failed\033[0m")
for f in failed: print(f"  ✗ {f}")
sys.exit(1 if failed else 0)
