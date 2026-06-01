# Changelog

## [1.4.0] - unreleased

### Added — Agent liveness dot (Plan 2: aib-cc UI; pairs with aib ≥ 1.3.0 Plan 1)
- **세션 카드별 실시간 생사 점 + 툴팁.** `aib`가 쓰는 `sessions/.live/<id>.status` sidecar를 읽어 `kill(pid,0)` 생존 확인 + 경과시간으로 effective 상태(`working`/`working_stale`/`blocked`/`crashed`/`interrupted`/`done`/`idle`/`none`)로 fold — `aib sessions state` 레퍼런스 매트릭스를 Rust 단위 테스트로 동일성 고정. `none`은 점 없음.
- **PTY 분리**: CC 내장 터미널 밖에서 띄운 `claude`도 추적. `.live/` watch(250ms 디바운스 `live-changed`) + 30초 `live-tick`로 시간 전이(`working_stale`) 반영.
- **done → idle ack**: `done` 카드를 펼치면 `ack_live_state`가 `.ack`를 atomic(temp+rename)하게 기록 → idle. Continue로 새 `run_id`가 시작되면 ack 불일치로 자동 재활성.
- non-Claude/hook-less 세션은 점 없음 — 부재 ≠ idle (범례로 명시).
- `libc` 런타임 의존성 추가(`kill(pid,0)`), `tempfile`을 dev-dep → 런타임 dep로 이동(`.ack` atomic write).

### Verification
- `cargo test` — 65 passed (live:: 10 신규: EPERM/unknown pid, fold 매트릭스 boundary·ack-mismatch·done+dead, read_live_states ack-join, malformed missing-`ts` 제외, ack atomic + path-escape reject).
- `npx tsc --noEmit` + `npm run build` — clean.

## [1.3.0] - 2026-06-01

### Added — Terminal scrollback disk persistence + archive tab
- **앱 재시작 후 이전 터미널 출력 복원.** raw PTY 바이트를 `app_data/scrollback/{id}.bin`(+ `meta.json`)에 atomic(unique temp + per-session write mutex + rename)하게 영속화. per-session 1MB cap(UTF-8/newline aligned tail-truncate), global 100MB + 14일 retention, rate-limited GC.
- **Archive 탭**: 죽은 세션을 read-only로 복원 — "프로세스 종료됨" 배너 + `load_scrollback` replay + 버튼(같은 cwd 새 세션 / 기록 삭제 / 닫기). 자동 PTY 부착 없음. 탭에 `mode: 'live' | 'archive'` 판별자.
- load는 best-effort(손상 파일도 panic 없음), `was_truncated`-gated ANSI straddle 보정(정상 파일 첫 줄 보존), `validate_pty_id` path-traversal 방어.

### Verification
- `cargo test` — 55 passed (8-thread concurrent-save consistency, UTF-8 boundary, path-traversal reject 포함).
- `npm run build` — clean, 0 type errors.
- Codex 코드리뷰 7항목 반영 (traversal/first-line/tmp-race/straddle/GC/stale-meta/orphan).

## [1.2.3] - 2026-05-31

### Fixed — Terminal clipboard paste deduplication
- **Clipboard paste in the built-in terminal no longer inputs text twice.** The v1.2.2 IME helper-textarea bypass now ignores `InputEvent.inputType === "insertFromPaste"`, leaving paste delivery to xterm.js' native `ClipboardEvent` handler and only clearing the helper textarea residue.
- **Korean/CJK IME workaround preserved.** The guard is scoped to clipboard paste, so composition input (`insertCompositionText` / `insertText`) continues through the existing IME path.

### Verification
- `git diff --check` — clean.
- `npx tsc --noEmit --pretty false` — clean.
- `npm run build` — clean (Vite chunk-size warning only).
- `cargo test --manifest-path src-tauri/Cargo.toml` — 28 passed.

## [1.2.2] - 2026-05-10

### Fixed (partial) — macOS WKWebView Korean/CJK IME
- **Composition events now fire on the helper-textarea.** xterm.js registers its capture-phase keyboard/input listeners inside `term.open()`, so any post-open hook ran *after* xterm's listener and `stopImmediatePropagation` was effectively a no-op. We now monkey-patch `HTMLTextAreaElement.prototype.addEventListener` *before* `term.open()`, install our IME listeners on the helper-textarea synchronously when xterm makes its first registration, and restore the prototype immediately after. xterm's later same-phase listeners run after ours, so our `stopImmediatePropagation` is real.
- **Hangul Jamo (U+1100-U+11FF, U+3131-U+318E) is dropped at the input-event boundary.** macOS IME emits these as pre-composition state when composition cycles fragment; they are never user-intended terminal input. Composed Hangul syllables (U+AC00-U+D7AF) flow through compositionend.
- **xterm onData and our IME bypass listener share a 50ms data+timestamp dedup window**, eliminating most space-doubling cases.
- **CompositionHelper.keydown(229) is suppressed** so xterm's 0ms `_handleAnyTextareaChanges` fallback cannot re-send pre-composition jamo.

