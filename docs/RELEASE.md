# v2.0.0 출시 체크리스트

출처: 배럭 `resources/design/aibcc-v2-parity-plan-2026-11-02.md` §I.

## 관문 (모두 충족해야 출시)

| # | 관문 | 상태 |
|---|---|---|
| G1 | v1 기능 패리티 A~H | 완료(계획표 참조) |
| G2 | 전체 self-test 0 fail (개발 빌드, 모든 스위트) | 2026-11-08 177 pass / 0 fail(build 90 = 3d0909e, IN-09 원인 확정·수정 — known-issues #10). 출시 직전 후보 commit으로 재실행 |
| G3 | 출시 빌드 self-test (`VARIANT=release`) unit·agents | 2026-11-07 unit·agents·integration 113 pass / 0 fail(build 84, 사용자 파일 무변경) |
| G4 | 사람 검사 15건 (README "사람 검사 5분", 한국어 IME 등) | **미실시 — 사용자** |
| G5 | Codex 리뷰 r4(87a558c..55c718c) + r5 + MD-05, 수정분 리뷰 r6·r7 | **충족(2026-11-05)** — r4 17건·r5 20건·r6 17건·r7 13건 처리(`docs/reviews/codex-r{4,5,6,7}-triage.md`), MD-05 pass. r7 수정분(004ca8b) 재리뷰는 GA 전에 |
| G6 | 실사용 smoke: 출시 앱으로 배럭 1곳에서 세션·문서 편집·Skills·Git 한 바퀴 | 미실시 |

## 베타 배포

- 2026-11-05 `v2.0.0-beta.1` pre-release(`v2` 브랜치, DMG·.app.tar.gz·SHA256SUMS, arm64). v1 `main`·latest(v1.6.1)는 그대로다. **예약 활성화 교착(r6 blocker) 포함 → beta.2로 교체**
- 2026-11-05 `v2.0.0-beta.2` pre-release: r6 17건·r7 13건 반영

## 미완 범위 (설계 대비, beta에 표기)

v1 패리티(G1) 완료와 aib 전체 의도 충족은 다르다(Codex build-84 F3, `docs/reviews/codex-build84-triage.md`).

1. Council 의사록 전용 화면: 라운드 접기, 최종 결론 중심, 합의도, 검증 3상태(미검증/통과/실패). 현재는 목록 + Markdown 뷰어
2. `archive prune`·`hooks codex install` 전용 경로(의미·보존·위험 설명). 현재는 터미널/Quick Command로만

## 게시 기록 (beta 포함, 게시할 때마다)

태그는 자산을 빌드한 commit에 붙이고, 아래를 Release 본문과 이 문서에 함께 남긴다(Codex build-84: 설치본을 commit에 묶을 근거가 없었음).

- 태그 → commit SHA (`git rev-parse <tag>^{commit}`)
- 앱: `CFBundleVersion`(build), `AIBSourceCommit`·`AIBSourceDirty=false`(Info.plist), build-info의 `executable_sha256`
- 자산: `SHA256SUMS`(DMG·.app.tar.gz)
- 그 commit의 검증: G2 전체 dev, G3 출시 빌드, `ux-stress.sh` 8/8, 데몬 smoke

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
