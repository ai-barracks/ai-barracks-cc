[major] `Vendor/libghostty-spm/Sources/GhosttyTerminal/InMemory/InMemoryTerminalSurfaceAccess.swift:127-129,296-298` — backlog 통지가 역전되면 소켓 읽기가 영구 정지한다.
재현/실패 시나리오: 수신 스레드가 `true` 통지를 준비하고 unlock 직후 선점 → 파서가 출력을 비워 `false` 전달 → 뒤늦게 `true` 전달 → 실제 backlog는 비었지만 소켓은 paused이고, 추가 상태 전이가 없어 재개되지 않는다.
수정 제안: 상태 변경 순서대로 통지를 단일 큐에 제출하거나 generation으로 오래된 통지를 폐기한다. callback 자체는 락 밖에서 실행한다.

[major] `Sources/PtyProtocol/FramedConnection.swift:163-174` — `EAGAIN` 없는 송신 완료에는 흐름 제어 재개 통지가 없다.
재현/실패 시나리오: daemon의 송신 대기가 1 MiB를 넘어 PTY를 pause → 상대가 빠르게 읽어 `writeBuffered()`가 `EAGAIN` 없이 모두 송신 → `hadBacklog == false`라 `onWriteDrained`가 호출되지 않는다. 이후 출력이 없으면 paused 상태가 유지된다. 실제 앱에서의 발생 빈도는 **추정**이다.
수정 제안: `EAGAIN` 경험 여부가 아니라 pending byte 수의 low-water 하향 통과를 기준으로 재개를 통지한다.

[major] `Sources/PtyDaemon/PtyReader.swift:109-129` — 연속 출력 중에는 pause·stop을 확인하지 않아 back-pressure를 우회한다.
재현/실패 시나리오: PTY가 계속 readable이거나 coalescing 대기 안에 출력이 들어옴 → `drain()`이 반환하지 않음 → daemon이 `setPaused(true)`를 호출해도 계속 읽는다. `maxBatch`는 전달 단위일 뿐 `pending`의 상한이 아니므로 메모리 증가와 연결 강제 종료가 가능하다.
수정 제안: bounded batch마다 pause·stop을 확인하고 pending에도 상한을 둔다. 종료 drain 역시 계속 생산되는 출력 때문에 무한히 연장되지 않도록 제한한다.

[major] `Sources/AIBCCPoC/Terminal/TerminalPane.swift:105-107,150-157` — 입력 mute의 해제 시점이 replay 수신·파싱 경계와 동기화되지 않는다.
재현/실패 시나리오: ATTACH 응답을 지연시키고 surface부터 생성 → size 변경이 settle을 시작 → 아직 출력이 없어 `waitForPendingOutput()`가 성공 → 나중에 도착한 과거 DA/DSR 응답이 실제 입력으로 샌다. 반대로 replay 직후 live 질의가 함께 파싱되면 필요한 응답까지 mute되어 자식이 기다릴 수 있다.
수정 제안: replay 수신 완료를 필수 조건으로 두고, 정확히 replay까지 파싱한 fence에서 unmute한다. 그 이후 live 출력은 fence 뒤에서 처리한다.

[major] `Sources/PtyDaemon/PtySession.swift:160-163` — 출력 drain 전에 공개되는 `exitInfo` 때문에 ATTACH가 EXITED를 너무 일찍 보낸다.
재현/실패 시나리오: `waitpid` 완료 → reader의 마지막 출력 전달 전 ATTACH 처리 → `Daemon.swift:128-129`가 EXITED 전송 → reader가 뒤늦게 OUTPUT과 정상 종료 통지를 전송한다. 수신 순서가 `EXITED → OUTPUT → EXITED`가 된다.
수정 제안: process reap과 출력 완료 상태를 분리하고, ATTACH의 EXITED도 마지막 OUTPUT 전달이 끝난 뒤에만 보낸다.

[major] `Sources/PtyProtocol/FramedConnection.swift:108-116` — DispatchSource 취소 완료를 기다리지 않고 fd를 닫는다.
재현/실패 시나리오: **추정:** 빠른 연결 생성·종료로 같은 fd 번호가 재사용되는 동안 기존 source의 내부 등록·해제가 완료되지 않아 감시 누락이나 dispatch 오류가 발생할 수 있다. `fdClosed`는 사용자 handler만 방어하며, Apple은 fd 해제를 cancellation handler에서 수행하도록 요구한다. [Apple 문서](https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/setcancelhandler%28handler%3A%29)
수정 제안: read/write source의 cancellation 완료를 모두 확인한 뒤 한 번만 close한다. PTY write source의 종료 처리에도 같은 수명 규칙을 적용한다.

