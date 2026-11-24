# Codex r6 처리 (2026-11-05)

리뷰: `docs/reviews/codex-r6.md` (범위 `55c718c..24108e7` = r4·r5 수정분, blocker 1 · major 13 · minor 3). 각 항목을 코드·재현으로 확인한 뒤 판정했다. 17건 모두 수용했다.

"재현"은 수정 전 코드(beta.1 데몬 바이너리 또는 한 줄 변이체)에서 테스트가 실패하는 것을 실제로 확인했다는 뜻이다.

| # | 등급 | 지적 | 판정·근거 | 수정 | 회귀 테스트 |
|---|---|---|---|---|---|
| 1 | blocker | 예약 활성화의 취소 확인이 같은 NSLock 재획득 → 교착 | 수용(재현) — `start()`가 lock을 잡은 채 `cancelled()` → `isShuttingDown`이 같은 lock 요청. 같은 lock을 쓰는 git·aib sync·종료도 함께 막힘. 변이체는 self-test가 멈춤 | a80f69c: 종료 상태를 별도 잠금으로, shutdown은 게이트를 먼저 닫고 kill | AC-01c(실제 Scheduler→Runner→BoundedProcess + 가짜 CLI: 슬롯 완료, 실행 중 OFF 즉시 종료) |
| 2 | major | libghostty patch 4: handler 재진입 교착 | 수용 — handler 실행 중 통지 잠금을 쥠. 현재 앱 handler는 재진입하지 않지만 계약 위반 | 68e16e9: 변경을 상태 잠금 아래 순서대로 큐에 쌓고, 한 스레드가 잠금 없이 순서대로 전달 | R6-01a(handler 안에서 handler 교체·pending 조회) |
| 3 | major | write source 취소 전 세션 해제 시 master fd 누수 | 수용, 재현 안 됨(Codex도 "추정") | 68e16e9: cancel handler·reader 완료 블록이 세션을 강하게 잡음 | 결정적 재현 테스트 없음(완료 순서 경합) |
| 4 | major | leader가 먼저 끝나면 남은 자손 미정리 | 수용(재현) — beta.1 데몬 smoke `kill-tree` FAIL | 68e16e9: reap 시점에 남은 session 구성원을 pid+시작 시각으로 기록, 이후 KILL이 그 프로세스만 종료(재사용 pid 보호) | smoke `kill-tree`(leader 종료 후 KILL) |
| 5 | major | 입력 상한 거부가 클라이언트에서 세션 종료로 처리 | 수용(재현) — FAILURE 프레임 → pane `hasExited` | 68e16e9: 별도 `INPUT_REFUSED` 프레임(구 클라이언트는 무시), pane은 잠깐 경고만 | PS-05a, smoke `input-cap`(거부 뒤 세션 생존·입출력 회복; beta.1 데몬 FAIL) |
| 6 | major | 앱이 없을 때 끝난 세션은 다시 붙어도 보관 안 함 | 수용 — `alive=false`를 "보관됨"으로 간주 | 68e16e9: 마지막 출력 파싱 뒤 보관, 데몬 pane은 세션 id로 보관해 재실행 시 중복 없음 | PS-05b |
| 7 | major | 같은 들여쓰기의 따옴표 여러 줄 값 손상 | 수용 | b3ff433: 같은 줄에서 닫히지 않는 따옴표·flow 값은 여러 줄로 보고 폼 저장 거부 | R6-01b |
| 8 | major | 순서 있는 하위 목록·이어지는 본문이 중첩 거부를 우회 | 수용 — 목록을 다시 쓰면 다른 항목으로 옮겨 붙음 | b3ff433: 마지막 항목에 속한 내용(바로 이어지는 줄, 빈 줄 뒤 들여쓴 내용)이 있으면 폼 저장 거부. 실제 배럭 문서 24개에는 해당 모양 0건. DP-01b fixture는 빈 줄로 분리 | R6-01b, DP-01b |
| 9 | major | GROWTH 셀 pipe 검증과 tokenizer 불일치 | 수용 | b3ff433: 폼이 읽기 tokenizer로 셀 검증, 쓴 행은 다시 읽어 같은지 확인 | R6-01b |
| 10 | major | raw→폼 전환으로 skill name 검증 우회 | 수용 | b3ff433: 두 편집기 결과 모두 같은 frontmatter 규칙 적용 | R6-01b |
| 11 | major | pane에서 실행하는 aib sync가 쓰기 큐를 우회 | 수용 | 72f6874: pane의 적용 단계(`lockf`)와 앱 큐가 같은 파일 잠금. 잠금은 적용 중에만(Enter 대기 중엔 아님) | R6-01c |
| 12 | major | ⌘⇧A·pane 메뉴가 이동 확인 우회 | 수용 | 72f6874: 모델 진입점(⌘⇧A·pane 메뉴·검색 결과·알림·새 pane·Quick Command·배럭 추가)이 스스로 확인. ⌘K의 일괄 감싸기는 제거(시트 열기가 편집을 버리던 문제) | NV-01b |
| 13 | major | 이동 없는 확인이 dirty 표시만 지움 | 수용 | 72f6874: "버리고 이동" 시 편집 버퍼도 초기화(discardRevision), 현재 위치 재선택은 묻지 않음 | NV-01b |
| 14 | major | make-demo.sh 경로 문자열 검사만으로 `rm -rf` | 수용 — `/tmp/../..`가 prefix 검사 통과 | 57229ec: `/tmp` 바로 아래 일반 폴더 이름만, 스크립트가 만든 표식 파일이 있을 때만 삭제 | 수동 확인(위험 경로 4종 거부, 표식 없는 폴더 보존, 정상 생성·재생성) |
| 15 | minor | AC-01b가 뒤에 붙은 인자를 못 잡음 | 수용 | 57229ec: argv 전체 비교 | AC-01b |
| 16 | minor | PR-01b 추가 요청 검사가 강제 종료와 경합 | 수용(추정) | 57229ec: 탐침의 쓰기 지점에서 기록(`onSend`) | PR-01b |
| 17 | minor | smoke leak이 준비 실패에도 PASS | 수용 | 68e16e9: 모든 사이클의 출력·종료 성공 필수 | smoke `leak` |

## beta.1 영향

- #1은 beta.1에 들어 있다. 예약 활성화를 켜고 예약 시각이 되어야 발생한다. 사용자의 공유 `activation.json`은 꺼져 있다(enabled false). beta.2에서 고쳤다.
- #5는 읽지 않는 프로그램에 8 MiB 넘게 붙여넣을 때만 보인다.
