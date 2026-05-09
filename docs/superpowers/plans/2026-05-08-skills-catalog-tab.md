# Skills 카탈로그 탭 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** aib-cc v1.1.2 — 배럭의 `skills/<slug>/SKILL.md`를 카탈로그 UI(좌측 카드+검색 / 우측 메타+마크다운)로 노출. Wiki 탭 패턴 미러.

**Architecture:** Tauri command 2개(`get_skills_index`, `get_skill_content`)가 frontmatter를 `serde_yaml`로 파싱해 `Vec<SkillCard>` 반환. 프론트엔드는 `SkillsTab.tsx` 단일 컴포넌트(클라이언트 substring 검색). silent skip 금지 — frontmatter 손상 시 `parse_error` 필드로 ⚠️ 배지 노출.

**Tech Stack:** TypeScript + React 19, Rust + Tauri v2, `serde` / `serde_yaml`(이미 의존성), `react-markdown` / `remark-gfm`(이미 의존성), `tempfile`(테스트용 신규 dev-dep).

**Spec:** `docs/superpowers/specs/2026-05-08-skills-catalog-tab-design.md`

**Branch:** `feat/v1.1.2-skills-tab` (이미 체크아웃됨, spec commit `ff9007f` 머리에 있음)

**작업 디렉터리:** `/Users/choihouse/Develop/ai-barracks-cc`

---

## File Structure

신규/수정 파일:

| 종류 | 경로 | 책임 |
|---|---|---|
| 신규 | `src-tauri/src/commands/skills.rs` | frontmatter parser + walker + 두 Tauri command |
| 신규 | `src/components/skills/SkillsTab.tsx` | 좌측 카드+검색 / 우측 메타+본문 |
| 수정 | `src-tauri/src/commands/mod.rs` | `pub mod skills;` 1줄 |
| 수정 | `src-tauri/src/lib.rs` | `use commands::{... skills}` + `invoke_handler!`에 명령 2개 등록 |
| 수정 | `src-tauri/Cargo.toml` | `[dev-dependencies] tempfile = "3"` 추가 |
| 수정 | `src/types/index.ts` | `SkillCard`/`SkillsIndex` interface, `TabType`에 `"skills"` 추가 |
| 수정 | `src/components/layout/MainContent.tsx` | `TABS` 배열 + switch case + import |
| 수정 (Task 8) | `src-tauri/tauri.conf.json` `package.json` `src-tauri/Cargo.toml` `src-tauri/Cargo.lock` `CHANGELOG.md` | 버전 1.1.1 → 1.1.2 |

각 파일은 단일 책임. Rust 측 모든 skills 로직은 `commands/skills.rs` 한 파일(예상 ~250줄)에 응집.

---

## Task 1: UI scaffold — 타입 + Tab 등록 + 빈 SkillsTab placeholder

**목적:** 컴파일·UI 등록만 먼저. 데이터 없이 탭 클릭 시 placeholder 보이도록.

**Files:**
- Modify: `src/types/index.ts`
- Modify: `src/components/layout/MainContent.tsx`
- Create: `src/components/skills/SkillsTab.tsx`

- [ ] **Step 1.1: `types/index.ts` — SkillCard/SkillsIndex 타입 추가, TabType 확장**

`src/types/index.ts`에 `WikiIndex` 정의(line 63~66) **다음**에 다음 블록을 추가하고, `TabType` 정의(line 110)에 `"skills"`를 추가:

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
```

`TabType`은 다음과 같이 변경:

```typescript
export type TabType = "overview" | "files" | "sessions" | "wiki" | "git" | "skills";
```

- [ ] **Step 1.2: `SkillsTab.tsx` placeholder 생성**

```tsx
// src/components/skills/SkillsTab.tsx
export function SkillsTab() {
  return (
    <div className="flex h-full items-center justify-center text-cc-text-muted">
      <div className="text-center">
        <div className="text-3xl mb-3">🧪</div>
        <p className="text-sm">Skills 탭 (구현 진행 중)</p>
      </div>
    </div>
  );
}
```

- [ ] **Step 1.3: `MainContent.tsx`에 Skills 탭 등록**

`src/components/layout/MainContent.tsx`에서:

1. import 줄 그룹에 추가 (GitTab import 다음 줄):
```tsx
import { SkillsTab } from "../skills/SkillsTab";
```

2. `TABS` 배열에 Wiki 다음으로 한 줄 추가:
```tsx
{ key: "skills", label: "Skills" },
```
배열 최종 형태:
```tsx
const TABS: { key: TabType; label: string }[] = [
  { key: "overview", label: "Overview" },
  { key: "files", label: "Config" },
  { key: "sessions", label: "Agents" },
  { key: "wiki", label: "Wiki" },
  { key: "skills", label: "Skills" },
  { key: "git", label: "Git" },
];
```

3. switch case에 `wiki`와 `git` 사이에 한 줄 추가:
```tsx
{activeTab === "skills" && <SkillsTab />}
```

- [ ] **Step 1.4: 타입 체크**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc && npx tsc -b --noEmit
```
Expected: exit 0, 출력 없음.

- [ ] **Step 1.5: Commit**

```bash
git add src/types/index.ts src/components/skills/SkillsTab.tsx src/components/layout/MainContent.tsx
git commit -m "feat(skills): scaffold tab with placeholder + types"
```

