# Codex code review r3 (static, diff 2790c14..HEAD)

**이번 diff에서 신규 blocker는 확인하지 못했습니다. 다만 새 self-test에는 중요한 false-pass 경로가 있습니다.**

검토 범위: `2790c14..cbc1c76`. 변경된 텍스트 파일 전체와 지정한 Ghostty 구현을 대조했습니다. 재빌드·앱 runtime 재검증은 하지 않았습니다. 아래 경로는 별도 표시가 없으면 `Sources/AIBCCPoC/` 기준입니다.

## Findings

1. **[major] WS-01a는 살아 있는 셸의 보존을 검증하지 않습니다.**  
   `SelfTest/LifecycleSuite.swift:9–10, 19–38`
   - `shellExitCleanup()` 직후 실행하므로, 현재 동작에서는 방금 종료·회수한 recorder pane을 복귀 대상으로 사용합니다.
   - cwd도 실제 프로세스가 아니라 **생성 설정**인 `configuration.workingDirectory`만 검사합니다. 동일 pane ID와 `window != nil`은 PID·surface·셸 상태 보존의 증거가 아닙니다.
   - **수정:** 살아 있는 fixture를 별도로 준비하고 실제 cwd·PID·세션 nonce를 전환 전후 비교하세요. 비활성 배럭의 지속 실행, 양방향 artifact root 복원, 전환 후 입력 격리도 검증해야 합니다.

2. **[major] ST-02a는 측정 중 flood가 실제로 진행되는지 확인하지 않습니다.**  
   `SelfTest/LoadSuite.swift:19–29, 33–42`  
   `Fixtures/flood_recorder.py:33–40, 54–56`
   - `ready`는 flood thread 시작 **전** 기록됩니다. 테스트는 출력 진행량·`flood_done`·측정 구간과 출력 구간의 겹침을 전혀 검사하지 않습니다.
   - 따라서 출력 thread 실패나 준비 지연으로 flood가 끝난 뒤에도 정상 입력만 받으면 pass할 수 있습니다.
   - 또한 현재는 1분할에서 약 1초간 40개 표본만 측정합니다. 사전 기준인 **10만 줄·1/4분할·출력 시작~종료 구간**과 다릅니다(`docs/acceptance-criteria.md:71`).
   - **수정:** 고정 줄 수와 시작·진행·종료 ACK를 두고, 출력 진행 중의 표본만 인정하세요. 1/4분할을 각각 측정하고 준비 timeout·출력 thread 오류를 판정에 포함해야 합니다.

3. **[major] ST-01b 추가로 SC를 실행하지 않고도 상위 ST-01이 pass됩니다.**  
   `SelfTest/InputSuite.swift:48–66`  
   `SelfTest/CriteriaCatalog.swift:64`
   - 실행하는 검사는 space·한글 callback contract·paste뿐입니다. 요구된 4분할 **선택·복사(SC)** 검사가 없습니다.
   - 클릭 직후 호출하는 각 helper가 다시 `harness.focus()`를 실행하므로, 이 테스트 자체에서는 클릭 실패도 가려집니다(`InputSuite.swift:73, 101, 225`).
   - **수정:** 4분할 SC 검사를 별도 필수 sub-ID로 추가하세요. 클릭 라우팅 검사는 강제 focus 없이 수행하고, 다른 pane의 PTY에는 바이트가 없는지도 확인하세요.

4. **[major] MD-04b는 스크롤하지 않아도 pass할 수 있습니다.**  
   `SelfTest/IntegrationSuite.swift:109–119, 138–141`
   - 짧은 fixture에 `window.scrollTo()`만 호출합니다. 문서가 viewport보다 짧으면 아무 이동도 없습니다.
   - JavaScript 오류를 무시하고 scroll offset도 검사하지 않습니다. 실제 wheel/trackpad 이벤트 경로 역시 통과하지 않습니다.
   - **수정:** 확실히 넘치는 긴 문서를 사용하고, 실제 scroll 이벤트 후 `scrollY` 변화가 확인되어야 다음 단계로 진행하세요. 렌더 준비 실패와 스크롤 실패도 명시적으로 판정해야 합니다.

5. **[minor] 배럭 전환은 기존 focus 보정 대상에서 빠져 있습니다.**  
   `App/WorkspaceModel.swift:157–168`
   - visibility는 모든 grid에 올바르게 적용하지만, focus 검사는 **새로 선택한 grid의 주차 pane**만 대상으로 합니다. 방금 비활성화한 배럭의 pane은 검사하지 않습니다.
   - 따라서 배럭 간 terminal focus 인계·복원은 이 코드가 보장하지 않습니다. 다만 **detached pane으로 실제 오배달된다고 확정할 근거는 없습니다**. AppKit은 제거한 view를 responder chain에서 제외하고, Ghostty도 detach 때 내부 focus를 끕니다. [AppKit 제거 규약](https://developer.apple.com/documentation/appkit/nsview/removefromsuperview%28%29)
   - **수정:** 전환 전 responder를 기록하고, terminal focus였던 경우 기존 focus를 해제한 뒤 선택 ID를 재확인하여 부착된 새 target으로 인계하세요. sidebar focus를 의도적으로 유지하는 경우와 구분한 회귀 테스트가 필요합니다.

6. **[minor] ST-02a가 잘못된 timestamp·음수 latency를 정상 pass로 처리합니다.**  
   `SelfTest/RecorderLog.swift:55–59`  
   `SelfTest/LoadSuite.swift:51–62`
   - `wall` 누락을 `0`으로 바꾸므로, 바이트만 일치하면 거대한 음수 latency가 만들어져 pass합니다.
   - wall clock 역행도 음수 latency로 통과하고, 순방향 보정은 앱 결함처럼 false-fail할 수 있습니다.
   - **수정:** timestamp 누락·비정상 값·음수 latency는 측정 무효로 처리하세요. 가능하면 양쪽에서 동일한 `mach_absolute_time` 기반 clock을 사용하세요. Python의 process-relative monotonic 값과 그대로 비교하면 안 됩니다.

**ST-02a에서 맞는 부분:** `Date().timeIntervalSince1970`과 `time.time()`의 epoch는 일치합니다. timestamp 기록 → event post → `await` 순서도 맞으며, 전체 송수신 byte 배열을 비교하므로 `zip`의 짧은 쪽만 일치해 통과하는 문제는 없습니다.

## R1 / R4 판정

- **R1: 핵심 구조는 수정됐지만 완료 판정은 보류합니다.** 배럭별 grid와 cwd 설정, 전체 pane visibility 처리는 맞습니다. pane의 view 소유와 Ghostty의 detach/reattach surface 재사용도 확인했습니다. 다만 WS-01a는 셸 생존을 증명하지 못하고, 전환 직후 focus·입력 격리 검증이 남습니다.
- **R4: 신규 기본 창 기준으로 해결됐습니다.** 1440×900 기본 크기, 목록 최대 260, 본문 최소 240으로 이전 공간 배분 문제가 개선됩니다. 저장된 작은 창 크기에는 기본값이 적용되지 않는다는 제한은 남습니다.
