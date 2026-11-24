# Codex code review r1 (read-only, static — not compiled)

전체 요청 파일과 pinned dependency를 읽고 대조했습니다. **빌드·Swift typecheck는 실행하지 않았습니다. 정적으로 확정할 컴파일/Swift 6 strict-concurrency 오류는 발견하지 못했지만, 배포 blocker와 여러 false-pass 경로가 있습니다.**

아래에서 `S/`는 `Sources/AIBCCPoC/`, `G/`는 dependency의 `Sources/GhosttyTerminal/`입니다.

## 수정 필요 — 심각도순

1. **[blocker] 패키징된 앱이 SwiftPM resource bundle을 찾지 못합니다.**  
   **위치:** `scripts/package-app.sh:41–45`, `G/Configuration/GhosttyRuntimeResources.swift:14–25`  
   **문제:** SwiftPM 6.3.2의 `Bundle.module` accessor는 **`Bundle.main.bundleURL/<bundle>` 또는 빌드 당시 절대 경로**를 찾습니다. 현재 복사 위치인 `Contents/Resources`는 검색하지 않습니다. 개발 머신에서는 `.build` fallback으로 성공해도, 다른 머신에서는 controller 초기화 중 `fatalError`가 발생합니다. [SwiftPM accessor 생성 소스](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3.2-RELEASE/Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift#L361-L398)  
   **수정:** dependency에 `Bundle.main.resourceURL` 아래 `GhosttyKit_GhosttyTerminal.bundle`을 먼저 찾고, 없을 때만 `Bundle.module`을 평가하는 resolver를 추가합니다. runtime resources와 AppKit localization 호출도 이 resolver로 통일합니다. 복사 위치는 유지하십시오. 앱 루트로 옮기는 편법은 strict codesign 구조 검증과 충돌할 수 있습니다.

2. **[major] `swift build` 실패를 삼키고 이전 바이너리를 패키징할 수 있습니다.**  
   **위치:** `scripts/package-app.sh:30–33,82`  
   **문제:** `build_binary | tail -1` 안에서 첫 `swift build`가 실패해도 다음 `--show-bin-path`가 성공하면 전체 결과가 성공이 됩니다. macOS Bash 3.2에서 동일 제어 흐름을 `false`로 대체하여 확인했습니다.  
   **수정:** 빌드를 독립 명령으로 실행한 뒤 경로만 별도로 받습니다.
   ```bash
   swift build -c "$CONFIG" --package-path "$ROOT"
   bin_dir="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
   ```

3. **[major] 레이아웃 변경이 기존 shell/PTY를 유지하지 않습니다.**  
   **위치:** `S/Terminal/TerminalGridView.swift:35–53`, `S/Terminal/TerminalPane.swift:25`, `S/App/WorkspaceModel.swift:29–36`  
   **문제:** `switch`의 서로 다른 SwiftUI 구조로 이동하면 representable이 재생성됩니다. factory는 매번 새 `ProbeTerminalView`를 만들고, `TerminalViewState`의 view/surface 참조는 weak입니다. 기존 view 해제 시 coordinator가 surface를 해제합니다(`G/Surface/TerminalSurfaceCoordinator.swift:591–627`). 모델 배열을 유지하는 것만으로 세션은 보존되지 않습니다. ResizeSuite도 recorder가 재시작한 사실을 놓칩니다.  
   **수정:** pane별 native view를 강하게 소유하고, 안정적인 AppKit container에서 동일 view를 재배치하십시오. 레이아웃 변경 전후 PID/session token과 recorder의 `ready` 발생 횟수가 유지되는지도 검사하십시오.

4. **[major] resize “3자 일치”가 화면 가시성을 전혀 검증하지 않습니다.**  
   **위치:** `S/SelfTest/ResizeSuite.swift:125–137,167–173`, `S/SelfTest/SelfTestRunner.swift:102`  
   **문제:** grid/PTY/geometry만 비교하므로 마지막 행·열이 렌더링되지 않아도 RS-*와 RG-04가 pass입니다. 저장된 이미지도 판정에 사용하지 않습니다. 게다가 `snapshotImage()`는 Metal frame이 포함되지 않을 수 있다고 dependency가 명시합니다(`G/Platform/AppKit/AppTerminalView+Snapshot.swift:10–18`).  
   **수정:** 실제 composited-window capture에서 TL/BR 표식을 검증하거나, 화면 검증 전에는 해당 criterion을 `unverified`로 유지하십시오. `gridFits`도 현재 한쪽 padding만 더하므로 양쪽 합으로 바꾸십시오. 단, **`widthPixels`를 grid 폭으로 해석하여 비교식을 제거하면 안 됩니다**. 이는 padding을 포함한 surface 폭입니다. [고정 commit의 size 반환 구현](https://github.com/ghostty-org/ghostty/blob/1e9e14af5df1/src/apprt/embedded.zig#L1795-L1805)

5. **[major] resize 수렴 판정이 이전 상태를 성공으로 잡거나 정상 수렴을 실패 처리합니다.**  
   **위치:** `S/SelfTest/ResizeSuite.swift:68–89,116–122`  
   **문제:** SwiftUI가 새 layout을 적용하기 전에 이전 grid/PTY/view가 일치하면 즉시 `agreed=true`가 됩니다. 이후 150ms 시점에 한 번만 검사하므로 그 순간 resize 중이면 3초 timeout이 남아 있어도 fail이고, 변화 자체가 없으면 pass입니다. 수렴 시간도 최초의 오래된 일치 시점까지로 기록됩니다.  
   **수정:** 요청한 크기·layout·font 변화가 실제 적용되었음을 먼저 확인하고, **새 상태가 150ms 연속 유지될 때까지** deadline 안에서 반복하십시오. 측정 시작점은 변경 요청 직전으로 옮기고, `performBindingAction`의 `Bool` 및 실제 `fontSize` 변화도 assert하십시오.

6. **[major] 영문 테스트가 사용자의 현재 입력기에 종속됩니다.**  
   **위치:** `S/SelfTest/InputSuite.swift:25–34,52–60,181–187`, `S/SelfTest/SelectionSuite.swift:117`, `S/SelfTest/IntegrationSuite.swift:72`  
   **문제:** 기본 테스트들은 실제 `interpretKeyEvents`를 사용하지만 ABC 입력기를 선택하지 않습니다. 한국어 입력기로 시작하거나 한국어로 복원되면 `"x"` 등이 조합에 들어가 정상 구현도 fail할 수 있습니다.  
   **수정:** 일반 키 테스트는 ABC/U.S. 입력기를 선택하고 활성 source ID를 확인한 뒤 실행하십시오. 입력기 guard를 중첩 가능한 scope 방식으로 바꾸어 synthetic Korean 테스트 후 **테스트 baseline 입력기**로, 전체 종료 시 **사용자의 원래 입력기**로 복원하십시오.

7. **[major] IME 테스트가 조합 중 조기 송신을 발견해도 pass할 수 있습니다.**  
   **위치:** `S/SelfTest/InputSuite.swift:134–148`  
   **문제:** `leakedWhileComposing`은 evidence에만 기록되고 `ok`에 포함되지 않습니다. 최종 바이트가 같으면 조합 중 잘못 먼저 전송한 구현도 통과합니다. 반대로 “가를 확정하고 나를 조합”하는 단계의 `"가"`는 정상 송신인데 현재 변수는 이를 leak처럼 기록합니다.  
   **수정:** 단계별 expected cumulative bytes를 비교하십시오. IN-01은 `"" → "" → "" → "가" → "가나 "`, IN-02는 마지막 확정 전까지 `""`입니다. 각 단계의 recorder 처리 완료를 확인하고 그 결과를 verdict에 포함하십시오.

8. **[major] pane 전환 테스트가 조합 분실을 허용하며 실제 클릭 경로도 검사하지 않습니다.**  
   **위치:** `S/SelfTest/InputSuite.swift:159–172`  
   **문제:** `bytesA.isEmpty || bytesA == ...`는 조합을 그냥 버려도 pass입니다. `makeFirstResponder`만 호출하므로 acceptance의 pane 클릭·패널 클릭 동작도 검증하지 않습니다.  
   **수정:** commit/cancel/조합 유지 정책을 하나로 고정하고 바이트와 marked state를 함께 검사하십시오. pane 및 패널 클릭을 실제 event 경로로 각각 테스트하고, scripted IME만으로 확인할 수 없는 부분은 `unverified`로 분리하십시오.

9. **[major] 복사 결과를 테스트가 직접 정리하여 공백 처리 결함을 숨깁니다.**  
   **위치:** `S/SelfTest/SelectionSuite.swift:85,94,141–145`  
   **문제:** SC-04b에서 clipboard에 불필요한 trailing spaces가 있어도 helper가 제거하므로 pass입니다. 다른 테스트에서도 잘못 추가된 줄바꿈을 숨깁니다.  
   **수정:** clipboard 원문을 그대로 expected와 비교하십시오. 허용할 newline 정책이 있다면 정확한 expected 값에 명시하고, 정규화하지 않은 문자열/UTF-8 hex를 evidence에 남기십시오.

10. **[major] 포커스 테스트가 검사하려는 결함을 스스로 복구합니다.**  
    **위치:** `S/SelfTest/SelectionSuite.swift:113–127`, `S/SelfTest/IntegrationSuite.swift:69–74`  
    **문제:** SC-08은 복사 후 `harness.focus()`로 포커스를 다시 잡아서 “복사로 포커스가 사라지는 버그”를 숨깁니다. MD-04는 WebView로 포커스를 옮긴 호출의 성공 여부를 확인하지 않아, 처음부터 terminal에 포커스가 남아 있어도 pass할 수 있습니다.  
    **수정:** SC-08의 재포커스를 제거하고 first responder를 assert한 뒤 입력하십시오. MD-04는 WebView 또는 내부 content view가 실제 first responder인지 확인하고, 요구된 클릭·스크롤 후 terminal 복귀를 수행하십시오.

11. **[major] acceptance 전체가 아닌 일부 동작에 상위 ID의 pass를 부여합니다.**  
    **위치:** `S/SelfTest/InputSuite.swift:55–103,219–228`, `S/SelfTest/ResizeSuite.swift:64–95`, `S/SelfTest/SelectionSuite.swift:47–48`, `S/SelfTest/IntegrationSuite.swift:41–54`, `S/SelfTest/SelfTestRunner.swift:37–43,113–130`  
    **누락된 주요 범위:**

    | Criterion | 현재 검증하지 않는 부분 |
    |---|---|
    | IN-06 | 영문·한글 혼합 200자 — 현재 ASCII만 |
    | IN-07 | 단일 줄·다른 앱 출처 및 고정된 newline 정책 |
    | IN-09 | 실제 fixture 종료 코드 — 현재 trap 파일만 |
    | IN-10 | Shift+Enter, Option, dead key, repeat |
    | IN-11 | ⌘K 등 나머지 shortcut |
    | RS-03/04 | 패널 폭 변경·split drag·실제 font shortcut |
    | SC-05 | **줄 경계에 걸친** wide character |
    | ST-01 | 4분할 핵심 suite 재실행 — 결과 자체가 없음 |
    | MD-03 | 읽던 위치 유지 — model content만 검사 |

    **수정:** 측정한 부분은 하위 ID로 보고하고, 필요한 하위 결과가 모두 pass일 때만 상위 ID를 pass로 집계하십시오. criterion 목록을 기준으로 누락 결과를 `unverified`로 생성하십시오. 현재 exit 0은 “측정된 blocking fail 없음”일 뿐 Go가 아닙니다. acceptance gate에는 별도 `incomplete` 결과/종료 코드를 사용하십시오.

12. **[major] root 변경 후 이전 directory scan 결과가 되살아날 수 있습니다.**  
    **위치:** `S/Markdown/ArtifactStore.swift:21–28,42–50`  
    **문제:** `watch(root: nil)`은 진행 중인 scan을 취소하지 않습니다. 뒤늦게 완료된 이전 scan이 비운 목록에 옛 배럭 파일을 다시 넣습니다. 이는 strict-concurrency 오류가 아니라 async 작업의 논리적 race입니다.  
    **수정:** root 변경 시 먼저 `scanTask?.cancel()`하고 generation을 증가시키십시오. 적용 직전에 cancellation과 captured root/generation 일치를 모두 검사하십시오.

13. **[major] renderer 로딩/JavaScript 실행 실패에는 원문 fallback이 없습니다.**  
    **위치:** `S/Markdown/MarkdownWebView.swift:48–55,70–75,90–95`, `Renderer/src/render.js:34–40`  
    **문제:** `showRaw`는 `aibccShow`가 실행된 뒤의 render 예외만 처리합니다. `renderer.js` 누락, navigation 실패, 함수 미정의 등의 경우에는 빈 WebView만 남습니다. `evaluateJavaScript` 오류도 버립니다. MD-02의 실패 시 원문 표시를 충족하지 못합니다.  
    **수정:** navigation 실패와 renderer-ready timeout을 처리하고 JS completion 오류를 수집하십시오. 실패 시 SwiftUI/native text viewer로 source를 표시하십시오.

14. **[major] shell 종료 시 pane 정리가 구현되어 있지 않습니다.**  
    **위치:** `S/Terminal/TerminalPane.swift:24–34`, `S/App/WorkspaceModel.swift:45–56`  
    **문제:** `state.onClose`를 설정하지 않습니다. dependency는 종료 요청을 `onClose?`로 전달할 뿐 pane을 제거하지 않습니다(`G/State/TerminalViewState+Delegate.swift:108–110`). 따라서 ST-04의 shell 종료 후 pane 정리를 현재 코드로 만족할 수 없습니다.  
    **수정:** `WorkspaceModel`에서 pane ID를 이용하는 weak-self `onClose` handler를 연결하고, process가 종료된 pane을 제거하십시오. 살아 있는 프로세스의 close 요청은 별도 확인 정책을 적용하십시오.

15. **[major] 보고서 저장 실패가 성공 종료로 처리됩니다.**  
    **위치:** `S/SelfTest/SelfTestRunner.swift:39–43,71–80`  
    **문제:** encode/write 실패를 모두 무시하므로 디스크 부족이나 쓰기 실패로 증거 파일이 없어도 exit 0이 가능합니다.  
    **수정:** `write`를 `throws`로 바꾸고, 실패 시 stderr에 원인을 출력하여 infrastructure error 코드로 종료하십시오. `report.json`은 atomic write를 사용하십시오.

16. **[minor] 삭제된 문서와 이전 오류 상태가 남습니다.**  
    **위치:** `S/Markdown/ArtifactStore.swift:25–28,54–60,64–72`  
    **문제:** 선택 파일이 삭제되어 목록에서 사라져도 기존 content가 유지됩니다. 선택 해제/root 변경 시 `loadError`도 남습니다. 오류 후 같은 내용으로 복구되면 70행의 early return 때문에 오류가 해제되지 않을 수도 있습니다.  
    **수정:** 선택 해제/root 변경 시 오류를 초기화하고, 성공적으로 읽었으면 내용 동일 여부 검사 **전에** 오류를 지우십시오. 선택 파일은 top-50 목록 포함 여부와 별개로 존재·변경을 검사하십시오.

17. **[minor] byte 안정화 대기가 무제한이며 cancellation을 무시합니다.**  
    **위치:** `S/SelfTest/SelfTestHarness.swift:55–77`  
    **문제:** 첫 대기만 timeout이 있고 이후 `while true`에는 deadline이 없습니다. 지속적인 오송신은 fail 보고 대신 suite를 영원히 붙잡습니다. `try? Task.sleep`도 cancellation을 삼킵니다.  
    **수정:** 전체 함수에 deadline과 cancellation 검사를 적용하고, 안정화 실패를 명시적으로 반환하십시오.

18. **[minor] 입력 로그가 무제한·제곱 시간으로 증가합니다.**  
    **위치:** `S/Terminal/ProbeTerminalView.swift:31,115`  
    **문제:** 모든 callback마다 `callLog + [entry]`로 전체 배열을 복사합니다. 장시간 입력할수록 MainActor 작업량이 증가하여 입력 지연 측정 자체를 왜곡합니다.  
    **수정:** `append`를 사용하고 기록을 opt-in 또는 크기가 제한된 buffer로 만드십시오.

## 특별 요청 사항 중 오탐으로 제외한 것

- **override 가능:** `ProbeTerminalView.swift:48–85`는 접근 수준 문제가 없습니다. `insertText/setMarkedText/unmarkText`는 `G/.../AppTerminalView+NSTextInputClient.swift:12–27`의 `open`인 Objective-C protocol 구현이고, `keyDown/doCommand`는 open NSResponder override입니다. `interpretKeyEvents`도 상속된 Objective-C 메서드입니다. 이 경우 extension 선언이라는 이유만으로 override가 금지되지 않습니다. [Swift의 `@objc` 추론 규칙](https://docs.swift.org/swift-book/ReferenceManual/Attributes.html)

- **API 사용 일치:** `TerminalPane.swift:13,25–30`의 factory, attached view, initializer labels는 맞습니다. `surfaceSize/isFocused/isMouseCaptured`도 존재하며, `performBindingAction`은 **`Bool`**입니다(`G/State/TerminalViewState.swift:16–17,58–67,163–184`).

- **열거한 concurrency 구문 자체는 오류가 아님:** FSEvents는 `.main` queue로 지정되어 있어 현재 `MainActor.assumeIsolated`의 전제가 맞습니다. `atexit` closure는 지역 context를 capture하지 않습니다. DispatchSource handler는 C signal handler가 아니며 `signalNumber` capture도 가능합니다. `Task.detached`는 `URL`을 capture하고 `[ArtifactFile]`을 반환합니다. `@Observable + @MainActor`와 현재 WKNavigationDelegate async signature도 맞습니다. `nonisolated(unsafe)`/`@unchecked Sendable`이 안전성을 증명하는 것은 아니지만, 이를 이유로 컴파일 오류라고 판정할 근거는 없습니다.

- **IME replay의 예상 최종 바이트는 타당:** collect 경로는 committed text를 `composing=false`로 보내고, marked-only 경로는 `composing=true`입니다. 따라서 조건이 갖춰지면 `"가나 "`와 `"가 "`가 맞습니다. 문제는 위 7번의 **중간 단계 판정 누락**입니다.

- **`currentEvent`는 실행 확인 필요:** `NSApp.sendEvent` 사용 때문에 guard가 반드시 실패한다고 단정할 수 없습니다. 다만 직접 dispatch가 queue에서 가져온 current event를 보장하는 것도 아닙니다. nil이면 dependency의 `insertText`가 조용히 버립니다. callback 안에서 current event를 기록하고, 필요하면 `postEvent`와 delivery acknowledgement로 바꾸십시오. [Apple의 `currentEvent` 정의](https://developer.apple.com/documentation/appkit/nsapplication/currentevent)

- **좌표·selection 기본 기대는 맞음:** `windowPoint`의 y 반전은 `mousePoint`와 역변환 관계이고 pixel→point 나눗셈도 맞습니다. 고정 엔진의 triple-click은 soft-wrap 전체 logical line을 선택하며, macOS Option rectangle과 기본 설정에서의 Shift-drag 우회도 지원됩니다. `clickCount: 1`만으로 double/triple-click이 깨진다고 볼 수 없습니다. wrapper는 이를 전달하지 않고 엔진이 반복 press의 시간·거리를 셉니다. [고정 commit의 selection 구현](https://github.com/ghostty-org/ghostty/blob/1e9e14af5df1/src/terminal/SelectionGesture.zig#L278-L295)

- **서명·shell 오탐:** 현재 Ghostty는 정적 링크 대상이므로 XCFramework를 앱에 그대로 복사하지 않은 것이 오류는 아닙니다. 또한 44행의 `[[ -e ... ]] && cp ...`는 AND-list 조건이므로 unmatched glob 자체가 `set -e` 종료 원인은 아닙니다. 실제 실패 은폐 문제는 위 2번입니다.