### Known limitation — first syllable of a Korean burst
- **macOS IME's first keystroke is "preview" mode** — `compositionstart` does not fire for it. The first jamo arrives as a regular input event ~400ms before composition engages. We drop it (per above) which preserves the rest of the syllable correctly *only when subsequent keys arrive within the same composition cycle*. In practice, **the first syllable of a Korean text burst typically arrives as 2-3 standalone jamo instead of a composed syllable**; subsequent syllables compose normally.
- Workaround for users: type one extra placeholder character before Korean text, or use an external terminal (iTerm) for Korean-heavy work.
- Full root-cause analysis and future-attempt guide in `ai_barracks_management/wiki/topics/AIB-CC-Terminal-Korean-IME-Troubleshooting.md` (5-hour spike, codex gpt-5.5 high review). Option B (custom textarea + ANSI key mapping) is the architectural fix; deferred to a future fresh session.

### Verification
- `npx tsc -b --noEmit` — clean.
- Manual: `echo "안녕하세요"` → first syllable jamo, rest composed correctly.
- Manual: `echo hello world` — single space (dedup working for non-IME path).
- Manual: arrow history, Tab completion, Ctrl-C, Ctrl-L — unaffected (xterm's keydown for non-229 keys passes through).

## [1.2.1] - 2026-05-09

### Fixed — Terminal Korean IME / UTF-8 PTY locale
- **Korean/CJK IME composition no longer gets intercepted before xterm.js CompositionHelper.** Removed the custom `attachCustomKeyEventHandler` path that returned `false` for `event.isComposing` / `keyCode === 229`, which could drop or split Hangul input before xterm flushed the hidden textarea into `onData`.
- **PTY child locale is forced to UTF-8 when inherited GUI app env is missing/non-UTF-8.** `LC_ALL` is respected when already UTF-8; otherwise `LC_CTYPE`/`LANG` are defaulted to `en_US.UTF-8` so shells/readline/TUIs treat Hangul as multibyte input.
- **Regression coverage:** Rust tests cover UTF-8 locale detection and partial Hangul byte-boundary buffering.

### Verification
- `cargo test` — 28 passed.
- `npm run build` — passed (Vite chunk-size warning only).

## [1.2.0] - 2026-05-09

### Added — Skills CRUD GUI (paired with aib v1.2.0 Skills loading)
- **Create / Edit / Delete / Rename SKILL.md from the GUI.** Skills tab gains `[+ New Skill]`, `[Edit]`, `[Delete]` actions.
- **Form / Raw hybrid editor**: Form mode (frontmatter fields + body textarea) is the source of truth; Raw mode is a read-only preview by default, with explicit `[Override with raw]` for direct YAML editing.
- **Save & Sync orchestration**: every Create/Update/Delete/Rename runs `aib sync` automatically. If sync fails, the disk write is preserved and a banner appears with `[Retry sync]` (spec §3.5 — sync failure never rolls back user assets).
- **Slug rename**: `[Rename slug]` button in Edit dialog. Backend moves the directory and updates the frontmatter `name:` field atomically.
- **aib version banner**: warns when installed aib < v1.2.0 (Skills loading wirings depend on it).

### Why this is aib-cc's first deliberate write-side feature for catalog data
Until v1.1, the catalog views (Wiki, Skills) were intentionally read-only because agents auto-update those via hooks/protocol. Skills are different — `templates/docs/skills-protocol.md` "보호 원칙" forbids agent self-registration of skills, so the user is the only path. GUI write here serves a workflow that text editors handle clumsily; the read-only policy still applies to wiki/sessions/RULES.

### Backend
- 4 new Tauri commands in `src-tauri/src/commands/skills.rs`: `create_skill`, `update_skill`, `delete_skill`, `rename_skill`. All return `Result<(), String>` and are idempotent within their own scope.
- `SkillFrontmatterWrite` struct with serde guards against the Tauri rename bidirectional trap (RULES.md [2026-05-09]).
- 8+ Rust unit tests covering write/collision/missing/rename/serialize-key invariants.

### Frontend
- New: `SkillEditorDialog`, `SkillFormFields`, `SkillDeleteDialog`, `useSkillCrud` hook.
- Modified: `SkillsTab.tsx` — wired action buttons, version banner, dialog renderers.

### Out of scope (deferred)
- Frontend unit test framework (vitest) — manual smoke test this release.
- In-app drift banner (`aib skills check` integration) — every successful save runs sync, so drift in normal flow is zero. Use `aib skills doctor` from terminal for ad-hoc check.
- Bulk import/export, template gallery, in-app skill invocation.

### Compatibility
- Requires aib v1.2.0+ at runtime (banner warns otherwise).
- v1.1.x SKILL.md files are loaded as-is into the editor; custom frontmatter fields are preserved in the `custom` map.

## [1.1.4] - 2026-05-09

### Added — Release pipeline 검증 step
- **`.github/workflows/release.yml`**: `checkout` 직후, build 전에 tag↔version 일치 검증 step 추가. 다음을 fail-fast로 검증:
  - 태그가 `vX.Y.Z[-pre]` semver 형식인지
  - `src-tauri/tauri.conf.json` / `package.json` / `src-tauri/Cargo.toml`의 `version` 필드가 모두 태그(앞의 `v` 제거)와 일치하는지
- **Why**: v1.1.0 릴리즈에서 3개 version 파일이 `1.0.2`인 채로 `v1.1.0` 태그만 푸시되어 DMG 파일명이 `_1.0.2_`로 잘못 묶이는 사고가 있었다. 워크플로우 차원에서 동일 사고를 차단.

### Docs
- README에 Skills 카탈로그 탭 섹션 추가, CHANGELOG `[1.1.1]/[1.1.2]/[1.1.3]`에 publish date stamp.

### Notes
- 코드 변경 없음 — release pipeline + 문서만 정비.

## [1.1.3] - 2026-05-09

### Fixed — argument-hint frontend mapping
- **`SkillCard.argument_hint`** serde attribute가 양방향(`rename = "..."`)이라 Tauri → frontend JSON 키가 `argument-hint` (hyphen)로 나갔고, TS interface는 `argument_hint` (underscore)를 기대 → frontend에서 모든 카드의 args 메타 칩이 표시되지 않음.
- Fix: `#[serde(rename(deserialize = "argument-hint"))]`로 변경 — YAML 입력 호환은 유지, JSON 출력은 underscore.
- 회귀 테스트 추가: `serializes_argument_hint_with_underscore_for_tauri`.

### Notes
- v1.1.2는 본 회귀를 가진 채 publish됨. 사용자는 v1.1.3 설치 권장.
- 다른 frontmatter 필드(aib_version, upstream, parse_error)는 영향 없음 — rename 어트리뷰트가 없거나 underscore 키 그대로 사용.

## [1.1.2] - 2026-05-09

### Added — Skills 카탈로그 탭
- **`SkillsTab`** (신규): 좌측 검색 박스 + SKILL.md 카드 리스트 / 우측 메타 박스 + 마크다운 본문. Wiki 탭 패턴 미러.
- **Tauri commands**: `get_skills_index` (skills/<slug>/SKILL.md walk + `serde_yaml` frontmatter 파싱), `get_skill_content` (frontmatter 제거 후 본문 반환).
- **frontmatter 손상 노출**: silent skip 금지 — 파싱 실패 시 카드에 ⚠️ 배지 + 메타 박스에 빨간 `parse_error` 표시. spec D3.

### Notes
- aib v1.1.0 release notes에서 v1.1.1로 약속됐던 "Skills 카탈로그 전용 탭" 항목 — v1.1.1은 메타데이터 sync 패치로 분리되어 본 항목은 v1.1.2로 이연됨.
- v1.1.3+ 후보로 이연: `aib skills doctor` 실행 버튼, external skills 표시, 카드 정렬 토글, 편집 모드.

## [1.1.1] - 2026-05-08

### Fixed — Version metadata sync
- **`src-tauri/tauri.conf.json`**: `version`을 1.0.2 → 1.1.1로 정정. v1.1.0 릴리즈 시 `tauri.conf.json` bump 누락으로 Info.plist `CFBundleShortVersionString` + DMG 파일명이 `1.0.2`로 표기되던 known cosmetic issue 해소.
- **버전 정렬**: `package.json` + `Cargo.toml` 1.1.0 → 1.1.1. tauri.conf.json과 함께 한 번에 정정.

### Notes
- 코드 변경 없음 — v1.1.0 코드 그대로. 메타데이터/번들 파일명만 정정.
- Info.plist의 `CFBundleShortVersionString`이 v1.1.1부터 실제 코드 버전과 일치 → 향후 설치 검증 시 메타데이터 신뢰 가능.

## [1.1.0] - 2026-05-08

### Changed — Skills Schema Compatibility (paired with aib 1.1.0)
- **`YamlFormEditor`**: `agent.yaml`의 `skills:` 블록을 더 이상 하드코딩된 리스트 형식으로 덮어쓰지 않음. 파싱 시 raw block을 보존하고, 저장 시 그대로 재출력. 1.0.x 리스트 형식·1.1.0 객체 형식(`discovery: auto, enabled: [...]`) 모두 안전하게 편집 가능.
  - **회귀 수정**: 기존 1.0.x 에디터는 알려지지 않은 필드(예: 사용자가 추가한 `skills.delegation`)를 저장 시 silent 손실시켰음. v1.1부터 skills 블록은 read-then-write로 보존.
- **버전 정렬**: `package.json` + `Cargo.toml` 1.0.2 → 1.1.0. aib 1.1.0과 페어링.

### Known Issue (cosmetic, fixed in v1.1.1)
- DMG 파일명 + Info.plist `CFBundleShortVersionString`이 `1.0.2`로 표시됨 (`tauri.conf.json` bump 누락). 코드는 v1.1.0 그대로. v1.1.1에서 정정.

### Notes
- aib ≥ 1.1.0 와 함께 사용 권장 (Skills 표준 디렉터리, `aib skills list/doctor` 명령).
- Skills 카탈로그 전용 탭은 v1.1.1로 이연 — 본 릴리즈는 편집기 호환성 확보가 목적.

## [1.0.1] - 2026-05-04

### Added
- **LAUNCH 실패 surfacing**: PTY가 5초 이내 exit하면 `useTerminal` Exit 핸들러가 inline 경고 배너를 출력 (Claude settings 깨짐 / Codex `--full-auto` 회귀 / CLI 미설치 등 흔한 원인 안내). 기존엔 `[Process exited]`만 짧게 떠서 진단이 어려웠음.
- **README Prerequisites 보강**: Claude/Gemini/Codex CLI 설치, `.claude/settings.local.json` 무결성 점검 스니펫, Codex 0.128 플래그 변경, 첫 Claude workspace trust 안내.

### Notes
- aib ≥ 1.0.1 와 함께 사용 권장 (Codex 플래그 회귀 수정 + Claude settings 사전검사).

## [1.0.0] - 2026-04-17

AI Barracks CommandCenter v1.0.0 공식 릴리즈.

### Features (v0.1.0 ~ v1.0.0 통합)

#### Overview
- 배럭별 상세 정보, 통계, Expertise 태그
- 버전 상태 표시 + 원클릭 Sync
- New Agent / Open Terminal / Council 실행

#### Config
- SOUL.md / GROWTH.md 마크다운 에디터 + 실시간 프리뷰
- RULES.md 구조화된 관리 UI
- agent.yaml 폼 에디터
- 파일 소유권 표시

#### Agents
- 세션 타임라인 + 필터 (Status, Client)
- Active 세션 Monitor (3초 자동 갱신)
- View (세션 + Violation 파일)
- Continue (완료된 작업 이어받기)

#### Wiki
- 토픽 카탈로그 + 마크다운 렌더링
- Recent Changes + Wiki Lint 실행

#### Git
- Branch, changes, remote URL 상태 표시
- Commit / Push
- 커밋 히스토리 + git show 상세 보기
- Terminal Actions (status, add -p, log --graph, stash)
- Mono-repo sub-path 자동 감지

#### System View
- 전체 배럭 버전 대시보드
- 선택적/일괄 Sync + Dry-run
- 새 배럭 생성

#### 내장 터미널
- xterm.js + portable-pty 기반 완전한 터미널 에뮬레이터
- 좌우 분할 레이아웃, 다중 터미널 탭
- Export (ANSI 제거), Quick Commands
- 폰트/크기/줄높이/커서 스타일 설정

#### 커맨드 팔레트 (Cmd+K)
- 배럭 컨텍스트 기반 명령어 추천
- Agent / AIB / Git / Quick 카테고리

#### 기타
- 전체 검색 (세션, 위키, 규칙, 설정 통합)
- Light/Dark 테마 (Apple HIG)
- 파일 실시간 감시
- 시스템 트레이 + 인앱 알림