---

## Task 2: Rust frontmatter parser TDD

**목적:** SKILL.md의 `---\n…\n---\n` 블록을 안전하게 분리하고 yaml로 파싱하는 helper. silent skip 금지 원칙으로 4가지 실패 모드를 명확히 분류한다.

**Files:**
- Create: `src-tauri/src/commands/skills.rs`
- Modify: `src-tauri/src/commands/mod.rs`
- Modify: `src-tauri/Cargo.toml`

- [ ] **Step 2.1: `tempfile` dev-dep 추가**

`src-tauri/Cargo.toml`의 `[dependencies]` 섹션 **아래**에 추가:

```toml
[dev-dependencies]
tempfile = "3"
```

- [ ] **Step 2.2: `commands/skills.rs` 골격 + `parse_skill_md` 함수 작성 (TDD: 테스트 먼저)**

신규 파일 `src-tauri/src/commands/skills.rs`:

```rust
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Deserialize, Clone, Default, PartialEq)]
pub struct SkillCard {
    pub slug: String,
    pub name: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aib_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    #[serde(rename = "argument-hint", default, skip_serializing_if = "Option::is_none")]
    pub argument_hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parse_error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SkillsIndex {
    pub skills: Vec<SkillCard>,
    pub skills_dir_exists: bool,
}

/// SKILL.md 한 파일을 파싱해 SkillCard로 변환.
/// slug는 호출자가 디렉터리 이름에서 채워준다.
fn parse_skill_md(slug: &str, content: &str) -> SkillCard {
    let normalized = content.replace("\r\n", "\n");
    let after_open = match normalized.strip_prefix("---\n") {
        Some(s) => s,
        None => {
            return SkillCard {
                slug: slug.to_string(),
                name: slug.to_string(),
                description: String::new(),
                parse_error: Some("frontmatter 블록 누락 (파일이 '---'로 시작하지 않음)".into()),
                ..Default::default()
            };
        }
    };
    let end_idx = match after_open.find("\n---\n").or_else(|| {
        // EOF 직전에 닫는 ---로 끝나는 케이스
        if after_open.ends_with("\n---") {
            Some(after_open.len() - 3)
        } else {
            None
        }
    }) {
        Some(i) => i,
        None => {
            return SkillCard {
                slug: slug.to_string(),
                name: slug.to_string(),
                description: String::new(),
                parse_error: Some("frontmatter 닫는 '---' 누락".into()),
                ..Default::default()
            };
        }
    };
    let yaml = &after_open[..end_idx];
    match serde_yaml::from_str::<SkillCard>(yaml) {
        Ok(mut card) => {
            card.slug = slug.to_string();
            // 빈 name은 slug로 폴백
            if card.name.is_empty() {
                card.name = slug.to_string();
            }
            card
        }
        Err(e) => SkillCard {
            slug: slug.to_string(),
            name: slug.to_string(),
            description: String::new(),
            parse_error: Some(format!("frontmatter YAML 파싱 실패: {}", e)),
            ..Default::default()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_frontmatter() {
        let input = "---\nname: foo\ndescription: bar\naib_version: \"1.1\"\n---\nBody text\n";
        let card = parse_skill_md("foo", input);
        assert_eq!(card.slug, "foo");
        assert_eq!(card.name, "foo");
        assert_eq!(card.description, "bar");
        assert_eq!(card.aib_version, Some("1.1".to_string()));
        assert!(card.parse_error.is_none(), "expected no parse_error, got {:?}", card.parse_error);
    }

    #[test]
    fn flags_missing_opening_delimiter() {
        let input = "name: foo\nBody\n";
        let card = parse_skill_md("foo", input);
        assert_eq!(card.slug, "foo");
        assert_eq!(card.name, "foo"); // slug fallback
        assert!(card.parse_error.as_deref().unwrap_or("").contains("frontmatter 블록 누락"));
    }

    #[test]
    fn flags_missing_closing_delimiter() {
        let input = "---\nname: foo\nBody\n";
        let card = parse_skill_md("foo", input);
        assert!(card.parse_error.as_deref().unwrap_or("").contains("닫는 '---'"));
    }

    #[test]
    fn flags_corrupt_yaml() {
        // YAML 파서가 거부하는 입력 (탭 들여쓰기는 yaml에서 금지)
        let input = "---\nname:\n\tfoo: bar\n---\nbody\n";
        let card = parse_skill_md("foo", input);
        assert!(
            card.parse_error.as_deref().unwrap_or("").contains("YAML"),
            "expected YAML parse error, got {:?}", card.parse_error
        );
    }

    #[test]
    fn handles_empty_body() {
        let input = "---\nname: foo\ndescription: bar\n---\n";
        let card = parse_skill_md("foo", input);
        assert!(card.parse_error.is_none());
        assert_eq!(card.description, "bar");
    }
}
```

`src-tauri/src/commands/mod.rs`에 한 줄 추가 (`pub mod search;` 다음):

```rust
pub mod skills;
```

