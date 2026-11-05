# Codex r7 처리 (2026-11-05)

리뷰: `docs/reviews/codex-r7.md` (범위 `8441e7f..101035e` = r6 수정분, blocker 0 · major 9 · minor 4). r6 blocker(예약 활성화 교착)는 해소됐다고 Codex가 확인했다. 각 항목을 코드·재현으로 확인한 뒤 판정했다. 13건 중 12건 수용, 1건 부분 수용.

"재현"은 수정 전 코드(beta.2 데몬 바이너리 또는 수정 전 파일)에서 테스트가 실패하는 것을 실제로 확인했다는 뜻이다.

| # | 등급 | 지적 | 판정·근거 | 수정 | 회귀 테스트 |
|---|---|---|---|---|---|
| 1 | major | 업데이트 후 남은 이전 데몬에 그대로 연결 | 수용(재현) — beta.2 데몬은 revision을 알릴 방법이 없음(smoke `hello` FAIL) | HELLO/WELCOME(revision 2). 시작 시 이전 revision이면 살아 있는 세션이 없을 때 교체, 있으면 유지하고 알림. 전환 기간에는 이전 데몬의 "input refused" FAILURE도 경고로 처리 | R7-01a(HELLO에 답하지 않는 대역: 세션 있음 → 유지, 없음 → 교체), smoke `hello` |
| 2 | major | reap 시점 목록이 이후 fork된 자손을 놓침 | 수용(재현) — beta.2 데몬 smoke `leftovers`(leader 종료 뒤 fork) FAIL | 알려진 구성원이 살아 있는 동안(세션 번호가 예약된 동안) 다시 훑고, SIGSTOP으로 fork를 멈춘 뒤 다시 훑어 SIGKILL | smoke `leftovers` |
| 3 | major | pruning·SHUTDOWN이 종료 세션의 자손을 정리 안 함 | 수용(재현) — beta.2 데몬 smoke `leftovers`(보관 한도 초과)·`shutdown` FAIL | 자손이 남은 기록은 pruning에서 보존(상한 64, 넘으면 정리 후 제거), SHUTDOWN은 종료 세션도 정리 | smoke `leftovers`, `shutdown` |
| 4 | major | 중간 보관본 때문에 최종 출력 보관 생략 | 수용 | 보관 기록에 `final`(종료 확인) 표시. 최종본이 아닌 기록은 끝난 뒤 다시 붙을 때 갱신 | PS-05c |
| 5 | major | anchor·tag 뒤의 따옴표 여러 줄 값 손상 | 수용 — 값을 바꾸면 anchor가 사라져 alias도 깨짐 | 값에 anchor·tag·alias(`&` `!` `*`)가 있으면 폼 저장 거부(primary·fallback) | R7-01b |
| 6 | major | `#`로 시작하는 모든 줄을 heading으로 취급 | 수용 | CommonMark ATX heading만 목록을 끝냄(`#tag`, 7개 `#`는 항목 본문) | R7-01b(RULES·GROWTH) |
| 7 | major | 개발·출시 앱이 서로 다른 잠금 사용 | 수용 | 잠금은 레지스트리 경로 기준, 두 앱 공용 폴더(`~/Library/Application Support/AIBarracks`). self-test는 자기 폴더 | R7-01d |
| 8 | major | Quick Command·새 pane이 확인 전에 실행 | 수용 | 편집 중이면 확인 전에는 아무것도 하지 않음(입력 송신·pane 생성 모두). 새 에이전트 시트는 확인 대기를 "가득 참"으로 오인하지 않음 | NV-01c(취소 시 입력 0바이트·pane 수 그대로, 확인 시 실행) |
| 9 | major | make-demo.sh 경로로 셸 주입 | 수용 | 이름은 `A-Z a-z 0-9 . _ -`만, 경로는 셸 코드에 넣지 않고 인자로 전달 | 수동 확인(주입 경로 3종 거부) |
| 10 | minor | pane 경로는 잠금 폴더를 준비하지 않음 | 수용 | `wrap`도 폴더 준비 | (R6-01c가 wrap 경로 사용) |
| 11 | minor | NV-01b가 실제 편집 버퍼 초기화를 검증 안 함 | 부분 수용 — 진입점의 실제 부작용 검사는 NV-01c로 추가. SwiftUI `@State` 편집 버퍼의 초기화는 자동 검사 범위 밖(사람 검사) | — | NV-01c |
| 12 | minor | R6-01a가 동시 호출 순서를 검증 안 함 | 수용 | — | R7-01c(두 번째 스레드의 변화가 handler를 기다리지도 끼어들지도 않고 순서대로) |
| 13 | minor | AC-01c가 교착 시 self-test 전체를 멈춤 | 수용 | 시나리오를 앱 자식 프로세스(`--selftest-probe=activation-gate`)에서 실행, 부모가 40초 watchdog | AC-01c |
