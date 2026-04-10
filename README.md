# AI Barracks CommandCenter

AI Barracks의 데스크톱 관제 앱. 배럭 관리, 설정 편집, 에이전트 히스토리, 위키 탐색을 한 곳에서.

> 스타크래프트의 Command Center처럼 — Barracks에서 유닛(에이전트)을 생산하고, Command Center에서 모든 것을 관제한다.

## 요구사항

- macOS (Apple Silicon / Intel)
- [ai-barracks](https://github.com/ai-barracks/ai-barracks) CLI (`brew install ai-barracks`)
- 1개 이상의 배럭이 `aib init`으로 초기화되어 있어야 함

> CommandCenter는 ai-barracks CLI의 GUI 확장입니다. CLI 없이는 동작하지 않습니다.

## 기능

### Overview
- 배럭별 상세 정보: 이름, 설명, Expertise 태그, 통계
- 버전 상태 표시 + 원클릭 Sync
- New Agent: Claude/Gemini/Codex 선택 → 터미널에서 세션 시작
- skip-permissions 토글

### Config (설정 편집)
- **SOUL.md** / **GROWTH.md**: 마크다운 에디터 + 실시간 프리뷰
- **RULES.md**: 구조화된 관리 UI (Must Always / Must Never / Learned 섹션별 규칙 추가/삭제)
- **agent.yaml**: 폼 에디터 (이름, 설명, 모델 설정)
- 파일 소유권 표시 (직접 편집 / 자동 축적 / aib 관리)

### Agents (에이전트 히스토리)
- 세션 타임라인: Task 제목 + 모델 배지 + 상태
- 필터: Status (Active/Completed/Interrupted) + Client (Claude/Gemini/Codex)
- 상세 보기: Log, Decisions, Blockers, Wiki Extractions
- Continue: 완료된 에이전트의 작업을 이어서 진행

### Wiki (지식 탐색)
- 토픽 카탈로그 + 렌더링된 마크다운 뷰어
- Recent Changes 표시

### System View (전체 관리)
- 사이드바 "CommandCenter" 클릭 → 전체 배럭 관리
- 버전 대시보드: 배럭별 aib_version vs CLI 버전 비교
- 선택적/일괄 Sync + Dry-run 모드
- 새 배럭 생성

### 기타
- **전체 검색**: 세션, 위키, 규칙, 설정 파일 통합 검색
- **Light/Dark 테마**: Apple HIG 기반 색상 체계
- **파일 실시간 감시**: 외부에서 파일 변경 시 UI 자동 갱신

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

- **Backend**: Rust (Tauri v2) — 파일 I/O, CLI 위임, 파일 감시 (notify)
- **Frontend**: React + TypeScript + Tailwind CSS
- **마크다운**: react-markdown + remark-gfm
- **상태관리**: Zustand
- **바이너리 크기**: ~10MB

## 로드맵

- [ ] 내장 터미널 (xterm.js + portable-pty)
- [ ] Git 연동 (상태 표시, commit, push)
- [ ] 시스템 트레이 상주 + 알림

## 관련 프로젝트

- [ai-barracks](https://github.com/ai-barracks/ai-barracks) — CLI 도구 (필수)
- [slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge) — Slack 연동
