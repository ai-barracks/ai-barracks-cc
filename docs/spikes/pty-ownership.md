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
