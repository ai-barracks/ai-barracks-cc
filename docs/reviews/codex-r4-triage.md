# Codex r4 처리 (2026-11-05)

리뷰: `docs/reviews/codex-r4.md` (범위 `87a558c..55c718c`, blocker 0 · major 16 · minor 1, MD-05 검증 포함). 각 항목을 코드·재현으로 확인한 뒤 판정했다. 17건 모두 수용했고, 그중 3건은 r5에서 이미 고쳐져 있었다.

"재현"은 수정 전 코드(옛 데몬 바이너리 또는 변이체)에서 테스트가 실패하는 것을 실제로 확인했다는 뜻이다. "재현 안 됨"은 코드 경로상 성립하지만 이 환경에서 실패를 만들어 내지 못한 경우로, 방어적으로 수정하고 불변 조건 검사를 추가했다.

| # | 등급 | 지적 | 판정·근거 | 수정 | 회귀 테스트 |
|---|---|---|---|---|---|
| 1 | major | libghostty backlog 통지 역전 → 소켓 영구 정지 | 수용 — 통지가 잠금 해제 뒤에 실행되어 순서가 보장되지 않음 | 0f217d8: libghostty patch 4, 통지 잠금을 상태 잠금 해제 전에 잡아 계산 순서대로 전달 | 스레드 경합이라 결정적 재현 테스트 없음(코드 검토로 확인) |
| 2 | major | EAGAIN 없는 송신 완료 시 재개 통지 없음 | 수용 — `hadBacklog`가 EAGAIN에만 묶임 | e3e4969: pending이 low-water 이하로 내려가면 통지 | smoke `pressure`(재개 후 전체 시퀀스 수신). EAGAIN 없는 경로 자체는 재현 안 됨 |
| 3 | major | 연속 출력 중 pause·stop 무시 | 수용, 재현 안 됨 — `cat`으로 PTY를 마르지 않게 해도 옛 데몬이 pause를 지킴 | e3e4969: batch마다 pause·stop 확인, pending 8 MiB 상한, 종료 시 마지막 읽기 4 MiB 제한 | smoke `pressure`(고정 20만 줄·끝 marker·EXITED 1회, 정지 중 자식 생존), `exit-order` |
| 4 | major | replay 입력 mute 경계가 수신·파싱과 어긋남 | 수용(재현) — mute를 marker 기반으로 바꾼 중간 수정에서도 replay 질의 응답이 샘(PS-04a 응답 2회, PS-01d stray). Ghostty가 응답을 app mailbox로 비동기 전달하기 때문 | 0f217d8: mute 제거, replay를 `ghostty_surface_write_buffer_replay`(libghostty patch 0011, Swift wrapper 미노출 → vendored patch 5)로 live 출력과 같은 큐에서 순서대로 파싱 | PS-04a(replay 질의 무응답 + 바로 뒤 live 질의 정확히 1회 응답), PS-01d |
| 5 | major | ATTACH가 마지막 OUTPUT보다 EXITED를 먼저 받음 | 수용, 재현 안 됨 — 옛 데몬도 `exit-order` 통과 | e3e4969: 출력 전달이 끝난 뒤에야 `exitInfo` 공개 | smoke `exit-order`(HUP 무시 자손이 계속 쓰는 중 자식 종료 + ATTACH, 두 연결 모두 EXITED 뒤 OUTPUT 없음) |
| 6 | major | DispatchSource 취소 전 fd close | 수용 — Apple 문서 요구사항 위반(Codex도 영향은 "추정") | e3e4969: FramedConnection·PTY write source 모두 취소 완료 뒤 한 번만 close | 재현 테스트 없음(fd 재사용 경합) |
| 7 | major | 일시적 복원 실패가 살아 있는 세션 종료로 이어짐 | 수용 — LIST 실패 시 nil → 빈 grid가 sessions.json 덮어씀 | 49eab15: LIST 재시도, 실패 시 저장본 유지(새로 연 pane과 병합) | PS-03a |
| 8 | major | HUP 무시 자손이 pane 종료 후 생존 | 수용(재현) — 옛 데몬 `kill-tree` FAIL | e3e4969: 유예 후 같은 session의 프로세스 전부 SIGKILL(reap된 leader 번호는 제외) | smoke `kill-tree` |
| 9 | major | 마지막 출력 파싱 전 보관 | 수용(재현) — PID 종료 시 보관하는 변이체가 PS-04b FAIL(보관본에 끝 marker 없음) | 0f217d8: 종료 뒤 marker가 실행될 때 보관, PID 감시는 종료 표시만 | PS-04b |
| 10 | major | 활성화: 취소 확인보다 spawn이 먼저 | 수용 — r5 #1과 같은 지적 | 7458dba(r5에서 수정) | AC-01b |
| 11 | major | 세션 callback 순환 참조 | 수용(재현) — 옛 데몬 `leak` FAIL(+58 MB/60세션) | e3e4969: id만 캡처, 종료 시 callback 해제 | smoke `leak`(+80 KB) |
| 12 | major | 읽지 않는 자식에 대한 입력 무제한 누적 | 수용(재현) — 옛 데몬 `input-cap` FAIL | e3e4969: 8 MiB 초과 입력은 거부하고 FAILURE 프레임 전송 | smoke `input-cap` |
| 13 | major | agent.yaml block scalar 손상 | 수용 — r5 #4와 같은 지적 | f272020(r5에서 수정) | CR-05a |
| 14 | major | GROWTH 표 escaped pipe 유실 | 수용 — r5 #7과 같은 지적 | f272020(r5에서 수정) | CR-05a, GR-01a/b |
| 15 | major | `run-persist-test.sh`가 1단계 실패 무시 | 수용 | 0f217d8: 1단계 `PS-01-setup` pass 필수, 2단계 PS-01·PS-02·PS-04 모두 pass여야 exit 0 | 스크립트 자체(두 실행 판정 결합) |
| 16 | minor | PS-02b가 crash 감지 결함을 판별 못 함 | 수용 — SHUTDOWN은 자식도 종료시킴 | 0f217d8: PS-02b에 사전 준비·데몬 소멸 조건 추가, PS-02c 신설(HUP 무시 자식이 살아 있는 채 데몬 SIGKILL → 연결 끊김만으로 pane 종료) | PS-02b, PS-02c |
| 17 | major | ptyd-smoke pressure가 prefix만 확인 | 수용 | e3e4969: 고정 길이 시퀀스·끝 marker·EXITED 순서·정지 중 자식 생존 확인 | smoke `pressure` |

## 함께 발견한 것

- macOS tty의 ONLCR은 한 write가 줄바꿈 위치에서 나뉘면 CR을 하나 더 넣는다(`\r\r\n`). 블록마다 같은 위치에서 나타나므로 데몬의 유실처럼 보였다. smoke는 `stty -onlcr`로 이 처리를 끈다.
- libghostty-spm upstream에는 이미 `ghostty_surface_write_buffer_replay`(patch 0011)가 있었다. Swift wrapper가 이 함수를 노출하지 않아 v2는 입력 mute로 우회하고 있었다.

## MD-05

r4 검증 근거에 따라 pass로 판정했다(`docs/evidence/2026-11-05-md05-review.json`).