[major] `Sources/AIBCCPoC/App/WorkspaceModel.swift:285-298` — 일시적인 복원 실패가 다음 실행에서 살아 있는 기존 세션의 종료로 이어진다.
재현/실패 시나리오: 기존 sessions.json과 살아 있는 세션이 있는 상태에서 LIST 한 번 타임아웃 → restore가 nil 반환 → init의 새 grid 저장이 기존 sessions.json을 덮어씀 → 다음 실행에서 기존 UUID들이 orphan으로 분류되어 KILL된다.
수정 제안: 복원 실패와 최초 실행을 구분하고, 실패 중에는 기존 저장본을 유지한다. 복원이 확인되기 전 새 snapshot 저장과 orphan sweep을 금지한다.

[major] `Sources/PtyDaemon/PtySession.swift:103-105` — 강제 종료가 root PID만 대상으로 하므로 pane을 닫아도 자손이 살아남는다.
재현/실패 시나리오: `trap '' HUP; sleep 600 & wait` 실행 → pane 교체 → master close의 SIGHUP 무시 → 3초 후 shell만 SIGKILL → HUP를 무시한 `sleep`은 계속 실행된다.
수정 제안: 소유한 process group과 자손의 종료를 관리하고, root PID 소멸만으로 정리 완료를 판정하지 않는다. HUP 무시 자손을 포함한 종료 테스트를 추가한다.

[major] `Sources/AIBCCPoC/Terminal/TerminalPane.swift:121-137` — 출력 파싱 완료 전에 archive를 저장하여 마지막 출력을 누락한다.
재현/실패 시나리오: 프로그램이 많은 출력과 마지막 결과를 쓰고 즉시 종료 → `ProcessExitMonitor`가 socket 전달·Ghostty 파싱보다 먼저 `onExit` 호출 → 이전 화면 또는 빈 화면을 archive → 이후 `.exited`에서는 archive를 갱신하지 않는다.
수정 제안: daemon의 최종 OUTPUT 수신과 terminal parsing 완료 뒤 archive한다. PID 종료 감지는 상태 표시와 최종 출력 저장을 분리한다.

[major] `Sources/AIBCCPoC/Activation/ActivationRunner.swift:142-157` — 취소 확인보다 spawn이 먼저여서 OFF·앱 종료 이후에도 요청을 시작할 수 있다.
재현/실패 시나리오: auth 완료 직후 설정 OFF → 다음 `BoundedProcess.run()`이 이미 취소된 상태에서도 request CLI를 spawn → 첫 cancellation 검사 전 네트워크 요청 가능. 또한 spawn과 `live.insert` 사이에 quit의 `killAll()`이 실행되면 새 자식이 정리 대상에서 빠진다.
수정 제안: 취소 generation 확인·spawn·live 등록을 하나의 launch gate로 보호한다. quit은 gate를 영구 폐쇄한 뒤 등록된 그룹을 종료한다.

[major] `Sources/PtyDaemon/Daemon.swift:110-115` — 세션 callback이 세션 자신을 강하게 캡처하여 종료 세션을 해제하지 못한다.
재현/실패 시나리오: `PtySession → onOutput/onExit closure → session` 순환 참조 형성 → pane 교체·KILL·32개 초과 pruning으로 dictionary에서 제거해도 replay와 reader 객체가 남는다. 반복 교체 시 메모리가 계속 증가한다.
수정 제안: callback에는 `session` 대신 미리 복사한 UUID를 캡처하고, 종료 완료 시 callback을 정리한다.

[major] `Sources/PtyDaemon/PtySession.swift:77-80` — 자식이 입력을 소비하지 않을 때 inputBacklog가 제한 없이 증가한다.
재현/실패 시나리오: `stty raw -echo; sleep 600` 실행 후 대용량 INPUT 반복 전송 → PTY write는 EAGAIN이지만 daemon은 소켓을 계속 읽어 `inputBacklog`에 누적한다. socket의 64 MiB 송신 제한은 이 별도 backlog를 제한하지 못한다.
수정 제안: 입력에도 세션별 high/low-water와 hard cap을 적용하고, 해당 입력 생산자에 back-pressure 또는 명시적 거부를 전달한다.

[major] `Sources/AIBCCPoC/Documents/Structured/AgentYamlDocument.swift:151-157` — YAML block scalar를 한 줄 scalar처럼 수정하여 원문을 손상시킨다.
재현/실패 시나리오: `description: |\n  line: value\n`의 description을 폼에서 `new`로 변경 → 첫 줄만 `description: new`로 교체하고 기존 block 본문을 남김 → 잘못된 YAML이 저장된다. `blocked()`의 probe도 이 형태를 거부하지 않는다.
수정 제안: block·multiline scalar는 폼 편집을 차단하거나, scalar 전체 범위를 파싱하여 교체한다. 저장 결과를 실제 YAML parser로 검증한다.

