**r6 완전 해소 판정은 보류합니다: blocker 0 / major 9 / minor 4.** 지정 범위의 6개 커밋 로그·diff·구현·테스트와 r6 원문·triage를 직접 대조했습니다. 줄 번호는 `101035e` 기준입니다.

[major] Sources/AIBCCPoC/Terminal/DaemonSession.swift:147-150 — 업데이트 후 기존 데몬에 연결하면 입력 거부가 여전히 세션 종료로 처리된다.  
재현/실패 시나리오: beta.1 데몬을 실행한 채 beta.2 앱으로 교체한다. protocol version과 소켓 이름은 그대로이고, `DaemonBackend.ensureRunning()`은 연결 가능 여부만 확인한다. 따라서 기존 데몬의 입력 상한 초과는 여전히 `FAILURE`로 도착하여 pane을 종료 처리한다. 데몬 측 자손 정리·fd 수정도 적용되지 않는다.  
수정 제안: 데몬 build/capability handshake와 안전한 교체 절차를 마련한다. 전환 기간에는 구 데몬의 입력 거부도 비치명적으로 처리하고, 구 데몬＋새 클라이언트 조합을 검사한다.

[major] Sources/PtyDaemon/PtySession.swift:119-121,233 — reap 시점의 고정된 leftovers 목록은 이후 생성된 자손을 놓친다.  
재현/실패 시나리오: **추정(실데몬 미실행):** leader 종료 후 살아남은 HUP 무시 helper가 새 자식을 생성한 다음 KILL한다. 기록된 helper만 종료되고 나중에 생긴 자식은 남는다. PID·시작 시각 비교는 기록된 프로세스의 식별에는 도움이 되지만 목록의 완전성은 보장하지 않는다. smoke는 미리 생성된 `sleep`만 검사한다.  
수정 제안: 정리 책임을 reap 시점 snapshot과 분리하고, 이후 생성되는 session 구성원까지 추적·정리한다. EXITED 이후 fork를 완료한 뒤 KILL하는 fixture를 추가한다.

[major] Sources/PtyDaemon/Daemon.swift:160-164,210-213 — pruning과 전체 종료는 exited 세션의 leftovers를 정리하지 않는다.  
재현/실패 시나리오: HUP를 무시하는 자손을 남긴 종료 세션이 보관 상한 32개에서 밀려나면 `terminate()` 없이 제거된다. 이후 해당 ID의 KILL도 무시된다. SHUTDOWN 역시 `isAlive`인 세션만 처리하므로 같은 자손이 남는다. r6의 개별 KILL 수정으로는 이 경로가 해결되지 않는다.  
수정 제안: record 제거·pruning·shutdown·idle 종료 전에 공통 cleanup을 수행한다. 종료 세션 33개와 exited 세션을 포함한 SHUTDOWN 테스트를 추가한다.

[major] Sources/AIBCCPoC/App/WorkspaceModel+Scrollback.swift:7-11 — 기존 archive가 있다는 이유만으로 최종 출력 보관을 생략한다.  
재현/실패 시나리오: **추정(실앱 미실행):** 자식은 살아 있지만 연결만 끊기면 `DaemonSession.connectionClosed()`도 `.outputComplete`를 발생시켜 중간 화면을 보관한다. 연결 종료는 클라이언트 write backlog 상한 초과로도 가능하다. 이후 자식이 최종 결과를 출력하고 종료한 뒤 재접속하면, 같은 session ID의 중간 archive 때문에 최종 출력을 버린다. PS-05b에는 기존 archive가 없다.  
수정 제안: archive metadata에 최종 EXITED 확인 여부를 기록하고, 중간 snapshot은 최종 출력으로 갱신한다. 부분 archive가 있는 재접속과 반복 attach를 검사한다.

