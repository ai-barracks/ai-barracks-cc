# Go/No-go 현황 (2026-11-01 정오 기준)

출처: self-test `2026-11-01T02-35-35Z`(exec 전체), `02-42-24Z`(PK-01 standalone), `02-34-02Z`(PS-01/02). 데몬 백엔드 전체 실행은 exec와 125개 결과 상태가 완전히 같다.

## 차단 기준 41개: pass 19 · fail 0 · unverified 22

**pass (19)**: IN-05 IN-08 IN-09 IN-11 · RS-03 · SC-01 SC-02 SC-03 SC-04 SC-05 SC-06 SC-08 · ST-01 · MD-01 MD-04 · WS-01 · PK-01 · RG-02 RG-03

**unverified (22) — 남은 방법별**

| 방법 | 기준 | 누가·언제 |
|---|---|---|
| 사람 5분 검사(README 체크리스트, ⌥⇧⌘L로 IME 로그 저장) | IN-01 IN-02 IN-03 IN-04 IN-06 IN-07 IN-10 · RG-01 · RD-01 RD-02 · RS-05 · SC-07 · MD-02 MD-03 · ST-04 | 사용자 — 합성 이벤트는 한국어 입력기(IMK)를 거치지 않아 실물 키보드만 판정 가능 |
| 창 캡처 육안 검토(`scripts/capture-watcher.sh` 실행 중 self-test) | RS-01 RS-02 RS-04 · RG-04 (RS-01b·RS-02b·RS-04c) | Claude — 최근 실행에 watcher가 없어 캡처 0장. 화면을 쓸 수 있을 때 재실행 |
| Claude Code TUI 리사이즈 잔해 비교 | RS-06 | Codex computer-use 또는 사용자(실제 claude 세션 실행이 필요해 부작용 동의 필요) |
| v1.6.1 기준선 측정 후 판정 | ST-02 (ST-02-baseline; ST-02a는 폭주가 40ms에 끝나 측정 창 부족 — ST-02c 확대 측정 p95 16.3ms로 보완) | Claude — 현재 Tauri 앱에 같은 부하·지연 측정 필요 |
| 코드 리뷰 | MD-05 (스크립트·외부 리소스 차단) | Codex — 사용 한도 해제(2026-11-04 19:40) 후 r4와 함께 |

## 비차단 스파이크

- **PS-01 세션 생존** pass(a~e), **PS-02 복구** pass(a/b) — `--backend=daemon`. 남은 제약은 known-issues #4.
- 처리량: 1분할 10만 줄 exec 39ms / daemon 69ms, 4분할 동시 exec 354ms / daemon 205ms. 폭주 중 입력 지연 p95 약 16ms(후보 기준 50ms).

## 해소된 제품 blocker

- #1 리소스 bundle 빌드 경로 의존 → vendoring + resolver(PK-01).
- #4 세션 생존 → 데몬 백엔드로 가능성 실증(기본값 전환은 미결).

## 대기 중

- Codex 리뷰 r4(87a558c..ee9ef57) — 한도 해제 후. 프롬프트: docs/reviews/codex-r4-prompt.md.
- 알려진 이슈 #10(pane 교체 직후 키 유실) 재현·Codex R5(창 복원 후 화면 갱신) — GUI 실행 가능할 때.
