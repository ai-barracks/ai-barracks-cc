# 관문 1 — PTY 소유권 스파이크 (정적 분석, 2026-10-31)

Council 결정문 3항: "`.exec`에서 출력 tap이 가능한가"를 먼저 판정. 빌드가 아직 허용되지 않아(자동 모드 분류기가 외부 프리빌트 바이너리 링크를 거부) **소스 정적 분석으로 1차 판정**하고 실행 확인은 빌드 후로 미룬다.

## 사실 (libghostty-spm 2.2.2026103001 소스)

| 질문 | `.exec` | `.inMemory(InMemoryTerminalSession)` |
|---|---|---|
| PTY·셸을 누가 소유? | Ghostty가 spawn·소유 | 호스트(앱)가 소유 — `write`/`resize` 클로저로 연결 |
| 사용자 입력 바이트 tap | 공개 API 없음 | `init(write:)` 클로저가 터미널이 내보내는 **모든 입력 바이트**를 받음 |
| 출력 바이트 tap | 공개 API 없음(C API `ghostty_surface_receive_buffer_cb`는 inMemory 경로 전용으로만 사용) | 호스트가 `receive(_:)`로 넣으므로 전부 보유 |
| 화면 텍스트 읽기 | 래퍼 내부 `ghostty_surface_read_text`(비공개) | `readViewportText()`(뷰포트만) |
| bell·OSC 알림·cwd·명령 종료 | `TerminalViewState`가 게시(bellCount, lastDesktopNotification*, workingDirectory, lastCommandExitCode) | 동일 |
| 앱 종료 후 세션 생존 | 불가(Ghostty가 자식 종료) | 호스트가 별도 데몬에 PTY를 두면 가능(zmx/tmux 방식) — 그 자체로 보장되지는 않음 |

## aib 쪽 사실

- aib의 Attention 원천(liveness 7상태)은 **hook이 쓰는 `.live/<id>.status` 파일**이며 PTY와 무관하다(CC README "PTY와 분리 — CC 밖에서 띄운 claude도 파일 기반 추적"). Council이 우려한 "출력 tap이 Attention 원천" 전제는 사실과 다르다.
- 출력 tap이 실제로 필요한 기존 기능은 **scrollback 디스크 영속화(v1.3.0, archive 탭)**다.

## 판정

1. PoC의 P0 터미널 검증은 Ghostty.app과 같은 `.exec`로 진행한다(실사용 조건과 동일).
2. 제품 전환 시 scrollback 영속화·세션 생존을 계승하려면 **`.inMemory` + 앱/데몬이 소유한 PTY**가 유력한 구조다. 입력 바이트도 호스트가 보므로 회귀 테스트의 정답 데이터로 쓸 수 있다.
3. 따라서 `.inMemory`는 "Go 차단"이 아니라 **제품 Go 전에 반드시 실행 검증할 경로**로 둔다(빌드 허용 후: 자체 forkpty 호스트로 `.exec`와 동일한 IN·RS·SC 시나리오 재실행).
4. 위험도: 중간, 해소 가능. `.inMemory`가 실패하면 래퍼 fork로 `ghostty_surface_read_text`를 공개해 종료 시 scrollback을 덤프하는 대안이 있다(검증 필요).

## 2단계 — 데몬 소유 PTY 실행 검증 (2026-11-01)

Herdr 데스크톱(herdr-core 데몬이 터미널을 소유, 앱 종료 후에도 유지)과 같은 구조를 opt-in 백엔드로 구현해 실측했다.

구조:
- `AIBCCPtyDaemon`(앱 번들 `Contents/MacOS`, 앱이 `posix_spawn`+`setsid`로 기동, 소켓당 1개 — flock): `forkpty`로 자식 생성, 세션마다 최근 출력 960KiB 보관, 종료한 세션도 최종 출력과 함께 보관(최대 32개).
- 프로토콜 `PtyProtocol`: `[type][16B session UUID][UInt32 BE length][payload]`, 제어는 JSON·입출력은 원시 바이트. CREATE는 첫 viewport 보고 때 실제 격자 크기로 보낸다(exec와 같은 시작 크기).
- 앱: pane = `TerminalSurfaceOptions(backend: .inMemory(session))`. 배럭별 그리드에 어떤 세션이 있는지 `<socket>.sessions.json`에 저장하고, 재실행 시 데몬 `LIST`와 대조해 자동 ATTACH. 어느 pane도 가리키지 않는 세션은 복원 때 정리.
- **재생된 질의의 응답 차단**: 재부착 시 과거 출력 속 DA1·DSR·OSC 색 질의를 Ghostty가 다시 응답해 살아 있는 프로세스에 입력으로 들어가는 문제가 있다 → 재생분은 `ghostty_surface_write_buffer_replay`(libghostty-spm patch 0011, 응답을 생성 지점에서 버림)로 live 출력과 같은 순서로 파싱한다(PS-01d가 실제 DA1 질의로, PS-04a가 replay 바로 뒤 live 질의 응답으로 검증). 처음 구현한 "파싱이 끝날 때까지 입력 차단"은 Codex r4에서 경계가 어긋난다는 지적을 받았다. 응답 일부가 app mailbox를 거쳐 늦게 전달되기 때문에 2026-11-05에 교체했다.

처리량·흐름 제어(첫 전체 실행에서 발견해 재설계):
- 첫 구현(dispatch read source + DispatchIO)은 PTY가 내주는 1KiB마다 깨어나 **14MB/s**에 그쳤고, **back-pressure가 없어** `yes` 같은 폭주가 메모리에 쌓이다 64MB에서 연결이 끊길 구조였다(exec에서는 Ghostty 파싱 속도가 자식을 자연히 늦춘다).
- 재설계: PTY 전용 reader 스레드(poll + non-blocking read, 흐르는 중에는 최대 1ms 모아 큰 프레임), DispatchIO 없는 소켓 계층, 종단 간 흐름 제어(Ghostty 미파싱 8MiB↑ → 앱이 소켓 읽기 중단 → 데몬 송신 대기 1MiB↑ → PTY 읽기 중단 → 자식이 write에서 대기).
- 데몬 단독(`scripts/ptyd-smoke.py`, 15/15): 키 입력 왕복 p50 0.40 / p95 0.63ms, 10만 줄(11.2MB) 183ms, 읽지 않는 클라이언트 3초 동안 데몬 RSS 변화 0KB, 재개 후 303만 줄 순서·누락 없음, 자식의 SIGPIPE/SIGHUP 기본 처리(대조군으로 판별력 확인).
- 앱 전체 self-test(`--backend=daemon`): exec와 **모든 항목 상태 동일, 실패 0**. 1분할 10만 줄 폭주 69ms(exec 39ms), 4분할 동시 205ms(exec 354ms), 폭주 중 입력 지연 p95 16.3ms.

세션 생존(`scripts/run-persist-test.sh`, 앱 2회 실행):
- PS-01a 앱 종료 후 같은 pid 생존(부모 = 데몬)·재실행 시 자동 재부착, PS-01b 이전 화면 재생, PS-01c 재부착 후 입력 도달, PS-01d 재생된 DA1 질의 응답 누출 0, PS-01e 고아 세션 0 — 모두 pass.
- PS-02a 없는 세션 attach → 종료 배너, PS-02b 앱 실행 중 데몬 종료 → 기존 pane 종료 표시·새 pane은 데몬 재기동 — pass.

판정: **세션 생존은 Swift + libghostty `.inMemory` + 데몬으로 달성 가능**하며 터미널 품질(P0) 회귀가 없다. 제품 기본값 전환 전 남은 일은 known-issues #4.
