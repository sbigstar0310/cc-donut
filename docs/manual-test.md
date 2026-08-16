# 멀티 계정 수동 테스트 (실제 터미널)

자동 테스트 235개가 통과해도 확인되지 않는 것들이 있다: 진짜 키체인, 진짜 계정 2개, 진짜 `/login`, 진짜 대화 복원. 이 문서는 그걸 순서대로 확인한다.

**전부 작업 트리에서 직접 실행한다.** 설치된 플러그인(현재 0.2.2)은 건드리지 않으므로, 테스트 중 문제가 생겨도 지금 쓰는 Claude Code 환경은 그대로다.

```sh
cd ~/Desktop/02_Projects/cc-donut
```

---

## ⚠️ 시작 전에 — 크레덴셜 백업

Stage 4부터는 **실제 로그인 크레덴셜을 바꾼다.** 잘못되면 로그아웃될 수 있으니 되돌릴 수단을 먼저 만든다.

```sh
security find-generic-password -s "Claude Code-credentials" -w > ~/claude-creds-backup.json
chmod 600 ~/claude-creds-backup.json
wc -c ~/claude-creds-backup.json          # 0이 아니어야 한다
```

**복구가 필요하면 (언제든):**

```sh
security add-generic-password -U -s "Claude Code-credentials" -a "$USER" \
  -w "$(cat ~/claude-creds-backup.json)"
```

> 이 백업 파일에는 refresh token이 평문으로 들어 있다. 테스트가 끝나면 지운다:
> `rm -P ~/claude-creds-backup.json`

**알아둘 것:** `ccd account add`를 실행하는 순간부터 `~/.claude/ccd/accounts/*.json`에 실제 refresh token이 mode 600 평문으로 저장된다. 설계상 의도된 동작이다(이식성 결정, `docs/multi-account.md` §9.1).

---

## Stage 1 — 아무것도 등록하지 않은 상태 (회귀 확인)

가장 중요한 확인. 기존 사용자에게 아무것도 안 바뀌어야 한다.

```sh
./bin/ccd-account list
#   기대: "No accounts registered. Run `ccd account add`."

./bin/ccd-account pick --json; echo "rc=$?"
#   기대: {"account": null, "reason": "no_candidate"}   rc=1  (즉시, 네트워크 없음)

echo '{"model":{"id":"claude-opus-5"},"workspace":{"current_dir":"/tmp"}}' | ./bin/ccd-statusline
#   기대: 평소 statusline 그대로. 계정 관련 줄이 추가되지 않아야 한다.
```

---

## Stage 2 — 계정 2개 등록

```sh
# 1) 지금 로그인된 계정(개인 구글)
./bin/ccd-account add
#   --name 없이 실행 → 이메일 local part가 이름이 되고 label도 자동으로 붙는다
```

이제 **다른 터미널에서** 두 번째 계정으로 로그인:

```sh
claude
# /login  → 두 번째 계정 선택 → 완료되면 /exit
```

돌아와서:

```sh
./bin/ccd-account add
./bin/ccd-account list
```

기대하는 모습:

```
Claude accounts
  ○ personal       p1   5h 48% · 7d 77%   personal@example.com
  ● work           p2   5h  3% · 7d 12%   work@example.com
```

확인 포인트:

- 이름과 label이 **자동으로** 붙었나 (`--name`, `--label` 안 줬다)
- `●`가 방금 로그인한 두 번째 계정에 있나
- 두 계정의 쿼타가 각각 다르게 나오나 → **비활성 계정 쿼타 조회가 실제로 된다는 증거**

```sh
ls -la ~/.claude/ccd/accounts/     # 디렉터리 700, 파일 600
```

---

## Stage 3 — `/login` 자동 감지 (추가 명령 없음)

이번 구현의 핵심. 사용자가 ccd를 거치지 않고 계정을 바꿔도 알아서 따라와야 한다.

```sh
./bin/ccd-account current          # 지금 계정 이름
```

