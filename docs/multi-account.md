# 멀티 계정 폴백 설계 (multi-account handoff)

> 상태: **구현됨** (ccd 0.4.0)
> 작성일: 2026-08-16
>
> 구현하면서 설계에서 바뀐 지점은 §13에 정리했다.

## 1. 목표

계정이 여러 개인 사용자가 한 계정의 쿼타를 소진했을 때, **바로 OpenRouter로 넘어가지 않고 여유가 있는 다른 Claude 계정으로 먼저 이동**한다. 등록된 모든 계정이 소진된 뒤에야 기존 OpenRouter 백본으로 떨어진다.

```
계정 A 소진
  ├─ 등록된 다른 계정 중 여유분 있음  → 계정 B 로 스왑, 같은 대화 계속   (구독, 무과금)
  └─ 전부 소진                        → OpenRouter 백본                (유료, 최종 방어선)
```

### 비목표

- 로드 밸런싱. ccd는 **소진 시 탈출** 도구다. "덜 쓴 계정으로 미리 분산"은 cswap/clauth의 영역이고, ccd가 흉내내면 정체성이 흐려진다. 전환은 오직 소진 시점에만 일어난다.
- 세션 중 라이브 스왑. ccd는 세션 경계에서만 크레덴셜을 만진다 (§6 참조).
- 계정 공유 지원. 한 사람이 소유한 여러 구독을 대상으로 한다 (§9).

## 2. 현재 구조 (변경 대상)

| 파일 | 역할 |
|---|---|
| `bin/ccd-handoff` | `~/.local/bin/claude` 로 설치되는 런처. 실제 claude를 돌리고 exit 129를 잡아 반대편 백본으로 relaunch 하는 루프 |
| `scripts/quota-guard.sh` | 훅 (`UserPromptSubmit`/`PostToolUse`/`StopFailure`/`SessionEnd`). 소진·회복을 판단하고 handoff 상태를 쓴 뒤 claude에 SIGHUP |
| `bin/ccd` | OpenRouter 백본 런처 (`ANTHROPIC_BASE_URL` 등을 세팅하고 claude exec) |
| `bin/ccd-statusline` | 상태 표시 |

### handoff 프로토콜 (현행)

1. 런처가 `CCD_HANDOFF`(32 hex 토큰)와 `CCD_HANDOFF_STATE`(그 토큰이 함의하는 경로)를 export
2. 훅이 소진을 감지 → `handoff-<token>.json` 을 atomic·600 으로 기록 → claude 에 `SIGHUP`
3. claude 가 SessionEnd 훅 실행 후 **129** 로 종료
4. 런처가 상태 파일을 읽고 `direction` 에 따라 반대편 백본에서 `--resume <sid>` 로 재기동

`direction` 은 현재 `to_fallback` | `to_subscription` 두 값뿐이다. **이 설계는 여기에 세 번째 값을 추가하는 것이 전부다.** 인터록, hop 카운터, transcript 존재 검사, headless 거부, 복원 실패 시 새 세션 폴백은 전부 그대로 재사용된다.

## 3. 검증된 사실

구현 전에 실측한 값들. 이 설계의 전제이므로 깨지면 재설계가 필요하다.

### 3.1 비활성 계정의 쿼타를 조회할 수 있다 ★

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Accept: application/json
```

토큰만 있으면 되고, 그 계정이 활성일 필요가 없다. **"다른 계정에 여유가 있을 때만 넘어간다"는 요구사항이 성립하는 유일한 근거.** 이게 없으면 눈감고 스왑한 뒤 실패하면 되돌아오는 수밖에 없다.

(출처: claude-dashboard 1.30.1 `dist/check-usage.js` — ccd가 이미 quota-cache를 얻는 데 쓰고 있는 바로 그 경로)

### 3.2 크레덴셜 blob 구조

macOS: Keychain generic password, service `Claude Code-credentials`
Linux: `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`

```jsonc
{
  "mcpOAuth": {                      // ← 계정 무관. notion/slack 등 MCP 서버 로그인
    "notion|<hash>": { "serverName": ..., "accessToken": ..., ... },
    "slack|<hash>":  { ... }
  },
  "claudeAiOauth": {                 // ← 계정 고유. 이것만 갈아끼워야 한다
    "accessToken": "str",
    "refreshToken": "str",
    "expiresAt": 1234567890123,      // ms epoch
    "refreshTokenExpiresAt": 1234567890123,
    "scopes": ["user:inference", "user:profile", "user:sessions:claude_code", ...],
    "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_5x"
  }
}
```

**blob 전체를 덮어쓰면 안 된다.** `mcpOAuth` 를 같이 날리면 전환할 때마다 사용자의 Notion/Slack MCP 로그인이 풀린다. 스왑은 `claudeAiOauth` 서브트리만 교체하는 **surgical merge** 여야 한다. (claude-swap 도 같은 결론에 도달해 있다.)

### 3.3 토큰 수명 — 이 기능의 최대 리스크

실측 (2026-08-16):

| 토큰 | 수명 |
|---|---|
| `accessToken` | **약 8시간** |
| `refreshToken` | **약 8.5일** (204.6h) |

파생되는 제약:

- 등록만 해두고 8시간 방치한 계정은 access token이 죽어 **쿼타 조회 자체가 불가능**하다 → refresh 필수
- refresh token은 **사용 시마다 회전(rotate)** 한다. 새 값을 못 받아 적으면 그 계정은 로그아웃된다
- **8.5일 이상 손대지 않은 계정은 완전히 죽는다.** 사용자가 `claude /login` 을 다시 해야 함 → 주기적 keep-alive 필요 (§7.2)

### 3.4 refresh 엔드포인트

```
POST https://console.anthropic.com/v1/oauth/token
Content-Type: application/json
User-Agent: claude-cli/<설치된 Claude Code 버전> (external, cli)

