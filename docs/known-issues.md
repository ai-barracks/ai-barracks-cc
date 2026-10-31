# Known issues (PoC)

Codex code review r1 (2026-10-31) 반영 후에도 남는 제약. 제품 전환 시 해결 대상.

1. **[product blocker] SwiftPM resource bundle lookup** — SwiftPM 6.3.2의 `Bundle.module`은 `.app` 루트와 빌드 당시 절대 경로만 찾는다. `Contents/Resources`에 복사한 `GhosttyKit_GhosttyTerminal.bundle`은 찾지 않으므로, 이 PoC는 **이 Mac의 `.build` 경로 fallback으로만 동작**한다. 제품에서는 libghostty-spm을 fork해 `Bundle.main.resourceURL` 우선 resolver를 넣거나 upstream에 제안한다. 앱 루트에 bundle을 두는 방식은 strict codesign 구조 검증과 충돌한다.
2. **split 경계 드래그 미지원** — layout 전환 시 터미널(PTY)을 보존하기 위해 SwiftUI `HSplitView` 대신 고정 비율 `PaneGridLayout`을 쓴다. 드래그 가능한 divider는 제품 단계에서 같은 Layout 위에 구현한다(RS-03-drag는 unverified).
3. **숨겨진 pane의 PTY 크기** — 4→1 전환 시 주차된 pane은 그리기를 멈추지만 전체 영역 크기를 제안받아 SIGWINCH가 한 번 발생한다.
4. **앱 종료 후 세션 생존 없음** — `.exec` 백엔드는 Ghostty가 PTY를 소유한다. scrollback 영속화·세션 생존은 `.inMemory` + 앱/데몬 소유 PTY로 별도 검증 필요(docs/spikes/pty-ownership.md).
5. **IME 조합 중 pane 전환의 A쪽 확정 정책** — 스크립트 재생으로는 실제 IMK의 commit/cancel을 재현할 수 없어 사람 검사(IN-04-phys)로만 판정한다.
6. **`--selftest` exit 0은 사람 검사 결과가 합쳐져야만 가능** — 자동 실행만으로는 최선이 exit 3(incomplete)이다.
