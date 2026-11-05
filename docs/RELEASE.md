# v2.0.0 출시 체크리스트

출처: 배럭 `resources/design/aibcc-v2-parity-plan-2026-11-02.md` §I.

## 관문 (모두 충족해야 출시)

| # | 관문 | 상태 |
|---|---|---|
| G1 | v1 기능 패리티 A~H | 완료(계획표 참조) |
| G2 | 전체 self-test 0 fail (개발 빌드, 모든 스위트) | 2026-11-05 161 pass / 0 fail(r6 반영 후, 사용자 파일 무변경) + `run-persist-test.sh` PS-01·02·04·05 pass + `ptyd-smoke.py` 19/19. 출시 직전 재실행 |
| G3 | 출시 빌드 self-test (`VARIANT=release`) unit·agents | 2026-11-05 unit·agents·integration 105 pass / 0 fail(beta.2, 사용자 파일 무변경) |
| G4 | 사람 검사 15건 (README "사람 검사 5분", 한국어 IME 등) | **미실시 — 사용자** |
| G5 | Codex 리뷰 r4(87a558c..55c718c) + r5 + MD-05, 수정분 리뷰 r6 | **충족(2026-11-05)** — r4 17건·r5 20건·r6 17건 모두 수용·수정(`docs/reviews/codex-r{4,5,6}-triage.md`), MD-05 pass(`docs/evidence/2026-11-05-md05-review.json`). r6 수정분(a80f69c 이후) 재리뷰는 GA 전에 |
| G6 | 실사용 smoke: 출시 앱으로 배럭 1곳에서 세션·문서 편집·Skills·Git 한 바퀴 | 미실시 |

## 베타 배포

- 2026-11-05 `v2.0.0-beta.1` pre-release(`v2` 브랜치, DMG·.app.tar.gz·SHA256SUMS, arm64). v1 `main`·latest(v1.6.1)는 그대로다. **예약 활성화 교착(r6 blocker) 포함 → beta.2로 교체**
- 2026-11-05 `v2.0.0-beta.2` pre-release: r6 17건 반영

## 결정 필요 (사용자)

1. 앱 이름: 기본값 "AI Barracks CommandCenter 2"(`scripts/package-app.sh` VARIANT=release 한 곳에서 바꿈)
2. 소스 저장소: 이 PoC 저장소를 `ai-barracks` org에 새 repo로 올릴지, `ai-barracks-cc`의 v2 브랜치/디렉터리로 합칠지
3. 배포: v1처럼 GitHub Actions DMG 빌드 + Release, Homebrew cask 추가 여부, 서명·공증(Developer ID) 여부
4. 아이콘: `scripts/make-icon.swift` 기본안(프롬프트 + liveness 비콘 3개)

## 출시 절차 (결정 후)

```bash
VARIANT=release ./scripts/package-app.sh
open -W "dist/release/AI Barracks CommandCenter 2.app" --args --selftest --selftest-only=unit,agents   # G3
./scripts/make-dmg.sh
git tag v2.0.0
# 원격 push, GitHub Release(gh release create — 태그만 push하지 말 것), cask 갱신은 결정 2·3에 따라
```
