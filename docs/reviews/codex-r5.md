[blocker] Sources/AIBCCPoC/Activation/ActivationRunner.swift:142-157 — 취소 확인·spawn·프로세스 등록이 분리되어 OFF 또는 앱 종료 뒤에도 요청이 시작될 수 있다.
재현/실패 시나리오: 인증 완료 직후 OFF → `run()`은 취소 여부를 확인하기 전에 요청 프로세스를 spawn한다. 또한 spawn과 `live.insert()` 사이에 앱 종료의 `killAll()`이 실행되면 해당 프로세스를 놓친다. `applicationWillTerminate`는 scheduler의 `stop()`도 호출하지 않는다.
수정 제안: v1처럼 취소 상태 확인·spawn·등록·그룹 종료를 하나의 lifecycle lock으로 직렬화한다. OFF와 앱 종료는 신규 spawn을 차단하고 등록된 그룹을 즉시 종료해야 한다.

[major] Sources/AIBCCPoC/Activation/ActivationSchedule.swift:58-63 — v1의 `deny_unknown_fields` 계약을 지키지 않고 알 수 없는 설정을 삭제한 뒤 활성화한다.
재현/실패 시나리오: `config`에 `enabled:true, claude:true, codex:false, extra:1`이 있는 파일 → v1은 거부하지만 Swift decoder는 `extra`를 무시한다. Scheduler 초기화가 이를 덮어쓰고 다음 슬롯에서 요청을 보낸다.
수정 제안: Document와 Config의 허용 key 집합을 명시적으로 검증한다. v1이 거부하는 입력은 실행·재저장 없이 거부하는 호환성 fixture를 추가한다.

[minor] Sources/AIBCCPoC/Activation/ActivationScheduler.swift:47-49 — 잠금 획득 실패 후에는 소유 앱을 종료해도 예약을 인계받지 않는다.
재현/실패 시나리오: v1 실행 → v2 실행 → v1 종료. v2는 `fileURL=nil`로 고정되고 `start()`도 반환하므로 이후 슬롯을 계속 놓친다. 오류 문구의 “그 앱을 끄면 이 앱이 맡습니다”와 다르다.
수정 제안: 안전한 잠금 재획득을 구현하거나 v2 재시작이 필요하다고 표시한다. 재획득 시 현재 슬롯을 즉시 실행하지 않도록 재무장한다.

[major] Sources/AIBCCPoC/Documents/Structured/AgentYamlDocument.swift:151-156 — block scalar를 한 줄만 교체하여 유효한 YAML을 손상시킨다.
재현/실패 시나리오: `description: |\n  key: old\n`에서 description을 `new`로 편집 → `description: new\n  key: old\n`가 저장되어 YAML 구문 오류가 된다. `blocked()`도 이 편집을 허용한다.
수정 제안: multiline scalar의 전체 범위를 처리하거나 해당 필드는 원문 편집만 허용한다. 결과를 실제 YAML parser로 검증하는 회귀 테스트를 추가한다.

[major] Sources/AIBCCPoC/Documents/Structured/AgentYamlDocument.swift:285-288 — YAML quoting 조건이 불완전하여 구문과 값의 타입을 바꾼다.
재현/실패 시나리오: 기존 unquoted description을 `Summary:`로 변경 → `description: Summary:`라는 잘못된 YAML 저장. `name`에 `null`을 입력하면 문자열이 아니라 null 값이 된다. 공유하는 Skills 패치도 영향을 받는다.
수정 제안: 문자열 필드는 안전하게 quote하거나 YAML scalar resolution까지 검사한다. 끝의 colon과 `null`·boolean·숫자형 문자열을 테스트한다.

[major] Sources/AIBCCPoC/Documents/Structured/MarkdownPatch.swift:116-123 — 목록 전체에 첫 항목의 들여쓰기를 적용하여 중첩 규칙을 평탄화한다.
재현/실패 시나리오: `- parent\n  - child\n- other\n`에서 `other`만 수정 → `child`도 최상위 항목으로 저장된다. 계층 변경은 `managedBullets()` 결과에 드러나지 않아 섹션 병합에서도 보호되지 않는다.
수정 제안: 항목별 계층·continuation을 보존하거나 중첩/여러 줄 항목이 있는 섹션의 폼 저장을 거부한다.

