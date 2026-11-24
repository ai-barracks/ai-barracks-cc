## 결론

**수정 후 재리뷰를 권고합니다.** 기본 실행은 새 터미널로 변경됐지만, **확인 이후 입력 보호 우회**, **idle shell 오판**, **폴더 검증 이후 다른 cwd에서 실행될 가능성**이 남았습니다.

`ad7d172` 기준으로 읽기 전용 검토했습니다. 빌드·SelfTest는 파일을 생성하므로 실행하지 않았습니다. 셸 구문 오류는 `zsh -n`으로 확인했습니다. 아래 경로는 별도 표기가 없으면 `Sources/AIBCCPoC/` 기준입니다.

### 1. [major] 확인·편집 이동 대기 이후 에이전트 차단을 우회한다

- **근거:** `App/WorkspaceModel+QuickCommands.swift:44–55`의 `send(_:to:)`만 에이전트를 검사합니다. 그러나 `Terminal/PaneMenu.swift:134–135`의 확인 버튼은 바로 `type(_:into:)`를 호출하고, `App/WorkspaceModel.swift:703–712`의 편집 이동 continuation도 다시 `type`을 호출합니다. 최종 입력 직전에는 에이전트 여부나 대상 pane의 유효성을 검사하지 않습니다.
- **실패 시나리오:** 일반 pane에서 `sleep …; aib start claude`가 실행 중일 때 입력 확인창을 엽니다. 기다리는 동안 Claude가 시작되고 liveness에도 등록되더라도, “입력”을 누르면 명령과 Enter가 Claude 프롬프트로 전달됩니다. `editInProgress`에 따른 이동 확인 대기에서도 같은 문제가 생깁니다.
- **수정 제안:** 모든 continuation을 하나의 guarded 입력 함수로 모으십시오. 확인은 **unknown 프로그램에 대한 허용**일 뿐 에이전트 금지까지 해제해서는 안 됩니다. 송신 직전에 pane/session 소속과 에이전트 상태를 재검사하고, 대상 프로그램이 바뀌면 기존 확인을 무효화해야 합니다.

### 2. [major] 자식 프로세스가 없다는 이유만으로 unknown 프로그램에 무확인 입력한다

- **근거:** `Terminal/TerminalPane.swift:63–65`의 `isIdleShell`은 생성 당시 `isPlainShell`과 `!ProcessTree.hasChildren(pid)`만 확인합니다. `Sessions/AgentLauncher.swift:67–69`의 프로세스 조회 실패도 사실상 “자식 없음”으로 처리됩니다. 새 `send(_:to:)`는 이를 무확인 입력 조건으로 사용합니다.
- **실패 시나리오:** 일반 셸에서 `exec /bin/cat`을 실행하면 PID는 유지되고 자식은 없습니다. 따라서 현재 프로그램은 셸이 아닌데도 Quick Command가 확인 없이 전달됩니다. 자식 없는 직접 실행 TUI나 셸 builtin `read`도 같은 판정 문제를 가집니다.
- **수정 제안:** 생성 당시 종류가 아니라 **현재 foreground 프로그램과 prompt-ready 상태**로 판단하십시오. 확인할 수 없거나 프로세스 조회에 실패하면 `.unknown`으로 처리하여 확인을 요구해야 합니다. 임시 대안은 에이전트 외 모든 기존-pane 입력에 확인을 요구하는 것입니다.

### 3. [major] 편집 확인 중 사라진 cwd에서 명령이 다른 폴더로 실행될 수 있다