{"grant_type":"refresh_token","refresh_token":"…","client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}
```

응답: `access_token`, `refresh_token`, `expires_in`.

**User-Agent가 전부다.** 정문이 공식 클라이언트 UA가 아닌 요청을 429로 조인다 — 하루
1회도 막히고, 같은 IP·같은 client_id·같은 파이썬 스택에서 UA만 바꾸면 통과한다
(2026-03부터, anthropics/claude-code#38248 등 다른 도구도 동일). 0.4.0은 `anthropic`
이라고 보내서 16일간 매 갱신이 죽었다. 갱신하는 토큰도 client_id도 Claude Code 것이니
그 클라이언트로 자기소개한다. 버전은 PATH의 `claude` 심링크가 가리키는 이름(네이티브
설치는 `versions/<x.y.z>`), PATH에 없으면 버전 저장소의 최신. 하드코딩하지 않는다 —
버전은 매주 바뀐다.

주의: Anthropic이 토큰 교환을 `https://platform.claude.com/v1/oauth/token` 으로 옮기는 중이라는 보고가 있다. **두 엔드포인트를 순차 시도**하고, 성공한 쪽을 캐시한다.

이건 공개 문서가 없는 비공식 표면이다. 깨질 수 있다 — 하지만 깨져도 치명적이지 않다: refresh 실패는 "해당 계정 skip" 으로 강등되고, 기존 OpenRouter 폴백이 그대로 살아 있다 (§8).

## 4. 상태 파일 스키마

### 4.1 계정 저장소 `~/.claude/ccd/accounts/<name>.json` (mode 600)

```jsonc
{
  "name": "personal",
  "label": "you@example.com",           // 표시용. oauthAccount.emailAddress 에서 자동
  "priority": 1,                        // 낮을수록 우선. 등록 순서가 기본값
  "claudeAiOauth": { … },               // §3.2 의 서브트리 그대로
  "added_at": 1755300000,
  "refreshed_at": 1755300000,
  "subscription_type": "max",
  "rate_limit_tier": "default_claude_max_5x"
}
```

`accounts/.active` 에 현재 활성 계정 이름을 평문 한 줄로 둔다. 어느 계정이 돌고 있는지는 blob 비교가 아니라 이 파일이 진실의 원천이다 (토큰이 회전해도 안정적).

### 4.2 쿼타 캐시 `~/.claude/ccd/accounts-quota.json` (mode 600)

```jsonc
{
  "personal": {
    "five_hour_percent": 100, "seven_day_percent": 77,
    "five_hour_reset": "2026-08-16T12:10:00Z",
    "seven_day_reset": "2026-08-18T04:00:00Z",
    "checked_at": 1755300000,
    "uuid": "…",                        // 이 판정이 설명하는 계정 (account_uuid)
    "cred": "9f2c1a4b7e0d6538",         // 측정 대상 access token 의 SHA-256 앞 16자
    "status": "ok"                      // ok | stale | dead | error
  },
  "work": { … }
}
```

`status` 의미:

- `ok` — 최근 조회 성공. 전환 후보
- `stale` — access token 만료, 아직 refresh 안 함. 필요 시 refresh 시도
- `dead` — refresh token 만료(8.5일 초과) 또는 refresh 거부. **전환 후보에서 제외**, `ccd doctor` 가 재로그인 안내
- `error` — 네트워크/서버 오류. 후보에서 제외하되 dead 로 승격하지 않음

### 4.3 handoff 상태 확장

```jsonc
{
  "armed": true,
  "token": "<32 hex>",
  "direction": "to_account",        // ← 신규
  "account": "work",                // ← 신규. to_account 일 때만
  "session_id": "…",
  "cwd": "…",
  "armed_at": 1755300000
}
```

기존 두 방향의 스키마는 그대로. `account` 는 `to_account` 에서만 읽는다.

## 5. 계정 선택 알고리즘

`quota-guard.sh` 의 `StopFailure` 분기에서 호출.

```
pick_account(excluded):
  후보 = 등록된 모든 계정 − 현재 활성 계정 − excluded   // excluded 는 §5.2
  각 후보에 대해:
      캐시가 CANDIDATE_TTL(=300s) 이내면 캐시 사용
      아니면: access token 유효? → 조회
              만료됨?           → refresh 시도 → 조회
              refresh 실패      → status=dead/error, 제외
  여유 있음 = five_hour_percent < HEADROOM(=90) AND seven_day_percent < HEADROOM
  여유 있는 후보 중 priority 오름차순, 동률이면 max(5h,7d) 오름차순으로 1개 선택
  없으면 None
```

**7일 창을 반드시 같이 본다.** 5h가 방금 리셋됐어도 7d가 99%면 그 계정은 몇 분 안에 다시 죽는다 — 그 상태로 스왑하면 hop 카운터만 태우고 OpenRouter에 도착하며, 사용자는 이유 없는 화면 전환을 두 번 겪는다.

`HEADROOM=90` 은 `ARM_THRESHOLD=95` 보다 낮게 잡는다. 95에서 탈출하는데 92짜리 계정으로 가면 곧바로 또 탈출한다.

### 5.2 루프 방지 — 횟수가 아니라 방문 집합으로

현행 `ccd-handoff` 는 `MAX_HOPS=3` 으로 연속 relaunch 횟수를 센다. 백본이 둘뿐일 때는 맞는 값이었지만, **계정이 늘면 이 상수가 곧 사다리 길이의 상한이 된다.** 계정 3개면 A→B→C 만으로 상한에 닿아 정작 최종 폴백인 OpenRouter 로 못 간다 — 루프 방지 장치가 탈출을 막는 셈이다. 계정 수는 사용자마다 다르므로 이 값은 **하드코딩할 수 없다.**

횟수를 세는 대신 **한 burst 안에서 이미 방문한 목적지를 기억한다.**

- **burst** = 사이에 의미 있는 작업(`HOP_RESET_SECONDS` 이상 지속된 세션)이 없이 연달아 일어난 relaunch 묶음
- 목적지 공간은 유한하고 상태에서 파생된다: `{등록된 계정 이름들} ∪ {fallback}`
- relaunch 할 때마다 목적지를 `visited` 에 넣는다
- **`visited` 를 `pick_account()` 의 `excluded` 로 그대로 넘긴다**
- 세션이 `HOP_RESET_SECONDS` 이상 살아남으면 `visited` 를 통째로 비운다 (기존 `hops=0` 과 같은 자리, 같은 의미)

이 규칙의 성질:

- **자기 스케일링.** 계정 2개면 최대 3홉(A→B→OR), 5개면 최대 6홉. 조정할 상수가 없다
- **자연스러운 배수(drain).** 소진된 계정이 후보에서 계속 빠지므로 사다리가 알아서 OpenRouter 쪽으로 흘러간다. 별도의 "이제 폴백으로 가라" 판단이 필요 없다
- **핑퐁에는 더 엄격하다.** A→B→A 는 세 번째 홉에서 즉시 잡힌다. 횟수 카운터라면 3에 우연히 걸려서 잡혔을 뿐이고, `MAX_HOPS` 를 5로 올린 순간 놓쳤을 것이다
- **정상 이동은 더 관대하다.** A→B→OR 처럼 목적지가 전부 다른 3홉은 (캐시가 낡아 B가 실제로는 소진이었던 경우) 통과된다. 기존 카운터는 이걸 막았다

burst 안에서 갈 곳이 전부 소진되면 — 즉 `fallback` 마저 `visited` 에 있으면 — 그때 멈추고 기존 안내를 낸다:

```
ccd: 갈 수 있는 백본을 모두 시도했습니다 — 중단합니다.
     이어서 하려면: claude --resume <sid>
```

**런처 → 훅 전달.** `visited` 는 런처(`ccd-handoff`)의 상태이고 `pick_account()` 는 훅(`quota-guard.sh`)에서 돈다. 서로 다른 프로세스이므로 런처가 relaunch 시 `CCD_BURST_VISITED` (콤마 구분)를 export 하고, 훅이 그대로 `ccd-account pick --exclude` 로 넘긴다. `CCD_HANDOFF` / `CCD_HANDOFF_STATE` 를 넘기는 기존 방식과 동일한 패턴이라 새 메커니즘이 아니다.

**런어웨이 백스톱.** `visited` 가 올바르면 burst 길이는 `|계정| + 1` 로 이미 유한하다. 그래도 저장소가 도중에 변하거나 버그가 나는 경우를 대비해 절대 상한을 하나 둔다 — 단 이것도 매 홉마다 현재 저장소에서 다시 계산한다 (`등록 계정 수 + 2`). **이건 정책 노브가 아니라 "무언가 고장났다" 는 트립와이어**이며, `visited` 가 정상 동작하는 한 도달하지 않는다. 상수로 고정된 정책값은 이 설계에 남지 않는다.

`HOP_RESET_SECONDS=60` 은 그대로 둔다. 이건 시간 임계값이지 사다리 길이에 대한 가정이 아니라서 계정 수와 함께 변하지 않는다.

## 6. 크레덴셜 스왑

### 6.1 타이밍 — ccd의 구조적 이점

cswap/clauth 는 **claude 가 살아 있는 동안** 키체인을 갈아끼운다. 그래서 Claude Code 자신의 토큰 refresh 와 경합하고, 그걸 막으려 크레덴셜 락을 잡는 코드가 필요하다.

ccd 는 다르다. 스왑은 **`ccd-handoff` 루프 안에서, claude 가 129로 종료한 뒤 relaunch 직전에** 일어난다. 그 순간 크레덴셜을 만지는 프로세스가 없다. **경합 자체가 존재하지 않는다.**

이건 이 기능을 ccd에 넣는 가장 큰 이유다.

단, 다른 터미널에서 별개의 claude 세션이 돌고 있을 수 있다. 그 세션은 이미 메모리에 토큰을 갖고 있어 즉시 깨지지는 않지만, 다음 refresh 때 남의 계정으로 refresh 하게 된다. → **다중 세션 감지 시 경고 후 진행**, 문서에 명시 (§8 표).

### 6.2 절차

```
swap_to(name):
  1. 락 획득          ~/.claude/ccd/accounts/.lock  (flock, 5s 타임아웃)
  2. 현재 blob 읽기    keychain(macOS) 또는 .credentials.json(Linux)
  3. 현재 계정 백업    live blob 의 claudeAiOauth → accounts/<active>.json 에 갱신 저장
                      (Claude Code 가 세션 중 회전시킨 최신 토큰을 잃지 않기 위함)
  4. surgical merge   new_blob = {**live_blob, "claudeAiOauth": target.claudeAiOauth}
                      ※ mcpOAuth 를 비롯한 모든 다른 키는 live 값 유지
  5. atomic write     macOS: security add-generic-password -U -s "Claude Code-credentials" …
                      Linux: tmp 파일 → chmod 600 → os.replace
  6. .active 갱신
  7. 락 해제
```

3번이 중요하다. 이걸 빼면 계정 A로 8시간 작업하며 회전된 토큰들이 버려지고, A로 돌아올 때 저장소의 낡은 refresh token을 쓰게 된다.

### 6.3 라이브 blob 의 위치 (§9.1 의 저장소 결정과 별개)

혼동하기 쉬운 두 가지를 구분한다:

| | 위치 | 주인 |
|---|---|---|
| **ccd 계정 저장소** | `~/.claude/ccd/accounts/*.json` — **모든 플랫폼에서 파일** (§9.1) | ccd |
| **라이브 크레덴셜 blob** | Claude Code 가 읽는 바로 그곳 | Claude Code |

저장소를 파일로 통일한다고 해서 라이브 blob 까지 파일에 쓸 수 있는 건 아니다. **스왑이 효력을 가지려면 Claude Code 가 실제로 읽는 곳에 써야 하고**, 그건 macOS 에서 Keychain(`Claude Code-credentials`), 그 외에서 `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json` 이다. 이 분기는 §9.1 이 피하려던 "저장소 이원화" 가 아니라 외부 계약이므로 선택의 여지가 없다 — 대신 `live_read()` / `live_write()` 단 두 함수에 가둔다.

**macOS 에서 파일이 함께 존재하면 둘 다 갱신한다.** Claude Code 는 키체인 접근이 실패하면 파일로 폴백하므로, 한쪽만 쓰면 그 폴백이 이전 계정을 되살려 "전환했는데 안 바뀐다" 는 최악의 증상을 만든다.

## 7. 토큰 refresh 정책

### 7.1 원칙 — 최소한으로, 직렬로

refresh token 이 회전하므로 refresh 는 **파괴적 연산**이다. 두 프로세스가 동시에 같은 계정을 refresh 하면 하나는 무효한 토큰을 쥐게 된다 (`anthropics/claude-code#54443` 이 보고하는 증상과 동형).

- 훅의 매 tick 마다 refresh 하지 않는다. 오직 두 시점: **(a) 전환 판단이 실제로 필요한 순간**, **(b) keep-alive 스케줄**
- 항상 §6.2 의 `.lock` 아래에서
- **활성 계정은 절대 ccd가 refresh 하지 않는다.** 그건 Claude Code 소유다
- 새 `refresh_token` 을 받으면 access token 을 쓰기 **전에** 먼저 디스크에 기록한다. 순서를 뒤집으면 크래시 시 계정이 죽는다

### 7.2 keep-alive

refresh token 8.5일 만료 때문에, 등록만 해두고 안 쓰는 계정은 조용히 죽는다. 사용자는 정작 필요한 순간에 그걸 발견한다 — ccd가 존재 이유로 삼는 실패 모드 그 자체.

`quota-guard.sh` 가 비활성 계정들을 refresh 한다. 매 refresh 가 새 8.5일짜리 토큰을 발급하므로 무기한 살아 있다. 훅은 어차피 매 프롬프트마다 도니 별도 데몬이 필요 없다.

한 패스는 락 안의 한 트랜잭션이다 — due 판정, 계정 읽기, refresh, 도장까지. 훅은 프롬프트와 툴 틱마다 뜨니 패스 여럿이 같은 초에 시작하는데, 락 밖에서 판정하면 전부 게이트를 통과해 같은 refresh token을 읽고, 첫 놈이 회전시킨 뒤 나머지는 죽은 토큰을 제출한다. 이미 진행 중이면 조용히 물러난다.

도장은 시도 **후**에, 결과와 함께 찍는다. 성공이면 24시간, 실패면 15분부터 2배씩 늘려 24시간 상한. 시도 전에 찍으면 실패한 패스가 하루치를 통째로 태워서, 토큰 수명 8.5일 동안 기회가 8번뿐이다 — 0.4.0이 정확히 그렇게 죽었다.

경고는 에러 종류가 아니라 **나이**로 낸다. 3일 이상 갱신이 안 된 계정이 있으면 `accounts-stale` 에 문장을 남기고, 다음 프롬프트 틱이 `additionalContext` 로 전달한다(4시간에 1회, flock으로 동시 프롬프트에서도 한 번만). 429든 500이든 끊긴 연결이든 사용자 노출은 같고, 에러 종류로 걸렀던 0.4.0은 429를 한 마디도 안 하고 삼켰다. 회복되면 파일이 사라지고 경고도 사라진다.

## 8. 실패 모드

| 상황 | 동작 |
|---|---|
| 다른 계정 전부 소진 | `to_fallback` — 기존 OpenRouter 경로. 현행과 동일 |
| 등록된 계정 없음 | `to_fallback`. 기능 도입 전과 완전히 동일하게 동작 |
| 후보 계정 refresh 실패 | `status=dead`, 후보에서 제외, 다음 후보로. 전부 실패하면 `to_fallback` |
| 쿼타 조회 네트워크 오류 | `status=error`, 제외. **낙관적 스왑을 하지 않는다** — 읽히지 않는 값은 절대 "여유 있음" 이 아니다 (기존 `quota_peak` 의 원칙과 동일) |
| 스왑 도중 크래시 | `.lock` + atomic write 로 blob 은 항상 온전. `.active` 가 어긋나면 다음 실행 시 live blob 과 대조해 복구 |
| 스왑 후 relaunch 가 즉시 실패 | 기존 로직 재사용: 15초 내 비정상 종료면 새 세션으로 이어가고 `--resume <sid>` 안내 |
| 다른 터미널에 세션 존재 | 경고 출력 후 진행. 그 세션은 다음 refresh 때 계정이 바뀐다 |
| 무한 전환 루프 | §5.2 의 방문 집합이 커버. burst 당 각 목적지 1회로 제한되므로 계정 수와 무관하게 유한 |
| 계정 N개 전부 거치기 | 정상 동작. 방문 집합은 계정 수에 따라 자동으로 늘어나므로 사다리가 잘리지 않는다 |
| OpenRouter 키 없음 + 다른 계정 있음 | **전환은 가능해야 한다.** 현행 `handoff_ready()` 는 `have_key()` 를 무조건 요구하는데, `to_account` 경로에는 키가 필요 없다 → 조건 분리 필요 (§10) |

## 9. 보안

### 9.1 저장 방식 — 이식성을 위한 선택

토큰을 `~/.claude/ccd/accounts/*.json` 에 **mode 600 평문**으로 저장한다.

**이유는 이식성이다.** ccd 는 macOS 전용 도구가 아니다. Keychain 을 저장소로 삼으면 macOS 에만 존재하는 경로가 생기고, Linux·Windows(WSL)·컨테이너·원격 개발 환경에서는 어차피 파일 경로를 따로 구현해야 한다. 저장소가 둘이면 스왑·백업·복구·마이그레이션·`doctor` 진단이 전부 두 벌이 되고, 그중 한쪽만 테스트되는 상태로 굳는다. 단일 저장 방식이 이 기능 전체의 동작을 플랫폼과 무관하게 만든다.

**노출 범위는 macOS 로 한정된다.** Claude Code 자신이 Linux·Windows 에서는 이미 `~/.claude/.credentials.json` 에 mode 600 평문으로 refresh token 을 두고 있다. 즉 그 플랫폼들에서 ccd 의 저장소는 **기존과 정확히 동일한 보안 수준**이며 새로운 노출면을 만들지 않는다. Keychain 대비 강등이 발생하는 것은 macOS 한 곳뿐이다.

그 한 곳에서의 강등은 실재한다: 키체인은 잠금/ACL/프로세스 인증이 걸리지만 평문 파일은 사용자 권한으로 실행되는 모든 프로세스가 읽는다. refresh token 하나면 8.5일간 계정 전체를 쓸 수 있다. 완화책으로 좁히되, 없앨 수는 없다.

완화책:

- 디렉터리 `700`, 파일 `600`, 생성 시 umask 고정
- `ccd doctor` 가 퍼미션을 검증하고 느슨하면 실패 처리
- `.gitignore` / 백업 도구 제외 안내를 README 에 명시
- `ccd account rm` 은 파일 삭제 전 덮어쓰기(overwrite-then-unlink)
- 로그·에러 메시지에 토큰이 절대 새지 않도록: 모든 진단 출력은 토큰을 `sha256[:8]` 로만 표시

**향후 옵트인 경로 (열어둘 것):** 저장소 접근을 `account_load()` / `account_save()` 두 함수로 완전히 캡슐화한다. 스키마에 `"storage": "file"` 필드를 처음부터 넣어 혼재 상태를 구분할 수 있게 한다.

나중에 macOS 사용자가 원하면 `ccd account migrate --keychain` 으로 **선택** 할 수 있게 하되, 기본값은 끝까지 파일로 둔다. 이식성이 이 설계의 전제이므로, 플랫폼별 분기는 기본 경로가 아니라 사용자가 명시적으로 고르는 부가 옵션이어야 한다 — 그래야 테스트되지 않는 두 번째 경로가 기본값 자리에 앉는 일이 없다.

### 9.2 ToS

Anthropic 은 **여러 구독을 보유하는 것 자체는 ToS 위반이 아니라**는 입장을 밝힌 바 있다 (Claude Code 팀). 단속 대상은 **계정 공유와 토큰 리셀링**이다.

README 에 한 문단 명시한다: 이 기능은 *본인이 소유한* 복수 구독을 위한 것이며, 한 계정을 여러 사람이 돌려쓰는 용도가 아니다. 연구실·팀 공유 계정을 등록하는 것은 사용자 책임 영역이다.

## 10. 구현 계획

### `bin/ccd-account` (신규, ~350줄)

저장소·조회·refresh·스왑의 단일 소유자. 다른 컴포넌트는 전부 이 스크립트를 호출한다 (bash 함수 공유 대신 별도 실행파일 — 훅과 런처 양쪽에서 쓰이므로).

```
ccd account add [--name N] [--priority P]   현재 활성 계정을 저장소에 등록
ccd account list [--json]                    등록 계정 + 쿼타 + status 표
ccd account rm <name>
ccd account use <name>                       수동 스왑 (claude 종료 상태에서만)
ccd account refresh [--all|<name>]           명시적 refresh
ccd account pick --json                      §5 알고리즘. 훅이 호출하는 내부 명령
```

`bin/ccd` 의 `case` 문(1190행 부근)에 `account)` 분기 추가 → `ccd-account` 로 위임.

### `scripts/quota-guard.sh`

- `handoff_ready()` 를 `handoff_ready_account()` / `handoff_ready_fallback()` 으로 분리. 전자는 `have_key()` 를 요구하지 않는다 (§8 마지막 행)
- `StopFailure` 분기: `peak >= ARM_THRESHOLD` 확인 후 `ccd-account pick --json --exclude "${CCD_BURST_VISITED:-}"` 먼저 시도 → 결과 있으면 `write_handoff true to_account <sid> <cwd> --account <name>`, 없으면 현행 `to_fallback`
- `write_handoff()` 에 `account` 인자 추가
- keep-alive: 하루 1회 `ccd-account refresh --all --inactive-only` 를 백그라운드로
- `SessionEnd` 안내 문구에 `to_account` 케이스 추가 — 어느 계정으로 가는지 label 표시

### `bin/ccd-handoff`

- **`MAX_HOPS=3` 상수 제거.** `hops` 카운터를 §5.2 의 `visited` 집합으로 교체하고, relaunch 직전 `CCD_BURST_VISITED` 로 export. 세션이 `HOP_RESET_SECONDS` 이상 살아남으면 비운다 (기존 `hops=0` 자리)
- `hf account` 필드 읽기
- `case "$dir"` 에 `to_account)` 분기:
  ```
  ccd-account use "$acct" || { fallback 으로 강등하거나 안내 후 exit }
  printf '▶ 🍩 <A> 쿼타 소진 — <B> 계정으로 같은 대화를 이어갑니다 (구독, 무과금)'
  args=(--resume "$sid"); resuming=1; backbone=subscription
  ```
- `to_subscription` (OpenRouter → 구독 복귀) 은 **손대지 않는다.** §13.1 참조

### `bin/ccd-statusline`

계정이 2개 이상 등록됐을 때만 활성 계정 label 을 표시. 1개 이하면 현행 출력 그대로 (기존 사용자에게 변화 없음).

### `bin/ccd doctor`

- 계정별 status / 토큰 만료까지 남은 시간
- 저장소 퍼미션 검증
- refresh 엔드포인트 도달성 (실제 refresh 는 하지 않음 — 진단이 토큰을 회전시키면 안 된다)

### 문서

`README.md` / `README.ko.md` 에 섹션 추가, `QUOTA-SOS.md` 에 "계정이 여러 개일 때" 항목 — 쿼타가 0이 된 뒤에는 읽기만 가능해야 하므로 명령어를 그대로 적는다.

## 11. 테스트 계획

`test/` 의 기존 구조(`smoke.sh`, `roundtrip.py`, `docker.sh`)를 따른다.

단위:
- surgical merge 가 `mcpOAuth` 를 보존하는가 (회귀로 반드시 고정)
- `pick` 이 7일 창 소진 계정을 배제하는가
- `pick` 이 조회 실패를 "여유 있음" 으로 해석하지 않는가
- refresh 응답의 새 refresh_token 이 access token 사용 전에 기록되는가
- `/login` 후 첫 명령이 라이브 토큰을 소유 계정 파일로 배킹하는가 (§12.0.1)
- **그 다음 회전들도** 계속 배킹되는가 — 자가 치유가 게이트를 죽이지 않는가 (§12.0.2)
- 스왑보다 낡은 프로필, 그리고 동시각 프로필로는 배킹하지 않는가 (§12.0.1)
- 다른 계정 파일에 이미 있는 토큰을 거부하는가 (§12.0.1)
- `use <이미 활성인 계정>` 이 라이브 토큰을 보존하는가 (§12.0.3)
- 교체된 토큰을 측정한 `dead` 판정이 은퇴하고, 현재 토큰을 측정한 것은 남는가 (§12.0.4)
- 동시각 프로필이 `swap_to` 를 통해 계정 간 오염을 만들지 않는가 (§12.0.1)

통합 (fake claude 바이너리 + stub HTTP):
- A 소진 → B 스왑 → 같은 session_id 로 `--resume` 되는가
- A·B 모두 소진 → OpenRouter 로 떨어지는가
- 계정 0개 등록 시 현행과 바이트 단위로 동일하게 동작하는가 (**가장 중요한 회귀 테스트**)
- 스왑 중 kill -9 후 blob 무결성

루프 방지 (§5.2) — 상수를 없앤 만큼 여기가 촘촘해야 한다:
- 계정 **5개** 전부 소진 → 5홉 모두 거친 뒤 OpenRouter 에 도달하는가 (예전 `MAX_HOPS=3` 이 잘랐을 시나리오)
- A→B→A 핑퐁이 3번째 홉에서 멈추는가
- 목적지가 전부 다른 3홉(A→B→OR)은 통과하는가
- `HOP_RESET_SECONDS` 넘긴 세션 뒤 `visited` 가 비워져 같은 계정으로 다시 갈 수 있는가
- `fallback` 까지 `visited` 에 든 상태에서 중단 메시지가 나오는가
- 백스톱이 `visited` 정상 동작 시 **절대 발동하지 않는가** (발동하면 그건 버그 신호이므로 테스트가 잡아야 한다)

## 12. 알려진 한계 / 미해결 질문

### 12.0 ccd 모르게 `/login` 으로 계정을 바꾸면 — 해결됨

`swap_to` 는 나가는 계정의 최신 토큰을 활성 계정 파일에 백업한다(§6.2 3번). 사용자가 ccd 를 거치지 않고 `/login` 으로 다른 계정에 로그인하면, 포인터는 낡은 이름을 가리키고 백업이 **엉뚱한 파일에 남의 토큰을 쓴다.** 두 항목이 같은 계정을 가리키게 되어 "예비 계정" 이 거짓말이 된다.

처음에는 "손으로 `/login` 했으면 `ccd account add --force` 를 한 번 실행하라" 는 규칙으로 두려 했다. **그건 최악의 UX 다** — 기억해야 하고, 안 지키면 조용히 저장소가 망가진다. 지켜야만 안전한 규칙은 해결책이 아니다.

**해결의 열쇠: `~/.claude.json` 의 `oauthAccount.accountUuid`**

```jsonc
"oauthAccount": {
  "accountUuid": "…",          // ← 토큰 회전과 무관하게 안정적, 계정마다 고유
  "emailAddress": "…",         // ← label 자동 획득 (§12.1 의 질문도 같이 해결)
  "profileFetchedAt": 1786870255655,   // ms epoch
  "organizationName": "…", "displayName": "…"
}
```

Claude Code 가 로그인 시 직접 관리하는 값이고, **네트워크 호출이 0이다.** 토큰은 계속 회전하므로 "토큰이 달라졌다" 는 계정 변경의 신호가 될 수 없지만, `accountUuid` 는 된다.

**양방향 staleness 를 `profileFetchedAt` 으로 판별한다.** 두 출처가 각자 다른 순간에 낡는다:

| 출처 | 무엇을 아는가 | 언제 낡는가 |
|---|---|---|
| `.active` 포인터 | ccd 가 마지막으로 설치한 것 | 사용자가 직접 `/login` 한 뒤 |
| `oauthAccount` | Claude Code 가 마지막으로 확인한 자기 정체 | ccd 가 스왑한 직후 (재시작 전까지 갱신 안 됨) |

그래서 `.active-at`(스왑 시각, ms)과 `profileFetchedAt` 을 비교해 **더 나중에 관측된 쪽**을 믿는다.

- 프로필이 더 새것 → 사용자가 `/login` 한 것 → identity 채택, **포인터를 조용히 자가 치유**
- 포인터가 더 새것 → 우리가 방금 스왑한 것 → 포인터 유지 (안 그러면 스왑이 스스로를 되돌린다)

**결과: 사용자가 칠 명령이 없다.** `/login` 은 자동 감지되고, 백업은 언제나 토큰을 실제로 소유한 계정 파일로 간다.

등록되지 않은 계정으로 로그인한 경우는 `active_name()` 이 `None` 을 돌려준다. 이건 실패가 아니라 **정답**이다 — 백업할 올바른 파일이 없으므로 아무 데도 쓰지 않는다.

`oauthAccount` 를 못 읽는 경우(구버전 Claude Code 등)에만 포인터 단독으로 강등된다.

### 12.0.1 절반만 고쳐져 있었다 — 저장된 토큰 배킹

§12.0 은 **누가 로그인했는지 감지하는 문제**만 풀었다. 감지한 뒤 포인터는 고쳤지만
**계정 파일의 토큰은 그대로 뒀다.** 그래서 다음이 남았다.

refresh token 은 1회용이고 쓸 때마다 회전한다. 저장소가 들고 있는 것은 회전하는
열쇠의 **스냅샷**이다. `/login` 은 새 refresh token 을 발급하며 기존 것을 정리하고,
평범한 세션도 갱신할 때마다 헌 것을 파기한다. 어느 쪽이든 ccd 밖에서 일어나면 스냅샷은
그 순간 죽고, **죽었는지 알아낼 방법은 실제로 써보는 것뿐이다.**

그 스냅샷이 바로 handoff 가 설치하는 값이고 `list` 가 찔러보는 값이다. 결과:

- 멀쩡히 쓰고 있는 계정이 `needs re-login` 으로 표시된다 (스냅샷만 죽었다)
- 활성 계정은 `token stale` 밖에 못 낸다. `cmd_list` 는 활성 계정을 일부러 갱신하지
  않는다(돌고 있는 세션의 토큰을 회전시키므로). **정상과 사망을 구분할 수 없는 유일한
  상태**이고, 비활성이 되는 순간 처음으로 사실이 드러난다.
- 등록된 예비 계정이 조용히 거짓말이 된다

처음의 해결책은 "`/login` 했으면 `ccd account add --force` 를 치라" 였다. §12.0 이
이미 거부한 규칙과 같은 종류다 — 기억해야 하고, 안 지키면 조용히 망가진다.

**해결: `bank_live_oauth()` — 모든 명령 앞에서 라이브 블롭을 소유 계정 파일로 복사한다.**

핵심은 비대칭이다. **라이브 블롭을 읽어 쓰는 것은 공짜**고, **저장된 토큰을 시험하는 것은
그 토큰을 죽인 회전을 한 번 더 쓰는 것**이다. 그러니 시험하지 말고 그냥 베껴 넣는다.

쓰기가 안전한 조건은 §12.0 이 이미 만들어 뒀다:

- `accountUuid` 가 라이브 블롭의 주인을 지목한다
- `profileFetchedAt > .active-at` 일 때만 그 지목을 믿는다. 스왑 직후에는 프로필이
  **방금 떠난 계정**을 가리키므로, 그때 배킹하면 들어온 계정의 토큰을 나간 계정 파일에
  쓰게 된다 — §12.0 이 막으려던 바로 그 오염이다
- 등록되지 않은 계정이면 아무 데도 쓰지 않는다
- 같은 refresh token 이 **다른 계정 파일에 이미 있으면** 거부한다. 라이브 블롭은 머신의
  모든 Claude Code 프로세스가 공유하므로, 남의 세션이 쓴 블롭일 수 있다. 죽은 자격증명보다
  **남으로 응답하는 자격증명**이 나쁘다

동시각(`==`)은 순서를 판정할 수 없으므로 `<=` 로 닫는다 — 동률은 증명이 아니다. `.active-at`
부재는 0 으로 읽혀 **통과한다**. 이건 예외가 아니라 같은 규칙이다: ccd 가 설치한 적이 없으면
프로필이 낡을 대상 자체가 없다.

**`active_name()` 도 같은 비교를 써야 한다.** 처음엔 `active_name()` 은 `>=`, 배킹은 `<=` 로
두고 "이름을 잘못 부르는 건 복구 가능, 자격증명을 잘못 쓰는 건 아니다" 로 정당화했다.
**틀렸다.** `swap_to` 는 `active_name()` 의 답을 받아 **자격증명을 백업한다.** 동률을 거기서
받아주면 프로필이 B 를 가리키는 사이 A 의 토큰이 b 파일에 저장된다 — 막으려던 오염이 다른
문으로 들어온다. 두 비교는 반드시 같아야 한다.

`live_identity()` → `_active_at()` → `accounts_all()` → `live_read()` 순서로 싼 것부터
검사하며 모두 fail-closed 다. 계정을 등록하지 않은 다수 사용자에게는 keychain 호출(~18ms)
전에 반환된다. 락 밖에서 한 번 훑어 **락 경합을 피하고**, 락을 잡은 뒤 `_bank_target()` 을
**다시 표본화**한다 — 라이브 블롭은 공유 자원이라 그 사이 바뀔 수 있다. 계정 레코드도 락
안에서 다시 읽는다. 그러지 않으면 동시에 돈 `rm`/`add` 를 되돌려 지운 계정을 부활시킨다.

### 12.0.2 `.active-at` 은 "포인터를 쓴 시각" 이 아니라 "자격증명을 설치한 시각" 이다

첫 구현은 이 구분을 놓쳤고, 그래서 **배킹이 딱 한 번만 동작했다.**

`/login` 직후 첫 명령에서 `active_name()` 이 포인터를 자가 치유하며 `active_set()` 을
불렀고, 그게 `.active-at` 을 **지금**으로 찍었다. 로그인의 `profileFetchedAt` 은 그보다
앞이므로, 그 다음 명령부터는 프로필이 영구히 "낡은" 것으로 판정된다. 결과: 로그인은
저장되지만 **이후 모든 회전이 조용히 버려진다.** 몇 시간 뒤 스냅샷은 다시 죽는다.

자가 치유는 설치가 아니다. ccd 가 관측한 사실을 적은 것뿐이다. `add` 도 라이브 블롭을
바꾸지 않으므로 설치가 아니다. 그래서 `active_set(name, stamp=False)` 를 도입해
**`swap_to` 만 시각을 찍는다.**

교훈: 게이트가 두 개의 서로 다른 양을 한 파일에 섞어 담으면, 한쪽 갱신이 다른 쪽의 의미를
조용히 파괴한다.

### 12.0.3 `use <이미 활성인 계정>` 이 복구를 되돌렸다

`swap_to` 는 `cur != name` 일 때만 나가는 토큰을 백업했다. 그런데 설치는 무조건 했다.
그래서 이미 로그인해 있는 계정으로 `use` 하면, 방금 `/login` 으로 받은 **라이브 토큰 위에
저장된 낡은 사본을 덮어썼다.** 고치려고 부른 명령이 고친 것을 지웠다.

이제 백업은 `cur` 이 있으면 항상 하고, `cur == name` 이면 **설치를 건너뛴다.** 라이브
블롭이 이미 그 계정 것이고 `oauth` 보다 새것이기 때문이다.

다만 건너뛰는 것은 *설치*이지 *동기화*가 아니다. macOS 에서는 키체인과
`~/.credentials.json` 두 곳이 라이브 소스이고, `live_write` 는 낡은 파일이 이전 계정을
되살리는 것을 막으려고 존재한다(§6.2). 그래서 `cur == name` 경로도 방금 읽은 블롭을
그대로 `live_write` 한다 — 설치는 없고 두 소스를 맞추기만 한다.

### 12.0.4 실패 판정은 그것을 측정한 자격증명보다 오래 살 수 없다

`cache_ttl_for` 는 `dead` 를 20분 붙잡는다. 배킹이 자격증명을 바꾼 뒤에도 그 판정이
서빙되면, 사용자의 `/login` 은 **20분간 아무 효과가 없어 보인다** — 이 변경이 없애려던
혼란 그대로다.

캐시 행을 지우는 대신 `quota_for` 에서 **무시한다.** 지우기는 락을 안 쓰는 캐시
기록자(`cmd_list`/`cmd_pick` 는 전체 캐시를 락 없이 되쓴다)가 부활시킬 수 있고, 저장과
무효화 사이에 죽으면 재시도되지 않는다.

판정 기준은 **시각이 아니라 정체성**이다. 캐시 행은 두 가지를 같이 적는다: 그 판정이
설명하는 계정(`uuid`)과, 측정 대상 access token 의 짧은 해시(`cred`).

- **`uuid` 는 모든 행에 대해 검사한다(`ok` 포함).** `add --force` 는 기존 이름을 **다른 계정**에
  물릴 수 있고, 그때 남은 쿼타 행은 이전 주인의 것이다. 특히 `pick --no-probe` 는 소켓을 전혀
  열지 않고 `ok` 행을 그대로 믿으므로, 검사가 없으면 **남의 여유분으로 핸드오프**한다.
- **`cred` 는 실패 판정에 대해 검사한다.** `ok` 는 토큰이 바뀌어도 유효하다. 쿼타는 계정의
  속성이지 자격증명의 속성이 아니기 때문이다.
- **`account_uuid` 가 없는 계정**(구버전 Claude Code 로 등록)은 이름의 주인을 구분할 durable 한
  값이 없다. 그때는 `cred` 가 계정까지 대신 답해야 하므로 **`ok` 행에도 요구**한다.

행을 **지우지 않고 무시**하는 이유도 여기 있다. 지우기는 캐시 전체를 락 없이 되쓰는 다른
프로세스가 되살린다. 시각으로 판정할 수 없는 이유는 둘이다:

- `now()` 는 초 단위다. 같은 초에 일어난 실패와 배킹은 동률이 되어 판정이 살아남는다.
- `probe_account` 는 도중에 토큰을 갱신할 수 있다. 그러면 방금 만든 실패 판정이 **자기
  자신의 토큰보다 낡아 보여** 매번 다시 프로브된다.

정체성 비교에는 둘 다 없다.

`bin/ccd-statusline` 은 캐시를 직접 읽으므로 **같은 규칙을 한 번 더 적는다**(`row_valid`).
50ms 짜리 subprocess 를 렌더마다 띄우지 않으려는 기존 결정의 연장이고, 두 곳이 갈라지지
않도록 스모크가 소스 수준 불변식으로 고정한다. 검사가 없으면 statusline 은 이전 주인의
쿼타를 보여주거나, 사용자가 이미 고친 `needs re-login` 을 계속 알린다.

**결과: 사용자가 칠 명령은 `/login` 하나다.** `add --force` 는 복구 수단에서 사라졌다.

### 12.0.5 남는 한계

**(1) 다른 계정의 세션이 라이브 블롭을 쓴 경우.** A 세션이 살아 있는 채로 B 로 로그인하면,
A 가 자기 토큰을 회전시켜 공유 블롭에 덮어쓸 수 있다. 프로필은 B 를 가리키므로 게이트는
통과한다. refresh token 이 이미 A 파일에 있으면 위 가드가 잡지만, A 가 회전한 직후 아직
배킹되지 않은 토큰이면 잡지 못한다. 블롭에 계정 식별자가 없는 한 구조적으로 남는다.
`swap_to` 가 다른 claude 프로세스 수를 세서 경고하는 이유가 이것이다.

**(2) `profileFetchedAt` 을 쓰지 않는 Claude Code.** `fetched_at` 이 0 이 되어, 한 번이라도
스왑한 뒤에는 배킹이 비활성된다. `active_name()` 이 그런 설치에서 포인터 단독으로 강등되는
것과 같은 범위이고 같은 이유로 의도된 동작이다. 확인: Claude Code 2.1.258 은 이 필드를 쓴다.

**(3) 부분 성공한 설치는 스탬프를 거짓말하게 만든다.** `live_write` 는 두 백엔드 중 하나만
성공해도 참을 돌려준다. macOS 에서 키체인 쓰기가 실패하고 파일만 성공하면 `swap_to` 는
일어나지 않은 설치를 `.active-at` 에 찍는다. 결과는 배킹이 보수적으로 멈추는 것(안전한
방향)이지만, `live_write` 의 "둘 다 맞춘다" 계약과는 어긋난다. 반대로 자격증명 기록 뒤
스탬프 기록이 실패하면 실제 설치가 기록되지 않는다. 두 경우 모두 `live_write` 가 백엔드별
결과를 돌려주지 않는 데서 오고, 그 서명을 바꾸는 것은 이 변경의 범위를 넘는다.

**(4) 자격증명 설치와 포인터 기록은 원자적이지 않다.** `swap_to` 는 `live_write` 로
자격증명을 설치한 뒤 `active_set` 으로 포인터와 스탬프를 쓴다. 그 사이에서 하드 킬을 당하면
**새 계정의 자격증명이 살아 있는데 포인터는 옛 계정을 가리킨다.** 그 상태에서 `swap_to` 의
백업은 새 계정의 토큰을 옛 계정 파일에 넣는다. 키체인과 파일에 걸친 쓰기를 한 번에 원자적으로
만들 방법이 없으므로 구조적이다. 이 변경 이전에도 있던 창이고(`active_set` 은 늘 두 파일을
썼다), 이 변경이 넓히지는 않았다 — 다만 `.active-at` 이 배킹의 근거가 되면서 결과가 하나
늘었다. 닫으려면 `live_write` 직전에 pending 표식을 쓰고 포인터 기록 뒤 지운 다음, pending
동안에는 identity 기반 배킹을 거부해야 한다. 자격증명 기록 경로에 상태 기계를 하나 더 얹는
일이라 이 변경의 범위 밖으로 뒀다.

(1)~(3) 은 "증명할 수 없으면 아무것도 쓰지 않는다" 는 규칙의 결과다. (4) 는 그 규칙이
닿지 않는 곳이다. 잃는 것은 갱신 한 세대, 잘못 쓰면 잃는 것은 계정 하나다.

### 12.1 남은 질문

1. **수동 진입점.** `ccd -c` 처럼 "다른 계정으로 지금 이 대화 이어가기" 를 주는가? `ccd account use B && claude --resume` 로 충분할 수도 있다.
2. **plan tier 혼재.** Max 5x 와 Pro 를 섞어 등록하면 `pick` 이 tier 를 고려해야 하는가? 현재는 무시(퍼센트만 본다)하되 `rate_limit_tier` 는 저장해둔다.

~~**label 획득 방법**~~ — 해결됨. `oauthAccount.emailAddress` 에서 자동으로 온다(§12.0). `--name` 도 필수가 아니게 됐다: 이메일 local part 가 기본 이름이 된다.

## 13. 구현하면서 설계에서 바뀐 것

### 13.1 `to_subscription` 은 건드리지 않았다 — 대신 "탈출 경로" 를 새로 뒀다

설계 §10 은 OpenRouter → 구독 복귀 시에도 `pick` 을 태워 가장 여유 있는 계정으로 가게 하자고 했다. **구현하면서 틀렸다는 게 드러났다.**

`pick` 은 활성 계정을 후보에서 제외한다. 그런데 기존 복귀 신호(`to_subscription`)는 *활성 계정의* 쿼타 창이 리셋됐다는 뜻이다. 여기에 `pick` 을 끼우면 "A가 회복됐다" 는 신호를 받고 **A가 아닌 B로** 가게 된다. 신호의 의미와 행동이 어긋난다.

그래서 기존 복귀 경로는 그대로 두고, 별도의 **탈출 경로**를 추가했다: OpenRouter 위에 있는 동안 등록된 다른 계정 중 여유가 있는 것이 생기면 즉시 `to_account` 로 빠져나간다. 회복을 기다리지 않는다.

두 경로는 이렇게 나뉜다.

| 신호 | 의미 | 행동 |
|---|---|---|
| 활성 계정의 창이 리셋됨 | 떠나온 그 계정이 살아남 | `to_subscription` — 그 계정으로 복귀 (기존 로직 그대로) |
| 다른 계정에 여유가 생김 | 더 싼 집이 비었음 | `to_account` — 그리로 이동 (신규) |

결과적으로 검증된 기존 코드는 한 줄도 바뀌지 않았고, 새 기능은 순수 추가분이다. 그리고 원래 의도했던 "돈 그만 쓰기" 효과는 오히려 더 빨리 난다 — 떠나온 계정이 회복될 때까지 기다릴 필요가 없으므로.

### 13.2 `pick --no-probe` — 훅 지연을 막기 위한 캐시 전용 모드

탈출 경로는 `UserPromptSubmit` 에서 돈다. 여기서 네트워크를 때리면 계정당 최대 10초씩 **사용자 프롬프트가 얼어붙는다.**

그래서 `pick` 에 `--no-probe` 를 추가했다: 캐시만 보고 판단하며 소켓을 절대 열지 않는다. 훅은 갱신용 `pick` 을 백그라운드로 하나 던지고, 결정은 `--no-probe` 로 내린다. 다음 tick 에는 캐시가 따뜻하다.

반면 `StopFailure`(쿼타가 방금 죽은 순간)에서는 **블로킹 probe 를 쓴다.** 그 턴은 이미 실패했으므로 지연이 무의미하고, 정확도가 전부이기 때문이다.

### 13.3 `handoff_ready()` 분리

설계대로 `handoff_ready_account()` 를 분리했다. 계정 간 이동에는 OpenRouter 키가 필요 없다. 이걸 안 나눴으면 **구독 2개를 가졌고 OpenRouter 를 쓸 생각이 없는 사용자** — 이 기능의 1차 대상 — 가 아무 데도 못 간다.

### 13.4 hop 상한의 하한선 3

`등록 계정 수 + 2` 로 파생시켰더니 계정 0개에서 상한이 2가 되어 **기존 동작(3)이 바뀌었다.** 회귀다. `max(3, 계정수 + 2)` 로 바닥을 깔아 계정이 없으면 기존과 바이트 단위로 동일하게, 계정이 있으면 올라가기만 하도록 고쳤다.

### 13.5 방문 집합은 기존 hop 카운터보다 한 홉 일찍 잡는다

기존 스모크 테스트 "hop cap" 은 같은 목적지로 계속 재무장하는 상황에서 3회 실행을 기대했다. 방문 집합에서는 2회에 멈춘다 — 같은 목적지 재방문은 횟수와 무관하게 루프이기 때문이다. 문서 §5.2 에 적어둔 "핑퐁에 더 엄격하다" 가 실제로 그렇게 나왔고, 테스트를 새 의미로 고쳤다.

### 13.6 `CCD_CREDENTIALS_BACKEND=file` — 테스트 격리용

스모크 스위트는 `HOME` 을 갈아끼워 격리한다. 그런데 키체인은 `HOME` 밖에 있다. **macOS 에서 테스트를 돌리면 개발자 본인의 Claude 로그인을 덮어쓴다.**

이 스위치를 켜면 모든 크레덴셜 연산이 `$HOME` 안에 머문다. 테스트 전용이며 프로덕션은 설정하지 않는다.

### 13.7 `CCD_DIR` 오버라이드를 없앴다

`ccd-account` 에 `CCD_DIR` 환경변수 오버라이드를 넣었다가 제거했다. `bin/ccd`·`quota-guard.sh`·`ccd-handoff` 는 전부 `$HOME/.claude/ccd` 를 하드코딩하고, **handoff 인터록은 양쪽이 독립적으로 계산한 경로 문자열을 비교한다.** 한쪽만 오버라이드를 존중하면 두 경로가 어긋나 handoff 전체가 조용히 죽는다. 격리는 `HOME` 하나로만 한다.

### 13.8 negative caching

`quota_for` 가 `status == "ok"` 일 때만 캐시를 재사용하도록 짰더니, dead/error 계정은 **훅 tick 마다 네트워크를 때렸다.** 훅은 프롬프트마다 + 도구 사용마다 도니 분당 수 회다. 상태별 TTL 로 고쳤다: `ok` 300초, `dead` 1200초(사람이 재로그인해야만 바뀜), `stale`/`error` 60초.

---

## 참고

- [claude-swap](https://github.com/realiti4/claude-swap) — 계정 무관 OAuth 상태 보존, 크레덴셜 락 처리의 선행 사례
- [clauth](https://github.com/uwuclxdy/clauth) — fallback chain, 캐시 기반 auto-switch
- [Claude Code OAuth flow 정리 (cedws gist)](https://gist.github.com/cedws/3a24b2c7569bb610e24aa90dd217d9f2) — refresh 엔드포인트·client_id
- [anthropics/claude-code#54443](https://github.com/anthropics/claude-code/issues/54443) — 동시 세션 refresh 경합으로 강제 로그아웃
- [anthropics/claude-code#34341](https://github.com/anthropics/claude-code/issues/34341) — 네이티브 멀티 계정 요청 (duplicate 처리, 미구현)