[major] Sources/AIBCCPoC/Documents/Structured/GrowthDocument.swift:121-129 — escaped pipe와 추가 열을 잘못 파싱하여 표 내용을 버린다.
재현/실패 시나리오: `| E | L | A \| B |`가 있는 표에서 이벤트만 수정 → 예시는 `A \`로 파싱되고 `B`가 저장 시 사라진다. 네 번째 사용자 정의 열도 `count >= 3` 검사를 통과한 뒤 삭제된다.
수정 제안: escape-aware tokenizer를 사용하고 정확한 열 구조를 검증한다. 지원하지 않는 표는 원문 편집으로 제한한다.

[major] Sources/AIBCCPoC/Skills/SkillSheets.swift:139-149 — 원문에서 폼으로 전환하면 폼 밖의 수정 내용이 유실된다.
재현/실패 시나리오: 원문에서 `upstream` 변경 또는 새 frontmatter key 추가 → 폼 전환 → 저장. 알려진 필드와 본문만 전달하고 저장은 다시 `patch(original, …)`를 호출하므로 원문 수정이 조용히 취소된다.
수정 제안: 충돌 검사용 최초 원문과 편집 중인 최신 원문을 분리한다. 폼 패치는 최신 원문에 적용하고 모드 왕복 테스트를 추가한다.

[major] Sources/AIBCCPoC/Documents/DocumentView.swift:77-80 — ⌘K·배럭·목적지 이동이 편집 이탈 확인을 우회한다.
재현/실패 시나리오: RULES 폼에서 수정 → ⌘K로 SOUL 검색 결과 선택. `selection`을 직접 바꾸고 `load()`가 편집 상태를 초기화하여 저장하지 않은 변경이 사라진다. `guardedSelection`은 왼쪽 파일 목록에만 적용된다.
수정 제안: 모든 navigation을 공통 dirty-state guard로 통과시킨다. View가 제거되는 목적지 이동도 상위 Workspace에서 확인해야 한다.

[major] Sources/AIBCCPoC/Skills/SkillsView.swift:159-162 — 기본 skill 삭제·이름 변경을 후속 `aib sync`가 되돌린다.
재현/실패 시나리오: `skills/council` 삭제 또는 `debate`로 이름 변경 → 자동 sync. 현재 설치된 aib의 `sync_new_files()`가 누락된 template `skills/council/SKILL.md`를 다시 생성하여 삭제한 skill이 돌아오거나 두 skill이 남는다.
수정 제안: CRUD 후에는 catalog/link만 갱신하는 경로를 사용한다. 기본 skill 삭제·rename을 지원하려면 재생성을 막는 정책도 함께 구현한다.

[major] Sources/AIBCCPoC/Terminal/ScrollbackArchive.swift:43-44 — 출력과 metadata의 교체가 하나의 원자적 저장이 아니다.
재현/실패 시나리오: 기존 id의 `.txt` 교체 성공 → `.json` 쓰기 또는 rename 실패. 새 출력에 이전 날짜·크기가 붙으며, 이전 날짜가 보존 기간을 넘으면 다음 GC가 새 출력을 삭제한다. 최초 저장 중 중단되면 metadata 없는 출력은 목록과 GC에서 모두 누락된다.
수정 제안: 출력과 metadata를 단일 record로 저장하거나 immutable payload와 commit metadata를 사용한다. 두 번째 쓰기 실패와 중간 종료를 주입해 검증한다.

[major] Sources/AIBCCPoC/Git/GitModel.swift:112-116 — 상속된 Git 환경변수가 배럭 경계와 self-test 저장소 격리를 무효화한다.
재현/실패 시나리오: `GIT_DIR=/real/.git`, `GIT_WORK_TREE=/real`을 상속한 상태에서 unit self-test → GitSuite의 임시 경로 `init/add/commit`이 실제 사용자 저장소를 대상으로 실행된다. 읽기 전용 `rev-parse`로도 `-C /tmp`가 이 환경을 우회하지 못함을 확인했다.
수정 제안: Git 호출에서 repository/index/object/config 관련 환경변수를 정리하고 완성된 환경을 전달한다. GitSuite는 실제 작업 전 저장소 root가 fixture 내부인지도 확인한다.

[major] Sources/AIBCCPoC/Skills/SkillsView.swift:165-176 — 겹치는 자동 sync가 전역 barracks registry 갱신을 경합시킨다.
재현/실패 시나리오: 배럭 A의 skill 저장 후 sync 완료 전에 B의 skill 저장 → 두 `aib sync` 동시 실행. 현재 aib의 `register_barrack`은 동일한 `barracks.json.tmp/.tmp2`를 사용하고 잠금이 없어 서로의 중간 파일을 덮어 등록 항목을 누락·중복시킬 수 있다.
수정 제안: 앱의 sync/init/remove/refresh 쓰기를 직렬화한다. 외부 CLI·v1까지 포함하려면 registry read-modify-write 자체에 공통 파일 잠금을 적용해야 한다.

[major] Sources/AIBCCPoC/Maintenance/MaintenanceScanner.swift:123-126 — 종료 유예가 EOF 이후에만 시작되어 자식 호출은 여전히 무기한 멈출 수 있다.
재현/실패 시나리오: `/bin/sh -c 'sleep 600 & exit 0'` → 부모 종료 신호가 와도 후손이 출력 pipe를 잡고 있어 `readDataToEndOfFile()`이 600초간 반환하지 않는다. 취소·전체 timeout·출력 상한도 없어 Git/aib 작업이 계속 대기하거나 메모리를 소진한다.
수정 제안: 실행 시작부터 monotonic deadline과 출력 상한을 적용한다. timeout·취소 시 프로세스 그룹과 pipe를 정리하고 continuation을 한 번만 완료한다.

[major] Sources/AIBCCPoC/Sessions/CodexModelProbe.swift:95-99 — 탐침 종료 시 app-server의 후손 프로세스를 남긴다.
재현/실패 시나리오: fake CLI가 `sleep 300 &`로 worker를 만든 뒤 응답하거나 멈춤 → 성공·timeout 후 root PID만 종료되고 worker는 살아남는다. root가 먼저 종료했다면 `isRunning` 조건 때문에 정리 자체를 건너뛴다.
수정 제안: v1 `Server::drop`처럼 전용 process group 전체를 정리한다. 성공·실패·timeout·취소 각각에서 후손 생존 여부를 검증한다.

[minor] Sources/AIBCCPoC/Sessions/CodexModelProbe.swift:185-201 — 줄·총량 제한을 초과한 완성된 응답도 반환한다.
재현/실패 시나리오: buffer에 60 KiB가 있는 상태에서 8 KiB와 LF 수신 → 먼저 줄을 queue에 넣고 buffer를 비워 64 KiB 검사를 통과한다. 총 512 KiB 초과로 `closed=true`가 되어도 `next()`는 이미 queue에 들어간 응답을 반환한다.
수정 제안: enqueue 전에 각 줄 길이와 누적 크기를 검사한다. 초과 시 queue를 폐기하고 명시적인 protocol-limit 오류로 종료한다.

[minor] Sources/AIBCCPoC/App/WorkspaceModel.swift:526-527 — 마지막 배럭을 제거한 빈 registry를 무시한다.
재현/실패 시나리오: 등록된 마지막 배럭 제거 → 디스크는 `[]`지만 `!loaded.isEmpty` 때문에 화면과 liveness에는 남는다. 이후 Sync All을 실행하면 제거했던 배럭이 다시 등록될 수 있다.
수정 제안: 정상적으로 읽은 빈 목록과 읽기/파싱 실패를 구분하고, 정상 빈 목록은 selection과 liveness까지 반영한다.

[minor] Sources/AIBCCPoC/SelfTest/ActivationSuite.swift:172-173 — 안전 인자의 기대값을 구현 함수에서 가져와 회귀를 검출하지 못한다.
재현/실패 시나리오: `requestArguments(.claude)`에서 hook/settings 차단 인자를 제거 → 실행 인자와 기대 인자가 함께 바뀌고 fake CLI는 무조건 성공하므로 AC-01b가 통과한다.
수정 제안: v1 계약의 독립적인 literal argv fixture와 비교한다. 취소된 상태에서는 spawn 자체가 없다는 검사도 추가한다.

[minor] Sources/AIBCCPoC/SelfTest/ProviderSuite.swift:70-74 — “추가 요청 없음” 검사가 fake CLI의 무시되는 종료 코드에만 의존한다.
재현/실패 시나리오: 마지막 model/list 응답 뒤 구현이 추가 JSON-RPC 요청을 전송하도록 변경 → fake CLI는 `exit 5`하지만 탐침은 이미 받은 모델 목록을 반환하고 테스트도 목록만 검사하여 통과한다.
수정 제안: fake CLI가 수신한 전체 요청을 기록하고 허용된 handshake·pagination sequence와 비교한다. 마지막 응답 이후의 요청도 검사해야 한다.

[minor] Sources/AIBCCPoC/SelfTest/V1ImportSuite.swift:35-36 — 가져온 프로필의 load 검사가 self-test에서는 항상 비활성화된다.
재현/실패 시나리오: import의 apply가 가져온 프로필 대신 기본 프로필을 저장하도록 변경 → data는 존재하고 `!AppSettings.isSelfTest`는 false이므로 V1-01a가 통과한다. 일반 실행에서는 정상적인 non-default load를 오히려 실패로 판정한다.
수정 제안: 주입한 테스트 defaults에서는 self-test 기본값 우회를 적용하지 말고, load 결과를 `found.profiles[.codex]`와 비교한다.

요약:
- 기준: `2d912fd^..55c718c`, 21개 커밋. 미커밋 변경 제외.
- 우선 수정: 예약 취소·종료 경합, 문서 손상, Git·aib 전역 상태 변경.
- 읽기 전용 검토; self-test·aib·모델 요청 미실행. **blocker 1 / major 13 / minor 6**