다른 터미널에서 `claude` → `/login` → **개인 계정**으로 전환 → `/exit`.

돌아와서 **아무 명령도 추가로 치지 않고**:

```sh
./bin/ccd-account current
#   기대: 첫 번째 계정 이름. (두 번째 계정이 나오면 실패)

cat ~/.claude/ccd/accounts/.active
#   기대: 같은 값. 포인터가 스스로 고쳐졌다.
```

이게 되면 §12.0의 "저장소 조용히 깨짐" 문제가 실제로 막힌 것이다.

---

## Stage 4 — 실제 스왑 (크레덴셜이 바뀐다)

```sh
./bin/ccd-account use <다른-계정-이름>
./bin/ccd-account current          # 바뀌었는지
```

**MCP 로그인이 살아있는지 반드시 확인** — 이게 통째 덮어쓰기와 surgical merge를 가르는 지점이다:

```sh
python3 -c "
import json,subprocess
d=json.loads(subprocess.run(['security','find-generic-password','-s','Claude Code-credentials','-w'],
    capture_output=True,text=True).stdout)
print('mcpOAuth servers:', sorted((d.get('mcpOAuth') or {}).keys()))
"
#   기대: notion|... , slack|... 이 그대로 있어야 한다. 비어 있으면 실패.
```

그리고 실제로 그 계정으로 동작하는지:

```sh
claude          # 새 터미널에서. /status 로 로그인 계정 확인
```

원래 계정으로 복귀:

```sh
./bin/ccd-account use <원래-계정>
```

---

## Stage 5 — 전환 판단 로직 (드라이런, 세션 영향 없음)

"쿼타가 죽으면 B로 갈까, OpenRouter로 갈까"를 실제로 소진시키지 않고 확인한다. 쿼타 캐시를 직접 심으면 된다.

```sh
Q=~/.claude/ccd/accounts-quota.json
cp $Q $Q.bak 2>/dev/null || true
A=$(./bin/ccd-account current)
B=$(ls ~/.claude/ccd/accounts/*.json | xargs -n1 basename | sed 's/.json//' | grep -v "^$A$" | head -1)

seed() { python3 -c "
import json,time,sys
now=int(time.time())
json.dump({sys.argv[1]:{'status':'ok','checked_at':now,'five_hour_percent':int(sys.argv[3]),'seven_day_percent':int(sys.argv[4])},
           sys.argv[2]:{'status':'ok','checked_at':now,'five_hour_percent':int(sys.argv[5]),'seven_day_percent':int(sys.argv[6])}},
          open('$Q','w'))" "$A" "$B" "$@"; }

# A 소진, B 여유 → B로 가야 한다
seed 99 99 10 20 && ./bin/ccd-account pick --json
#   기대: {"account":"<B>", ..., "reason":"headroom"}

# 둘 다 소진 → OpenRouter (rc=1)
seed 99 99 99 99 && ./bin/ccd-account pick --json; echo "rc=$?"
#   기대: {"account":null,"reason":"all_exhausted"}  rc=1

# B의 5h는 비었지만 7일이 꽉참 → 가면 안 된다 (몇 분 뒤 또 죽으므로)
seed 99 99 5 99 && ./bin/ccd-account pick --json; echo "rc=$?"
#   기대: all_exhausted, rc=1

# 런처의 방문 집합이 전달되는 경로
seed 99 99 10 20 && ./bin/ccd-account pick --exclude "$B" --json; echo "rc=$?"
#   기대: no_candidate, rc=1

mv $Q.bak $Q 2>/dev/null || rm -f $Q          # 캐시 원복
```

---

## Stage 6 — statusline · doctor 표시

```sh
echo '{"model":{"id":"claude-opus-5"},"workspace":{"current_dir":"/tmp"}}' | ./bin/ccd-statusline
```

계정이 2개 이상이므로 이제 줄이 하나 붙어야 한다:

```
● claude:<현재계정> │ spare <다른계정> 20%
```

