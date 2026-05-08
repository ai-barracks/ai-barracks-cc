# Skills 카탈로그 탭 — 설계 문서

- **타겟 릴리즈**: aib-cc v1.1.2
- **페어**: aib v1.1.0 (Skills first-class), v1.1.0 release notes에서 약속된 "Coming in v1.1.1" 항목의 분리·이연
- **작성일**: 2026-05-08
- **상태**: 설계 승인됨 → 구현 계획 작성 대기

## 1. 컨텍스트

aib v1.1.0이 Skills를 first-class로 도입(Anthropic Agent Skills 표준 + ai-barracks 확장)하면서 모든 배럭에 `skills/<slug>/SKILL.md` 시드(council)가 배포됐다. 그러나 aib-cc v1.1.0은 **YamlFormEditor 호환성 확보**가 우선이라 카탈로그 UI는 이연됐다. v1.1.0 release notes는 "Coming in v1.1.1: Skills 카탈로그 전용 탭"을 약속했지만, v1.1.1은 메타데이터 sync 패치(tauri.conf.json 등)로 분리됐고, **Skills 탭은 v1.1.2로 이연**됐다.

본 spec은 그 v1.1.2 작업의 설계 문서다.

## 2. 목표

배럭의 `skills/<slug>/SKILL.md` 파일들을 카탈로그로 노출해 **Skills의 가시성을 확보**한다. Wiki 탭과 동일한 패턴으로 구현해 학습 비용 0에 가깝게 한다.

### 2.1 v1.1.2 범위 (포함)

- `skills/<slug>/SKILL.md` 디렉터리 walk + frontmatter 파싱
- 좌측 카드 리스트 (검색 박스 + 카드별 메타: aib_version / upstream / argument-hint)
- 우측 메타 박스 + 마크다운 본문 렌더 (Wiki 탭의 react-markdown + remark-gfm 동일)
- 클라이언트 측 substring 검색 (name + description, 대소문자 무시)
- frontmatter 파싱 실패 시 ⚠️ 배지로 표시 (silent skip 금지)
- 배럭에 `skills/` 없거나 비었을 때 빈 상태 안내 + `aib sync` 힌트

### 2.2 명시적 비범위 (v1.1.3+ 이연)

| 항목 | 사유 |
|---|---|
| `aib skills doctor` 실행 버튼 | 분량 절충 — 사용자가 Standard MVP를 선택해 v1.1.2에서 제외. Wiki Lint 패턴(터미널 세션 추가)으로 추후 추가 가능 |
| external skills 표시 (`agent.yaml`의 `skills.external`, `aib skills list --external`) | Skills 발견 영역(로컬 vs 외부) 분리는 v1.2 minor에서 다룰 가치. 카탈로그 변별력은 로컬만으로 충분 |
| 카드 정렬 토글 (slug / aib_version / mtime) | 시드는 1개라 정렬 가치↓. 카탈로그 규모 증가 후 |
| 편집 모드 (frontmatter 또는 본문 in-place 편집) | 원본은 `aib sync`로 갱신되는 시드 — 편집은 별도 흐름이며 v1.x 범위 외 |

## 3. 아키텍처

```
+------------------------+        invoke         +-----------------------+
| SkillsTab.tsx (React)  |  -------------------> | commands/skills.rs    |
|  - 카드 리스트          |  get_skills_index    |  walk skills/<slug>/  |
|  - 검색 박스            | <-------------------- |  parse SKILL.md       |
|  - 메타 박스 + 본문     |  Vec<SkillCard>      |    frontmatter (yaml) |
|                        |                       +-----------------------+
|                        |                                ^
|                        |                                |
|                        |  get_skill_content(slug)       |
|                        |  ----------------------------->|
|                        |  String (frontmatter 제외)    |
|                        | <----------------------------- |
+------------------------+                                +
```

### 3.1 데이터 흐름

1. 사용자가 Skills 탭 진입
2. `SkillsTab` 마운트 → `invoke("get_skills_index", { barrackPath })`
3. Rust: `${barrackPath}/skills/`를 walk, 각 하위 디렉터리의 `SKILL.md`를 찾음
4. 파일별로 `---\n…\n---\n` frontmatter를 `serde_yaml`로 파싱 → `SkillCard` 생성
5. `Vec<SkillCard>` 반환, slug 알파벳 오름차순 정렬
6. 사용자가 카드 클릭 → `invoke("get_skill_content", { barrackPath, slug })`
7. Rust: 해당 SKILL.md 읽기, frontmatter 블록 제외하고 본문만 반환
8. 우측 패널: 메타 박스(aib_version / upstream / argument-hint 칩) + ReactMarkdown 본문

### 3.2 검색

- 클라이언트 측 substring 필터 (`String.includes`, `toLowerCase`)
- 검색 대상: `card.name + " " + card.description`
- 검색 디바운스 불필요 (시드 규모 작음, 클라이언트 필터 즉시 반응)

