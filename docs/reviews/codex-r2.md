# Codex code review r2 (read-only, static — not compiled)

**결론: Go 판정은 아직 보류해야 합니다.** #1의 유예는 로컬 엔진 검증에는 수용 가능하지만, 판정 로직의 false-pass 경로가 남았습니다.

지정 diff·변경 소스 전문·의존성을 대조했습니다. **빌드·실행 검증은 하지 못했습니다.** 제한적 typecheck도 module-cache 쓰기 제한으로 완료하지 못했으며, 로컬 SDK는 26.5여서 macOS 27 SDK 검증은 미완료입니다. 아래 컴파일 판정은 정적 분석입니다.

Swift 파일 경로는 `Sources/AIBCCPoC/` 아래이며, `G/`는 제공된 의존성 소스입니다.

## A. 1차 지적 18건

| # | 판정 | 근거 |
|---|---|---|
| 1 | **not resolved — 의도적 유예 수용** | `docs/known-issues.md:5`, `scripts/package-app.sh:54–57`. `.build`를 유지하는 동일 Mac의 **로컬 엔진 검증에 한해 허용**할 수 있습니다. `.build` 삭제·이동 시 crash 위험과 제품 Go 차단은 유지해야 합니다. |
| 2 | **resolved** | `scripts/package-app.sh:94–96`: 빌드와 경로 조회 분리, 실패 시 중단. |
| 3 | **resolved** | `TerminalPane.swift:37–46`, `TerminalGridView.swift:37–40`: weak-self factory와 강한 view 소유, 안정적인 `ForEach`. `G/Platform/AppKit/AppTerminalView+Lifecycle.swift:61–69`도 재부착 시 기존 surface를 유지합니다. |
| 4 | **partially resolved** | `ResizeSuite.swift:66–68,192–196`: 화면 검증 분리·양쪽 padding 수정. 그러나 `CriteriaCatalog.swift:34–36`의 RS-02/04에는 화면 검증 의존성이 없습니다. |
| 5 | **partially resolved** | `ResizeSuite.swift:155–174`: 반복 안정화는 추가했지만, 무변화도 500ms 후 허용하며 geometry가 계속 바뀌어도 성공할 수 있습니다. |
| 6 | **partially resolved** | `InputSuite.swift:19–21`, `InputSourceGuard.swift:30–35`: baseline·중첩 복원 의도는 맞지만 `with`에 Swift 6 actor 경계 문제가 있습니다. |
| 7 | **partially resolved** | `InputSuite.swift:161–178`: 단계별 mismatch를 verdict에 반영. 다만 고정 sleep은 해당 이벤트·recorder 처리 완료 증거가 아닙니다. |
| 8 | **partially resolved** | `InputSuite.swift:194–208`, `CriteriaCatalog.swift:21`: 실제 pane 클릭과 미검증 분리는 개선. A의 확정 정책·marked state·패널 클릭 검증은 남았습니다. |
| 9 | **resolved** | `SelectionSuite.swift:143–163`: clipboard 원문 비교 및 hex 기록, 정규화 제거. |
| 10 | **partially resolved** | `SelectionSuite.swift:123–135`: 재포커스 제거. `IntegrationSuite.swift:69–77`: viewer focus 확인은 추가했지만 실제 viewer 클릭·스크롤은 없습니다. |
| 11 | **partially resolved** | `CriteriaCatalog.swift:87–108`, `SelfTestRunner.swift:62–67`: 누락·incomplete 처리는 추가. 필수 범위 누락과 setup 실패 누락은 여전합니다. |
| 12 | **resolved** | `ArtifactStore.swift:25–30,52–59`: cancellation·generation·root를 적용 직전에 모두 확인합니다. |
| 13 | **partially resolved** | `MarkdownWebView.swift:51–65,89–116`: 실패 처리 추가. 하지만 초기 실패의 동기적 SwiftUI state 변경과 로드 이후 WebContent 종료는 미처리입니다. |
| 14 | **resolved** | `WorkspaceModel.swift:59–62,95–99`: weak-self 종료 handler와 종료 pane 교체 구현. 실제 프로세스 정리 검증은 별도입니다. |
| 15 | **resolved** | `SelfTestRunner.swift:53–57,95–103`: 저장 오류 전파·exit 4·atomic write. |
| 16 | **resolved** | `ArtifactStore.swift:63–94`: 삭제·선택 해제 처리, 읽기 성공 시 early return 전에 오류 해제. |
| 17 | **partially resolved** | `SelfTestHarness.swift:76–86`: 무제한 대기는 제거. timeout/cancellation을 정상 바이트 반환과 구별하지 않습니다. |
| 18 | **resolved** | `ProbeTerminalView.swift:122–125`: bounded buffer와 `append` 적용. |