```sh
./bin/ccd doctor 2>&1 | sed -n '/Spare Claude accounts/,/^$/p'
```

- 계정별 쿼타
- 재로그인 필요한 계정이 있으면 빨간 경고
- 저장소 퍼미션 검증

---

## Stage 7 — 진짜 end-to-end 핸드오프 (선택, 가장 확실함)

실제 런처가 세션을 끝내고 → 계정을 갈아끼우고 → **같은 대화를 복원**하는 전 과정.

쿼타를 실제로 소진시킬 수 없으므로, 런처가 감시하는 상태 파일을 직접 무장시킨다. 스모크 테스트가 하는 것과 동일한 경로다.

터미널 하나만 쓴다. 신호는 **세션이 자기 자신에게** 보내므로 다른 프로세스를 맞힐
길이 없다 — Claude Code 가 `CLAUDE_PID` 를 자식에게 내려주기 때문이다.

토큰을 고정해서 런처를 띄운다(고정하지 않으면 매번 랜덤이라 상태 파일 경로를 모른다):

```sh
cd ~/Desktop/02_Projects/cc-donut
CCD_HANDOFF_TOKEN=00000000000000000000000000000001 ./bin/ccd-handoff
```

Claude Code가 뜨면 **아무 대화나 한 번 주고받는다** (복원할 내용이 있어야 하므로).

그 다음, **같은 세션 안에서** 프롬프트에 `!` 를 붙여 실행한다. 세션 ID 도 환경변수로
들어오므로 따로 옮겨 적을 필요가 없다. `<옮겨갈 계정 이름>` 만 바꾼다:

```
!python3 -c "import json,os,sys;p=os.path.expanduser('~/.claude/ccd/handoff-00000000000000000000000000000001.json');json.dump({'armed':True,'token':'0'*31+'1','direction':'to_account','account':sys.argv[1],'session_id':sys.argv[2],'cwd':os.getcwd()},open(p,'w'));os.chmod(p,0o600)" <옮겨갈 계정 이름> "$CLAUDE_CODE_SESSION_ID" && ps -p $CLAUDE_PID -o pid=,comm= && kill -HUP $CLAUDE_PID
```

`ps` 가 `<pid> claude` 한 줄만 찍고 나서 신호가 간다. 다른 창은 건드릴 수 없다.

> **반드시 한 줄로 유지할 것.** `!` 로 넘긴 명령은 `eval` 을 거치므로 여러 줄짜리
> 따옴표 문자열은 `parse error near '\n'` 으로 죽는다. 같은 이유로 값은 환경변수가
> 아니라 `sys.argv` 로 넘긴다 — `TARGET=x python3 …` 형태의 셸 변수는 export 되지
> 않아 `os.environ['TARGET']` 이 `KeyError` 를 낸다.

<details>
<summary>두 번째 터미널에서 보내야 한다면 (권장하지 않음)</summary>

> ## 🚨 `pkill` 을 쓰지 말 것
>
> ```sh
> pkill -HUP -f "claude"        # ← 절대 금지
> pkill -HUP -f "claude" -n     # ← 더 나쁨. -n 이 안 먹는 정도가 아니다
> ```
>
> macOS(BSD) 의 `pkill`/`pgrep` 은 **첫 비옵션 인자를 패턴으로 잡고 옵션 파싱을 멈춘다.**
> 패턴 뒤의 `-n` 은 "가장 최근 하나만" 으로 동작하지 않고 **추가 패턴으로 해석되어
> 매칭 범위가 오히려 넓어진다.** 실측:
>
> ```
> pgrep -f "sleep 30" -n   → 14개 매칭
> pgrep -n -f "sleep 30"   →  1개 매칭
> ```
>
> 게다가 `-f` 는 명령줄 전체를 본다. Cursor 의 확장 경로
> (`.../anthropic.claude-code/...`) 나 claude 를 띄운 다른 터미널이 전부 걸리므로
> **에디터와 모든 터미널 창이 한 번에 닫힌다.** 반드시 PID 를 특정해서 보낼 것.