- **근거:** `App/WorkspaceModel+QuickCommands.swift:29–34`의 `run(_:)`은 최초 호출에서만 폴더를 검사합니다. `App/WorkspaceModel.swift:440–453`의 `openPane`은 이동 확인 후 `run`이 아닌 자신을 재호출합니다. 최종 실행부인 **`Sources/PtyDaemon/PtySession.swift:338–339`**의 `ChildLauncher.forkOnPTY()`는 `chdir` 실패를 무시하고 `execve`를 수행합니다.
- **실패 시나리오:** 편집 중 저장된 폴더의 Quick Command 실행 → 이동 확인 대기 → 외부에서 폴더 삭제·이름 변경 → 이동 승인. missing-folder 선택창 없이 실행되며, daemon이 상속한 cwd에서 명령이 동작할 수 있습니다. 존재하지만 접근 권한이 없는 폴더도 같은 위험이 있습니다.
- **수정 제안:** 이동 확인 후 Quick Command의 검증 진입점부터 재실행하고, **실행부에서도 `chdir` 실패 시 반드시 실행을 중단**하십시오. 재검사만으로는 TOCTOU가 남으므로 두 방어가 모두 필요합니다.

### 4. [major] `"; exec …"` 연결이 정상적인 저장 명령의 셸 문법을 깨뜨린다

- **근거:** `App/WorkspaceModel+QuickCommands.swift:70–72`의 `launch`는 명령에 무조건 `"; exec /bin/zsh -l"`을 붙입니다.
- **실패 시나리오:** 정상 명령 `printf ok;`가 `printf ok;; exec /bin/zsh -l`로 바뀝니다. 읽기 전용 구문 검사에서 실제로 **`parse error near ';;'`, exit 1**을 확인했습니다. 명령 실행과 후속 셸 유지가 모두 실패합니다.
- **수정 제안:** 명령과 후속 셸을 개행으로 분리하는 등 shell program 경계를 보존하십시오. 끝의 `;`, 따옴표, 개행, here-document를 회귀 테스트에 넣어야 합니다. `AgentLauncher.shellQuote`의 작은따옴표 escaping 자체가 아니라 **인용 전 프로그램 조립**의 문제입니다.

### 5. [major] 이미 가져온 v1 Quick Command에는 cwd가 이관되지 않는다

- **근거:** `App/V1SettingsImport.swift:86–90`의 `apply`는 여전히 `command` 문자열만으로 중복을 제거합니다. 새 `cwd`는 이 필터를 통과한 항목에만 저장됩니다.
- **실패 시나리오:** 이전 버전에서 `npm test`를 가져와 `cwd=nil`인 사용자가 다시 가져오기를 실행합니다. v1의 `/project/A` 경로가 파싱돼도 기존 명령이라는 이유로 제외됩니다. 이후 배럭 B에서 실행하면 A가 아닌 B에서 동작합니다. 같은 명령을 서로 다른 폴더에 저장한 경우도 구분하지 못합니다.
- **수정 제안:** cwd를 포함한 항목 식별과 기존 데이터 이관 정책을 추가하십시오. 기존 nil 경로를 임의로 덮어쓰지 말고, 명확한 기존 import 항목만 보완하거나 충돌 선택을 제공해야 합니다. `parse → apply → 재로드` 전체 테스트가 필요합니다.

### 6. [major] 재부착 후 Save-from-pane이 초기 명령·cwd를 잃는다

- **근거:** `Terminal/TerminalPane.swift:28–31,112–114`에 추가된 정보가 `App/SessionStore.swift:6–9`에는 없습니다. `App/WorkspaceModel.swift:357`은 session/title만 저장하고, `:323`의 `restore`는 명령 없이 **배럭 경로**를 넘깁니다. `App/WorkspaceModel+QuickCommands.swift:64–65`의 `saveDraft`는 이 값을 그대로 사용합니다.
- **실패 시나리오:** 배럭 A에서 `/project/B`의 명령을 실행한 뒤 앱을 재시작합니다. 같은 PTY에 다시 붙어도 저장 초안은 빈 명령과 A 경로를 제시합니다. 명령을 수동으로 복원하면 잘못된 폴더까지 저장할 수 있습니다. agent 표식도 사라집니다.
- **수정 제안:** 시작 명령·시작 cwd·agent 정보를 세션 메타데이터로 저장·복원하십시오. 구형 기록에서 모르는 경로를 배럭 경로로 가장하지 말고 명시적으로 미상 처리해야 합니다. `docs/PARITY.md:16`에도 인정된 제한이며, council의 Save-from-pane 합의는 아직 완결되지 않았습니다.