- [ ] **Step 2.3: 테스트 실행 → fail 확인 (참고: 첫 빌드에서 컴파일 에러일 수도 있음, 그것도 RED로 간주)**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc/src-tauri && cargo test --lib commands::skills::tests
```
Expected: 5개 테스트 모두 PASS (구현이 이미 들어있으므로 RED → GREEN을 한 번에 통과). 만약 어느 테스트가 FAIL하면 그 테스트가 실제 구현 행동과 어긋난 것이므로 인라인 fix.

> **검증 의의:** 이 task의 TDD 단계는 "테스트 케이스가 spec 7번 표의 4가지 실패 모드(+정상 1개)를 모두 망라하는가"를 보장하는 것. 테스트 5개 + 구현 1개를 한 commit으로 묶는다.

- [ ] **Step 2.4: Commit**

```bash
git add src-tauri/Cargo.toml src-tauri/src/commands/skills.rs src-tauri/src/commands/mod.rs
git commit -m "feat(skills): add SKILL.md frontmatter parser with 5 unit tests"
```

---

## Task 3: `get_skills_index` walker + 명령 등록

**목적:** `${barrack_path}/skills/`를 walk해 각 sub-디렉터리의 SKILL.md를 발견·파싱·정렬·반환하는 Tauri command. SKILL.md가 없는 디렉터리는 silent skip(spec 7번 표 D3 분기).

**Files:**
- Modify: `src-tauri/src/commands/skills.rs`
- Modify: `src-tauri/src/lib.rs`

- [ ] **Step 3.1: `walk_skills_dir` + `get_skills_index` 추가 + 테스트 4개**

`src-tauri/src/commands/skills.rs`의 `parse_skill_md` 함수 **다음**에 추가:

```rust
fn walk_skills_dir(skills_dir: &Path) -> Vec<SkillCard> {
    let mut cards = Vec::new();
    let entries = match fs::read_dir(skills_dir) {
        Ok(e) => e,
        Err(_) => return cards,
    };
    let mut slugs: Vec<(String, PathBuf)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let skill_md = path.join("SKILL.md");
        if !skill_md.is_file() {
            continue; // SKILL.md 없는 디렉터리는 skill 후보 아님 (spec 7번 표)
        }
        let slug = match path.file_name().and_then(|s| s.to_str()) {
            Some(s) => s.to_string(),
            None => continue,
        };
        slugs.push((slug, skill_md));
    }
    slugs.sort_by(|a, b| a.0.cmp(&b.0));
    for (slug, skill_md) in slugs {
        let content = fs::read_to_string(&skill_md).unwrap_or_default();
        cards.push(parse_skill_md(&slug, &content));
    }
    cards
}

#[tauri::command]
pub fn get_skills_index(barrack_path: String) -> Result<SkillsIndex, String> {
    let skills_dir = PathBuf::from(&barrack_path).join("skills");
    let exists = skills_dir.is_dir();
    let skills = if exists {
        walk_skills_dir(&skills_dir)
    } else {
        Vec::new()
    };
    Ok(SkillsIndex {
        skills,
        skills_dir_exists: exists,
    })
}
```

`#[cfg(test)] mod tests` 블록 안에 추가 (기존 테스트 5개 다음):

```rust
    use std::fs::{self, File};
    use std::io::Write;
    use tempfile::TempDir;

    fn write_skill(dir: &Path, slug: &str, content: &str) {
        let sub = dir.join(slug);
        fs::create_dir_all(&sub).unwrap();
        let mut f = File::create(sub.join("SKILL.md")).unwrap();
        f.write_all(content.as_bytes()).unwrap();
    }

    #[test]
    fn empty_dir_returns_no_cards() {
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("skills");
        fs::create_dir_all(&skills_dir).unwrap();
        let cards = walk_skills_dir(&skills_dir);
        assert!(cards.is_empty());
    }

    #[test]
    fn finds_single_skill() {
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("skills");
        write_skill(&skills_dir, "council", "---\nname: council\ndescription: A skill\n---\nBody\n");
        let cards = walk_skills_dir(&skills_dir);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].slug, "council");
        assert_eq!(cards[0].name, "council");
        assert_eq!(cards[0].description, "A skill");
    }

    #[test]
    fn sorts_alphabetically_by_slug() {
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("skills");
        write_skill(&skills_dir, "zoo", "---\nname: zoo\ndescription: z\n---\n");
        write_skill(&skills_dir, "alpha", "---\nname: alpha\ndescription: a\n---\n");
        write_skill(&skills_dir, "mid", "---\nname: mid\ndescription: m\n---\n");
        let cards = walk_skills_dir(&skills_dir);
        let slugs: Vec<&str> = cards.iter().map(|c| c.slug.as_str()).collect();
        assert_eq!(slugs, vec!["alpha", "mid", "zoo"]);
    }

    #[test]
    fn ignores_dirs_without_skill_md() {
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("skills");
        write_skill(&skills_dir, "council", "---\nname: council\ndescription: c\n---\n");
        // SKILL.md 없는 디렉터리
        fs::create_dir_all(skills_dir.join("not_a_skill")).unwrap();
        let cards = walk_skills_dir(&skills_dir);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].slug, "council");
    }

    #[test]
    fn get_skills_index_handles_missing_skills_dir() {
        let tmp = TempDir::new().unwrap();
        // skills 디렉터리 자체가 없음
        let result = get_skills_index(tmp.path().to_string_lossy().to_string()).unwrap();
        assert!(!result.skills_dir_exists);
        assert!(result.skills.is_empty());
    }
```

