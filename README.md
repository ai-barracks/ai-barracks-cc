# 🎛️ AI Barracks CommandCenter

*배럭이 하나일 땐 CLI로 충분합니다. 둘 이상이 되는 순간 — CC가 필요합니다.*

AI Barracks의 데스크톱 관제 앱. 배럭 관리, 설정 편집, 에이전트 히스토리, 위키 탐색, 내장 터미널을 한 곳에서.

> 스타크래프트의 Command Center처럼 — Barracks에서 유닛(에이전트)을 생산하고, Command Center에서 모든 것을 관제한다.

<img width="2048" height="1152" alt="스크린샷 2026-04-18 오후 10 19 55" src="https://github.com/user-attachments/assets/4ca37a8d-af70-417b-b0c8-c865f6d4f3d8" />

---

## 🤔 Why CommandCenter?

[AI Barracks CLI](https://github.com/ai-barracks/ai-barracks)는 에이전트의 장기 기억을 파일로 남기는 훌륭한 엔진입니다. 하지만 배럭이 여러 개가 되는 순간, 다음과 같은 상황들이 매일같이 반복됩니다.

| 상황 | CLI만 쓸 때 | CC와 함께 쓸 때 |
|------|-------------|----------------|
| 🗺️ 여러 배럭 상태 확인 | 디렉토리마다 `cd` → `aib status` 반복 | 사이드바에서 모든 배럭 상태·active 세션 수 **한눈에** |
| ✏️ `SOUL.md` / `RULES.md` 편집 | vim에서 H2 섹션 순서·형식을 **수동으로** 지켜가며 편집 | **스키마 기반 폼 에디터** — 구조를 깨뜨릴 수 없음 |
| 🔒 Ownership 실수 방지 | `<!-- AIB:OWNERSHIP -->` 주석을 놓치고 SYSTEM 파일을 건드림 | **Ownership Banner**가 상단에 경고로 표시 |
| 🛎️ 2시간 방치된 세션 발견 | **다음 세션 시작 시**에야 알게 됨 (사후 대응) | **30초 주기 감시** → macOS 네이티브 알림 (사전 대응) |
| 🔄 `brew upgrade` 후 sync 필요성 | 수동으로 기억해 배럭마다 `aib sync` 실행 | 버전 불일치 배럭 수 **자동 경고** + 일괄 sync 버튼 |
| 🔍 "그때 ClickHouse 설정 어디서 했지?" | 배럭마다 `grep`/`ripgrep` 수동 실행 | **Cmd+K** 통합 검색 (sessions + wiki + rules + config) |
| ♻️ 세션 이어받기 | `aib hook continue <session_id>` 명령·ID 기억 | 세션 카드의 **Continue 버튼** 클릭 |
| 🌿 Git 관리 | 별도 터미널에서 `git` 실행, 모노레포 sub-path 수동 처리 | **Git 탭** — 모노레포 sub-path 자동 감지, UI에서 commit/push |
| 🧩 Claude/Gemini/Codex 병렬 작업 | Terminal.app 탭·창 수동 관리 | **Split/Grid 레이아웃** + 배럭별 터미널 상태 **영속** |
| 💥 창 닫거나 리로드 시 터미널 | 세션 날아감 | **PTY 생존** + replay + 자동 재연결 · **앱 재시작 후엔 디스크 scrollback 복원 + archive 탭** |

한 줄로 요약하면:

> **CLI가 기억을 쌓는 엔진이라면, CC는 그 기억을 안전하게 조작하고 놓치지 않게 지켜주는 조종석입니다.**

배럭이 3개를 넘어가기 시작하면, CC 없이 관리하는 것은 *기술적으로 가능하지만 실질적으로 권장되지 않습니다.*

---

## 🌱 Origin Story

### 네 가지 번거로움에서 시작되었습니다

> 1. **IDE만으로는 배럭을 제대로 운영하기 어려웠다.**
>    Cursor나 Antigravity 같은 IDE로 작업해도, 하네스 설정·진행 중인 세션·wiki 구조를 **전부 머릿속에 지고 다녀야** 했다.
>
> 2. **파일을 확인하려고 디렉토리를 일일이 뒤지는 게 일이었다.**
>    `sessions/`, `wiki/topics/`, `RULES.md` — 정보는 구조화되어 있는데, **그 구조를 눈으로 탐색하는 건** 도구를 쓰는 게 아니라 도구에 쓰이는 느낌이었다.
>
> 3. **여러 배럭에서 여러 에이전트를 돌리다 보니 터미널이 엉망이 됐다.**
>    이 창은 Claude, 저 창은 Gemini, 또 다른 탭은 Codex — **어느 창이 어느 배럭인지** 헷갈리기 시작했다.
>
> 4. **CLI가 업데이트되면, 배럭마다 수동으로 `aib sync`를 돌려야 했다.**
>    쉽게 잊어버리는 일이었고, **버전 드리프트**는 결국 자잘한 버그로 돌아왔다.

### 세 줄의 명제로 수렴했습니다

> 🧠 **외워야 할 것은, 도구가 대신 기억한다.**
>
> 🗺️ **흩어진 파일과 세션은, 하나의 화면에 모인다.**
>
> 🔄 **업데이트는 배럭마다 돌지 않고, 한 번에 번진다.**

### 세 가지 기술 위에 세웠습니다

| 기술 | 역할 | CC에 녹인 방식 |
|------|------|----------------|
| 🦀 **Tauri v2** | 네이티브 데스크톱 프레임워크 | Rust 백엔드 + React UI + 시스템 트레이 + 파일 감시 + 네이티브 알림 |
| ⌨️ **xterm.js + portable-pty** | 인앱 터미널 | 웹뷰 리로드에 견디는 분리형 PTY + 배럭별 멀티 슬롯 레이아웃 |
| 📂 **AI Barracks 파일 스펙** | CLI의 마크다운 구조 | Ownership 마커와 섹션 스키마를 **일급 편집 대상**으로 승격 |

그리고 **CLI = 엔진, CC = 조종석**이라는 한 쌍의 관계를 명확히 했습니다.
CC는 [AI Barracks CLI](https://github.com/ai-barracks/ai-barracks) 없이는 동작하지 않습니다.

---

## 🚀 Quick Start

### Prerequisites

```bash
# 1. AI Barracks CLI 먼저 설치 (v1.5 model profile launch에는 ≥ 1.4.0 필요)
brew tap ai-barracks/ai-barracks
brew install ai-barracks/ai-barracks/ai-barracks
aib version

# 2. 배럭 하나 이상 초기화
cd ~/my-project
aib init

# 3. CC 내장 터미널에서 띄울 LLM CLI를 PATH에 두기 (사용하는 것만)
#    설치·업데이트는 아래 provider 공식 안내를 따릅니다.
#    설치 후 사용하는 CLI의 경로와 버전을 확인합니다.
command -v claude codex gemini
# 사용하는 것만 실행: claude --version / codex --version / gemini --version
```

[Codex CLI 공식 설치 안내](https://learn.chatgpt.com/docs/codex/cli)와 [Claude Code 공식 설치 안내](https://code.claude.com/docs/en/quickstart)를 참고하세요. 문서 검증을 위해 provider CLI나 전역 설정을 자동 업그레이드하지 않습니다. 미지원 Homebrew/CLT 환경의 AIB 수동 배치는 [CLI 설치 안내](https://github.com/ai-barracks/ai-barracks/blob/main/docs/installation.md)를 확인하세요.

#### 알려진 함정 (반드시 확인)

- **`.claude/settings.local.json` 무결성**: `permissions.allow[]`의 `Bash(...)` 항목 quote가 깨지면 Claude Code 일부 버전(예: 2.1.118)이 CC PTY에서 invisible Settings 다이얼로그를 띄우며 stdin 전체를 가로챕니다 → TUI는 보이는데 키 입력이 무시되는 증상. aib ≥ 1.0.1은 launch 직전 자동 검사·경고합니다. 수동 검사:
  ```bash
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); allow=d.get("permissions",{}).get("allow",[])
  bad=[x for x in allow if isinstance(x,str) and x.startswith("Bash(") and x.endswith(")") and (x[5:-1].count("\"")%2 or x[5:-1].count("'\''")%2)]
  print("\n".join(bad) or "OK")' .claude/settings.local.json
  ```
- **Provider CLI flag 호환성**: 권한 우회를 기본 설치 해결책으로 사용하지 마세요. 설치 버전의 help·공식 문서와 project trust를 확인하고, 지원하지 않는 isolated-call flag는 오류로 처리합니다. model profile availability와 새 세션 실행 여부는 CLI가 최종 검증합니다.
- **첫 Claude 실행 시 workspace trust 다이얼로그**: 새 디렉토리에서 첫 실행 시 신뢰 확인이 필요. 외부 Terminal에서 한 번 `claude`로 trust 한 뒤 CC에서 사용 권장.

### Install CommandCenter

[v1.5.0 GitHub Releases](https://github.com/ai-barracks/ai-barracks-cc/releases/tag/v1.5.0)에 universal macOS `.dmg`, app archive 및 `SHA256SUMS`가 게시되어 있습니다.

1. Release의 자산을 내려받고 `SHA256SUMS`와 대조합니다.
2. 기존 앱의 작업을 저장하고 Quit한 뒤 이전 앱·사용자 데이터를 백업합니다. 새 app bundle을 Applications에 설치하고 실행합니다.
3. System에서 **CC v1.5.0 / CLI v1.4.0 이상**이 표시되는지 확인합니다. CLI 설치와 기존 배럭 템플릿 동기화는 별개입니다.
4. Scheduled activation은 기본 OFF입니다. 비용·실행 조건을 읽고 실제 요청을 원할 때만 ON을 확인합니다.

**Signing 제한:** Mach-O executable에는 linker의 ad-hoc signature가 있지만 Info.plist가 signature에 bound되지 않고 resources도 sealed되지 않았습니다. 완전한 Apple Developer app signing·notarization은 제공하지 않습니다. Checksum 일치는 archive 무결성 검사이며 Apple notarization을 대신하지 않습니다. OS 경고를 자동 우회하거나 Gatekeeper/quarantine을 비활성화하는 절차는 제공하지 않습니다.

소스 빌드·개발이 필요한 경우:

```bash
git clone https://github.com/ai-barracks/ai-barracks-cc.git
cd ai-barracks-cc
npm ci
npm run tauri build    # 배포용 빌드
npm run tauri dev      # 개발 모드
```

CC를 실행하면:
- ✅ `~/.aib/barracks.json`에서 등록된 배럭 자동 감지
- ✅ 각 배럭의 `sessions/`, `SOUL.md`, `RULES.md`, `GROWTH.md`, `agent.yaml` 실시간 감시
- ✅ 시스템 트레이에 아이콘 등록 (창 닫아도 백그라운드 유지)
- ✅ 30초 주기 health check 시작 (stale session, sync 필요 자동 감지)

---

## ✨ Core Features

CC의 기능들은 **해결하는 문제** 기준으로 묶여 있습니다.

### 🗺️ 조감: 여러 배럭을 한 화면에

**Sidebar**에는 등록된 모든 배럭이 나열되며, 각각의 **active 세션 수 배지**가 실시간으로 업데이트됩니다. 어느 배럭에서 뭐가 돌고 있는지 즉시 보입니다.

**Overview Tab**은 배럭 단위로:
- 📊 세션 통계 (total / active / completed / interrupted)
- 📚 위키 토픽 수
- ⚖️ 규칙 개수 (Must Always / Must Never / Learned)
- 🧬 SOUL 요약 (이름 / 전문성 / 성격)
- 🏷️ agent.yaml 메타데이터 + aib_version

한눈에 정리해서 보여줍니다.

**Sessions Tab**은 모든 세션을 카드 리스트로 표시하며, 각 카드에 **Continue 버튼**이 있어 다른 CLI에서 이어받기를 원클릭으로 실행합니다. 상세 뷰에서는 `Log`, `Decisions`, `Blockers`, `Wiki Extractions`, `Identity Suggestions`를 **섹션별로 파싱한 구조화된 UI**로 보여줍니다 — raw 마크다운을 직접 읽을 필요가 없습니다.

---

### ✏️ 안전한 편집: 파일 구조를 지켜주는 에디터

<img width="1398" height="994" alt="스크린샷 2026-04-18 오후 10 04 50" src="https://github.com/user-attachments/assets/ef111c65-d13e-44f8-a27d-afebf24a169b" />


⭐ **이것이 CC의 가장 큰 차별점입니다.**

CLI가 만드는 파일들에는 **ownership 마커**와 **섹션 스키마**가 있습니다:

```markdown
<!-- AIB:OWNERSHIP — [USER-OWNED] 사용자가 정의 -->
<!-- AIB:SOUL:v1 — 이 구조를 유지하세요 -->
# Agent Identity

## Name
...

## Expertise
- 항목 1
- 항목 2

## Personality
...
```

vim이나 VSCode로 열면 이 구조를 **사람이 매번 신경 써서** 지켜야 합니다. 섹션 순서가 바뀌거나, ownership 주석을 지우거나, 자동 생성 영역(`<!-- AIB:SESSION-MEMORY-PROTOCOL -->` 내부)을 건드리면 CLI가 정상 동작하지 않을 수 있습니다.

CC는 각 파일을 **스키마 기반 폼 에디터**로 제공합니다:

| 파일 | Ownership | 편집 UI |
|------|-----------|---------|
| `SOUL.md` | 🖋️ **직접 편집** | H2 섹션 폼 (Name / Expertise / Personality / Core Values / Constraints) |
| `GROWTH.md` | 🖋️ **직접 편집** | Decision Table 구조화 에디터 |
| `RULES.md` | ♻️ **자동 축적** | 3섹션 리스트 UI (Must Always / Must Never / Learned) |
| `agent.yaml` | 🔒 **aib 관리** | YAML 폼 — 읽기 전용 필드 명확히 구분 |

그리고 모든 파일 상단에는 **Ownership Banner**가 표시되어, 이 파일을 어떻게 다뤄야 하는지 한눈에 보입니다:

```
┌─────────────────────────────────────────────────────────────┐
│ 🔒 SYSTEM  이 파일은 aib CLI가 관리합니다. 수동 수정 금지.     │
└─────────────────────────────────────────────────────────────┘
```

**Round-trip 보장**: `RULES.md`를 CC에서 편집 → 저장하면, CLI가 기대하는 canonical 마크다운 포맷으로 정확히 복원됩니다. CC로 편집한 파일은 CLI가 읽을 때 *절대 깨지지 않습니다.*

---

### 🛎️ 자동 감시: 내가 잊어도 시스템이 기억

CC가 켜져 있는 동안 **두 개의 백그라운드 스레드**가 항상 돌고 있습니다.

**파일 감시 (FSEvent 기반)**:
```
~/.aib/barracks.json          ← 배럭 등록/해제
{barrack}/sessions/           ← 세션 생성/종료
{barrack}/SOUL.md             ← 에이전트 정체성 변경
{barrack}/RULES.md            ← 규칙 추가
{barrack}/GROWTH.md           ← 성장 트리거 변경
{barrack}/agent.yaml          ← 버전 / 메타데이터
```

변경이 감지되면 UI가 **자동으로 리프레시** — 새로고침 필요 없습니다.

**30초 주기 Health Check**:

🛑 **Stale Session 감지**
- 각 세션 파일의 mtime을 검사
- 2시간 이상 미갱신이면 stale 판정
- macOS 네이티브 알림 + 인앱 토스트 동시 발송
- 1시간 suppress window로 중복 알림 방지

🔄 **Sync 필요 감지** *(Origin Story 4번의 직접적인 해결책)*
- 현재 CLI 버전 vs 각 배럭의 `agent.yaml`의 `aib_version` 비교
- 불일치 배럭 수를 카운트해 알림 발송
- **CC 안에서 바로 Sync 버튼 클릭** → 일괄 `aib sync` 실행으로 모든 배럭에 한 번에 전파

CLI는 세션 시작 시점에 stale을 정리하지만, **CC는 stale이 *발생한* 시점에 알려줍니다.** 사후 대응에서 사전 대응으로의 전환입니다.

---

### 🟢 에이전트 생사 인지: 세션이 살아있는지 한눈에

각 세션 카드 앞의 **색점 하나**가 그 에이전트의 *실제* 상태를 말해줍니다. `aib`(≥ 1.3.0)의 Claude Code hook이 `sessions/.live/<id>.status` sidecar에 남긴 상태를, CC가 읽어 `kill(pid,0)` 프로세스 생존 확인 + 경과시간으로 **effective 상태**로 fold합니다 — `aib sessions state`와 **동일한 규칙을 Rust로 재구현**(매트릭스 일치를 단위 테스트로 고정).

| 점 | 상태 | 의미 |
|----|------|------|
| 🔵 | `working` | 도구 실행 중 (Pre/PostToolUse) |
| 🔵 흐림 | `working_stale` | working인데 180초+ 무갱신 |
| 🔴 | `blocked` | 사용자 승인/입력 대기 (Notification) |
| 🔴 테두리 | `crashed` | blocked인데 프로세스가 죽음 |
| 🟠 | `interrupted` | working 도중 프로세스가 죽음 |
| 🟢 | `done` | 턴 완료 (Stop) — 확인 대기 |
| ⚪ | `idle` | done을 확인함 (카드를 펼치면 자동 ack) |

- **PTY와 분리** — CC 내장 터미널 *밖에서* 띄운 `claude`도 파일 기반으로 추적됩니다.
- `.live/` 변경은 **250ms 디바운스**로 합치고, **30초 tick**으로 `working → working_stale` 같은 시간 전이도 반영합니다.
- `done` 카드를 펼치면 해당 run을 ack → ⚪ idle. Continue로 새 run이 시작되면 `run_id`가 바뀌어 자동으로 다시 활성 표시됩니다.
- *hook 없는 세션은 점이 없습니다 (Codex native hooks는 CLI v1.4에서 opt-in)* — 점의 부재를 idle로 오해하지 마세요.

> sidecar 스키마와 fold 알고리즘의 레퍼런스는 어디까지나 `aib sessions state`이고, CC는 그 규칙을 그대로 따릅니다 (헤드리스 일관성).

---

### ⌨️ 강화된 터미널: 웹뷰가 죽어도 PTY는 산다

CC의 터미널은 단순히 xterm을 내장한 게 아닙니다. **세션 생존성**이 핵심 설계 원칙입니다.

```
        ┌─────────────────┐           ┌──────────────────┐
        │  React + xterm  │ ───────→ │  PtySession       │
        │   (Channel)     │ ←─────── │    master PTY     │
        └─────────────────┘           │    output_buffer  │
                  ×                   │    (1000 chunks)  │
          웹뷰 리로드 발생             └──────────────────┘
                  │                          │
                  │                    버퍼에 계속 쌓음
                  ▼                          │
        ┌─────────────────┐                  │
        │  새 Channel     │  ←── replay ────┘
        │  reconnect()    │    버퍼 → 새 stream
        └─────────────────┘
```

**PTY 세션은 웹뷰로부터 분리**되어 있습니다. React가 리로드되거나 앱이 멈춰도, Rust 쪽의 `PtySession`은 독립적으로 돌면서 1,000 chunk까지 출력을 버퍼링합니다. 재연결 시:
1. 살아있는 PTY ID 목록을 조회 (`terminal_list`)
2. 각 PTY에 새 Channel 연결 (`terminal_reconnect`)
3. 버퍼 replay → 라이브 스트림 이어받기

**결과**: Claude Code가 10분짜리 리팩토링을 돌리는 중에 CC를 리로드해도 **아무것도 잃지 않습니다.**

**앱을 완전히 종료(Quit)하면 PTY는 사라집니다.** v1.3.0부터 이를 위해 **터미널 출력을 디스크에 영속화**합니다:
- 각 세션 scrollback이 `app_data/scrollback/<id>.bin`에 atomic하게 저장됩니다 (per-session 1MB cap, UTF-8 경계 안전, global 100MB + 14일 retention GC).
- 앱 재시작 시 살아있는 PTY가 없는 세션은 **archive 탭**(read-only)으로 복원돼 "프로세스 종료됨" 배너와 함께 이전 출력을 replay합니다. 같은 cwd에서 새 세션을 시작하거나 기록을 삭제할 수 있습니다 (자동 PTY 부착 없음).

시스템 트레이까지 더해 이중으로 보호합니다:
- 창을 X로 닫아도 → 트레이로 숨음, PTY 유지
- 트레이 메뉴의 "Quit"을 통해야만 → 모든 PTY 명시적 정리

**부가 디테일**:
- 🇰🇷 **한국어 IME 지원** — `event.isComposing` 감지로 조합 중 raw key 차단
- 🎨 **Truecolor + macOS System color** — `COLORTERM=truecolor` + Light/Dark 테마 자동 연동
- 🐚 **Login shell** — `-l` 플래그로 `.zshrc` 로드, GUI 앱 PATH 문제 자동 해결
- ⚡ **Quick Commands** — 자주 쓰는 명령을 저장해 클릭으로 실행

---

### 🧩 멀티 슬롯: Claude + Gemini + Codex 병렬 워크플로우

*Origin Story 3번 — "터미널이 엉망이 됐다" 에 대한 답입니다.*

Multi-LLM 워크플로우를 위해 설계된 **배럭별 독립 레이아웃**:

```typescript
activeTerminalPerBarrack: Record<string, string>    // 배럭 → 활성 터미널 ID
splitLayoutPerBarrack:    Record<string, SplitLayout>  // 배럭 → single | split | grid
panelWidthPerBarrack:     Record<string, number>    // 배럭 → 패널 너비
```

- `etf-platform` 배럭에는 Claude 하나만
- `o11y-cli` 배럭에는 Claude + Gemini + Codex **3분할**
- `research` 배럭에는 Gemini + Codex **2분할**

각 배럭의 레이아웃이 **독립적으로** 유지되고, localStorage에 저장되어 앱 재시작 후에도 복원됩니다. 슬롯 간 터미널 드래그 이동 시 중복 할당도 자동 방지됩니다. 더 이상 "어느 창이 어느 배럭인지" 헷갈리지 않습니다.

---

### 🔍 통합 검색: Cmd+K 한 번으로 모든 배럭을 훑다

```
Cmd+K → "ClickHouse ZooKeeper"
         ↓
         [모든 배럭] 병렬 스캔:
           • sessions/*.md
           • wiki/topics/*.md
           • RULES.md / SOUL.md / GROWTH.md
         ↓
         source 태그로 그룹핑:
           [session] o11y-cli / claude-20260215-1430 — "ZooKeeper XID overflow 디버깅"
           [wiki]    o11y-cli / ClickHouseOperations.md — "ZooKeeper 설정 패턴"
           [rules]   etf-platform / RULES.md — "ZooKeeper 재시작 전 replica 확인"
         ↓
         클릭 → 해당 파일/탭으로 즉시 이동
```

**여러 프로젝트에 걸친 지식**을 한 번에 찾을 수 있습니다. "그때 어느 배럭에서 했었지?" 에 대한 답이 1초 안에 나옵니다.

---

### 🧪 Skills 카탈로그: 배럭이 가진 능력의 지도

aib v1.1부터 모든 배럭이 `skills/<slug>/SKILL.md`를 first-class 자원으로 가집니다 — Anthropic Agent Skills 표준 + ai-barracks 확장 필드(`aib_version`, `upstream`). CommandCenter는 그 카탈로그를 한 화면에 풀어줍니다.

좌측에는 SKILL.md frontmatter를 파싱해 만든 카드 리스트(name, description, `aib X.Y · upstream · args: …` 메타 칩) + 검색 박스. 우측에는 선택한 스킬의 메타 박스와 마크다운 본문이 Wiki 탭과 같은 prose 스타일로 렌더됩니다.

**frontmatter가 깨진 SKILL.md는 silent skip하지 않습니다.** 카드 우상단에 ⚠️ 배지가 붙고 메타 박스에 빨간 `parse_error`가 노출되어, 시드를 손볼 시점을 놓치지 않게 합니다.

빈 상태에서는 "이 배럭에는 Skills가 없습니다 / `aib sync`로 시드를 받으세요" 메시지가 표시됩니다.

### Skills 카탈로그 + 등록·편집 (v1.2.0+)

각 배럭의 `skills/<slug>/SKILL.md`를 GUI에서 직접 등록·수정·삭제·이름 변경할 수 있습니다 (Anthropic Agent Skills 호환).

- **카탈로그**: 배럭에 등록된 모든 스킬을 카드로 검색·열람.
- **`[+ New Skill]`**: frontmatter 폼(name·description·argument-hint·allowed-tools·custom field 등) + 본문 markdown 에디터로 새 스킬 생성.
- **`[Edit]`**: 기존 스킬 편집. `[Rename slug]`로 디렉토리 이름까지 변경 가능 (frontmatter `name`도 자동 갱신).
- **`[Delete]`**: 슬러그 타이핑 확인 후 디렉토리 재귀 삭제.
- **Save & Sync 자동**: 모든 mutation은 `aib sync`를 자동 호출하여 W1 symlink + W2 카탈로그를 즉시 materialize. sync 실패 시 SKILL.md는 보존되고 `[Retry sync]` 배너가 표시됩니다.

> **요구사항**: aib v1.2.0+ 설치 (Skills loading wirings를 처리하는 것은 aib 본체).

---

### 🌿 Monorepo-aware Git

배럭이 repo 루트일 필요가 없습니다. `my-project/agents/etf-platform` 같은 **서브디렉토리도 지원**:

```rust
detect_git_root(barrack_path) → (git_root, is_sub_path)

if is_sub_path:
    git status --porcelain -- {barrack_path}    // 배럭 경로만 필터
    git log -- {barrack_path}                   // 해당 경로 커밋만
    git add -- {barrack_path}                   // 배럭 경로만 스테이징
    git commit                                   // 전체 repo에서 커밋
```

Git 탭에서:
- 🌿 Branch / ahead / behind 카운트
- 📝 변경 / untracked / staged 파일 수 (sub-path 필터링됨)
- 🔗 Remote URL + 최근 커밋
- 📜 최근 50개 커밋 로그 (sub-path 필터링됨)
- ✅ 커밋 · 푸시를 UI에서 바로 수행

업무/개인/자료 repo를 분리해서 쓰는 사용자에게 특히 유용합니다.

---

## 🏗️ 아키텍처

```
┌──────────────────────────────────────────────────────────────────┐
│  🎛️ CommandCenter (Tauri v2 Desktop App)                         │
│                                                                  │
│  ┌─── React 19 UI ──────────────────────────────────────────┐   │
│  │  Sidebar | MainContent | TerminalPanel | CommandPalette  │   │
│  │  Zustand (appStore / terminalStore / notificationStore)  │   │
│  └─────────────┬─────────────────────────────────┬──────────┘   │
│                │ invoke() IPC                    │ Channel 스트림 │
│  ┌─────────────▼─────────────────────────────────▼──────────┐   │
│  │  Rust Backend                                            │   │
│  │  ┌──────────────────────┐  ┌──────────────────────────┐ │   │
│  │  │ commands/            │  │ watcher.rs               │ │   │
│  │  │   barracks · files   │  │  FSEvent 파일 감시        │ │   │
│  │  │   sessions · wiki    │  │  30초 health check       │ │   │
│  │  │   git · search       │  │  stale / sync 알림        │ │   │
│  │  │   sync · terminal    │  └──────────────────────────┘ │   │
│  │  └──────────────────────┘  ┌──────────────────────────┐ │   │
│  │                            │ portable-pty 세션 관리    │ │   │
│  │                            │  output_buffer 1000 chunk │ │   │
│  │                            │  webview reload 견디는 PTY│ │   │
│  │                            └──────────────────────────┘ │   │
│  └──────────┬─────────────────────────────┬───────────────┘   │
└─────────────┼─────────────────────────────┼───────────────────┘
              │ subprocess                  │ fs read/write
              ▼                             ▼
     ┌──────────────────┐          ┌────────────────────────┐
     │  aib CLI         │          │  배럭 디렉토리          │
     │  (Homebrew)      │          │   ~/.aib/barracks.json │
     │   init · sync    │          │   {barrack}/sessions/  │
     │   barracks       │          │   {barrack}/wiki/      │
     │   version        │          │   {barrack}/SOUL.md ...│
     └──────────────────┘          └────────────────────────┘
```

**핵심 원칙**: CLI가 Single Source of Truth. CC는 파일 구조를 파싱·편집·시각화만 담당하며, 상태 변경이 필요한 작업(`aib init`, `aib sync`, `aib barracks refresh`)은 **항상 CLI subprocess로 위임**합니다. CLI 업그레이드가 곧 CC 업그레이드이며, 이중 구현으로 인한 드리프트가 없습니다.

---

## 🎯 Design Philosophy

### 1. CLI가 Single Source of Truth
CC는 상태 변경이 필요한 작업을 직접 구현하지 않고 CLI subprocess로 위임합니다. 이중 구현 없음, 드리프트 없음.

### 2. 파일 구조를 UI로 승격
Ownership 마커와 섹션 스키마를 UI-level 허락/경고로 번역합니다. 사용자가 일반 에디터로 여는 것보다 CC로 여는 쪽이 **구조적으로 더 안전**합니다.

### 3. 백그라운드에서 대신 기억한다
창을 닫아도 트레이에 숨어 PTY와 watcher가 돌아갑니다. **CC가 켜져 있다는 건, 누군가 내 배럭들을 지켜보고 있다는 뜻**입니다.

### 4. 네이티브 감성을 지킨다
xterm 팔레트, 창 테마, 알림 — 전부 macOS System color 기반. 시스템 트레이, 네이티브 notification, Korean IME — *"Tauri 앱인지 모를 정도"* 가 목표입니다.

---

## 📋 Requirements

- **macOS**
- **AI Barracks CLI** 설치 필수 (`/opt/homebrew/bin/aib` 또는 `/usr/local/bin/aib`)
- **하나 이상의 등록된 배럭** (`aib init`으로 생성)

---

## 🧱 Tech Stack

| Layer | Library | 역할 |
|-------|---------|------|
| Desktop | **Tauri v2** | 네이티브 쉘 + IPC |
| UI | **React 19** + TypeScript | 컴포넌트 렌더링 |
| State | **Zustand 5** | 배럭/터미널/알림 상태 |
| Styling | **Tailwind 3** + `@tailwindcss/typography` | Utility-first CSS |
| Terminal | **xterm.js 6** + FitAddon + WebLinksAddon | 터미널 UI |
| PTY | **portable-pty 0.8** | Rust PTY 추상화 |
| Watcher | **notify 8** (macos_fsevent) | 파일 감시 |
| Markdown | **react-markdown** + **remark-gfm** | 위키/세션 렌더링 |
| Async | **tokio** | PTY 비동기 스트림 |

---

## 🔗 관련 프로젝트

| 프로젝트 | 역할 |
|---------|------|
| [**ai-barracks**](https://github.com/ai-barracks/ai-barracks) | AI Barracks CLI — **엔진** (이 앱의 전제 조건) |
| [**slack-agent-bridge**](https://github.com/CYRok90/slack-agent-bridge) | Slack → 배럭 자동 라우팅 브릿지 |
| [**open-gitagent**](https://github.com/open-gitagent/gitagent) | 호환되는 에이전트 정체성 표준 |

---

## 📜 License

[MIT](https://opensource.org/license/mit)

---

<div align="center">

**Your barracks deserve a cockpit.**

*배럭에는 조종석이 필요합니다.*

[⭐ Star on GitHub](https://github.com/ai-barracks/ai-barracks-cc)&nbsp;·&nbsp;[🐛 Report a bug](https://github.com/ai-barracks/ai-barracks-cc/issues)&nbsp;·&nbsp;[🏰 AI Barracks CLI](https://github.com/ai-barracks/ai-barracks)


## 예약 활성화 (v1.5)

사이드바 상단 **CommandCenter → System → Scheduled activation**에서 CLI를 선택하고 ON을 확인합니다. 기본값은 **OFF**입니다.

- 시각: **06:00, 11:00, 16:00, 21:00 Asia/Seoul**, host timezone과 무관. Backend가 5초마다 확인하며 시각 직후 1분 안에 slot을 claim합니다.
- 동작: 선택한 Claude Code/Codex에 고정된 짧은 `OK` 요청. 모델은 격리된 CLI runtime 기본값을 사용하며 저장된 project/user model preference를 적용하지 않습니다. 개발 작업·프로젝트 파일·aib session summary를 실행하지 않습니다.
- 보호: CLI별 날짜/시각 claim을 **요청 전 디스크에 저장**하고 실패·crash에도 재전송하지 않습니다. 두 CLI는 순서대로 실행하므로 두 번째는 앞선 CLI의 종료 뒤 시작합니다. 인증 확인 20초, 모델 호출 120초 timeout.
- 인증: `claude auth status --json` / `codex login status`의 알려진 account auth만 허용합니다. API-key/대체 provider 환경변수는 제외하며 알 수 없는 auth나 미지원 CLI flag는 실패로 기록합니다. 인증 원문·token·model output은 저장하지 않습니다.
- ON/CLI 선택 변경/재시작은 **다음 미래 slot**부터 적용. OFF는 pending/in-flight subprocess를 중단하지만 이미 서버에 도착한 요청을 취소하거나 사용량을 되돌릴 수는 없습니다.
- **CC와 Mac이 실행·각성 상태여야 합니다.** 창을 닫아 tray로 숨기는 것은 가능하지만 Quit, sleep, reboot 중에는 실행하지 않습니다. 잠자기 해제, 로그인 자동 실행, 놓친 slot catch-up은 제공하지 않습니다.
- local app data의 `activation.json`/`activation.lock`에 설정과 최근 80개 기록을 보관합니다. 다른 CC instance가 lock을 가지거나 저장 파일이 손상되면 fail-closed로 비활성화합니다.

### 비용·검증 한계

짧은 요청도 사용량을 소모합니다. **사용량 window 시작/초기화 및 무료 실행은 보장되지 않습니다.** extra usage/credits가 켜져 있으면 account 로그인이라도 비용이 생길 수 있습니다. Scheduler는 CLI invocation을 slot당 한 번 시작할 뿐, provider/CLI 내부 transport retry 횟수까지 통제하지는 않습니다.

실제 모델 요청 없이 stub으로 회귀 검증했고, **2026-10-01 native macOS UI smoke**도 통과했습니다. 공개 CC v1.5.0에서 모델 metadata 조회, profile 저장/재시작, 예약 확인→ON→다음 KST slot 표시→OFF, provider 미선택 차단을 확인했습니다. 검증에 사용한 설치 CLI는 Codex 0.139.0 / Claude Code 2.1.118이며 이 버전들이 항상 최신이거나 모든 계정에서 지원된다고 주장하지 않습니다.

최종 상태는 두 model/effort profile runtime default, 두 provider 선택, 예약 OFF, activation history 0, 실제 model prompts 0입니다. **실제 slot 발송·모델 response/quality·PTY/IME 전체 E2E는 미실행**입니다. 관리자가 강제한 policy는 CLI에서 별도로 적용될 수 있습니다. 비용이 발생하는 실제 확인은 사용자가 ON을 선택한 뒤 진행하세요. 자세한 범위와 설치 제약은 [release validation](docs/release-validation-1.5.md)을 참고하세요.

관련 공식 동작: [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [Claude CLI reference](https://code.claude.com/docs/en/cli-reference).

개발 회귀 검증:

```bash
npm test
npm run build
cd src-tauri
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
```

## Provider / Model profiles (v1.5)

System의 모델 목록 조회는 모델 turn을 보내지 않습니다. Codex는 설치된 app-server의 `initialize → initialized → model/list`를 사용하고, advertised models·effort를 표시합니다. 최대 12초/4 pages, unknown schema/timeout은 오류 표시 후 runtime/custom 선택을 유지합니다. Claude 목록은 문서상 `sonnet`/`opus`/`haiku` alias로, 계정별 availability를 보장하지 않습니다.

빈 model/effort가 기본(runtime default)입니다. 저장된 profile은 Sessions·Command Palette의 **새 세션에만** 적용하며 기존 세션·Continue·예약 활성화에는 적용하지 않습니다. 이 launch 기능에는 `aib >= 1.4.0`이 필요합니다. model ID를 YAML 메타데이터나 전역 CLI 설정에 쓰지 않습니다.
