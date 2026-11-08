# Codex build-84 재검증 처리 (2026-11-08)

리뷰: 배럭 `resources/reviews/20261108-aibcc-build84-recheck.md`(설치본 build 84 재검증)와 그 상세 근거 `20261107-aibcc-v2-progress-review.md`(F1~F4·사용성 관찰). 각 항목을 코드·재현으로 확인한 뒤 판정했다. "재현"은 수정 전 코드에서 테스트가 실패하는 것을 실제로 확인했다는 뜻이다.

| # | 등급 | 지적 | 판정·근거 | 수정 | 회귀 테스트 |
|---|---|---|---|---|---|
| F1 | P1 | 정비 결과가 다른 배럭에 표시되고 실행됨 | 수용 — 공유 store가 진행 중 새 요청을 버리고 늦게 끝난 이전 배럭 결과를 그대로 대입 | 결과를 배럭 id에 결속, 전환 시 비움, 세대 번호로 늦은 완료 폐기, 행 실행은 표시 중인 배럭 항목일 때만 (63c5241) | MT-01d(느린 가짜 scanner로 A 점검 중 B 전환 → B에 A 결과 없음, 역방향도) |
| F2 | P2 | 작은 창 + 최대 Outputs가 작업면을 잠식(8×26) | 수용 — 300~640 고정 clamp, 중앙 가용 폭 미고려 | 표시 폭 = min(저장 폭, 가용 폭 − 420), 200 미만이면 접음, 드래그는 표시 폭에서 시작 (454edb2) | LY-02a(경계값), LY-02b(최소 창 + 저장 폭 640 → pane 419pt·24열, New Agent 버튼 표시) |
| F3 | 설계 미완 | Council 의사록 전용 경험(라운드 접기·결론 중심·합의도·검증 3상태)과 `archive prune`·`hooks codex install` 전용 경로 없음 | 수용(범위) — 현재는 Markdown 뷰어·터미널 실행 수준 | **이번 구현 안 함.** RELEASE.md "미완 범위"에 명시, v1 패리티 완료와 aib 전체 의도 충족을 구분 | — |
| F4 | P2 | ux-stress가 마지막 라운드 hang·비정상 종료를 PASS로 셀 수 있음 | 수용 — 시작 로그만 확인 | 완료 marker(마지막 resize 뒤 출력) + 예외 없음 + exit 0/3 + 그 실행 report의 UX-02 pass (454edb2, d6adb91) | `ux-stress.sh --check-verdict`(가짜 실행 9종: 정상 2·hang·crash·timeout·abort·report 없음·UX-02 fail·다른 목적지) |
| IN-09 | 검증 마감 | 자동 Ctrl+C 실패 원인 격리 | 원인 확정 — 시스템 Window › 중앙 정렬(fn⌃C, mask 0x840000)이 fn 없는 합성 ⌃C를 가져가 창을 가운데로 옮김(`window_moved=true`), keyDown 미도달. 11/05 통과 이후 같은 OS에서 실패 시작, beta.2도 같은 실패 | 포커스된 터미널이 ⌃/⌃⇧+ASCII 영문자를 메뉴보다 먼저 처리. fn·⌥·⌘ 조합은 메뉴로(fn⌃C 가운데 정렬·⌘C 복사 유지) (855aae5) | IN-09a(press 시점 활성·key window·메뉴 ⌃C 점유 항목·창 이동 기록), IN-09b(누르기 직전 ⌃C 메뉴 항목 설치 — 수정 전 fail, 수정 후 pass), IN-09c(키 판정 11케이스) |
| U1 | 사용성 | 빈 셸 4개가 새 agent를 막음 | 수용 | 가득 찬 그리드에서 첫 번째 idle 셸(자식 프로세스 없음·미종료)을 제자리 교체. Agents bar는 교체할 셸도 없을 때만 비활성 (80cb37c) | PN-01a |
| U2 | 사용성 | `runInPane` nil(만석)이 조용함(정비·Council) | 수용 | 만석이면 "터미널 4개가 모두 사용 중" 알림(.panes) 후 nil (80cb37c) | PN-01a(바쁜 pane 4개 → nil + 알림) |
| U3 | 사용성 | Info 규칙 수가 폼 관리 목록만 합산(4) | 수용 | RULES.md의 코드 블록 밖 모든 항목(### 하위 섹션 포함). 폼 분류는 tooltip (80cb37c) | OV-02a |
| R | 출처 | build-info에 source commit 없음 | 수용 | build-info: build·source_commit·source_dirty·executable_sha256, Info.plist: AIBSourceCommit·AIBSourceDirty (3d0909e) | release 검증 시 확인 |

## IN-09 해석

- Codex의 실물 경로(CUA로 `sleep 60` → Ctrl+C → 130)는 build 84에서도 성공했다. 실물 키보드 이벤트는 fn 비트가 일관되어 메뉴가 일치시키지 않은 것으로 보인다. 자동 테스트의 합성 이벤트만 메뉴에 걸렸다.
- 그래도 제품에서 막은 이유: 터미널은 ⌃-영문자를 셸에 주는 것이 기대 동작이고, 사용자 지정 ⌃ 단축키나 OS 메뉴 변화에도 Ctrl+C·⌃D·⌃Z가 안전해진다. IN-09b는 이 보장을 OS와 무관하게 검사한다.
- 실물 한국어 IME·Ctrl+C 실물 키보드 확인은 사람 검사(G4)로 따로 남는다. 자동 통과로 대체하지 않는다.

## 미완 범위(F3)

설계 명세(배럭 `resources/design/aibcc-v2-design-spec-draft-2026-11-01.md`) 대비 남은 것:

1. Council 의사록 화면: 라운드 접기, 최종 결론 중심 표시, 합의도, 검증 3상태(미검증/통과/실패). 현재는 `councilMinutes` 목록 + 일반 Markdown 뷰어.
2. §8 `archive prune`, `hooks codex install` 전용 경로(의미·보존·위험 설명 포함). 현재는 터미널/Quick Command로만 실행 가능.

v1 패리티 완료 ≠ aib 전체 의도 충족. beta에서는 위 두 항목을 "미완"으로 표기한다.
