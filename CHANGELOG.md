# Changelog

## [2.0.0-beta.1] - 2026-11-05

CommandCenter 2 첫 베타. Swift + libghostty로 다시 만든 macOS 네이티브 앱으로, v1(1.6.1)과 나란히 설치된다.

- v1 1.6.1 기능 전체: 배럭 관리·추가·제거, 세션 기록, ⌘K, Health/정비 큐, 터미널 관리·Quick Commands·출력 내보내기, RULES·SOUL·GROWTH·agent.yaml 폼 편집(충돌 시 섹션 병합), Wiki, Skills 생성·편집·이름 변경·삭제, Git(배럭 경로만 커밋·push), Files, Council, 새 에이전트, 터미널 출력 보관, Provider/Model 프로필, 예약 활성화(v1과 파일·잠금 공유), v1 설정 가져오기
- 터미널: Ghostty 엔진, 1/2/4 분할, 출력 폭주 중 입력 지연 p95 16.7 ms(v1.6.1 240 ms), 리사이즈 잘림 없음
- 세션 유지: PTY 데몬이 셸을 소유해 앱을 다시 켜도 세션이 살아 있고 이전 화면을 재생(재생 속 질의에는 다시 응답하지 않음)
- 검증: 전체 self-test 155 pass / 0 fail, 출시 빌드 unit·agents·integration 99 / 0, 데몬 smoke 19/19, Codex 리뷰 r4·r5 지적 37건 수정
- 남은 것: 사람 검사 15건(한국어 IME 등), Codex 리뷰 r6(수정분) 진행 중