## B/C. 신규·잔여 문제 — 심각도순

1. **[blocker · 컴파일] `InputSourceGuard.with`의 async closure isolation 누락**  
   `InputSourceGuard.swift:30–33`: `body`는 nonisolated async이고 반환형 `T`에는 `Sendable` 제약이 없습니다. 이를 MainActor에서 받아오는 선언은 Swift 6 actor 경계 검사에 걸립니다. 앱 `Package.swift:16–25`에는 `NonisolatedNonsendingByDefault`도 없습니다. [Swift SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)  
   **수정:** `body: @MainActor () async -> T`로 선언하십시오. 복원은 `defer`로 보장하고, 선택 후 검증 실패 경로에서도 이전 source를 복원하십시오.

2. **[major] 숨긴 pane이 계속 키보드 입력을 받습니다**  
   `TerminalGridView.swift:63–64`, `WorkspaceModel.swift:102–105`: pane을 화면 밖으로 옮기고 렌더링만 중단합니다. pane 4에 포커스를 둔 채 `⌥⌘1`로 전환하면 first responder는 숨겨진 pane에 남을 수 있습니다.  
   **수정:** 숨겨질 pane이 first responder이면 조합 정책을 적용한 뒤 보이는 pane으로 focus를 이동하십시오. 이 전환의 입력 격리 테스트도 추가해야 합니다.

3. **[major] resize 수렴은 여전히 실제 변경·안정 상태를 증명하지 않습니다**  
   `ResizeSuite.swift:162–167`: grace 경과만으로 `changed=true`; geometry가 계속 변해도 매번 triad만 일치하면 timer가 유지됩니다. `LifecycleSuite.swift:24–30`은 이전 grid/PTY 일치를 즉시 성공으로 받는 기존 문제를 재도입했습니다. 전체화면도 `ResizeSuite.swift:133–136`에서 animation 완료 전에 반대 toggle을 요청할 수 있습니다.  
   **수정:** 요청별 적용 조건을 확인하고, **동일한 최종 geometry**가 150ms 유지될 때만 성공시키십시오. fullscreen은 didEnter/didExit notification까지 기다리고, 의도한 no-op은 별도로 처리하십시오.

4. **[major] Catalog가 불완전한 검증을 상위 pass로 승격합니다**  
   `CriteriaCatalog.swift:26,28,34–36,61,79`에는 각각 **IN-09 종료 코드, IN-11 ⌘K, RS 화면 검증, ST-01의 4분할 IN/SC 핵심 재실행, MD-04 클릭·스크롤**이 빠져 있습니다. 또한 실제로 제거된 split drag(`docs/known-issues.md:6`)를 단순 미검증으로 취급합니다. 반대로 `:18`의 synthetic 결과 필수화는 IMK 미경유 시 physical 검사가 통과해도 IN-01을 계속 미완료로 만듭니다.  
   **수정:** 필수 sub-ID를 보완하고, 알려진 미지원은 `fail`, 미측정은 `unverified`로 구분하십시오. synthetic 측정 가능 여부와 physical acceptance gate도 분리해야 합니다.

