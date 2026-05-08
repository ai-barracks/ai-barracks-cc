# Changelog

## [1.1.0] - unreleased

### Changed — Skills Schema Compatibility (paired with aib 1.1.0)
- **`YamlFormEditor`**: `agent.yaml`의 `skills:` 블록을 더 이상 하드코딩된 리스트 형식으로 덮어쓰지 않음. 파싱 시 raw block을 보존하고, 저장 시 그대로 재출력. 1.0.x 리스트 형식·1.1.0 객체 형식(`discovery: auto, enabled: [...]`) 모두 안전하게 편집 가능.
  - **회귀 수정**: 기존 1.0.x 에디터는 알려지지 않은 필드(예: 사용자가 추가한 `skills.delegation`)를 저장 시 silent 손실시켰음. v1.1부터 skills 블록은 read-then-write로 보존.
- **버전 정렬**: `package.json` + `Cargo.toml` 1.0.2 → 1.1.0. aib 1.1.0과 페어링.

### Notes
- aib ≥ 1.1.0 와 함께 사용 권장 (Skills 표준 디렉터리, `aib skills list/doctor` 명령).
- Skills 카탈로그 전용 탭은 v1.1.1로 이연 — 본 릴리즈는 편집기 호환성 확보가 목적.

## [1.0.1] - 2026-05-04

### Added
- **LAUNCH 실패 surfacing**: PTY가 5초 이내 exit하면 `useTerminal` Exit 핸들러가 inline 경고 배너를 출력 (Claude settings 깨짐 / Codex `--full-auto` 회귀 / CLI 미설치 등 흔한 원인 안내). 기존엔 `[Process exited]`만 짧게 떠서 진단이 어려웠음.
- **README Prerequisites 보강**: Claude/Gemini/Codex CLI 설치, `.claude/settings.local.json` 무결성 점검 스니펫, Codex 0.128 플래그 변경, 첫 Claude workspace trust 안내.

### Notes
- aib ≥ 1.0.1 와 함께 사용 권장 (Codex 플래그 회귀 수정 + Claude settings 사전검사).

## [1.0.0] - 2026-04-17

AI Barracks CommandCenter v1.0.0 공식 릴리즈.

### Features (v0.1.0 ~ v1.0.0 통합)

#### Overview
- 배럭별 상세 정보, 통계, Expertise 태그
- 버전 상태 표시 + 원클릭 Sync
- New Agent / Open Terminal / Council 실행

#### Config
- SOUL.md / GROWTH.md 마크다운 에디터 + 실시간 프리뷰
- RULES.md 구조화된 관리 UI
- agent.yaml 폼 에디터
- 파일 소유권 표시

#### Agents
- 세션 타임라인 + 필터 (Status, Client)
- Active 세션 Monitor (3초 자동 갱신)
- View (세션 + Violation 파일)
- Continue (완료된 작업 이어받기)

#### Wiki
- 토픽 카탈로그 + 마크다운 렌더링
- Recent Changes + Wiki Lint 실행

#### Git
- Branch, changes, remote URL 상태 표시
- Commit / Push
- 커밋 히스토리 + git show 상세 보기
- Terminal Actions (status, add -p, log --graph, stash)
- Mono-repo sub-path 자동 감지

#### System View
- 전체 배럭 버전 대시보드
- 선택적/일괄 Sync + Dry-run
- 새 배럭 생성

#### 내장 터미널
- xterm.js + portable-pty 기반 완전한 터미널 에뮬레이터
- 좌우 분할 레이아웃, 다중 터미널 탭
- Export (ANSI 제거), Quick Commands
- 폰트/크기/줄높이/커서 스타일 설정

#### 커맨드 팔레트 (Cmd+K)
- 배럭 컨텍스트 기반 명령어 추천
- Agent / AIB / Git / Quick 카테고리

#### 기타
- 전체 검색 (세션, 위키, 규칙, 설정 통합)
- Light/Dark 테마 (Apple HIG)
- 파일 실시간 감시
- 시스템 트레이 + 인앱 알림
