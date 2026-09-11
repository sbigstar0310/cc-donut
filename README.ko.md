<p align="center">
  <img src="assets/logo.svg" alt="cc-donut logo" width="220">
</p>

# cc-donut

**Claude Code를 위한 도넛 스페어 타이어. 최고 시속 80km, 집까지는 갑니다.**

한국어 · [English](README.md)

[![License: MIT](https://img.shields.io/github/license/sbigstar0310/cc-donut)](LICENSE)
[![tests](https://github.com/sbigstar0310/cc-donut/actions/workflows/test.yml/badge.svg?branch=main&event=push)](https://github.com/sbigstar0310/cc-donut/actions/workflows/test.yml?query=branch%3Amain+event%3Apush)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet)](#install)

<p align="center">
  <img src="assets/loop.gif" alt="타이어 펑크, 도넛 스페어 장착, 집까지 주행, 원래 타이어 복귀" width="480">
</p>

## 무엇을 하나

Claude 쿼타가 바닥나면 대화를 **본인이 쓰는 다른 Claude 구독**으로 옮깁니다. 하던 대화,
도구, hook, skill, MCP server가 그대로 유지되고 과금도 없습니다. 이미 돈을 내고 있는
구독이니까요. 쿼타가 초기화되면 원래 계정으로 돌아갑니다.

두 구독의 쿼타가 동시에 바닥나는 일은 드물어서, 대부분은 계정 전환만으로 계속 쓸 수
있습니다. 등록한 구독의 쿼타를 모두 쓴 경우에만 OpenRouter로 넘어갑니다. 이쪽은 토큰
사용량에 따라 과금되는 최후 수단입니다.

## Install

```sh
claude plugin marketplace add sbigstar0310/cc-donut
claude plugin install ccd@cc-donut
```

그다음 Claude Code에서 `/ccd:setup`을 실행하세요.

<details>
<summary>Claude Code 안에서 설치하고 싶다면</summary>

슬래시 명령은 **한 줄씩** 해석됩니다. 아래를 한 메시지로 붙여 넣으면 작동하지 않으니
각각 따로 입력하세요.

1. `/plugin marketplace add sbigstar0310/cc-donut`
2. `/plugin install ccd@cc-donut`
3. `/reload-plugins`
4. `/ccd:setup`

statusline은 다음번에 Claude Code를 사용할 때부터 나타납니다. 재시작은 필요 없습니다.

</details>

## 쿼타가 남아 있을 때 세팅하세요

쿼타가 0%가 되면 Claude의 도움을 받을 수 없습니다.

```sh
ccd account add     # 지금 로그인되어 있는 계정을 등록
claude              # /login으로 다른 계정 로그인 후 /exit
ccd account add     # 그 계정도 등록
ccd account list    # 두 계정과 실시간 쿼타 확인
ccd setup --auto    # 선택: 칠 것 없이 알아서 전환
```

구독 두 개를 쓰는 세팅은 이게 전부입니다. OpenRouter(`ccd key`)는 선택 사항이고,
등록한 구독의 쿼타를 모두 쓴 뒤에만 필요합니다.

## 쿼타가 바닥났을 때

```text
이전       작업 중간에 막힘, 재시작, 맥락 상실

수동       !ccd account use <name>    세션 안에서 바로
           /exit, claude --resume     같은 대화, 무과금

자동       칠 것 없음                 ccd setup --auto, 양방향 모두 자동
```

`!`를 붙이면 Claude Code를 벗어나지 않고 셸 명령을 실행할 수 있어서, 하던 자리에서
그대로 계정을 바꿀 수 있습니다. 전환은 즉시 적용되지만 지금 떠 있는 세션은 재시작할
때까지 이전 계정의 모델과 한도를 유지합니다. `/exit` 후 `claude --resume`이 그 때문입니다.

---

<details>
<summary><b>구독 두 개, 자세히</b></summary>

등록 순서대로 계정 전환을 시도하며, `--priority`로 순서를 바꿀 수 있습니다.
**5시간 쿼타와 7일 쿼타가 모두** 남아 있는 계정만 후보가 됩니다. 주간 쿼타를 99% 쓴
계정으로 옮겨 봐야 몇 분 뒤 다시 바닥나기 때문입니다.

statusline은 현재 쓰는 계정, 예비 계정의 쿼타 사용량, 해당 쿼타의 초기화 시점을
보여줍니다.

```text
● claude:personal │ spare work 20% (2h10m)     # 지금 바로 전환 가능
● claude:personal │ spare work 98% (13m)       # 소진됐지만 기다릴 만함
```

`ccd doctor`는 계정별 쿼타를 보고하고 재로그인이 필요한 계정을 표시합니다. 토큰이
만료돼도 해당 계정을 다시 쓸 때까지 알아채기 어렵습니다. 그래서 ccd는 사용하지 않는
계정의 토큰을 하루 한 번 갱신하고, 더 이상 갱신되지 않으면 세션에서 알려줍니다. 해당
계정으로 `/login`하면 복구되고, ccd가 새 토큰을 자동으로 저장하므로 계정을 다시 등록할
필요는 없습니다.

계정을 바꿔도 MCP 로그인(Notion, Slack 등)은 영향을 받지 않습니다. 토큰은
`~/.claude/ccd/accounts/`에 저장되고(mode 600, [SECURITY.md](SECURITY.md) 참고),
`ccd account rm <name>`으로 지웁니다.

> **구독을 여러 개 보유하는 경우.** Anthropic은 구독을 두 개 이상 보유하는 것 자체는
> 약관 위반이 아니라고 밝혔습니다. 계정 공유와 이용 권한 재판매는 금지됩니다. 이 기능은
> *본인이 보유한* 구독에 쓰도록 만들었습니다. 여러 사람이 함께 쓰는 계정을 등록하는 것은
> 본인 판단이자 본인 책임입니다.

</details>

<details>
<summary><b>자동 전환, 아무것도 안 쳐도 되는 방식</b></summary>

```sh
ccd setup --auto
```

런처를 `~/.claude/ccd/bin/claude`에 설치하고, 셸이 이 런처를 먼저 찾도록 셸 초기화
파일에 한 줄을 추가할지 묻습니다.

```sh
export PATH="$HOME/.claude/ccd/bin:$PATH"
```

공식 설치 프로그램이 관리하는 `~/.local/bin/claude`를 가리지 않도록 별도 디렉터리를
씁니다. 프롬프트에 no라고 답하면 추가할 줄만 출력합니다. 미리 승인하려면 `--yes`를
지정하세요.

그다음부터는 평소처럼 `claude`로 시작하면 됩니다. 런처가 실제 claude를 실행하고 종료
코드를 확인합니다. 쿼타가 바닥나면 다음 계정에서 대화를 자동으로 이어가고, 쿼타가
초기화되면 원래 계정으로 돌아갑니다.

자동 전환의 조건과 제약:

- **세 조건이 모두 충족돼야 작동합니다.** 런처가 실행 중이고, 쿼타 조회 결과가
  rate-limit 에러와 일치하며, 전환할 대상이 있어야 합니다. 하나라도 충족되지 않으면
  아무 동작도 하지 않습니다. 갈 곳 없이 세션을 끝내는 일은 없습니다.
- **진행 중이던 턴은 유실됩니다.** 실패한 턴 뒤에 전환이 일어나므로 마지막 프롬프트는
  다시 보내야 합니다.
- **비대화형 실행은 재시작하지 않습니다.** `claude -p ...`처럼 출력이 리다이렉트된
  실행은 돌아올 터미널도, 다시 보낼 프롬프트도 없습니다. 대신 이어가는 방법을
  알려줍니다.

자동 전환이 작동하지 않을 때는 문서에 안내된 수동 전환 방법을 그대로 쓸 수 있습니다.
`ccd setup --no-auto`로 끄고 `ccd uninstall`로 제거합니다. ccd가 만들지 않은
`~/.claude/ccd/bin/claude` 파일이나 ccd가 추가하지 않은 PATH 줄은 건드리지 않습니다.

</details>

<details>
<summary><b>OpenRouter, 최후 수단</b></summary>

등록한 구독의 쿼타가 모두 소진됐을 때만 OpenRouter로 전환합니다. 본인 키를 사용하고
토큰 사용량에 따라 과금되므로, 필요해지기 전에 설정해 두는 편이 좋습니다.

```sh
ccd key           # OpenRouter 키 저장 (입력 내용이 보이지 않고, 채팅에도 들어가지 않음)
ccd doctor        # ✓ OK면 탈출 경로가 살아 있음
```

기본 모델은 이미 쓰던 alias에 그대로 연결됩니다.

| Alias | 기본 모델 | 가격 (입력/출력, 1M당) | 용도 |
| --- | --- | --- | --- |
| `/model haiku` | deepseek/deepseek-v4-flash | $0.11 / $0.22 | 스캔, grep, 사소한 편집 |
| `/model sonnet` | openai/gpt-5.6-luna | $0.10 / $0.60 | 일반적인 코딩 작업 |
| `/model opus` | moonshotai/kimi-k3 | $2.90 / $14.00 | 어려운 문제, 디버깅 |

세션 중에도 `/model z-ai/glm-5.2:floor`처럼 입력해
[openrouter.ai/models](https://openrouter.ai/models)의 어떤 slug로든 모델을 바꿀 수
있습니다. alias를 영구히 바꾸려면 `ccd pick`, 한 번만 바꾸려면 `ccd -c --opus sol`을
씁니다. 모델을 직접 지정하고 실행 시점의 컨텍스트 한도를 적용해 대화를 이어가려면
`ccd -c --model provider/model`을 씁니다.

기본값은 최저가 provider(`:floor`)이며, 이번 실행 비용과 구독 쿼타를 쓸 수 없는 동안의
누적 비용이 화면에 표시됩니다.

```text
ccd │ openai/gpt-5.6-luna:floor · high │ in $0.10/M · out $0.60/M │ run $0.0123 · total $0.4200
```

카탈로그는 특정 시점의 정보라 최신 벤치마크와 가격이 반영되지 않을 수 있습니다. 쿼타가
남아 있을 때 Claude에게 *"ccd 모델 추천 갱신해줘"* 라고 하면 `/ccd` skill이 현재
벤치마크와 가격으로 갱신안을 먼저 제안한 뒤 반영합니다.

싼 provider가 tool call을 제대로 처리하지 못하면 `ccd -c --routing exacto`를 써 보세요.

</details>

<details>
<summary><b>명령어</b></summary>

| 명령 | 용도 |
| --- | --- |
| `ccd account add` | 로그인된 계정을 예비 구독으로 등록 |
| `ccd account list` | 등록된 계정과 실시간 쿼타 확인 |
| `ccd account use <name>` | 그 계정으로 전환. 세션 안에서는 `!ccd account use <name>`, 반영하려면 `/exit` 후 `claude --resume` |
| `ccd account rm <name>` | 계정 제거 |
| `ccd setup --auto` | 자동 전환 켜기 |
| `ccd setup --no-auto` | 자동 전환 끄기 |
| `ccd doctor [model]` | 탈출 경로 전체 진단 |
| `ccd` | 상태 확인: 계정, 키, 슬롯, 라우팅, 절차 |
| `ccd key` | OpenRouter 키 저장 |
| `ccd -c` | OpenRouter로 전환하고 대화 이어가기 |
| `ccd go` | 이어가지 않고 새 세션으로 전환 |
| `ccd models` / `ccd pick` | 카탈로그 확인 / alias 세 개 재배정 |
| `ccd off` | 다시 구독으로 claude 실행 |

**Claude Code 안의 skill** (`/` 입력하면 보입니다):

| Skill | 하는 일 |
| --- | --- |
| `/ccd` | 준비 상태 점검과 대화형 설정 |
| `/ccd:setup` | 초기 설정 후 같은 세션에서 키 등록과 doctor 실행 |
| `/ccd:key` | 입력 내용을 숨기는 네이티브 입력창에서 OpenRouter 키 설정 |
| `/ccd:doctor` | 계정, 키, API, slug, 연동 설정 진단. 실패 시 수정 방법 제안 |
| `/ccd:update` | 명령 하나로 플러그인 업데이트 |
| `/ccd:uninstall` | 플러그인 제거 (요청하지 않으면 키는 남김) |

Claude 없이도 읽을 수 있고 `~/.claude/ccd/QUOTA-SOS.md`에 오프라인으로 보관되는
긴급 런북: [QUOTA-SOS.md](QUOTA-SOS.md)

</details>

<details>
<summary><b>어떻게 동작하나</b></summary>

계정은 세션과 세션 사이, 즉 자격 증명을 사용하는 프로세스가 없을 때 전환합니다. 이때
현재 자격 증명 데이터에서 `claudeAiOauth` 부분만 교체하므로, MCP 로그인을 포함한
나머지는 그대로 남습니다.

OpenRouter를 쓸 때는 모델 슬롯 환경변수(`ANTHROPIC_DEFAULT_*_MODEL`)가 OpenRouter의
Anthropic 호환 엔드포인트를 가리키도록 설정한 뒤 `claude`를 실행합니다. `settings.json`
에는 아무것도 쓰지 않으므로 다른 세션이나 백그라운드 에이전트의 연결 경로가 사용자
모르게 바뀌는 일은 없고, claude.ai 로그인은 ccd 프로세스 안에서만 가려집니다.

`UserPromptSubmit`/`PostToolUse` hook이 10분 캐시로 Claude 쿼타를 읽고, `StopFailure`
hook은 rate-limit 에러와 쿼타 수치가 일치하면 전환을 준비합니다. 이 수치는 ccd가 예비
계정 확인에 이미 쓰는 Anthropic usage 엔드포인트에서 직접 읽으므로 **claude-dashboard는
필수가 아닙니다**. 설치하면 ccd 행 위에 claude-dashboard의 상세 정보도 표시됩니다.

상태와 설정은 `~/.claude/ccd/` 아래에 있습니다.

</details>

<details>
<summary><b>요구사항과 주의점</b></summary>

macOS와 Linux, bash / python3 / curl이 필요합니다. 키 입력창만 macOS 전용(osascript)이고,
다른 환경에서는 입력 내용을 숨기는 터미널 프롬프트를 사용합니다.

- **공식 지원 경로가 아님** (OpenRouter에 한해): Anthropic과 OpenRouter 모두 Claude
  Code에서 Claude 이외의 모델을 사용할 때의 동작을 보장하지 않는다고 밝혔습니다. 지금은
  표준 모델 슬롯 변수로 동작하지만 Claude Code 업데이트 후에는 작동하지 않을 수 있습니다.
  `ccd doctor`로 점검하세요.
- 게이트웨이를 거칠 때 Claude Code는 모델 ID에 `[1m]` 힌트가 없으면 컨텍스트 한도를
  200K로 잡습니다. ccd는 캐시된 OpenRouter 엔드포인트 데이터에서 해당 slug의 모든 후보
  provider가 200K를 넘는 컨텍스트를 지원하는 것으로 확인된 경우에만, 대화 슬롯에 한해
  `[1m]`을 붙입니다. auto-compact 한도는 확인된 provider 중 가장 작은 값에서 계산되므로,
  가짜 1M이 아니라 실제 한계에서 압축이 걸립니다. `[1m]`을 붙여도 모델 자체의 컨텍스트
  한도는 늘어나지 않고, 이미 실행 중인 프로세스의 컨텍스트 한도도 바꿀 수 없습니다.
  statusline이 수동 재선택이 안전한지 재시작이 필요한지 알려줍니다.
- OpenRouter를 쓰는 동안에는 Remote Control, 음성 입력, fast mode가 꺼집니다.
- 돌아올 때 `/logout`은 쓰지 마세요. 진짜로 로그아웃됩니다. 복귀는 `/exit` 후
  `claude --resume`입니다.

</details>

<details>
<summary><b>보안</b></summary>

- 계정 토큰은 `~/.claude/ccd/accounts/`에 저장되고(디렉터리 700, 파일 600) 기기 밖으로
  나가지 않습니다. ccd는 Anthropic과 OpenRouter에 직접 연결하며 중간 릴레이가 없습니다.
- OpenRouter 키는 `~/.claude/ccd/providers/keys.env`(mode 600)에만 저장되고, 뒷자리만
  남기고 가려서 표시되며, 설치 시 플러그인이 키를 요구하거나 동봉하지 않습니다. export된
  `OPENROUTER_API_KEY`가 파일보다 우선하며 이는 플러그인 표준 관례입니다.
- 키는 네이티브 입력창이나 입력 내용을 숨기는 터미널 프롬프트에서만 받습니다. 그래도
  채팅에 키를 붙여 넣으면 ccd는 저장은 하되 키 교체를 권합니다. 대화 기록에 남기
  때문입니다.
- `settings.json`의 `env` 블록에 `ANTHROPIC_*` 게이트웨이 변수를 넣지 마세요. 셸에서
  export한 값을 덮어써서 백그라운드 에이전트를 포함한 모든 세션이 계속 외부 게이트웨이를
  쓰게 됩니다.

</details>

<details>
<summary><b>개발</b></summary>

```sh
test/smoke.sh                 # 임시 HOME에서 실제 스크립트를 상대로 돌리는 이식성 검사
test/docker.sh                # 깨끗한 Debian 컨테이너에서 같은 스위트
test/docker.sh alpine:3.20    # musl/BusyBox에서도
```

네트워크 없음, 실제 키 없음, 임시 HOME 밖으로 쓰지 않음. 릴리스 전에 컨테이너 테스트를
돌리세요. GNU/BSD 차이(예: `stat`)로 인해 macOS에서는 문제가 없던 코드가 Linux에서는
실패할 수 있습니다. CI는 push마다 셋 다 실행합니다.

</details>
