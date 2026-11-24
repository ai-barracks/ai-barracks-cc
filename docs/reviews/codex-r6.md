`55c718c..24108e7`의 13개 커밋, diff, 구현·테스트, r4/r5 원문·triage를 대조했습니다. **blocker 1 / major 13 / minor 3**입니다. 줄 번호는 `24108e7` 기준입니다.

[blocker] Sources/AIBCCPoC/Terminal/BoundedProcess.swift:149-150 — 실제 activation의 취소 확인이 같은 NSLock을 재획득하여 교착한다.  
재현/실패 시나리오: 예약 실행 → `LiveGroups.start()`가 lock 획득 → `cancelled()` → `ActivationScheduler.isCancelled()`(:204-205) → `BoundedProcess.isShuttingDown` → 같은 lock 재획득. 첫 auth spawn 전부터 멈추며, 이후 OFF의 `kill(tag:)`와 앱 종료의 `shutdown()`도 막힌다. [NSLock은 재귀 잠금이 아니다.](https://developer.apple.com/documentation/foundation/nslock) AC-01a는 activate 대역, AC-01b는 상수 cancellation closure를 사용하므로 이 조합을 실행하지 않는다.  
수정 제안: 취소 상태 변경·검사·spawn·등록·kill을 재진입 없는 공통 launch gate로 설계한다. 실제 Scheduler→Runner→BoundedProcess와 fake executable을 연결하여 실행·OFF·quit의 제한 시간 내 완료를 검사한다.

[major] Vendor/libghostty-spm/Sources/GhosttyTerminal/InMemory/InMemoryTerminalSurfaceAccess.swift:336-339 — patch 4가 callback 재진입 교착을 만든다.  
재현/실패 시나리오: backlog callback 실행 중 `backlogNotifyLock`을 계속 보유한다. callback이 high-water 상태에서 handler를 교체하면 `setBacklogObserver()`가 다시 같은 잠금을 요청하여 교착한다. **추정:** 다른 스레드가 condition을 잡고 notify lock을 기다리는 동안 callback이 `pendingOutputByteCount`를 읽어도 잠금 순환이 성립한다. 현재 DaemonSession callback은 재진입하지 않지만, :313-314에 명시된 재진입 계약은 깨졌다.  
수정 제안: 상태 잠금 아래에서 통지 순서를 확정하되, callback은 두 잠금 모두 해제한 상태에서 직렬 전달한다. handler 교체·pending 조회를 포함한 결정적 경합 테스트를 추가한다.

[major] Sources/PtyDaemon/PtySession.swift:172,219-236 — write-source 취소 완료 전에 session이 해제되면 master fd가 누수된다.  
재현/실패 시나리오: **추정:** 입력 EAGAIN 상태에서 KILL → reader 완료가 write-source cancellation handler보다 먼저 실행 → `closeFD()`는 `liveWriteSources > 0`이라 반환 → `onExit`가 daemon dictionary에서 session 제거. cancellation handler도 `[weak self]`이므로 마지막 소유자가 사라지면 fd를 닫을 주체가 없다.  
수정 제안: cancellation 완료까지 session 또는 독립적인 fd owner를 강하게 유지한다. reader와 모든 source가 정리된 뒤 소유권을 해제하고, 두 완료 순서를 강제하는 fd-count 테스트를 추가한다. [Apple의 cancellation 수명 규칙](https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/setcancelhandler%28handler%3A%29)

[major] Sources/PtyDaemon/PtySession.swift:113-118 — leader가 먼저 종료하면 남은 session member를 정리하지 않는다.  
재현/실패 시나리오: `trap '' HUP; sleep 600 & exit 0`처럼 HUP를 무시하는 자손을 남기고 leader 종료 → reap 뒤 pane 닫기. `terminate()`는 `reaped`이면 반환하고, `Daemon.kill()`(:139-147)은 종료 record만 제거한다. 자손 sweep이 예약되지 않아 `sleep`이 남는다. smoke `kill-tree`는 leader가 `wait` 중인 경우만 검사한다.  
수정 제안: leader 생존 여부와 session 정리 책임을 분리한다. leader 종료 후 KILL·pruning 경로에서도 소유한 자손을 정리하고, leader가 먼저 사라지는 테스트를 추가한다.

[major] Sources/PtyDaemon/Daemon.swift:83-85 — 입력 상한의 비치명적 거부가 클라이언트에서는 세션 종료로 처리된다.  
재현/실패 시나리오: 읽지 않는 자식에게 8 MiB 넘게 입력 → FAILURE 전송. 자식은 살아 있지만 `DaemonSession.swift:144-145`를 거쳐 `TerminalPane.swift:145-149`가 영구적으로 `hasExited = true`와 실패 배너를 설정한다. 이후 정상 출력·입력이 돌아와도 종료 표시가 복구되지 않는다. smoke는 FAILURE 문자열만 검사한다.  
수정 제안: recoverable input rejection과 create/attach 실패를 구분한다. 입력 거부는 경고·재시도/back-pressure로 처리하고, 자식 생존 및 이후 I/O 회복까지 검사한다.

[major] Sources/AIBCCPoC/Terminal/TerminalPane.swift:137-139 — 앱이 없는 동안 종료된 세션은 재접속 후에도 최종 출력을 보관하지 않는다.  
재현/실패 시나리오: 세션 유지 상태로 앱 종료 → 자식이 마지막 결과를 출력하고 종료 → 앱 재실행. ATTACHED의 `alive=false`만으로 `reportedExit=true`를 설정하므로, replay 파싱 뒤 도착한 `.outputComplete`가 `reportExit()`에서 무시된다. 그동안 archive를 작성한 앱은 없었다. PS-04b는 계속 연결된 pane만 검사한다.  
수정 제안: `alive=false`를 “이미 보관됨”으로 간주하지 않는다. 최종 marker에서 보관하고, 중복 방지가 필요하면 실제 archive metadata와 session identity로 판단한다.

[major] Sources/AIBCCPoC/Documents/Structured/AgentYamlDocument.swift:310-318 — 같은 들여쓰기의 quoted multiline scalar는 여전히 손상된다.  
재현/실패 시나리오: 유효한 `models:\n  primary: "first\n  second"\n`에서 primary를 변경하면 다음 줄의 들여쓰기가 같아 multiline 검사를 통과한다. 첫 줄만 `primary: new`로 바뀌고 `second"`가 남는다. 메모리 내 YAML parser 검사에서 원문은 유효했지만 결과는 ScannerError였다. CR-05a에는 이 형태가 없다.  
수정 제안: quote의 종료와 scalar 전체 범위를 판별하거나 열린 quoted scalar의 폼 편집을 거부한다. 저장 결과를 실제 YAML parser로 검증한다.

[major] Sources/AIBCCPoC/Documents/Structured/MarkdownPatch.swift:118-131 — ordered 하위 목록·continuation은 중첩 거부를 우회한다.  
재현/실패 시나리오: `- a\n- b\n  1. child\n`는 unordered run의 들여쓰기가 모두 같아 허용된다. 폼에서 `b`를 삭제하면 ordered child는 남아 `a`의 자식으로 바뀐다. 여러 줄 본문도 같은 문제가 있다. GROWTH의 `notGrowthRuns()` 역시 `- ` 밖의 continuation을 놓친다.  
수정 제안: 관리 목록의 모든 continuation·ordered/unordered 하위 노드를 포함하여 검사한다. AST 기반 보존이 어렵다면 해당 섹션의 폼 저장을 거부하고 혼합 목록 fixture를 추가한다.

[major] Sources/AIBCCPoC/Documents/Structured/GrowthEditorView.swift:74-79 — pipe 검증과 tokenizer의 escape 판정이 달라 잘못된 표를 저장한다.  
재현/실패 시나리오: 셀에 `A\\|B`처럼 pipe 앞에 역슬래시 두 개를 입력하면 UI regex는 허용한다. 그러나 `GrowthDocument.cells()`는 이를 열 구분자로 처리한다. 메모리 내 동일 로직 검사에서 저장 행이 4열이 되었으며, 다음 parse에서는 해당 행이 제외된다. `patchTable()`은 기존 행만 검증한다.  
수정 제안: UI와 저장 계층에 같은 tokenizer를 사용하고 생성된 행도 검증한다. 역슬래시 1·2·3개와 pipe의 round-trip 테스트를 추가한다.

[major] Sources/AIBCCPoC/Skills/SkillSheets.swift:178-195 — 최신 원문 보존 수정으로 raw 저장의 name 검증을 우회할 수 있다.  
재현/실패 시나리오: `skills/foo/SKILL.md`의 raw에서 `name`을 `bar`로 변경하거나 삭제 → 폼으로 전환 → 저장. 변경된 `formBase`는 보존되지만 `name == slug` 검사는 raw 저장 분기에만 있다. 결과적으로 catalog가 문제 파일로 판정하는 내용을 정상 저장한다.  
수정 제안: 모드별 텍스트 생성 후 최종 `edited`에 공통 frontmatter·name·description 검증을 적용한다. raw→form 왕복에 name 변경·삭제 사례를 추가한다.

[major] Sources/AIBCCPoC/App/WorkspaceModel.swift:599-601 — GUI의 터미널 기반 sync는 AibWriteQueue를 우회한다.  
재현/실패 시나리오: Skills 자동 sync 실행 중 “Sync All”이나 palette의 `aib sync`를 적용하면 별도 PTY에서 동시에 실행된다. 설치된 `aib`의 `register_barrack`(:199-207)은 잠금 없이 같은 `.tmp/.tmp2`를 사용하므로 사용자 registry 경합이 남는다. R5-01a는 queue에 직접 넣은 두 sleep 작업만 검사한다.  
수정 제안: 모든 GUI apply 경로를 프로세스 완료까지 동일 coordinator로 관리하거나, CLI registry read-modify-write에 공통 파일 잠금을 도입한다. 실제 자동 sync와 pane sync의 동시 실행을 검사한다.

[major] Sources/AIBCCPoC/App/WorkspaceModel.swift:448-449,633 — attention 단축키와 pane 선택은 이동 확인을 여전히 우회한다.  
재현/실패 시나리오: RULES 편집 중 주의 항목이 있는 상태에서 ⌘⇧A 실행 → `goToNextAttention()`이 배럭·destination을 직접 변경한다. 터미널 메뉴의 `bringToFront()`도 동일하다. NV-01a는 `navigate()`를 직접 호출할 뿐 실제 진입점을 검사하지 않는다.  
수정 제안: 일부 View가 아니라 모델의 이동 명령에서 guard를 강제한다. attention·pane 선택·새 pane 생성 등 실제 사용자 진입점으로 dirty editor 보존을 검사한다.

[major] Sources/AIBCCPoC/App/WorkspaceModel+Navigation.swift:13-18 — 이동하지 않는 작업의 확인도 dirty 표시만 지워 다음 이동에서 편집을 유실시킨다.  
재현/실패 시나리오: RULES 편집 → 이미 선택된 RULES를 다시 클릭 → “버리고 이동” 확인. destination이 그대로여서 editor는 초기화되지 않지만 `editInProgress`만 false가 된다. `DocumentView.swift:85`는 여전히 true인 `isDirty`의 변화가 없어 이를 복원하지 않는다. 다음 실제 이동은 확인 없이 진행된다. palette에서 sheet만 여는 작업도 같은 구조다.  
수정 제안: no-op 이동은 확인하지 않고, discard는 editor의 실제 버퍼 초기화와 연결한다. 상위 Boolean만 지우지 말고 editor lifecycle과 이동 transaction을 함께 관리한다.

[major] scripts/make-demo.sh:10-15 — 임시 경로의 문자열 검사만으로 사용자 디렉터리를 삭제할 수 있다.  
재현/실패 시나리오: `/tmp/../../Users/choihouse/.aib`는 `/tmp/*` 검사를 통과하지만 이 환경의 realpath는 `/Users/choihouse/.aib`다. 바로 다음 `rm -rf`가 registry를 포함한 사용자 디렉터리를 삭제한다. `.claude`, `.gemini`도 동일하다. 실제 삭제 명령은 실행하지 않았다.  
수정 제안: `mktemp`로 생성·소유한 fixture만 삭제한다. 사용자 지정 경로를 지원한다면 canonical path, symlink 조상, 전용 marker를 검증하고 광범위한 선행 삭제를 제거한다.

[minor] Sources/AIBCCPoC/SelfTest/ActivationSuite.swift:198 — AC-01b는 Claude argv 뒤에 추가된 인자를 검출하지 못한다.  
재현/실패 시나리오: 정상 argv 뒤에 임의 인자를 추가해도 `prefix(v1Claude.count)`만 비교하여 통과한다. 기대값의 구현 의존성은 제거했지만 정확한 안전 인자 계약 검사는 아니다.  
수정 제안: `--tools ""`의 빈 문자열 인자를 보존하면서 전체 argv와 개수를 literal fixture에 비교한다.

[minor] Sources/AIBCCPoC/SelfTest/ProviderSuite.swift:76-83 — PR-01b의 마지막 추가 요청 검사는 강제 종료와 경합한다.  
재현/실패 시나리오: **추정:** 마지막 응답 뒤 추가 요청을 보내도 fake CLI가 이를 읽고 기록하기 전에 `CodexModelProbe.swift:97-100`의 `finish()`가 그룹을 SIGKILL하면 로그에는 정상 네 요청만 남는다. 이미 죽은 fake에 대한 200 ms 대기는 이를 해결하지 못한다.  
수정 제안: 송신 경계의 spy로 모든 요청을 기록하거나, fake가 입력을 끝까지 관찰했음을 확인하는 teardown handshake를 사용한다. 마지막 응답 뒤 추가 송신하는 변이체가 확실히 실패해야 한다.

[minor] scripts/ptyd-smoke.py:381-395 — leak 검사는 출력·종료 준비가 전부 실패해도 PASS한다.  
재현/실패 시나리오: 각 cycle의 출력 대기와 EXITED 대기 결과를 버리고 RSS 차이만 판정한다. 실제 검사 함수에 메모리 대역을 주입하여 130번의 대기를 모두 false로 만들었는데도 `PASS leak rss +0KB`를 반환했다.  
수정 제안: 모든 cycle의 생성·출력량·종료 성공을 필수 조건으로 검사한다. 실패한 fixture에서 RSS가 증가하지 않은 것을 누수 해결 근거로 인정하지 않는다.

**추가 확인 범위**
- FramedConnection의 low-water 통지·취소 후 close, PtyReader의 batch별 pause/stop·drain 상한, drain 뒤 `exitInfo` 공개, replay/marker 구분과 trim 시 타입 보존, 복원 실패 저장본 유지, immutable archive payload, Git 환경 정리에서는 위 항목 외 추가 결함을 확인하지 못했습니다.
- PS-02c·PS-03a·PS-04a/b·PO-01c에는 기존 결함을 겨냥한 독립적인 조건이 있습니다. 다만 본 리뷰에서는 실앱·실데몬 테스트를 실행하지 않았습니다.
- 일반 self-test의 지정 파일 쓰기는 BA-01a의 registry·Claude/Gemini 설정 경로 주입, SK-02d의 registry 주입, activation의 임시 디렉터리 및 background scheduler 차단을 확인했습니다. 설치된 `aib`도 해당 override를 사용합니다. 다만 `ensure_registry()`는 `~/.aib` 디렉터리를 생성할 수 있으며, 위 demo 경로 검사는 별도로 위험합니다.

요약:
1. blocker 1 / major 13 / minor 3: 실제 activation 교착 때문에 수정 완료 판정을 보류해야 합니다.
2. PTY 수명·자손 정리, 문서 손상, 이동 확인 우회와 테스트 false-pass가 남아 있습니다.
3. 읽기 전용 소스 검토와 메모리 내 검사를 수행했으며, 파일 수정·실앱/실데몬 self-test·사용자 설정 쓰기는 하지 않았습니다.