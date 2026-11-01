# Go/No-go 현황 (2026-11-01 저녁 기준)

출처: self-test `2026-11-01T08-52-02Z`(exec 전체 + 캡처) + 증거 병합(`scripts/merge-evidence.py <run> docs/evidence/2026-11-01-*.json` → `report.merged.json`): 캡처 육안 검토 RS-01b·RS-02b·RS-04c, standalone 실행 `08-53-31Z`의 PK-01b, RS-06 PoC 실행 `09-59-09Z` 캡처 검토. 데몬 백엔드 전체 실행은 exec와 결과 상태가 같다.

## 차단 기준 41개: pass 25 · fail 0 · unverified 16

**pass (25)**: IN-05 IN-08 IN-09 IN-11 · RS-01 RS-02 RS-03 RS-04 RS-06 · ST-02 · SC-01 SC-02 SC-03 SC-04 SC-05 SC-06 SC-08 · ST-01 · MD-01 MD-04 · WS-01 · PK-01 · RG-02 RG-03 RG-04

**unverified (16) — 남은 방법별**

| 방법 | 기준 | 누가·언제 |
|---|---|---|
| 사람 5분 검사(README 체크리스트, ⌥⇧⌘L로 IME 로그 저장; 결과는 `docs/evidence/*.json`으로 기록 후 merge) | IN-01 IN-02 IN-03 IN-04 IN-06 IN-07 IN-10 · RG-01 · RD-01 RD-02 · RS-05 · SC-07 · MD-02 MD-03 · ST-04 | 사용자 — 합성 이벤트는 한국어 입력기(IMK)를 거치지 않아 실물 키보드만 판정 가능 |
| 코드 리뷰 | MD-05 (스크립트·외부 리소스 차단) | Codex — 사용 한도 해제(2026-11-04 19:40) 후 r4와 함께 |

## 비차단 스파이크

- **PS-01 세션 생존** pass(a~e), **PS-02 복구** pass(a/b) — `--backend=daemon`. 남은 제약은 known-issues #4.
- 처리량: 1분할 10만 줄 exec 39ms / daemon 69ms, 4분할 동시 exec 354ms / daemon 205ms. 폭주 중 입력 지연 p95 약 16ms(후보 기준 50ms).

## 해소된 제품 blocker

- #1 리소스 bundle 빌드 경로 의존 → vendoring + resolver(PK-01).
- #4 세션 생존 → 데몬 백엔드로 가능성 실증(기본값 전환은 미결).

## ST-02 판정 근거 (v1.6.1 기준선)

`scripts/run-bench.py latency` — 실제 HID 키 80개(6ms 간격)를 출력 폭주 중에 보내고 PTY 도착 시각과 비교(LoadSuite와 같은 규칙):

| 앱 | 부하 | p50 | p95 | 최대 | 표본 |
|---|---|---|---|---|---|
| aibcc v1.6.1 | 10만 줄(사전 등록) | 190.8ms | **240.4ms** | 242.6ms | 29 |
| PoC | 100만 줄(10배) | 11.5ms | **16.7ms** | 16.8ms | 57 |

후보 기준 50ms를 유지(기준선보다 훨씬 엄격). PoC는 10배 부하에서도 v1.6.1의 약 1/14. ST-02a(사전 조건 10만 줄)는 PoC가 40~60ms에 소화해 표본이 부족 → 10배 부하 결과로 충족 판정(종합자 판단, docs/evidence/2026-11-01-st02-baseline.json). Terminal.app은 키 전달 실패로, iTerm은 사용자 세션이 떠 있는 기존 앱이라(업데이트 대화상자도 키를 가로챔) 레퍼런스에서 제외.

## RS-06 판정 근거

PoC에서 Claude Code 2.1.287→(실행 중 자동 업데이트)2.1.316을 창 축소·확대, 패널 숨김·표시, 2/1분할, 20단계 빠른 드래그 2회 등 10회 레이아웃 변경에 통과시킨 캡처에서 잔해 0. 잔해 0은 어떤 레퍼런스 이하이므로 레퍼런스 캡처 없이 판정했다(레퍼런스 캡처는 `run-bench.py rs06`, 권한 대기). 실행 중 Claude Code가 스스로 업데이트를 설치했다(사용자 환경 변화).

## 재현 테스트(비차단)

- RP-10 알려진 이슈 #10(pane 교체 직후 키 유실): exec·daemon 각 60회 유실 0 → 재현 안 됨.
- RP-R5 Codex R5(창 상태 변화 후 화면 갱신): 리뷰 순서·최소화 복원 모두 그려짐(픽셀 비교) → 재현 안 됨.

## 대기 중

- Codex 리뷰 r4(87a558c..HEAD) — 한도 해제(2026-11-04 19:40) 후. 프롬프트: docs/reviews/codex-r4-prompt.md.
