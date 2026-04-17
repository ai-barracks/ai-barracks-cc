# Changelog

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