## 4. 컴포넌트 / 파일 변경

### 4.1 신규 파일

| 파일 | 책임 |
|---|---|
| `src/components/skills/SkillsTab.tsx` | 좌측 검색+카드 리스트, 우측 메타 박스+마크다운. 약 160줄, Wiki 탭 미러 |
| `src-tauri/src/commands/skills.rs` | frontmatter parser, skills 디렉터리 walker, get_skills_index/get_skill_content 핸들러 |

### 4.2 수정 파일

| 파일 | 변경 |
|---|---|
| `src/types/index.ts` | `TabType`에 `"skills"` 추가, `SkillCard`/`SkillsIndex` interface 정의 |
| `src/components/layout/MainContent.tsx` | `TABS` 배열에 `{ key: "skills", label: "Skills" }` 추가, `activeTab === "skills" && <SkillsTab/>` switch case 추가, import 추가 |
| `src-tauri/src/commands/mod.rs` | `pub mod skills;` 추가 |
| `src-tauri/src/lib.rs` | `invoke_handler!` 매크로에 `skills::get_skills_index`, `skills::get_skill_content` 등록 |

### 4.3 의존성

추가 의존성 없음. `serde_yaml` 0.9는 이미 `src-tauri/Cargo.toml`에 있음(다른 명령에서 사용 중). frontend의 `react-markdown`/`remark-gfm`도 Wiki 탭이 사용 중.

## 5. 데이터 모델

### 5.1 Rust (`commands/skills.rs`)

```rust
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SkillCard {
    pub slug: String,            // 디렉터리 이름 (예: "council")
    pub name: String,            // frontmatter.name
    pub description: String,     // frontmatter.description
    pub aib_version: Option<String>,    // ai-barracks 확장
    pub upstream: Option<String>,       // ai-barracks 확장
    pub argument_hint: Option<String>,  // 표준
    pub parse_error: Option<String>,    // 파싱 실패 시 메시지
}

#[derive(Debug, Serialize)]
pub struct SkillsIndex {
    pub skills: Vec<SkillCard>,
    pub skills_dir_exists: bool,
}

#[tauri::command]
pub fn get_skills_index(barrack_path: String) -> Result<SkillsIndex, String>;

#[tauri::command]
pub fn get_skill_content(barrack_path: String, slug: String) -> Result<String, String>;
```

### 5.2 TypeScript (`src/types/index.ts`)

```typescript
export interface SkillCard {
  slug: string;
  name: string;
  description: string;
  aib_version?: string;
  upstream?: string;
  argument_hint?: string;
  parse_error?: string;
}

export interface SkillsIndex {
  skills: SkillCard[];
  skills_dir_exists: boolean;
}

export type TabType = "overview" | "files" | "sessions" | "wiki" | "git" | "skills";
```

## 6. UI 명세

### 6.1 좌측 패널 (w-64)

```
┌─ Skills (1) ────────────────┐
│ [🔍 검색...]                 │
│                              │
│ ┌──────────────────────────┐ │
│ │ council                  │ │
│ │ Use when an architectural│ │
│ │ decision...              │ │
│ │ aib 1.1 · upstream: ai-…│ │
│ │ args: <topic> [-m ...]  │ │
│ └──────────────────────────┘ │
└──────────────────────────────┘
```

- 헤더: `Skills (count)` (Wiki 헤더 패턴 미러)
- 검색 박스: `<input type="search">` (단순)
- 카드:
  - 1행: `name` (font-medium)
  - 2행: `description` (line-clamp-2, text-muted)
  - 3행 (메타): `aib {version}` · `upstream: {short}` · `args: {hint}` 칩 (text-[10px])
  - parse_error 있으면 카드 우상단에 ⚠️ 배지 + tooltip

### 6.2 우측 패널 (flex-1)

- 카드 미선택 시: Wiki 탭과 동일한 빈 상태 ("스킬을 선택하세요" + 아이콘)
- 카드 선택 시:
  - 상단 메타 박스 (border, padding) — name 큰 글씨, description, frontmatter 필드 정렬 표시
  - 하단 마크다운 본문 (Wiki 탭과 동일 prose 스타일)

### 6.3 빈 상태

- `skills_dir_exists === false` → 좌측에 "이 배럭에는 Skills가 없습니다" + small inline 코드 `aib sync` 힌트
- `skills_dir_exists === true && skills.length === 0` → "skills 디렉터리는 있으나 SKILL.md를 찾지 못했습니다" + 디렉터리 구조 안내

## 7. 오류 처리