> ⚠️ **주의:** `use std::fs::{self, File};` 등의 use 문은 이미 `mod tests` 바깥에 있는 `use std::fs;`와 다른 스코프이므로 `mod tests` 내부 첫 줄들에 그대로 추가한다. 만약 충돌이 나면 `tests` 모듈 안에서 `use super::*;` 다음 줄에 `use std::fs::File; use std::io::Write; use tempfile::TempDir;`로 바꾼다(파일 상단에 이미 `use std::fs;`가 있음).

- [ ] **Step 3.2: `lib.rs`에 명령 등록**

`src-tauri/src/lib.rs` 4번째 줄 use 라인에 `skills` 추가:

```rust
use commands::{barracks, files, git, search, sessions, skills, sync, terminal, wiki};
```

`invoke_handler!` 매크로의 `wiki::get_wiki_topic,` 다음 줄에 추가:

```rust
            skills::get_skills_index,
```
(다음 task에서 `get_skill_content`도 같은 자리에 추가 예정 — 일단 한 줄만)

- [ ] **Step 3.3: 테스트 실행 → 모든 skills 테스트 PASS**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc/src-tauri && cargo test --lib commands::skills::tests
```
Expected: 9개 테스트 PASS (Task 2의 5개 + Task 3의 4개).

- [ ] **Step 3.4: 전체 cargo build로 lib.rs 등록 검증**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc/src-tauri && cargo build --lib 2>&1 | tail -5
```
Expected: `Finished` 또는 `Compiling … Finished`. 에러 없음.

- [ ] **Step 3.5: Commit**

```bash
git add src-tauri/src/commands/skills.rs src-tauri/src/lib.rs
git commit -m "feat(skills): add get_skills_index Tauri command + 4 walker tests"
```

---

## Task 4: `get_skill_content` 명령 + 본문 추출 정책 테스트

**목적:** 카드 클릭 시 SKILL.md의 frontmatter를 제거하고 본문만 반환. spec 7.1 정책 — `---` 직후 빈 줄 1개까지만 trim, 그 이상은 보존.

**Files:**
- Modify: `src-tauri/src/commands/skills.rs`
- Modify: `src-tauri/src/lib.rs`

- [ ] **Step 4.1: `extract_body` + `get_skill_content` 추가 + 테스트 3개**

`src-tauri/src/commands/skills.rs`의 `get_skills_index` **다음**에 추가:

```rust
/// frontmatter 블록을 제거하고 본문만 반환.
/// 정책 (spec 7.1): 닫는 '---' 다음의 빈 줄(`\n`)은 최대 1개까지 trim, 그 이상은 보존.
/// frontmatter 자체가 없는 파일은 전체를 그대로 반환.
fn extract_body(content: &str) -> String {
    let normalized = content.replace("\r\n", "\n");
    let after_open = match normalized.strip_prefix("---\n") {
        Some(s) => s,
        None => return normalized, // frontmatter 없음 — 전체 반환
    };
    let end_idx = match after_open.find("\n---\n") {
        Some(i) => i,
        None => {
            // 닫는 --- 없음. 안전하게 frontmatter 없는 것으로 처리해 원본 반환.
            return normalized;
        }
    };
    let body = &after_open[end_idx + "\n---\n".len()..];
    // 시작 빈 줄 1개까지만 제거
    body.strip_prefix('\n').unwrap_or(body).to_string()
}

#[tauri::command]
pub fn get_skill_content(barrack_path: String, slug: String) -> Result<String, String> {
    let path = PathBuf::from(&barrack_path).join("skills").join(&slug).join("SKILL.md");
    let content = fs::read_to_string(&path).map_err(|e| format!("SKILL.md 읽기 실패: {}", e))?;
    Ok(extract_body(&content))
}
```

`mod tests` 블록 끝에 추가:

```rust
    #[test]
    fn extracts_body_after_frontmatter() {
        let input = "---\nname: foo\n---\n\nBody line 1\nBody line 2\n";
        let body = extract_body(input);
        // 첫 빈 줄 1개 제거 → "Body line 1\nBody line 2\n"
        assert_eq!(body, "Body line 1\nBody line 2\n");
    }

    #[test]
    fn preserves_extra_blank_lines() {
        let input = "---\nname: foo\n---\n\n\nIntentional blank\n";
        let body = extract_body(input);
        // 앞 빈 줄 1개만 제거 → 빈 줄 1개 + 본문
        assert_eq!(body, "\nIntentional blank\n");
    }

    #[test]
    fn returns_full_content_when_no_frontmatter() {
        let input = "no frontmatter here\nbody\n";
        let body = extract_body(input);
        assert_eq!(body, "no frontmatter here\nbody\n");
    }
```

- [ ] **Step 4.2: `lib.rs`에 명령 등록**

`src-tauri/src/lib.rs`의 `skills::get_skills_index,` 다음 줄에 추가:

```rust
            skills::get_skill_content,
```