[major] `Sources/AIBCCPoC/Documents/Structured/GrowthDocument.swift:121-129` — escaped pipe를 열 구분자로 처리하여 표 내용을 유실한다.
재현/실패 시나리오: `| A\|B | rules | keep |`를 읽으면 event=`A\`, location=`B`, example=`rules`가 된다. 다른 행 하나만 편집해도 표 전체 재작성 과정에서 원래 `keep` 값이 사라진다.
수정 제안: escape와 code span을 이해하는 표 tokenizer를 사용한다. 지원하지 않는 행은 저장을 차단하고, 열 수를 `>= 3`으로 허용하지 않는다.

[major] `scripts/run-persist-test.sh:41-47,80-84` — phase 1 실패를 최종 판정에 반영하지 않아 PS-01이 false-pass할 수 있다.
재현/실패 시나리오: DA 질의 또는 응답 기능을 제거 → phase 1은 `da_answered=false`로 fail하지만 state 파일은 저장 → phase 2는 stray가 없고 입력이 동작하여 pass → 스크립트는 phase 2의 PS-01/02만 검사하여 exit 0.
수정 제안: phase 1의 `PS-01-setup == pass`를 명시적으로 강제하고, 두 실행의 결과를 최종 판정에 함께 반영한다.

[minor] `Sources/AIBCCPoC/SelfTest/PersistSuite.swift:151-159` — PS-02b의 정상 shutdown은 daemon crash 감지 결함을 판별하지 못한다.
재현/실패 시나리오: `connectionClosed()`의 종료 처리가 고장 나도 SHUTDOWN이 먼저 자식을 종료하여 PID monitor가 `hasExited`를 설정 → 기존 pane 종료·새 daemon 생성 조건이 모두 충족되어 pass한다.
수정 제안: 정상 shutdown과 daemon SIGKILL을 별도 시험하고, 사전 recorder ready와 daemon 소멸 대기의 성공 여부도 필수 조건으로 검사한다.

[major] `scripts/ptyd-smoke.py:265-270` — pressure 검사는 유효한 출력 prefix만 확인하여 재개 실패·후미 유실을 놓친다.
재현/실패 시나리오: 첫 10,001줄 이상을 버퍼링한 뒤 출력이 영구 정지하거나 이후 출력을 버림 → 재개 구간에는 기존 prefix만 수신 → RSS 차이·순서·최소 줄 수 조건을 만족하여 pass한다. EXITED 대기의 성공도 판정에 포함되지 않는다.
수정 제안: 총량이 정해진 sequence와 종료 marker를 사용하여 전체 개수·내용·종료 순서를 검증한다. 재개 이후 새 출력이 실제로 생산·수신되었는지도 별도로 확인한다.

**MD-05 검증 근거**
- `Renderer/src/render.js:8-11,38`: raw HTML 허용 옵션이 없으며, 현재 dist 변환 검사에서 script·onerror·iframe·object·SVG는 escape되고 `javascript:`·`data:` URL은 빈 URL로 처리됐다. [micromark 보안 규칙](https://github.com/micromark/micromark#security)
- `Renderer/src/index.html:5-6`: 원격 img는 생성될 수 있으나 CSP가 차단한다. 외부 CSS·font·frame·object도 허용되지 않는다. dist의 HTML/CSS는 대상 커밋 소스와 바이트 단위로 일치했다. [CSP 규칙](https://www.w3.org/TR/CSP3/#directives)
- `Sources/AIBCCPoC/Markdown/MarkdownWebView.swift:109-140`: 링크 클릭은 항상 앱 내 탐색을 취소하며 HTTP(S)만 외부 브라우저로 전달한다. 문서 내용에서 CSP 우회나 임의 앱 내 탐색으로 이어지는 경로는 확인되지 않았다.

요약:
1. 범위·줄 번호는 `87a558c..55c718c` 기준이며, 이후 수정 커밋은 제외했다.
2. 핵심 위험은 영구 pause, replay 입력 오염, 복원 실패 후 세션 강제 종료, 출력·문서 유실이다.
3. 읽기 전용 정적 검토와 메모리 내 검사를 수행했다. 전체 앱 테스트·WKWebView 네트워크 계측은 미실시이며, Git 미추적 dist의 당시 배포물 동일성은 미확인이다.

blocker **0** / major **16** / minor **1**

MD-05: pass