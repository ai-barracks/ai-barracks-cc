# Known issues (PoC)

Codex code review r1 (2026-10-31) 반영 후에도 남는 제약. 제품 전환 시 해결 대상.

1. **SwiftPM resource bundle lookup — 해소(2026-11-01)** — SwiftPM 6.3.2의 `Bundle.module`은 `.app` 루트와 빌드 당시 절대 경로만 찾고 없으면 `fatalError`라, 배포 앱(빌드 디렉터리 없음)은 첫 터미널 생성에서 죽었다(대조 실험으로 크래시 재현). libghostty-spm을 `Vendor/libghostty-spm`으로 들여와 `Bundle.main.resourceURL`을 먼저 찾는 resolver로 패치(`Vendor/libghostty-spm/PATCHES.md`, upstream 제안 후보). PK-01a(리소스·terminfo·현지화 문자열이 `Contents/Resources`에서 해석)·PK-01b(`scripts/verify-standalone.sh`: 빌드 경로 bundle을 치운 채 터미널 시작·입력) pass. 바이너리 xcframework는 원래 URL·checksum 그대로 받는다.
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
10. **pane 교체 직후 키 유실 — 재현 안 됨(2026-11-01)** — 원래 관측(IN-09 Ctrl+C 2/5 유실)은 활성화 가드 도입 전, 디스플레이 절전으로 앱이 비활성일 수 있던 시간대의 실행이었다. `--selftest-only=repro10`(RP-10a~d: Ctrl+C·일반 문자·원래 조건·직전 순서[한글 입력 소스 왕복+bracketed paste pane] 재현, 각 15회, drain 없음)에서 exec·daemon 모두 **60회 중 유실 0**. 비활성 앱 영향으로 추정하고 회귀 테스트로 유지한다.
11. **macOS 창 크기 복원** — 기본 창 크기(1440×900)는 저장된 창 상태가 없을 때만 적용된다. self-test는 시작 시 기본 크기로 맞춘다(이전 실행이 남긴 최소 크기 때문에 RS-08 첫 단계가 inspector 자동 표시 애니메이션 ~0.5s를 포함해 측정된 사례).
12. **Codex 실행 리뷰 R5(창 상태 변화 후 화면 미갱신) — 재현 안 됨(2026-11-01)** — 리뷰 순서(4→1분할·배럭 왕복·창 축소)와 최소화→복원 뒤 입력을 recorder echo로 화면에 그리게 하고, 전후 캡처의 pane 픽셀 차이(최소 3칸 면적, 커서 깜박임 배제)로 판정: exec·daemon 모두 그려짐(`--selftest-only=repro-r5`, RP-R5a/b). 당시 관측은 computer-use 캡처 경로 문제였을 가능성이 크다. 사람 검사 RS-05에서 실제 화면으로 한 번 더 본다.
