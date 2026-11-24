# Codex r5 처리 (2026-11-04~05)

리뷰: `docs/reviews/codex-r5.md` (범위 `2d912fd^..55c718c`, blocker 1 · major 13 · minor 6). 각 항목을 코드·재현으로 확인한 뒤 판정했다. 20건 모두 수용.

| # | 등급 | 지적 | 판정·근거 | 수정 | 회귀 테스트 |
|---|---|---|---|---|---|
| 1 | blocker | 취소 확인·spawn·등록 분리, 종료 시 stop 누락 | 수용 — `run()`이 spawn 후에야 취소를 봄 | 7458dba: BoundedProcess가 취소 확인·spawn·등록을 한 잠금에서, 거부는 `.notStarted`, 종료 시 `shutdown()`, OFF·stop은 즉시 그룹 kill | AC-01b (사전 확인을 뺀 변이체가 실패함을 확인) |
| 2 | major | v1 `deny_unknown_fields` 미준수 | 수용 — v1 Document·Config는 거부 | 7458dba: v1 키 집합 밖이면 실행·재저장 없이 거부 | AC-01a |
| 3 | minor | 잠금 소유 앱 종료 후 인계 없음 | 수용 — 문구와 동작 불일치 | 7458dba: 대기 중 재획득, 인계한 슬롯은 실행 안 함 | AC-01a |
| 4 | major | agent.yaml block scalar 한 줄 교체로 YAML 손상 | 수용(재현) | f272020: 여러 줄 값은 폼 저장 거부·사전 표시 | CR-05a |
| 5 | major | YAML 따옴표 조건 불완전(`Summary:`, `null`) | 수용(재현) | f272020: 끝 콜론·null/bool/숫자/날짜·탭 따옴표 | CR-05a |
| 6 | major | 중첩 목록 평탄화 | 수용 — v1도 같은 결함 | f272020: 들여쓰기가 섞인 목록은 폼 저장 거부 | CR-05a |
| 7 | major | GROWTH 표 `\|`·추가 열 유실 | 수용(재현) | f272020: escape 인지 분리, 정확히 3열, GFM `\|\|`는 빈 칸 | CR-05a, GR-01a/b |
| 8 | major | Skill 원문→폼 전환 시 원문 수정 유실 | 수용 | f272020: 폼은 마지막으로 읽은 원문에 적용(SkillEditBuffer) | SK-02a |
| 9 | major | ⌘K·배럭·목적지 이동이 편집 확인 우회 | 수용 | 6fdf882: 작업면 수준 이동 확인(사이드바·배럭·⌘K·알림) | NV-01a |
| 10 | major | 기본 skill 삭제·이름 변경을 sync가 되돌림 | 수용 — `sync_new_files`가 템플릿 재생성 확인 | 00db720: aib 템플릿 skill은 삭제·이름 변경 차단(편집 가능) | R5-01a |
| 11 | major | 보관 출력·메타 비원자적 | 수용 | f272020: 불변 payload + 기록이 커밋, 고아 payload GC | SB-01a |
| 12 | major | 상속 GIT_DIR 등이 `-C` 우회 | 수용 | 00db720: 재지정 변수 제거, GitSuite는 fixture 저장소 확인 후에만 커밋 | R5-01a, GT-01b |
| 13 | major | 동시 aib sync가 레지스트리 경합 | 수용 — register_barrack 무잠금 | 00db720: 앱의 aib 쓰기 직렬화(AibWriteQueue) | R5-01a |
| 14 | major | 종료 유예가 EOF 이후에만 시작 | 수용(재현 시나리오 그대로) | c25732c: ProcessOutput을 BoundedProcess로(시작부터 기한·출력 상한·그룹 kill) | PO-01c |
| 15 | major | 탐침 후손 프로세스 잔존 | 수용 | c25732c: 전용 그룹으로 실행·종료 | PR-01b |
| 16 | minor | 탐침 한도 초과 응답 반환 | 수용 | c25732c: enqueue 전 검사, 한도 초과는 프로토콜 오류 | PR-01b |
| 17 | minor | 마지막 배럭 제거 후 빈 레지스트리 무시 | 수용 | 00db720: 정상 `[]`은 반영, 없음·0바이트·손상은 무시 | R5-01a |
| 18 | minor | AC-01b 기대값을 구현에서 가져옴 | 수용 | 7458dba: v1 argv 리터럴 fixture | AC-01b |
| 19 | minor | ProviderSuite 추가 요청 검사 무력 | 수용 | c25732c: 가짜 CLI가 모든 요청을 기록, 순서 정확히 비교 | PR-01b |
| 20 | minor | V1ImportSuite 프로필 검사가 self-test에서 비활성 | 수용 | 00db720: 테스트가 넘긴 저장소에는 self-test 기본값 우회 미적용 | V1-01a |