5. **[major] suite 준비 실패가 exit 판정에서 사라집니다**  
   `InputSuite.swift:312–314` 등의 `IN/RS/SC/MD-setup`은 Catalog에서 참조하지 않습니다. `SelfTestRunner.swift:49–59,62–67`은 parents만 판정하므로 실제 `.fail`이 있어도 exit 3인 “실패 없음·미완료”가 됩니다.  
   **수정:** setup 결과를 별도로 집계하여 exit 2로 종료하고, 실패한 준비 조건 이후 suite를 실행하지 마십시오.

6. **[major] `postEvent` 뒤의 sleep은 delivery acknowledgement가 아닙니다**  
   `EventSynthesizer.swift:62,97`, `SelfTestHarness.swift:69–86`: enqueue만 보장됩니다. 따라서 `InputSuite.swift:119–120`의 60ms 후 상태 검사는 false-fail, `:103–107`의 무수신 검사는 이벤트가 아직 미처리여도 false-pass가 가능합니다. timeout 직전 도착한 바이트도 안정화 없이 반환됩니다. [AppKit 정의](https://developer.apple.com/documentation/appkit/nsapplication/postevent(_:atstart:))  
   **수정:** 이벤트별 dispatch 완료·목표 responder 확인 후 recorder barrier/quiet-window를 기다리십시오. timeout/cancellation은 바이트 배열 대신 명시적 실패로 반환해야 합니다.

7. **[major] bracketed paste가 본문을 전부 버려도 pass입니다**  
   `InputSuite.swift:260–266`: 시작·종료 marker만 검사하므로 `ESC[200~ESC[201~`만 수신해도 통과합니다.  
   **수정:** 내부 종료 marker를 어떻게 무력화할지 정책을 고정하고, **나머지 본문·newline을 포함한 전체 expected bytes**와 비교하십시오.

8. **[medium · hang 위험] cancellation 이후에도 resize 반복과 후속 suite가 계속됩니다**  
   `SelfTestHarness.swift:65–66`은 cancellation을 삼키고, `ResizeSuite.swift:161–172`에는 취소 검사가 없습니다. 취소된 sleep이 즉시 반환하면 deadline까지 반복하여 UI를 오래 점유할 수 있습니다.  
   **수정:** sleep 오류와 `Task.checkCancellation()`을 runner까지 전파하고, 복원은 `defer`에서 수행하십시오. 무한대기는 아니지만 긴 정지·오판 위험입니다.

9. **[medium] native fallback 진입과 복구가 불완전합니다**  
   `MarkdownWebView.swift:19–24,51–56` → `ArtifactPanel.swift:45`는 `makeNSView` 도중 `@State`를 동기 변경합니다. 또한 로드 후 WebContent process가 종료되면 취소된 readiness timer(`:80–82`)가 도와주지 않습니다. `rendererFailure`도 문서 변경 후 남습니다.  
   **수정:** 실패 통지는 다음 MainActor turn으로 미루고, `webViewWebContentProcessDidTerminate` 처리와 명시적인 재시도/reset 경로를 추가하십시오.

10. **[medium] 캐시한 NSView 하나를 여러 창이 공유합니다**  
    `AIBCCPoCApp.swift:7–12`의 공유 workspace + `WindowGroup`, `TerminalPane.swift:42–46` 조합에서는 새 창에도 동일 native view를 반환합니다. 정상적인 detach/reattach와 달리 **동시 두 hierarchy 소유**는 불가능하여 기존 창의 terminal이 이동·사라집니다.  
    **수정:** PoC는 단일 `Window`로 제한하거나, workspace와 pane/view를 창별로 소유하십시오.

**오탐 제외:** factory의 `[weak self]` 자체에 새 retain cycle은 없습니다. `TerminalGridView.swift:53–64`의 `Layout` signatures도 유효합니다. `MarkdownWebView.swift:89–95`의 두 failure delegate selector 역시 현재 공개 WebKit 선언과 일치하며, 이를 컴파일 오류로 지적할 근거는 없습니다. [Layout](https://developer.apple.com/documentation/swiftui/layout), [WebKit 선언](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKNavigationDelegate.h)
