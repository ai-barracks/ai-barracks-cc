당신은 시니어 macOS/Swift·POSIX 리뷰어다. 로컬 저장소 /Users/choihouse/Develop/aibcc-swift-poc 의 커밋 2d912fd^..HEAD (v1 CommandCenter 1.6.1 기능 패리티: 세션 기록·⌘K·Health·터미널 관리·구조화 편집기·Skills CRUD·Git·Files·배럭 관리·개요·터미널 출력 보관·Provider 프로필·예약 활성화·v1 설정 가져오기·출시 변형)를 코드 리뷰하라. 읽기 전용이다. `git -C /Users/choihouse/Develop/aibcc-swift-poc log 2d912fd^..HEAD`와 diff, 파일을 직접 읽어라. v1 원본은 /Users/choihouse/Develop/ai-barracks-cc (src-tauri/src/*.rs, src/components/*)에 있고 대조해도 된다. 대조표: 배럭 /Users/choihouse/Develop/ai-barracks-yr/ai_barracks_management/resources/design/aibcc-v2-parity-plan-2026-11-02.md.

중점(우선순위 순):
1. 사용자 비용·외부 효과: Activation/*(예약 활성화) — 구독 계정으로 실제 모델 요청을 보낸다. 같은 슬롯 이중 실행, 재시도·밀린 실행, 켠 직후 즉시 실행, 끈 뒤 실행, API 키·다른 인증으로 요청, 크래시 후 재실행, v1과 공유하는 activation.json/flock 계약(v1 스키마 deny_unknown_fields 호환) 위반 경로. 자식 프로세스 그룹 종료(posix_spawn, 타임아웃·취소·앱 종료), 출력 상한.
2. 사용자 데이터 손상·유실: Documents/Structured/*(RULES·SOUL·GROWTH·agent.yaml 줄 단위 패치, 충돌 시 섹션 병합), Skills/*(SKILL.md 패치·이름 변경·휴지통 삭제·경로 안전), DocumentView 저장·충돌·편집 중 이동, Git/*(배럭 경로만 커밋 — 다른 staged 파일이 섞이는 경로), Terminal/ScrollbackArchive(권한·원자적 쓰기·GC가 남겨야 할 것을 지우는 경로), App/V1SettingsImport.
3. 전역 부작용: aib 호출(Maintenance/AibSync, Barracks/BarrackAdmin — aib sync/init이 ~/.aib/barracks.json·~/.claude/settings.json을 쓴다), 자체 테스트가 사용자 파일(레지스트리·CLI 설정·v1 activation.json·사용자 보관소·휴지통)을 건드릴 수 있는 경로.
4. 동시성·프로세스: ProcessOutput(waitUntilExit 제거, terminationHandler+유예), CodexModelProbe(JSON-RPC, 경계), @unchecked Sendable 클래스의 실제 안전성, MainActor 경계.
5. 테스트의 false-pass: SelfTest/*Suite.swift(DocumentSuite, SkillSuite, GitSuite, ActivationSuite, ProviderSuite, ScrollbackSuite, BarrackAdminSuite, V1ImportSuite)가 결함이 있어도 통과하는 지점.

출력 형식(한국어): 각 발견마다 `[blocker|major|minor] 파일:줄 — 결함 한 줄`, 다음 줄에 `재현/실패 시나리오:` 구체적 입력·상태 → 잘못된 결과, 그 다음 `수정 제안:` 한두 줄. 추측이면 "추정"이라고 표시. 마지막에 `요약:` 3줄과 blocker/major/minor 개수. 칭찬·일반론은 쓰지 말 것.
