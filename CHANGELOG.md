# Changelog

## [Unreleased]

사용자 실사용 피드백(2026-11-06) 반영.

- **Agents**: "세션" → "Agents". 그리드 위 New Agent 막대(Claude·Codex·Gemini·Terminal·Council, skip-permissions)와 실행 중 에이전트 칩(상태 점·전환·닫기)
- **Barrack**: 사이드바 맨 위 새 항목 — 배럭 정보(Info)와 상태(Status)를 나란히. 오른쪽 패널은 Outputs만
- 메뉴 이름 통일: Barrack · Agents · History · Rules · Wiki · Skills · Council · Git
- **창 크기 변경 충돌 수정**: Rules·Wiki·History·Skills에서 창을 최소 크기로 줄이면 앱이 종료되던 문제(SwiftUI inspector의 열 크기 협상 루프). Outputs 패널을 직접 만든 열로 바꿔 해결. 화면 전환 때 패널 폭이 바뀌던 것과 터미널 출력이 사라지던 것도 함께 해결
- 좁은 창: Agents 막대는 가로 스크롤, Barrack은 위아래로 쌓임, 문서 목록은 좁아짐, 헤더 문구는 한 줄(전체는 마우스 오버)

Codex build-84 재검증 반영(2026-11-08, `docs/reviews/codex-build84-triage.md`).

- **Barrack Status 결과가 다른 배럭에 보이던 문제**: 점검 중 배럭을 바꾸면 이전 배럭의 빈 세션·Wiki 경고(파일 목록 포함)가 새 배럭 화면에 남고, 새 배럭 점검은 빠지던 것. 결과를 배럭별로 묶고 늦게 끝난 이전 점검은 버림
- **Outputs가 터미널을 밀어내던 문제**: 작은 창에서 Outputs를 넓혀 두면 터미널이 8열까지 좁아지던 것. 가운데 작업면 420pt를 먼저 남기고, 자리가 모자라면 Outputs를 접음
- **Ctrl+C**: 터미널에 포커스가 있으면 ⌃+영문자(⌃C·⌃D·⌃Z 등)는 메뉴보다 먼저 터미널로. macOS Window 메뉴의 "중앙 정렬"(fn⌃C)이 Ctrl+C를 가져가 창만 움직일 수 있던 경로를 막음. fn⌃C 가운데 정렬·⌘C 복사는 그대로
- 4분할이 빈 셸로 차 있으면 새 Agent·정비·Council이 빈 셸 하나를 대신 씀. 모두 사용 중이면 "터미널 4개가 모두 사용 중" 알림(전에는 아무 반응 없음)
- Barrack Info의 규칙 수가 RULES.md 전체(하위 섹션 포함)를 셈
- 빌드 기록에 source commit·dirty 여부·실행 파일 해시, Info.plist에 `AIBSourceCommit`
- **미완(설계 대비)**: Council 의사록 전용 화면(라운드 접기·결론·합의도·검증 상태), `archive prune`·`hooks codex install` 전용 경로

## [2.0.0-beta.2] - 2026-11-05

Codex 리뷰 r6·r7(수정분 리뷰) 지적 30건을 고친 베타.

- **예약 활성화 교착 수정(beta.1 사용자 필독)**: 예약 시각이 되면 프로세스 게이트가 같은 잠금을 다시 잡아 멈추고, 그 뒤 git·aib sync·앱 종료까지 막히던 문제. beta.1에서는 예약 활성화를 켜지 마세요
- 터미널: 읽지 않는 프로그램에 입력이 거부되면 pane을 종료로 표시하지 않고 잠깐 경고만 표시. 앱이 꺼져 있는 동안 끝난 세션도 다시 붙을 때 출력 보관. 이미 끝난 셸이 남긴 백그라운드 작업도 pane을 닫으면 정리
- 문서 폼: 따옴표가 여러 줄에 걸친 YAML 값, 순서 있는 하위 목록·이어지는 본문, `\\|`가 든 GROWTH 셀, 원문에서 바꾼 skill name을 저장 전에 거부
- 이동 확인: ⌘⇧A·pane 메뉴·알림·새 pane에서도 편집 중이면 먼저 묻고, 버리면 편집 버퍼까지 초기화
- aib 쓰기: pane에서 실행하는 sync 적용과 앱 내부 sync가 같은 잠금으로 하나씩 실행(개발·출시 앱 공용)
- 업데이트: 이전 빌드가 남긴 PTY 데몬은 세션이 없으면 새 데몬으로 교체, 세션이 있으면 유지하고 알림
- 터미널 출력 보관: 중간에 끊긴 보관본은 프로그램이 끝난 뒤 최종 출력으로 갱신

## [2.0.0-beta.1] - 2026-11-05

CommandCenter 2 첫 베타. Swift + libghostty로 다시 만든 macOS 네이티브 앱으로, v1(1.6.1)과 나란히 설치된다.

- v1 1.6.1 기능 전체: 배럭 관리·추가·제거, 세션 기록, ⌘K, Health/정비 큐, 터미널 관리·Quick Commands·출력 내보내기, RULES·SOUL·GROWTH·agent.yaml 폼 편집(충돌 시 섹션 병합), Wiki, Skills 생성·편집·이름 변경·삭제, Git(배럭 경로만 커밋·push), Files, Council, 새 에이전트, 터미널 출력 보관, Provider/Model 프로필, 예약 활성화(v1과 파일·잠금 공유), v1 설정 가져오기
- 터미널: Ghostty 엔진, 1/2/4 분할, 출력 폭주 중 입력 지연 p95 16.7 ms(v1.6.1 240 ms), 리사이즈 잘림 없음
- 세션 유지: PTY 데몬이 셸을 소유해 앱을 다시 켜도 세션이 살아 있고 이전 화면을 재생(재생 속 질의에는 다시 응답하지 않음)
- 검증: 전체 self-test 155 pass / 0 fail, 출시 빌드 unit·agents·integration 99 / 0, 데몬 smoke 19/19, Codex 리뷰 r4·r5 지적 37건 수정
- 남은 것: 사람 검사 15건(한국어 IME 등), Codex 리뷰 r6(수정분) 진행 중