| 시나리오 | 동작 |
|---|---|
| `skills/` 디렉터리 없음 | `skills_dir_exists: false` 반환, 빈 상태 UX |
| `<slug>/SKILL.md` 없음 (다른 파일만 있는 디렉터리) | 해당 디렉터리는 skill 후보가 아니라고 판단 — 카탈로그에서 제외 (silent skip 허용). D3의 "silent skip 금지"는 *SKILL.md가 존재하나 frontmatter가 깨진* 경우에 한정 — 두 케이스를 구분한다 |
| frontmatter 누락 (`---` 없이 시작) | `parse_error: "frontmatter 누락"` + name=slug, description=빈 문자열 |
| frontmatter 손상 YAML | `parse_error: "<serde_yaml 에러 메시지>"` + name=slug |
| 본문 읽기 실패 (`get_skill_content`) | Wiki와 동일하게 "Error: …" 텍스트 우측 패널에 표시 |

**원칙**: silent skip 금지. 사용자에게 ⚠️로 노출해 wiki/RULES.md에서 fix 가능하게 한다.

## 8. 테스트 계획

### 8.1 Rust unit (commands/skills.rs)

- `parse_frontmatter`: 정상 / `---` 없음 / yaml 손상 / 본문 누락 (빈 마크다운) 4 케이스
- `walk_skills_dir`: 빈 디렉터리 / SKILL.md 1개 / 다중 slug / SKILL.md 없는 sub-dir 혼재
- `get_skills_index`: council 시드를 가진 임시 fixture에서 정확히 1개 카드, 필드값 일치
- `get_skill_content`: frontmatter 블록 닫는 `---` **다음 줄부터 EOF까지**를 본문으로 반환. 본문 시작의 빈 줄(`\n`)은 **최대 1개까지** `trim_start_matches('\n')` 적용, 그 이상의 의도된 빈 줄은 보존. frontmatter 자체가 없는 파일은 전체 내용을 그대로 반환.

### 8.2 TypeScript

- `npx tsc -b --noEmit` exit 0 (CI 동일 검증)

### 8.3 수동 E2E

- Skills 탭 진입 → council 카드 1개 표시, 메타 칩 정상
- 카드 클릭 → 우측 메타 박스 + 본문 렌더
- 검색 박스에 "council" 입력 → 카드 유지, 다른 문자열 입력 → 카드 사라짐
- 임시 배럭(skills 디렉터리 없음)에서 빈 상태 안내 표시
- 일부러 손상된 SKILL.md 만들어 ⚠️ 배지 + parse_error tooltip 확인

### 8.4 회귀 가드

- 다른 탭(Wiki/Git/Sessions/Overview/Config)이 영향 받지 않는지 수동 확인
- aib_version 필드는 v1.1+ 시드부터 존재 — 빠진 v1.0.x 시드라도 `Option`이라 안전

## 9. 마이그레이션 / 호환성

- aib < 1.1: `skills/` 디렉터리 자체가 없을 수 있음 → 빈 상태 UX로 안전 처리
- aib >= 1.1: `skills/council/SKILL.md` 시드 자동 배포 → 기본 1 카드 표시
- agent.yaml의 `skills.external` 같은 새 필드는 v1.1.2 범위 외, 무시

## 10. 릴리즈 전략

- 브랜치: `feat/v1.1.2-skills-tab`
- v1.1.1과 동일 패턴: PR → main 머지 → `v1.1.2` 태그 push → release.yml 자동 트리거
- CHANGELOG에 [1.1.2] - unreleased 신규 + Skills 카탈로그 탭 항목
- `tauri.conf.json` / `package.json` / `Cargo.toml` / `Cargo.lock` 모두 1.1.1 → 1.1.2 (v1.1.1에서 확립한 lock-step)

## 11. 결정 이력

| ID | 결정 | 근거 |
|---|---|---|
| D1 | UI 패턴은 Wiki 탭 미러 (좌측 카드 + 우측 마크다운 + 검색 박스 추가) | 학습 비용 0, 일관성, react-markdown/remark-gfm 재사용 |
| D2 | frontmatter 파싱은 Rust(`serde_yaml`)에서 수행 | 의존성 이미 존재, 본문 분리 로직과 같은 곳에 두면 응집도↑, JS 측 yaml lib 추가 회피 |
| D3 | parse_error는 silent skip 금지 — ⚠️ 배지 노출 | 시드가 깨졌을 때 사용자에게 알리지 않으면 wiki/RULES 갱신 트리거 누락 (Growth Protocol과 일관) |
| D4 | Doctor 버튼/external skills/정렬 토글/편집 모드는 v1.1.3+ 이연 | Standard MVP 사용자 선택. v1.1.2 분량 절충 |
| D5 | 검색은 클라이언트 측 substring (디바운스 없음) | 시드 규모 작음, 즉시 반응이 더 자연스러움 |
| D6 | spec 위치는 ai-barracks-cc repo의 `docs/superpowers/specs/` | 구현 repo와 spec 동거 — PR/커밋 함께 흐를 수 있음 |
