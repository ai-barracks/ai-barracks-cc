# AI Barracks CommandCenter

AI Barracks의 데스크톱 관제 앱. 배럭 관리, 설정 편집, 에이전트 히스토리, 위키 탐색, 내장 터미널을 한 곳에서.

> 스타크래프트의 Command Center처럼 — Barracks에서 유닛(에이전트)을 생산하고, Command Center에서 모든 것을 관제한다.

## 요구사항

- macOS (Apple Silicon / Intel)
- [ai-barracks](https://github.com/ai-barracks/ai-barracks) CLI (`brew install ai-barracks`)
- 1개 이상의 배럭이 `aib init`으로 초기화되어 있어야 함

> CommandCenter는 ai-barracks CLI의 GUI 확장입니다. CLI 없이는 동작하지 않습니다.

## 기능

### Overview
- 배럭별 상세 정보: 이름, 설명, Expertise 태그, 통계
- 버전 상태 표시 + 원클릭 Sync (터미널에서 dry-run → 확인 → 실행)
- New Agent: Claude/Gemini/Codex 선택 → 내장 터미널에서 세션 시작
- Open Terminal: 배럭 경로에서 셸 열기 + `aib status` 자동 실행
- Council: 멀티-LLM 토론 (`aib council`) 실행
- skip-permissions 토글

### Config (설정 편집)
- **SOUL.md** / **GROWTH.md**: 마크다운 에디터 + 실시간 프리뷰
- **RULES.md**: 구조화된 관리 UI (Must Always / Must Never / Learned 섹션별 규칙 추가/삭제)
- **agent.yaml**: 폼 에디터 (이름, 설명, 모델 설정)
- 파일 소유권 표시 (직접 편집 / 자동 축적 / aib 관리)
- 저장 시 자동 검증: `aib sync --dry-run` 터미널 실행으로 변경 영향 확인

### Agents (에이전트 히스토리)
- 세션 타임라인: Task 제목 + 모델 배지 + 상태
- 필터: Status (Active/Completed/Interrupted) + Client (Claude/Gemini/Codex)
- 상세 보기: Log, Decisions, Blockers, Wiki Extractions
- **Monitor**: Active 세션 실시간 감시 (3초 간격 자동 갱신)
- **View**: 터미널에서 세션 파일 + Violation 파일 함께 보기
- **Continue**: 완료된 에이전트의 작업을 내장 터미널에서 이어서 진행

### Wiki (지식 탐색)
- 토픽 카탈로그 + 렌더링된 마크다운 뷰어
- Recent Changes 표시
- **Lint**: `aib wiki lint` 터미널 실행 (stale/oversized/index mismatch 검사)

### Git
- Branch, changes, remote URL 상태 표시
- **Changes 카드 클릭** → 터미널에서 `git diff` 보기
- Commit (변경사항 stage + 메시지 입력) / Push
- **커밋 히스토리 클릭** → 터미널에서 `git show` 상세 보기
- **Terminal Actions**: `git status`, `git add -p`, `git log --graph`, `git stash` 원클릭 실행
- Mono-repo sub-path 자동 감지 (배럭 하위 파일만 필터링)

### System View (전체 관리)
- 사이드바 "CommandCenter" 클릭 → 전체 배럭 관리
- 버전 대시보드: 배럭별 aib_version vs CLI 버전 비교
- 선택적/일괄 Sync + Dry-run 모드
- **Sync in Terminal**: 선택된 배럭들을 터미널에서 순차 동기화
- 새 배럭 생성

### 내장 터미널
- **xterm.js + portable-pty** 기반 완전한 터미널 에뮬레이터
- 좌우 분할 레이아웃 (드래그로 폭 조절)
- 다중 터미널 탭 (동시 여러 세션 실행)
- ai-barracks 기능과 깊이 연동:
  - 배럭 Overview/Agents/Git/Wiki 등 모든 UI 액션이 터미널에서 실행
  - 인앱 알림 (Stale 세션/Sync 필요) → **Resume/Sync 버튼** → 원클릭 터미널 실행
  - 검색 결과 클릭 → 해당 배럭 선택 + 터미널에서 파일 내용 보기
- **Export**: 터미널 출력을 파일로 저장 (ANSI 코드 제거)
- **Quick Commands**: 자주 쓰는 명령어 저장 → 커맨드 팔레트에서 재실행

### 커맨드 팔레트 (`Cmd+K`)
- 현재 배럭 컨텍스트 기반 명령어 추천
- 카테고리: Agent (세션 시작), AIB (status/sync/lint/council), Git (diff/add-p/graph), Quick (사용자 저장 매크로)
- 화살표 키 + Enter로 빠른 실행
- 멀티 배럭 일괄 Sync, Barracks List 등 시스템 명령

### 터미널 설정
- **폰트**: 종류 (SF Mono, Menlo 등), 크기 (10~24px), 줄 높이 (1.0~2.0)
- **커서 스타일**: block / underline / bar
- `Cmd+`/`Cmd-` 단축키로 폰트 크기 즉시 조절
- 앱 테마 (Dark/Light) 전환 시 터미널 색상 자동 동기화
- 설정값 localStorage 영구 저장

### 기타
- **전체 검색**: 세션, 위키, 규칙, 설정 파일 통합 검색 → 클릭 시 배럭 라우팅 + 터미널 보기
- **Light/Dark 테마**: Apple HIG 기반 색상 체계
- **파일 실시간 감시**: 외부에서 파일 변경 시 UI 자동 갱신
- **시스템 트레이**: 메뉴바 상주, 윈도우 닫아도 감시 계속
- **인앱 알림**: Stale 세션 (2시간+), Sync 필요 시 액션 버튼 포함 토스트 알림
- **단축키**: `Cmd+K` 커맨드 팔레트, `` Cmd+` `` 터미널 토글, `Cmd+`/`Cmd-` 폰트 크기

## 다운로드

[GitHub Releases](https://github.com/ai-barracks/ai-barracks-cc/releases)에서 macOS용 .dmg를 다운로드할 수 있습니다.

> Apple Silicon과 Intel 모두 지원하는 Universal Binary입니다.

## 빌드

```bash
# Rust 설치 (없는 경우)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Tauri CLI 설치
cargo install tauri-cli --version "^2"

# 의존성 설치 + 빌드
npm install
npm run tauri build
```

빌드 산출물:
- `.app`: `src-tauri/target/release/bundle/macos/AI Barracks CommandCenter.app`
- `.dmg`: `src-tauri/target/release/bundle/dmg/`

## 개발

```bash
npm run tauri dev    # 핫 리로드 개발 서버
```

## 기술 스택

- **Backend**: Rust (Tauri v2) — 파일 I/O, CLI 위임, 파일 감시 (notify), PTY 관리 (portable-pty)
- **Frontend**: React + TypeScript + Tailwind CSS
- **터미널**: xterm.js + @xterm/addon-fit + @xterm/addon-web-links
- **마크다운**: react-markdown + remark-gfm
- **상태관리**: Zustand
- **바이너리 크기**: ~11MB

## 로드맵

- [x] Git 연동 (상태 표시, commit, push, mono-repo sub-path 지원)
- [x] 시스템 트레이 상주 + 알림 (stale 세션, sync 필요)
- [x] 내장 터미널 (xterm.js + portable-pty)
- [x] 터미널-배럭 통합 (알림 액션, Git/Sync/Wiki 연동, 세션 모니터링)
- [x] 커맨드 팔레트 + Quick Commands
- [x] 터미널 Export + 설정 (폰트/크기/테마)

> v1.0.0 — 모든 로드맵 항목 완료.

## 관련 프로젝트

- [ai-barracks](https://github.com/ai-barracks/ai-barracks) — CLI 도구 (필수)
- [slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge) — Slack 연동