[major] Sources/AIBCCPoC/Documents/Structured/AgentYamlDocument.swift:326-330,368-369 — anchor·tag가 앞선 quoted multiline scalar는 여전히 손상된다.  
재현/실패 시나리오: `models:\n  primary: &m "first\n  second"\n` 또는 `!!str "first…"`에서 primary를 변경한다. 첫 문자가 `&`/`!`라 continuation 검사가 false이고 다음 줄의 들여쓰기도 같아 첫 줄만 교체한다. 메모리 내 parser 검사에서 원문은 유효하지만 결과는 `ScannerError`였다. 값 앞의 anchor·tag는 유효한 YAML이다. [YAML node properties](https://yaml.org/spec/1.2.2/#69-node-properties)  
수정 제안: node properties를 포함해 scalar 범위를 판별하거나, 해당 형태의 폼 편집을 거부한다. R6-01b에 anchor·tag fixture와 저장 결과 parser 검증을 추가한다.

[major] Sources/AIBCCPoC/Documents/Structured/MarkdownPatch.swift:141-149 — 모든 `#` 시작 줄을 heading처럼 취급하여 continuation 거부를 우회한다.  
재현/실패 시나리오: `- a\n- b\n#tag\n`에서 b를 삭제하면 `hasHangingContent`가 false여서 `#tag`가 a의 본문으로 옮겨 붙는다. `####### text`도 같다. markdown-it으로 원문과 변환 결과의 소속 변경을 확인했다. 이들은 ATX heading이 아니다. [CommonMark heading 규칙](https://spec.commonmark.org/0.31.2/#atx-headings)  
수정 제안: 실제 heading 문법을 사용하고 section 분리와 판정을 통일한다. RULES와 GROWTH 양쪽에 `#tag`·7개 hash continuation 테스트를 추가한다.

[major] Sources/AIBCCPoC/Maintenance/AibWriteLock.swift:9-11 — 같은 사용자 registry를 쓰는 개발·출시 앱이 서로 다른 잠금을 사용한다.  
재현/실패 시나리오: 개발 앱과 출시 앱을 함께 실행하면 잠금은 각각 `AIBCCPoC/aib-write.lock`, `CommandCenter2/aib-write.lock`에 생긴다. 반면 기본 쓰기 대상은 모두 `~/.aib/barracks.json`이다. 서로 다른 bundle ID라 SingleInstance도 막지 않는다. 설치된 `aib`는 여전히 공통 `.tmp/.tmp2`를 사용하므로 동시 sync의 registry 경합이 남는다.  
수정 제안: 잠금 위치를 앱 variant가 아니라 공유 쓰기 대상에 연결한다. 두 support directory에서 같은 registry를 수정하는 교차 프로세스 테스트를 추가한다.

[major] Sources/AIBCCPoC/App/WorkspaceModel.swift:653-656 — Quick Command는 이동 확인을 기다리지 않고 실행된다.  
재현/실패 시나리오: 문서 편집 중 palette에서 Quick Command를 선택하면 `showSessions()`는 확인만 예약하고 반환하지만, 바로 다음 줄이 기존 터미널에 명령과 Enter를 보낸다. “계속 편집”을 눌러도 실행을 취소할 수 없다. `openPane()` 역시 확인 전에 pane을 생성·저장하여 취소 후에도 남기며, 나중에 세션 화면에 들어가면 실행된다.  
수정 제안: 이동뿐 아니라 명령 송신·pane 생성 전체를 확인 후 실행하는 transaction으로 묶는다. 취소 시 입력 바이트·pane 수·저장 layout이 불변인지 검사한다.

[major] scripts/make-demo.sh:18,36-39 — 새 경로 검사가 shell injection을 막지 못한다.  
재현/실패 시나리오: `/tmp/r6'; printf DEMO_INJECTED; #`는 새 NAME 검사를 통과한다. 이를 `zsh -lc "aib init '$dir'"`에 보간하면 추가 명령이 된다. 실제 `aib` 대신 출력만 하는 대역으로 추가 `printf` 실행을 확인했다. 주입 명령은 marker·삭제 경로 검사와 무관하게 사용자 파일에 접근할 수 있다.  
수정 제안: 경로를 shell 코드에 보간하지 말고 positional argument로 전달한다. “plain folder name”을 지원한다면 문자 whitelist도 적용한다. 실제 init·삭제 명령은 실행하지 않았다.

[minor] Sources/AIBCCPoC/Maintenance/AibWriteLock.swift:15-16 — pane 경로에서는 잠금 파일의 부모 폴더를 준비하지 않는다.  
재현/실패 시나리오: support directory가 없는 최초 실행을 `--backend=exec` 또는 별도 데몬 소켓으로 시작하고 pane sync를 적용하면 `lockf`가 부모 폴더를 만들지 못해 apply가 실패한다. 폴더 생성은 `hold()`에만 있어, queued write를 먼저 실행했는지에 따라 달라진다.  
수정 제안: 두 경로가 공통 준비 함수를 사용하고 준비 실패를 명시적으로 전달한다. 기존 support directory가 없는 조건을 검사한다.

[minor] Sources/AIBCCPoC/SelfTest/AgentSuite.swift:304-326 — NV-01b는 실제 편집 버퍼 초기화와 표시된 진입점들을 검증하지 않는다.  
재현/실패 시나리오: 실제 editor 없이 `editInProgress = true`를 설정하고 Boolean·revision만 비교한다. `DocumentView`의 discard 처리 전체를 제거해도 이 검사는 통과한다. 제목의 ⌘⇧A 호출도 없으며 Quick Command·palette·취소 후 부작용도 검사하지 않는다.  
수정 제안: 실제 raw/form 편집 상태에서 discard 후 재편집·다음 이동을 검사하고, 각 진입점의 취소가 부작용을 남기지 않는지 확인한다.

[minor] Sources/AIBCCPoC/SelfTest/ReviewR6Suite.swift:101-112 — R6-01a는 동시 호출의 true→false 전달 순서를 검증하지 않는다.  
재현/실패 시나리오: 단일 thread·surface 없는 상태에서 `first:true`, `second:true`만 확인한다. 큐 없이 unlock 후 즉시 callback을 호출하는 구현도 이 조건을 만족하므로, r4의 동시 통지 역전 회귀를 검출하지 못한다.  
수정 제안: 두 thread와 barrier로 high/low 전이를 교차시키고, handler 교체·pending 조회·마지막 resume까지 결정적으로 검사한다.

[minor] Sources/AIBCCPoC/SelfTest/ActivationSuite.swift:200-201 — AC-01c는 교착 감지 후 cleanup에서 다시 무한 대기한다.  
재현/실패 시나리오: 이전 단일-lock 변이체에서는 `finishes()`가 timeout을 반환해도 마지막 `release()`가 `stop()` → `BoundedProcess.kill()`로 이미 교착한 gate를 다시 기다린다. 따라서 제한 시간 내 FAIL 보고서를 만드는 테스트가 아니다. triage의 “self-test가 멈춤”과도 일치한다.  
수정 제안: 전역 gate를 교착시키는 회귀 검사는 별도 프로세스로 격리하고 부모 watchdog이 실패를 판정한다. 같은 방식으로 shutdown 경합도 검사한다.

**해소 확인 및 사용자 파일 경로**

- `BoundedProcess`의 현재 cancellation 호출 경로에서는 기존 재획득 교착이 제거됐다. backlog 큐도 상태 잠금 아래 순서를 확정하고 잠금 밖에서 단일 전달한다. 강한 cancel/reader completion capture는 취소 및 completion 배열 해제로 순환을 끊는 구조다.
- Growth의 pipe tokenizer 통일·생성 행 재검증, Skill의 최종 공통 name 검증, AC-01b 전체 argv 비교, PR-01b 송신 경계 spy는 해당 r6 반례를 겨냥한다. smoke leak에 모든 대기를 false로 주입한 메모리 검사도 이제 **FAIL**했다.
- 일반 self-test의 지정 네 파일에 대한 추가 직접 쓰기 경로는 발견하지 못했다. BA-01a는 registry·Claude/Gemini settings를 임시 경로로 주입하며 설치된 `aib`도 이를 사용한다. SK-02d는 registry를 별도 지정하고 sync는 global hook 설정을 호출하지 않는다. ActivationSuite는 임시 directory만 사용하며, self-test의 background scheduler 생성은 차단돼 있다.
- 다만 `aib.ensure_registry()`의 `~/.aib` 폴더 생성과 신규 support-directory lock 파일 쓰기는 존재한다. 위 demo injection은 별도의 격리 우회 경로다.

요약:
1. blocker 0 / major 9 / minor 4: 기존 activation 교착은 해소됐지만 r6 전체 완료 판정은 보류한다.
2. 자손 정리·최종 archive·문서 보존·이동 확인 전 부작용·공유 잠금 및 demo 경로 보완이 필요하다.
3. 읽기 전용 소스 검토와 메모리 내 검사만 수행했으며, 파일 수정·실앱/실데몬 self-test·사용자 설정 쓰기는 하지 않았다.