**터미널 1** 의 세션 안에서 그 세션 자신의 PID 를 묻는다. Claude Code 가 `CLAUDE_PID`
를 내려주므로 이게 가장 확실하다 — 프롬프트에 `!` 를 붙여 실행:

```
!echo "PID=$CLAUDE_PID"
```

**터미널 2** — 무장하고, **보낼 대상을 눈으로 확인한 뒤** 신호를 보낸다:

```sh
SID=<터미널1의 session id>
TARGET=<옮겨갈 계정 이름>
PID=<터미널1에서 확인한 CLAUDE_PID>

python3 -c "import json,os,sys;p=os.path.expanduser('~/.claude/ccd/handoff-00000000000000000000000000000001.json');json.dump({'armed':True,'token':'0'*31+'1','direction':'to_account','account':sys.argv[1],'session_id':sys.argv[2],'cwd':os.getcwd()},open(p,'w'));os.chmod(p,0o600)" "$TARGET" "$SID"

# 보내기 전에 확인 — comm 이 정확히 'claude' 인 프로세스 하나여야 한다
ps -p "$PID" -o pid=,tty=,comm=

kill -HUP "$PID"
```

`CLAUDE_PID` 를 못 얻었다면, 터미널 1 에서 미리 `tty` 를 찍어두고 **그 tty 안에서만**
찾는다 (`-f` 없이, 이름 정확 일치):

```sh
TTY1=ttys012        # 터미널 1 에서 `tty` 로 확인한 값
ps -t "$TTY1" -o pid=,comm= | awk '$2=="claude"{print $1}'
```

</details>

터미널 1에서 기대하는 동작:

```
[ccd] ✓ <TARGET> 계정으로 갈아탑니다 — 구독 그대로, 대화 그대로 이어집니다

▶ ✓ 쿼타 소진 — <TARGET> 계정으로 같은 대화를 이어갑니다 (구독, 무과금)
```

그리고 **직전 대화가 그대로 복원된 채** 새 세션이 뜬다. `/status`로 계정이 바뀌었는지 확인.

터미널 1 이 통째로 죽으면 런처도 같이 끌려가므로 스왑은 **일어나지 않는다.** 그때는
`./bin/ccd-account current` 가 그대로일 뿐 저장소는 멀쩡하니, 다시 하면 된다.

---

## 정리

```sh
# 계정 등록을 남기지 않으려면
./bin/ccd-account rm <name>          # 파일을 덮어쓴 뒤 삭제한다

# 백업 파일 제거 (refresh token 평문)
rm -P ~/claude-creds-backup.json

# 쿼타 캐시
rm -f ~/.claude/ccd/accounts-quota.json
```

`ccd setup --auto`는 이 문서에서 한 번도 실행하지 않았으므로 PATH와 shim은 건드려지지 않았다. 실제로 자동 핸드오프까지 켜보려면 그때 실행하고, 되돌릴 때는 `ccd setup --no-auto`.

---

## 실패했을 때 볼 것

| 증상                                | 확인                                                                                                                                                      |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `add`가 이름을 자동으로 못 지음     | `python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claude.json')))['oauthAccount'].keys())"` — `accountUuid`/`emailAddress`가 있는지 |
| `/login` 후에도 `current`가 안 바뀜 | 같은 명령으로 `profileFetchedAt` 확인. 스왑 시각(`~/.claude/ccd/accounts/.active-at`)보다 커야 identity가 채택된다                                        |
| `pick`이 계속 `all_exhausted`       | `cat ~/.claude/ccd/accounts-quota.json` — `status`가 `dead`면 재로그인 필요, `error`면 네트워크                                                           |
| 스왑 후 MCP 로그아웃                | surgical merge 실패. Stage 4의 python 스니펫 출력을 남길 것                                                                                               |
| 계정이 `needs re-login`             | `claude` → `/login` → `./bin/ccd-account add`(같은 계정이면 자동으로 제자리 갱신된다)                                                                     |
