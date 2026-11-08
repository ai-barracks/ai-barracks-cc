# Codex 리뷰(P11·P03, 32a738a..ad7d172) 처리 — 2026-11-08

리뷰: `docs/reviews/codex-p11p03.md`(major 8 · minor 3, 함수·줄 인용 확인). 11건 모두 수용.

| # | 등급 | 지적 | 처리 | 검증 |
|---|---|---|---|---|
| 1 | major | 확인·편집 이동 뒤 에이전트 차단 우회 | **수정**(3089a8a) — 입력은 `confirmSend` 하나로, 입력 직전 에이전트·pane 유효성·foreground 프로그램 재검사. raw `type` 제거 | QC-01b(편집 이동 중 에이전트 시작 → 0바이트), 변이체 fail |
| 2 | major | 자식 없음 = 빈 셸 오판 | **수정** — 기존 pane 입력은 항상 확인. 확인 시점 프로그램(process group+이름)과 다르면 거부 | QC-01b(빈 셸도 확인, 바뀐 프로그램 거부) |
| 3 | major | 편집 이동 뒤 cwd 재검사 없음, 데몬 chdir 실패 무시 | **수정** — `run`이 편집 이동 뒤 폴더 확인(3089a8a), 데몬은 들어갈 수 없는 폴더면 126+메시지(7acb41d, revision 3) | QC-01a(이동 중 폴더 삭제), smoke `cwd`(build 93 데몬 fail) |
| 4 | major | `"; exec"`가 `printf ok;` 등을 깨뜨림 | **수정** — 개행으로 분리 | QC-01a(`;`·따옴표·here-doc), 변이체 fail |
| 5 | major | 이미 가져온 v1 항목 cwd 미보완 | **수정** — 명령+폴더로 구분, 같은 이름·명령·폴더 없음 항목만 보완, 사용자 폴더는 덮어쓰지 않음 | QC-01c(parse→apply→reload), 변이체 fail |
| 6 | major | 재부착 후 시작 명령·cwd·agent 유실 | **수정** — 세션 기록에 command·directory·agent, 기록 없는 옛 세션은 저장 비활성(배럭 폴더 가장 안 함) | QC-01a(세션 기록), QC-01c(옛 기록 읽기) |
| 7 | major | CrashTrace handler가 async-signal-safe 아님 | **대기** — 사전 할당 버퍼·원시 주소만 쓰는 handler + 자식 프로세스 검증(CT-01a)으로 교체 예정. 진단 전용(self-test)이라 제품 경로 영향 없음 | — |
| 8 | major | 테스트 거짓 통과 | **부분 수정** — QC: fixture 실패 즉시 FAIL, 양성 대조, 확인 후 우회·편집 이동·바뀐 프로그램·재가져오기·경로 수정 편집기. **AC-02a 보강(ON→OFF→ON, 고지 문구, 5초 갱신)은 대기** | QC-01a/b/c |
| 9 | minor | cwd 공백 제거 | **수정** — 공백뿐일 때만 nil | QC-01c |
| 10 | minor | ON+사용 불가를 "꺼짐"으로 표시 | **대기** | — |
| 11 | minor | 기본 취소 미보장(확인 필요) | **대기** — 취소를 기본 동작으로 명시하는 확인 UI로 교체 예정, Return/Escape 사람 검사 | — |

## 실행 중 발견: 시트를 닫는 순간의 크래시

CrashTrace가 잡은 백트레이스(agents 2회 연속): SwiftUI `AppKitDialogBridge.updateExistingAlert`가 레이아웃 중에 경고창을 닫으며 `NSSheetMoveHelper closeSheet` 애니메이션을 중첩 run loop로 돌리고, 그 안에서 macOS 27 `UpdateCycle`의 `UC::DriverCore::continueProcessing`이 SIGSEGV. 경고창을 띄우고 잠깐 기다린 뒤(애니메이션 도중) 코드로 닫는 테스트(NV-01c, QC-01a)에서 발생. 테스트는 `settleSheet`로 시트 표시·닫힘을 기다리게 바꿈(3089a8a, 컴파일만 확인 — 디스크 부족으로 미실행). 사용자가 버튼으로 닫는 경로는 다르지만, 코드가 경고창을 닫는 제품 경로가 생기면 같은 위험이 있음(known-issues #13).

## 남은 일

- 디스크 확보 후: agents·unit·전체 self-test 재실행(settleSheet 포함), #7·#8(AC)·#10·#11 수정, Codex 재리뷰
