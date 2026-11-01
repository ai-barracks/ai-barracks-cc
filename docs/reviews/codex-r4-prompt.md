당신은 시니어 macOS/Swift·POSIX 리뷰어다. 로컬 저장소 /Users/choihouse/Develop/aibcc-swift-poc 의 커밋 87a558c..HEAD (데몬 백엔드 2519b0c·a9c9224·f7d1bf3, libghostty-spm vendoring ee9ef57 — Vendor/libghostty-spm/PATCHES.md, 캡처·증거 병합 5ac5c41, 재현 테스트 이후 커밋. `git log 87a558c..HEAD`로 전체 확인)를 코드 리뷰하라. 읽기 전용이다. `git -C /Users/choihouse/Develop/aibcc-swift-poc diff 87a558c..HEAD` 와 파일을 직접 읽어라.

배경: Swift(SwiftUI+libghostty-spm) 터미널 앱 PoC. 이번 변경은 opt-in `--backend=daemon`: AIBCCPtyDaemon(Sources/PtyDaemon)이 forkpty로 PTY를 소유해 앱 종료 후에도 셸이 살아남고, 앱은 libghostty `.inMemory` 백엔드로 화면만 붙는다(Sources/AIBCCPoC/Terminal/DaemonSession.swift, DaemonBackend.swift, TerminalPane.swift, App/WorkspaceModel.swift, App/SessionStore.swift). 공용 프로토콜·소켓 계층은 Sources/PtyProtocol. 처리량 문제로 PTY reader 스레드(PtyReader.swift)·DispatchIO 없는 FramedConnection·종단 간 흐름 제어를 넣었다. 테스트: scripts/ptyd-smoke.py(데몬 단독 15항목), scripts/run-persist-test.sh + SelfTest/PersistSuite.swift(PS-01a~e, PS-02a/b), 전체 self-test가 exec와 동일 상태라고 보고됨(docs/spikes/pty-ownership.md 2단계).

중점(우선순위 순):
1. 정확성 결함: 동시성(락·큐·스레드 경계, Swift 6 Sendable 우회 @unchecked의 실제 안전성), fd 수명(close 후 재사용 번호 접근, poll 중 close, CLOEXEC 누락으로 자식에 fd 누출), fork 후 자식에서 async-signal-safe 위반, waitpid/exit 경합, 흐름 제어 교착(일시정지된 세션이 영원히 재개되지 않는 경로), 재부착 재생 중 입력 차단이 영원히 풀리지 않거나 너무 일찍 풀리는 경로, 출력 순서 역전·유실.
2. 세션 영속·복원: sessions.json 저장/복원 순서, 고아 세션 정리가 살아 있는 세션을 죽일 수 있는 경로, pane 교체·배럭 전환·앱 종료 시 세션 종료/생존 의미가 의도(교체=종료, 앱 종료=생존)와 어긋나는 경로.
3. 테스트의 false-pass 경로: PS-01/02와 ptyd-smoke.py가 결함이 있어도 pass할 수 있는 지점(예: 판별력 없는 조건, 타이밍 의존, 대조군 부재).
4. 보안·자원: 소켓 권한(0600·디렉터리 0700), 환경 변수 전달, 로그, 메모리 상한.

출력 형식(한국어): 각 발견마다 `[blocker|major|minor] 파일:줄 — 결함 한 줄`, 다음 줄에 `재현/실패 시나리오:` 구체적 입력·상태 → 잘못된 결과, 그 다음 `수정 제안:` 한두 줄. 추측이면 "추정"이라고 표시. 마지막에 `요약:` 3줄과 blocker/major/minor 개수. 칭찬·일반론은 쓰지 말 것.