- [ ] **Step 4.3: 전체 cargo test 실행**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc/src-tauri && cargo test --lib commands::skills::tests 2>&1 | tail -15
```
Expected: 12개 테스트 PASS (Task 2의 5 + Task 3의 4 + Task 4의 3).

- [ ] **Step 4.4: Commit**

```bash
git add src-tauri/src/commands/skills.rs src-tauri/src/lib.rs
git commit -m "feat(skills): add get_skill_content with body trim policy + 3 tests"
```

---

## Task 5: SkillsTab 카드 리스트 + 검색

**목적:** Wiki 탭 패턴을 미러해 좌측 검색 박스 + 카드 리스트 구현. 카드는 name·description·메타 칩(aib_version/upstream/argument-hint)을 표시. parse_error 있으면 ⚠️ 배지.

**Files:**
- Modify: `src/components/skills/SkillsTab.tsx` (Task 1의 placeholder를 풀구현으로 교체)

- [ ] **Step 5.1: SkillsTab 풀구현 (좌측만, 우측은 빈 상태)**

`src/components/skills/SkillsTab.tsx`를 다음으로 **전부 교체**:

```tsx
import { useEffect, useMemo, useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "../../stores/appStore";
import type { SkillCard, SkillsIndex } from "../../types";

export function SkillsTab() {
  const { selectedBarrack } = useAppStore();
  const barrackPath = selectedBarrack?.path;
  const [index, setIndex] = useState<SkillsIndex | null>(null);
  const [selectedSlug, setSelectedSlug] = useState<string | null>(null);
  const [query, setQuery] = useState("");

  const loadIndex = useCallback(async () => {
    if (!barrackPath) return;
    try {
      const idx = await invoke<SkillsIndex>("get_skills_index", { barrackPath });
      setIndex(idx);
    } catch (e) {
      console.error("Failed to load skills:", e);
      setIndex({ skills: [], skills_dir_exists: false });
    }
  }, [barrackPath]);

  useEffect(() => {
    loadIndex();
  }, [loadIndex]);

  useEffect(() => {
    setSelectedSlug(null);
    setQuery("");
  }, [barrackPath]);

  const filteredSkills = useMemo(() => {
    if (!index) return [];
    const q = query.trim().toLowerCase();
    if (!q) return index.skills;
    return index.skills.filter((s) =>
      `${s.name} ${s.description}`.toLowerCase().includes(q)
    );
  }, [index, query]);

  if (!index) return null;

  return (
    <div className="flex h-full">
      {/* Left: search + cards */}
      <div className="w-64 min-w-[256px] border-r border-cc-border p-4">
        <div className="mb-3">
          <h3 className="text-xs font-medium text-cc-text-muted uppercase tracking-wider">
            Skills ({index.skills.length})
          </h3>
        </div>
        <input
          type="search"
          placeholder="검색..."
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          className="w-full mb-3 px-2 py-1 text-xs bg-cc-panel border border-cc-border rounded focus:outline-none focus:border-cc-accent"
        />

        {!index.skills_dir_exists ? (
          <div className="text-xs text-cc-text-muted py-8 text-center">
            이 배럭에는 Skills가 없습니다.
            <br />
            <code className="text-[10px]">aib sync</code>로 시드를 받으세요.
          </div>
        ) : filteredSkills.length === 0 ? (
          <div className="text-xs text-cc-text-muted py-4 text-center">
            {query ? "검색 결과 없음" : "skills 디렉터리에서 SKILL.md를 찾지 못했습니다"}
          </div>
        ) : (
          <div className="space-y-2">
            {filteredSkills.map((skill) => (
              <SkillCardItem
                key={skill.slug}
                skill={skill}
                selected={selectedSlug === skill.slug}
                onClick={() => setSelectedSlug(skill.slug)}
              />
            ))}
          </div>
        )}
      </div>

      {/* Right: empty for now (Task 6 fills this in) */}
      <div className="flex-1 p-6 overflow-y-auto">
        <div className="flex items-center justify-center h-full text-cc-text-muted">
          <div className="text-center">
            <div className="text-3xl mb-3">🧪</div>
            <p className="text-sm">스킬을 선택하세요</p>
          </div>
        </div>
      </div>
    </div>
  );
}

function SkillCardItem({
  skill,
  selected,
  onClick,
}: {
  skill: SkillCard;
  selected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={`w-full text-left p-3 rounded-lg border transition-colors ${
        selected
          ? "bg-cc-accent/20 border-cc-accent/40"
          : "border-cc-border hover:bg-cc-panel"
      }`}
    >
      <div className="flex items-start justify-between gap-2 mb-1">
        <div className="text-sm font-medium">{skill.name}</div>
        {skill.parse_error && (
          <span title={skill.parse_error} className="text-xs">
            ⚠️
          </span>
        )}
      </div>
      {skill.description && (
        <p className="text-xs text-cc-text-muted line-clamp-2 mb-1">
          {skill.description}
        </p>
      )}
      <div className="flex flex-wrap gap-1 text-[10px] text-cc-text-muted">
        {skill.aib_version && <span>aib {skill.aib_version}</span>}
        {skill.upstream && <span>· upstream</span>}
        {skill.argument_hint && (
          <span className="truncate max-w-full">· args: {skill.argument_hint}</span>
        )}
      </div>
    </button>
  );
}
```

- [ ] **Step 5.2: 타입 체크**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc && npx tsc -b --noEmit
```
Expected: exit 0.

- [ ] **Step 5.3: 수동 E2E**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc && npm run tauri dev
```

다음을 화면에서 확인:
- (이 배럭 또는 council 시드가 있는 배럭 선택 후) Skills 탭 클릭
- 좌측에 "Skills (1)" 헤더 + 검색 박스 + council 카드 1개 표시
- 카드에 name="council", description, "aib 1.1 · upstream · args: …" 메타 칩 보임
- 검색 박스에 "council" 입력 → 카드 유지, "xyz" 입력 → "검색 결과 없음"
- 우측은 "스킬을 선택하세요" 빈 상태

확인 후 dev 서버 종료 (Ctrl+C in dev terminal).

- [ ] **Step 5.4: Commit**

```bash
git add src/components/skills/SkillsTab.tsx
git commit -m "feat(skills): render card list with search + meta chips"
```

---

## Task 6: 우측 메타 박스 + 마크다운 본문 패널

**목적:** 카드 클릭 시 `get_skill_content`로 본문 가져오고, 우측 패널에 메타 박스(name/description/필드 표) + 마크다운 본문을 렌더.

**Files:**
- Modify: `src/components/skills/SkillsTab.tsx`

- [ ] **Step 6.1: SkillsTab에 본문 로딩 + 우측 패널 구현**

`src/components/skills/SkillsTab.tsx`의 import 라인에 추가:

```tsx
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
```

`SkillsTab` 컴포넌트의 state 추가 (selectedSlug 다음):

```tsx
  const [content, setContent] = useState<string>("");
  const selectedCard = useMemo(
    () => index?.skills.find((s) => s.slug === selectedSlug) ?? null,
    [index, selectedSlug]
  );
```

기존 `setSelectedSlug(...)` onClick 핸들러를 다음과 같이 비동기 fetch로 교체:

```tsx
  const handleSelect = useCallback(
    async (slug: string) => {
      setSelectedSlug(slug);
      if (!barrackPath) return;
      try {
        const body = await invoke<string>("get_skill_content", {
          barrackPath,
          slug,
        });
        setContent(body);
      } catch (e) {
        setContent(`Error: ${e}`);
      }
    },
    [barrackPath]
  );
```

`SkillCardItem`에 전달하는 `onClick`을 `() => handleSelect(skill.slug)`로 교체.

`barrackPath` 변경 effect에 `setContent("")` 추가:

```tsx
  useEffect(() => {
    setSelectedSlug(null);
    setQuery("");
    setContent("");
  }, [barrackPath]);
```

우측 패널(현재 빈 상태) **전체**를 다음으로 교체:

```tsx
      <div className="flex-1 p-6 overflow-y-auto">
        {selectedCard ? (
          <div className="space-y-4">
            {/* Meta box */}
            <div className="border border-cc-border rounded-lg p-4 bg-cc-panel/40">
              <div className="text-base font-semibold mb-1">{selectedCard.name}</div>
              {selectedCard.description && (
                <p className="text-sm text-cc-text-dim mb-3">{selectedCard.description}</p>
              )}
              <dl className="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-xs text-cc-text-muted">
                <dt>slug</dt>
                <dd className="font-mono text-cc-text-dim">{selectedCard.slug}</dd>
                {selectedCard.aib_version && (
                  <>
                    <dt>aib_version</dt>
                    <dd className="font-mono text-cc-text-dim">{selectedCard.aib_version}</dd>
                  </>
                )}
                {selectedCard.upstream && (
                  <>
                    <dt>upstream</dt>
                    <dd className="font-mono text-cc-text-dim break-all">{selectedCard.upstream}</dd>
                  </>
                )}
                {selectedCard.argument_hint && (
                  <>
                    <dt>argument-hint</dt>
                    <dd className="font-mono text-cc-text-dim">{selectedCard.argument_hint}</dd>
                  </>
                )}
                {selectedCard.parse_error && (
                  <>
                    <dt className="text-red-400">parse_error</dt>
                    <dd className="text-red-400">{selectedCard.parse_error}</dd>
                  </>
                )}
              </dl>
            </div>

            {/* Body */}
            <div className="prose prose-sm max-w-none prose-headings:text-cc-text prose-p:text-cc-text-dim prose-li:text-cc-text-dim prose-strong:text-cc-text prose-code:text-cc-accent prose-code:bg-cc-panel prose-code:px-1 prose-code:rounded prose-a:text-cc-accent">
              <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
            </div>
          </div>
        ) : (
          <div className="flex items-center justify-center h-full text-cc-text-muted">
            <div className="text-center">
              <div className="text-3xl mb-3">🧪</div>
              <p className="text-sm">스킬을 선택하세요</p>
            </div>
          </div>
        )}
      </div>
```

- [ ] **Step 6.2: 타입 체크**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc && npx tsc -b --noEmit
```
Expected: exit 0.

- [ ] **Step 6.3: 수동 E2E**

`npm run tauri dev`로 실행 후:
- council 카드 클릭 → 우측에 메타 박스(slug=council, aib_version=1.1, upstream=ai-barracks/scripts/council.sh, argument-hint=...) + 마크다운 본문(SKILL.md의 # LLM Council — 멀티라운드 교차 리뷰 등) 정상 렌더
- 다른 카드 클릭 → 본문 즉시 교체
- 배럭 전환 → 선택 해제, 빈 상태 복귀
- dev 종료 (Ctrl+C)

- [ ] **Step 6.4: Commit**

```bash
git add src/components/skills/SkillsTab.tsx
git commit -m "feat(skills): render detail panel with meta box + markdown body"
```

---

## Task 7: 빈 상태 / parse_error 회귀 검증

**목적:** spec 7번의 모든 오류 분기가 실제 UI에서 의도대로 보이는지 수동 회귀. 코드 변경은 거의 없고 fixture 만들고 시각 확인.

**Files:**
- (코드 변경 없음 — 회귀 검증만)

- [ ] **Step 7.1: 빈 상태 UX 검증**

임시 배럭 디렉터리 생성하고 그 배럭을 추가:

```bash
mkdir -p /tmp/aib-empty-barrack/{wiki,sessions}
echo "name: empty-barrack" > /tmp/aib-empty-barrack/agent.yaml
```

`npm run tauri dev`로 실행 후 System View → "+ Add Barrack" → `/tmp/aib-empty-barrack` 추가 → Skills 탭 클릭 → "이 배럭에는 Skills가 없습니다 / `aib sync`로 시드를 받으세요" 메시지 표시 확인.

확인 후 그 임시 배럭은 System View → Remove로 제거 + `rm -rf /tmp/aib-empty-barrack`.

- [ ] **Step 7.2: parse_error UX 검증**

이번 배럭에 일부러 깨진 SKILL.md 추가:

```bash
mkdir -p /Users/choihouse/Develop/ai-barracks-yr/ai_barracks_management/skills/_broken_demo
cat > /Users/choihouse/Develop/ai-barracks-yr/ai_barracks_management/skills/_broken_demo/SKILL.md <<'EOF'
no frontmatter here at all
just plain body
EOF
```

`npm run tauri dev`에서 ai_barracks_management 배럭의 Skills 탭 → `_broken_demo` 카드에 ⚠️ 배지 + tooltip "frontmatter 블록 누락…" 표시 확인. 카드 클릭 → 우측 메타 박스의 `parse_error` 필드가 빨간색으로 표시.

확인 후 fixture 제거:

```bash
rm -rf /Users/choihouse/Develop/ai-barracks-yr/ai_barracks_management/skills/_broken_demo
```

- [ ] **Step 7.3: 다른 탭 회귀 확인**

Wiki / Git / Sessions / Overview / Config 탭을 한 번씩 클릭해 모두 정상 동작 확인 (Skills 탭 추가가 다른 탭을 깨지 않았는지).

- [ ] **Step 7.4: 회귀 검증 자체에 commit할 변경 없음 — 다음 task로 진행**

(상황에 따라 README나 docs에 스크린샷/노트 추가하고 싶으면 별도 commit. 본 plan에선 생략.)

---

## Task 8: 버전 bump + CHANGELOG 갱신 (v1.1.2 release 준비)

**목적:** v1.1.1과 동일 lock-step으로 4개 매니페스트 + Cargo.lock + CHANGELOG 갱신. 머지 후 `v1.1.2` 태그 push로 release.yml 트리거.

**Files:**
- Modify: `src-tauri/tauri.conf.json`
- Modify: `package.json`
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/Cargo.lock` (cargo가 갱신)
- Modify: `CHANGELOG.md`

- [ ] **Step 8.1: 4개 매니페스트 버전 1.1.1 → 1.1.2**

```
src-tauri/tauri.conf.json   "version": "1.1.1" → "1.1.2"
package.json                "version": "1.1.1" → "1.1.2"
src-tauri/Cargo.toml        version = "1.1.1" → "1.1.2"
```

- [ ] **Step 8.2: Cargo.lock 갱신**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc/src-tauri && cargo update -p ai-barracks-cc --offline
```
Expected: `Updating ai-barracks-cc v1.1.1 -> v1.1.2`.

- [ ] **Step 8.3: CHANGELOG 항목 추가**

`CHANGELOG.md`의 최상단(`## [1.1.1]` **이전**)에 다음을 추가:

```markdown
## [1.1.2] - unreleased

### Added — Skills 카탈로그 탭
- **`SkillsTab`** (신규): 좌측 검색 박스 + SKILL.md 카드 리스트 / 우측 메타 박스 + 마크다운 본문. Wiki 탭 패턴 미러.
- **Tauri commands**: `get_skills_index` (skills/<slug>/SKILL.md walk + `serde_yaml` frontmatter 파싱), `get_skill_content` (frontmatter 제거 후 본문 반환).
- **frontmatter 손상 노출**: silent skip 금지 — 파싱 실패 시 카드에 ⚠️ 배지 + 메타 박스에 빨간 `parse_error` 표시. spec D3.

### Notes
- aib v1.1.0 release notes에서 v1.1.1로 약속됐던 "Skills 카탈로그 전용 탭" 항목 — v1.1.1은 메타데이터 sync 패치로 분리되어 본 항목은 v1.1.2로 이연됨.
- v1.1.3+ 후보로 이연: `aib skills doctor` 실행 버튼, external skills 표시, 카드 정렬 토글, 편집 모드.
```

- [ ] **Step 8.4: 검증 — cargo test + tsc + cargo build**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc/src-tauri && cargo test --lib commands::skills::tests 2>&1 | tail -3
cd /Users/choihouse/Develop/ai-barracks-cc && npx tsc -b --noEmit
cd /Users/choihouse/Develop/ai-barracks-cc/src-tauri && cargo build --lib 2>&1 | tail -3
```
Expected: 12 tests PASS, tsc exit 0, cargo `Finished`.

- [ ] **Step 8.5: Commit**

```bash
git add src-tauri/tauri.conf.json package.json src-tauri/Cargo.toml src-tauri/Cargo.lock CHANGELOG.md
git commit -m "chore: bump to v1.1.2 + CHANGELOG (Skills 카탈로그 탭)"
```

- [ ] **Step 8.6: Push + PR + 머지 + 태그**

```bash
cd /Users/choihouse/Develop/ai-barracks-cc && git push -u origin feat/v1.1.2-skills-tab
```

PR 생성:

```bash
gh pr create --base main --head feat/v1.1.2-skills-tab \
  --title "feat: v1.1.2 — Skills 카탈로그 탭" \
  --body "$(cat <<'EOF'
## Summary

- **`SkillsTab`** 신규: Wiki 탭 패턴 미러 (좌측 검색+카드 / 우측 메타+마크다운)
- **Tauri commands** `get_skills_index` / `get_skill_content` — `serde_yaml`로 SKILL.md frontmatter 파싱
- **silent skip 금지** — frontmatter 손상 시 ⚠️ 배지로 노출
- aib v1.1.0 release notes에서 약속된 "Skills 카탈로그 탭"의 v1.1.2 이연 구현. external skills / Doctor 버튼 / 정렬 토글 / 편집 모드는 v1.1.3+로 이연

## Spec / Plan

- Spec: `docs/superpowers/specs/2026-05-08-skills-catalog-tab-design.md`
- Plan: `docs/superpowers/plans/2026-05-08-skills-catalog-tab.md`

## Test plan

- [x] `cargo test --lib commands::skills::tests` — 12개 PASS (parser 5 + walker 4 + body 3)
- [x] `npx tsc -b --noEmit` exit 0
- [x] 수동 E2E — council 카드 표시·검색·메타 박스·마크다운 본문 렌더
- [x] 빈 상태 (skills/ 없는 임시 배럭) 안내 표시
- [x] parse_error fixture (frontmatter 누락) ⚠️ 배지 + 빨간 parse_error 표시
- [ ] 머지 후 v1.1.2 태그 push → release.yml 트리거 → DMG 빌드 + Info.plist `1.1.2` 검증
EOF
)"
```

머지 + 태그 push:

```bash
gh pr merge --merge --delete-branch
cd /Users/choihouse/Develop/ai-barracks-cc && git checkout main && git pull --ff-only
git tag v1.1.2 -m "v1.1.2 — Skills 카탈로그 탭" && git push origin v1.1.2
```

- [ ] **Step 8.7: release 빌드 모니터링 + 설치 검증**

빌드는 ~7~8분. 완료 후:

```bash
gh release view v1.1.2 --repo ai-barracks/ai-barracks-cc --json assets,publishedAt
```
Expected: assets에 `AI.Barracks.CommandCenter_1.1.2_universal.dmg` 표기 (메타데이터 정정 검증).

설치 검증은 사용자 결정에 따라 (자동 설치는 DMG mount/copy 필요 — 사용자 승인 후).

---

## Self-Review

**1. Spec coverage:**

| Spec 섹션 | 구현 task |
|---|---|
| 2.1 skills/<slug>/SKILL.md walk + frontmatter 파싱 | Task 2 (parser), Task 3 (walker) |
| 2.1 좌측 카드 + 검색 + 메타 칩 | Task 5 |
| 2.1 우측 메타 박스 + 마크다운 | Task 6 |
| 2.1 silent skip 금지(파싱 실패 ⚠️) | Task 2 (parse_error 필드), Task 5 (배지), Task 6 (빨간 표시), Task 7 (회귀 검증) |
| 2.1 빈 상태 안내 + `aib sync` 힌트 | Task 5 (UX), Task 7 (회귀 검증) |
| 4 컴포넌트/파일 변경 | Task 1 (UI scaffold), Task 2~4 (Rust), Task 5~6 (UI 풀구현) |
| 5 데이터 모델 | Task 1 (TS), Task 2 (Rust) |
| 7 오류 처리 | Task 2 (분기), Task 7 (회귀) |
| 8 테스트 | Task 2/3/4 (Rust unit), Task 5/6/7 (수동 E2E) |
| 10 릴리즈 전략 | Task 8 |

모든 spec 섹션이 task에 매핑됨. 갭 없음.

**2. Placeholder scan:**

- "TBD" / "TODO" / "implement later": 없음
- "Add appropriate error handling" 등 vague: 없음 — 모든 오류 처리는 Task 2의 4가지 분기 + Task 7 회귀 검증으로 명시
- 코드 단계마다 코드 블록 포함됨

**3. Type consistency:**

- `SkillCard` 필드: `slug` `name` `description` `aib_version` `upstream` `argument_hint` `parse_error` — Task 1 (TS) ↔ Task 2 (Rust serde tag `argument-hint` → snake_case `argument_hint`로 변환됨, frontmatter 키는 hyphen) 일관
- `SkillsIndex` 필드: `skills` `skills_dir_exists` — Task 1 (TS) ↔ Task 3 (Rust) 일관
- 명령 이름: `get_skills_index` / `get_skill_content` — Task 3/4 등록 ↔ Task 5/6 invoke 일관

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-08-skills-catalog-tab.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
