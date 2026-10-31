# AIBCC Swift PoC

aibcc(CommandCenter) 대개편의 **Go/No-go 판정용 PoC**. 제품 repo(`ai-barracks-cc`)와 분리된 로컬 repo다.

- 목표: 사용자 P0 "터미널 품질"(입력·리사이즈·선택 복사·가독성)과 P1 "산출물 .md 뷰어"를 Swift + libghostty로 달성할 수 있는지 판정.
- 합격 기준(사전 고정): [docs/acceptance-criteria.md](docs/acceptance-criteria.md)
- PTY 소유권 스파이크: [docs/spikes/pty-ownership.md](docs/spikes/pty-ownership.md)
- 근거: 배럭 Council `20261031_144814_73390`(디자인), `20261031_153914_85165`(PoC 계획)

## 구성

| 영역 | 구현 |
|---|---|
| 터미널 | libghostty-spm `2.2.2026103001`(Ghostty `1e9e14af5df1`) `.exec` 백엔드, 1/2/4 분할(HSplitView/VSplitView) |
| 레이아웃 | NavigationSplitView(배럭 목록) + 중앙 터미널 + 오른쪽 `.inspector`(산출물 뷰어) |
| 산출물 뷰어 | 배럭의 최근 수정 `.md`(wiki/sessions/skills/RULES 등 고정 뷰어 대상 제외), FSEvents 자동 새로고침, WKWebView + micromark GFM(원시 HTML 이스케이프, CSP) |
| 자체 테스트 | `--selftest`: 입력·리사이즈·선택·통합 스위트, PTY 수신 바이트 기록기 기반 판정, `report.json` |

## 빌드·실행 (Xcode 불필요, Command Line Tools만)

```bash
# 최초 1회 또는 렌더러 수정 시 (네트워크 불필요, 로컬 node_modules의 esbuild·micromark 사용)
AIBCC_NODE_MODULES=/path/to/ai-barracks-cc/node_modules ./scripts/build-renderer.sh

# 빌드 + .app 패키징 + ad-hoc 서명 (여유 공간 3GB 미만이면 중단)
./scripts/package-app.sh

# 항상 .app으로 실행한다 (TSM/IME·리소스 로딩을 실제 앱과 같게)
open dist/AIBCC-PoC.app

# (선택) 창 캡처 서비스 — 화면 캡처 권한이 있는 터미널에서 먼저 띄운다 (RS-01b 증거)
./scripts/capture-watcher.sh &

# 자체 테스트 — 실행 중에는 키보드·마우스를 건드리지 말 것
# (일반 키 테스트는 ABC 입력 소스, 합성 한글 테스트만 2벌식으로 잠시 전환 후 원래 입력 소스로 복원)
open -W dist/AIBCC-PoC.app --args --selftest
cat ~/Library/Application\ Support/AIBCCPoC/selftest/*/summary.txt
```

종료 코드: 0 = 모든 차단 기준 통과(사람 검사 결과 병합 시에만 가능) · 1 = 차단 기준 실패 · 2 = 준비 실패 · 3 = 실패 없음·미검증 남음(자동 실행의 최선) · 4 = 보고서 저장 실패. 상위 ID(IN-01 등)는 하위 결과가 **모두** pass일 때만 pass다. 알려진 제약: [docs/known-issues.md](docs/known-issues.md).

`swift build`는 GitHub에서 프리빌트 `GhosttyKit.xcframework`(약 76MB zip)를 받는다. 출처·체크섬은 `Package.swift`가 고정한 태그의 매니페스트에 있다.

## 사람 검사 5분 (자동화로 판정할 수 없는 항목)

한국어 2벌식으로 PoC 터미널에서 수행한다. 끝나면 메뉴 **레이아웃 → 입력 호출 로그 저장**(⌥⇧⌘L)으로 IME 호출 로그를 fixture로 남긴다.

1. `echo 안녕하세요 반갑습니다` 를 빠르게 입력 → 화면·실행 결과 모두 정확, 스페이스 두 칸 없음 (IN-01, IN-05)
2. `가나다` 입력 중 `다`를 조합하다가 Backspace → 조합만 지워짐 (IN-02)
3. 한/영 전환 직후 첫 글자 (영→한 `ㅎ`, 한→영 `a`) 유실 없음 (IN-03)
4. 2분할에서 왼쪽에 한글 조합 중 오른쪽 pane 클릭 → 오른쪽에 글자 안 들어감 (IN-04)
5. 다른 앱에서 복사한 한글 문장 붙여넣기 → 1회만 (IN-07)
6. 창을 크게·작게 여러 번 드래그, `claude` 실행 상태에서도 반복 → 마지막 줄·열이 잘리지 않음 (RS-01, RS-06)
7. 출력 일부를 드래그·더블클릭·트리플클릭으로 선택 후 ⌘C → 다른 앱에 붙여넣어 확인 (SC-01, SC-02)
8. 다크/라이트에서 한글·영문 가독성, 커서·선택 영역이 잘 보이는지 (RD-01, RD-02)
