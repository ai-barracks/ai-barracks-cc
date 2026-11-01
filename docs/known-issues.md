# Known issues (PoC)

Codex code review r1 (2026-10-31) 반영 후에도 남는 제약. 제품 전환 시 해결 대상.

1. **[product blocker] SwiftPM resource bundle lookup** — SwiftPM 6.3.2의 `Bundle.module`은 `.app` 루트와 빌드 당시 절대 경로만 찾는다. `Contents/Resources`에 복사한 `GhosttyKit_GhosttyTerminal.bundle`은 찾지 않으므로, 이 PoC는 **이 Mac의 `.build` 경로 fallback으로만 동작**한다. 제품에서는 libghostty-spm을 fork해 `Bundle.main.resourceURL` 우선 resolver를 넣거나 upstream에 제안한다. 앱 루트에 bundle을 두는 방식은 strict codesign 구조 검증과 충돌한다.
2. **split 경계 드래그는 자체 구현** — layout 전환 시 터미널(PTY)을 보존하려고 `HSplitView` 대신 `PaneGridLayout` + overlay divider(드래그 비율 0.2~0.8)를 쓴다. 키보드로 divider를 옮기는 접근성 경로는 아직 없다.
3. **숨겨진 pane의 PTY 크기** — 4→1 전환 시 주차된 pane은 그리기를 멈추지만 전체 영역 크기를 제안받아 SIGWINCH가 한 번 발생한다.
4. **앱 종료 후 세션 생존 — 스파이크로 해소, 기본값은 아직 `.exec`** — `--backend=daemon`(opt-in)에서 AIBCCPtyDaemon이 PTY를 소유하고 앱은 `.inMemory`로 화면만 붙는다. 앱 종료 후 같은 프로세스 생존·재실행 시 자동 재부착·이전 화면 재생·입력 연결이 실측 통과(PS-01a~e, PS-02a/b; docs/spikes/pty-ownership.md 2단계). 남은 제약:
   - **단일 앱 인스턴스 가정** — 같은 소켓을 쓰는 앱 두 개가 동시에 뜨면 세션 배치 파일을 서로 덮어쓰고, 복원 시 상대 인스턴스의 세션을 고아로 보고 정리할 수 있다(`open -n` 동시 실행 금지).
   - **재생은 최근 960KiB 원시 바이트** — 서버 측 터미널 상태가 아니라 출력 꼬리를 다시 파싱한다. 재생 시작점이 escape sequence 중간이면 첫 몇 글자가 깨질 수 있고, 그보다 오래된 scrollback은 재부착 화면에 없다(TUI는 SIGWINCH 재그리기로 복구). Herdr식 서버 측 상태 유지(libghostty-vt)는 제품 단계 과제.
   - 숨은 배럭 pane이 대량 출력을 내면 libghostty in-memory 세션의 부착 전 버퍼(1MiB, 오래된 것부터 버림)만큼만 남는다.
   - 데몬은 앱이 띄우는 자식 프로세스(setsid)다. 로그인 시 자동 기동(launchd)·버전이 다른 데몬과의 프로토콜 협상은 없다.
5. **IME 조합 중 pane 전환의 A쪽 확정 정책** — 스크립트 재생으로는 실제 IMK의 commit/cancel을 재현할 수 없어 사람 검사(IN-04-phys)로만 판정한다.
6. **`--selftest` exit 0은 사람 검사 결과가 합쳐져야만 가능** — 자동 실행만으로는 최선이 exit 3(incomplete)이다.
7. **자동화 미완 하위 항목** — ST-01b(4분할에서 IN/SC 핵심 재실행), MD-04b(뷰어 클릭·스크롤 후 복귀)는 `unverified`로 보고된다.
8. **settle timeout과 정상 종료 구분 없음**(Codex r2 #17 잔여) — 바이트 비교가 기대값과 어긋나면 fail로 드러나므로 판정은 안전하지만, evidence에 timeout 여부가 따로 남지 않는다.
9. **이 Mac의 Command Line Tools 손상** — `usr/lib/swift/pm/{ManifestAPI,PluginAPI}`에 2024-02 CLT의 `*.private.swiftinterface`가 남아 있어 swiftc가 옛 PackageDescription API로 manifest를 컴파일하고, 현재 `libPackageDescription.dylib`와 링크하다 실패한다(`Undefined symbols ... Package.__allocating_init`). **모든 SwiftPM 패키지가 영향**. 시스템 파일은 건드리지 않고 `scripts/make-toolchain-fix.sh`가 공개 인터페이스만 담은 미러를 `.toolchain-fix/`에 만들고 `SWIFTPM_CUSTOM_LIBS_DIR`로 지정한다(`package-app.sh`가 자동 적용). 근본 해결은 CLT 재설치 또는 관리자 권한으로 stale 파일 4개 삭제.
10. **pane 교체 직후 같은 이벤트 루프 턴의 키 입력 유실 가능성** — self-test에서 pane을 교체한 직후 바로 누른 Ctrl+C의 press가 2/5회 사라졌다(keyEquivalent 이후 keyDown 미도달). 이벤트 큐를 비운 뒤 누르면 3/3 통과. 실사용 영향은 낮지만 제품 단계에서 "pane 생성·교체 직후 입력" 재현 테스트로 원인을 확정한다.
11. **macOS 창 크기 복원** — 기본 창 크기(1440×900)는 저장된 창 상태가 없을 때만 적용된다.