### 7. [major] CrashTrace의 signal handler는 async-signal-safe하지 않다

- **근거:** `SelfTest/CrashTrace.swift:25–30`의 `write`는 handler 안에서 Swift `String`·`Array`를 생성합니다. 또한 Apple의 `backtrace_symbols_fd` 구현은 내부에서 `dladdr`와 `snprintf`를 호출하므로, 주석처럼 안전한 `write`만 수행하는 경로가 아닙니다. [Apple Libc 구현](https://github.com/apple-oss-distributions/Libc/blob/main/gen/backtrace.c), [Apple signal-safety 문서](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/sigaction.2.html)
- **실패 시나리오:** allocator/runtime 내부에서 발생한 SIGABRT·SIGSEGV를 처리하다 다시 할당·잠금 경로에 들어가 교착하거나 재충돌할 수 있습니다. 진단하려던 원래 실패 대신 handler 실패나 watchdog timeout만 남을 수 있습니다.
- **수정 제안:** 최소 C handler에서 사전 준비된 버퍼와 fd에 signal 번호·주소 같은 원시 정보만 기록하고, symbolication은 프로세스 밖에서 수행하십시오. stack overflow도 다루려면 alternate signal stack이 필요합니다. 별도 자식 프로세스와 watchdog으로 종료 signal·로그 생성까지 검증해야 합니다.

### 8. [major] AC-02a·QC-01a/b/c의 PASS가 핵심 안전 경로의 회귀를 놓칠 수 있다

- **근거 및 거짓 통과 시나리오:**
  - **AC-02a:** `SelfTest/ActivationSettingsTests.swift:13–48`은 모델 메서드와 `refresh()`만 직접 호출합니다. 실제 확인창·비용 문구·5초 `.task`를 제거해도 이 테스트는 검출하지 못합니다. 정상적인 **ON→OFF→ON 재확인**도 시험하지 않습니다.
  - **QC-01a/b:** `SelfTest/QuickCommandTests.swift:24–25,72–83`은 install/readiness 실패를 무시합니다. `SelfTest/RecorderLog.swift:27–32`는 로그가 없어도 빈 배열을 반환하므로, recorder가 죽어 있어도 “입력 0바이트” 검사가 통과할 수 있습니다.
  - **QC-01b:** `:79–80`은 확인 버튼을 실행하지 않고 prompt를 nil로 지웁니다. 따라서 **1번의 확인 후 우회와 navigate 경로를 검증하지 않습니다.** 기존 `NV-01c`도 `SelfTest/AgentSuite.swift:409,420`에서 guarded `send`가 아닌 raw `type`을 호출합니다.
  - **QC-01c:** `:122–123`은 v1의 cwd 파싱만 검사하여 **5번의 실제 apply 누락을 놓칩니다.** QC-01a 역시 경로 수정 버튼을 누르지 않으므로 `ad7d172`의 alert→sheet 전환은 검증 대상이 아닙니다.
- **수정 제안:** fixture 준비 실패를 즉시 FAIL 처리하고, recorder가 실제 입력을 관측하는지 양성 대조를 추가하십시오. 실제 확인·취소·경로 수정·편집 이동 continuation, liveness 변경, 재import까지 테스트해야 합니다. 현재 새 pane 생성·`pwd` marker 검사는 유효하지만, 그것만으로 전체 안전 UX를 PASS 처리해서는 안 됩니다.

### 9. [minor] `upsert`가 유효한 cwd의 공백을 제거해 다른 폴더로 바꾼다

- **근거:** `Terminal/TerminalTools.swift:34–39`의 `upsert`는 cwd 전체에 `trimmingCharacters(in: .whitespacesAndNewlines)`를 적용합니다.
- **실패 시나리오:** 실제 시작 폴더가 `/tmp/project `처럼 끝에 공백을 포함하면 Save-from-pane이나 v1 가져오기에서 `/tmp/project`로 변경됩니다. 두 폴더가 모두 존재하면 경고 없이 다른 위치에서 실행됩니다.
- **수정 제안:** 공백뿐인 입력을 nil로 판단하는 것과 실제 경로 문자열 변경을 분리하십시오. 비어 있지 않은 저장 경로는 원문을 보존하거나 변경 내용을 사용자에게 확인받아야 합니다.

### 10. [minor] 예약이 ON이면서 사용 불가인 상태를 “꺼짐”으로 표시한다

- **근거:** `Activation/ActivationSettingsView.swift:143`은 `nextSlot == nil`이면 항상 “꺼짐 — 예약된 요청 없음”을 표시합니다. 그러나 `Activation/ActivationScheduler.swift:136–137`의 `view()`는 enabled가 true여도 오류·다른 앱 잠금 상태에서는 nextSlot을 nil로 반환합니다.
- **실패 시나리오:** v1이 활성화된 예약을 소유하고 있을 때 v2에는 ON 토글과 “꺼짐” 설명이 동시에 나타납니다. 사용자는 실제 자동 요청 여부를 잘못 판단할 수 있습니다.
- **수정 제안:** OFF, ON이나 사용 불가, 다른 앱이 예약 소유 중인 상태를 구분하십시오. `nextSlot` 부재를 OFF의 근거로 사용하면 안 됩니다.

### 11. [minor] “기본 취소” 보장은 확인 필요

- **근거:** `Activation/ActivationSettingsView.swift:130–135`는 취소 버튼에 `.cancel` role만 설정하고 `.keyboardShortcut(.defaultAction)`은 지정하지 않습니다. Apple 문서는 dismiss 역할과 default action 지정을 별도로 설명합니다. [Apple confirmationDialog 문서](https://developer.apple.com/documentation/swiftui/view/confirmationdialog%28_%3Aispresented%3Atitlevisibility%3Aactions%3Amessage%3A%29)
- **실패 시나리오 — 확인 필요:** 대상 macOS에서 Return이 활성화 버튼에 연결된다면 의도한 기본 취소 계약을 위반합니다. 이번 읽기 전용 리뷰에서는 실제 키 동작을 확인하지 않았으므로, 활성화가 기본이라고 단정하지는 않습니다.
- **수정 제안:** 취소를 default action으로 명시하고 Return·Escape·명시적 활성화 클릭을 UI 테스트하십시오. 그 전까지 `docs/PARITY.md:24`의 “기본 취소” 완료 판정은 미검증으로 남기는 편이 정확합니다.

## 요약 표

| # | 심각도 | 발견 사항 | 관련 합의 |
|---|---|---|---|
| 1 | major | 확인·navigate 이후 에이전트 차단 우회 | P03 입력 보호 |
| 2 | major | 자식 없음으로 idle shell 오판 | P03 unknown 확인 |
| 3 | major | cwd 재검증 누락 + `chdir` 실패 무시 | P03 조용한 대체 금지 |
| 4 | major | 후속 셸 연결이 정상 명령 문법 파괴 | P03 실행 정확성 |
| 5 | major | 기존 v1 import 항목의 cwd 이관 누락 | P03 가져오기 |
| 6 | major | 재부착 후 초기 명령·cwd·agent 유실 | P03 Save-from-pane |
| 7 | major | signal handler의 비동기 안전성 위반 | SelfTest 진단 신뢰성 |
| 8 | major | 핵심 경로 미검증·죽은 recorder로 거짓 통과 가능 | AC-02a·QC-01a/b/c |
| 9 | minor | cwd trimming으로 경로 변경 | P03 경로 보존 |
| 10 | minor | ON·사용 불가를 OFF로 표시 | P11 상태 정확성 |
| 11 | minor · 확인 필요 | 기본 취소의 실제 키 동작 미검증 | P11 기본 취소 |
