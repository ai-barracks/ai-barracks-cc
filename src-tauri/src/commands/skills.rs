use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone, Default, PartialEq)]
pub struct SkillCard {
    pub slug: String,
    pub name: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub aib_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    #[serde(rename(deserialize = "argument-hint"), default, skip_serializing_if = "Option::is_none")]
    pub argument_hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parse_error: Option<String>,
}

/// Task 3의 get_skills_index 명령에서 반환 — 카탈로그 카드 목록과 디렉터리 존재 여부.
#[derive(Debug, Serialize)]
pub struct SkillsIndex {
    pub skills: Vec<SkillCard>,
    pub skills_dir_exists: bool,
}

/// frontmatter YAML만 담는 중간 구조체.
/// slug와 parse_error는 호출자가 채우므로 제외.
#[derive(Debug, Deserialize, Default)]
struct SkillFrontmatter {
    #[serde(default)]
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    aib_version: Option<String>,
    #[serde(default)]
    upstream: Option<String>,
    #[serde(rename = "argument-hint", default)]
    argument_hint: Option<String>,
}

/// Write-side frontmatter struct. Used by create_skill / update_skill.
/// Custom fields go into `custom` (serde_yaml::Mapping) so users can add arbitrary frontmatter keys.
#[derive(Debug, Deserialize, Serialize, Default, Clone)]
pub struct SkillFrontmatterWrite {
    pub name: String,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub argument_hint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allowed_tools: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aib_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upstream: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub growth_origin: Option<String>,
    #[serde(default)]
    pub custom: serde_yaml::Mapping,
}

/// Render `SkillFrontmatterWrite` to a YAML string suitable for the SKILL.md frontmatter
/// block (between `---` fences). Uses hyphen keys for `argument-hint` / `allowed-tools`
/// to match the Anthropic Agent Skills standard. The rendered string ends in a trailing newline.
pub fn render_frontmatter_yaml(fm: &SkillFrontmatterWrite) -> String {
    use serde_yaml::Value;
    let mut map = serde_yaml::Mapping::new();
    map.insert(Value::String("name".into()), Value::String(fm.name.clone()));
    map.insert(Value::String("description".into()), Value::String(fm.description.clone()));
    if let Some(v) = &fm.argument_hint {
        map.insert(Value::String("argument-hint".into()), Value::String(v.clone()));
    }
    if let Some(v) = &fm.allowed_tools {
        map.insert(Value::String("allowed-tools".into()), Value::String(v.clone()));
    }
    if let Some(v) = &fm.aib_version {
        map.insert(Value::String("aib_version".into()), Value::String(v.clone()));
    }
    if let Some(v) = &fm.upstream {
        map.insert(Value::String("upstream".into()), Value::String(v.clone()));
    }
    if let Some(v) = &fm.growth_origin {
        map.insert(Value::String("growth_origin".into()), Value::String(v.clone()));
    }
    for (k, v) in &fm.custom {
        map.insert(k.clone(), v.clone());
    }
    serde_yaml::to_string(&Value::Mapping(map))
        .unwrap_or_else(|_| "name: invalid\ndescription: invalid\n".to_string())
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
        // EOF 케이스: 파일이 trailing newline 없이 "...\n---"로 끝남
        if after_open.ends_with("\n---") {
            // YAML 끝 = "\n---" 시작 위치. find("\n---\n")가 \n 위치를 반환하는 것과 일관되게.
            Some(after_open.len() - "\n---".len())
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
    match serde_yaml::from_str::<SkillFrontmatter>(yaml) {
        Ok(fm) => {
            let name = if fm.name.is_empty() {
                slug.to_string()
            } else {
                fm.name
            };
            SkillCard {
                slug: slug.to_string(),
                name,
                description: fm.description,
                aib_version: fm.aib_version,
                upstream: fm.upstream,
                argument_hint: fm.argument_hint,
                parse_error: None,
            }
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

fn walk_skills_dir(skills_dir: &Path) -> Vec<SkillCard> {
    let mut cards = Vec::new();
    let entries = match fs::read_dir(skills_dir) {
        Ok(e) => e,
        Err(_) => return cards,
    };
    let mut slugs: Vec<(String, PathBuf)> = Vec::new();
    // 개별 entry의 IO 에러는 silent skip (transient FS 이슈에 graceful).
    // 영속적 에러는 카드 누락으로 나타남 — 디렉터리 자체 read_dir 실패는 위에서 빈 Vec 반환.
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
        match fs::read_to_string(&skill_md) {
            Ok(content) => cards.push(parse_skill_md(&slug, &content)),
            Err(e) => cards.push(SkillCard {
                slug: slug.clone(),
                name: slug.clone(),
                description: String::new(),
                parse_error: Some(format!("SKILL.md 읽기 실패: {}", e)),
                ..Default::default()
            }),
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_frontmatter() {
        // slug와 name을 다르게 해서 name이 YAML에서 왔는지 / slug fallback인지 구분 가능하게 함
        let input = "---\nname: pretty-name\ndescription: bar\naib_version: \"1.1\"\n---\nBody text\n";
        let card = parse_skill_md("my-slug", input);
        assert_eq!(card.slug, "my-slug");
        assert_eq!(card.name, "pretty-name");  // YAML의 name이 사용됨 (slug fallback 아님)
        assert_eq!(card.description, "bar");
        assert_eq!(card.aib_version, Some("1.1".to_string()));
        assert!(card.parse_error.is_none(), "expected no parse_error, got {:?}", card.parse_error);
    }

    #[test]
    fn parses_argument_hint_with_hyphen_yaml_key() {
        // YAML의 'argument-hint' (hyphen)이 Rust의 argument_hint (underscore)로 매핑되는지 확인
        let input = "---\nname: council\ndescription: x\nargument-hint: \"<topic> -m debate\"\n---\nbody\n";
        let card = parse_skill_md("council", input);
        assert!(card.parse_error.is_none(), "expected no parse_error, got {:?}", card.parse_error);
        assert_eq!(card.argument_hint, Some("<topic> -m debate".to_string()));
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

    use std::fs::{self as test_fs, File};
    use std::io::Write;
    use tempfile::TempDir;

    fn write_skill(dir: &Path, slug: &str, content: &str) {
        let sub = dir.join(slug);
        test_fs::create_dir_all(&sub).unwrap();
        let mut f = File::create(sub.join("SKILL.md")).unwrap();
        f.write_all(content.as_bytes()).unwrap();
    }

    #[test]
    fn empty_dir_returns_no_cards() {
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("skills");
        test_fs::create_dir_all(&skills_dir).unwrap();
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
        test_fs::create_dir_all(skills_dir.join("not_a_skill")).unwrap();
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

    #[test]
    fn read_failure_surfaces_as_distinct_parse_error() {
        // SKILL.md 자리에 디렉터리를 만들면 read_to_string은 IO Err 반환.
        // walk_skills_dir은 이를 "SKILL.md 읽기 실패: ..."로 분류해야 함.
        let tmp = TempDir::new().unwrap();
        let skills_dir = tmp.path().join("skills");
        // (macOS/Linux에서 chmod 000 파일은 read 실패를 일으킨다.)
        use std::os::unix::fs::PermissionsExt;
        test_fs::create_dir_all(skills_dir.join("noperm")).unwrap();
        let path = skills_dir.join("noperm").join("SKILL.md");
        File::create(&path).unwrap().write_all(b"---\nname: x\n---\n").unwrap();
        let mut perms = test_fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o000);
        test_fs::set_permissions(&path, perms).unwrap();

        let cards = walk_skills_dir(&skills_dir);
        // 권한 복구해서 cleanup이 가능하게
        let mut restore = test_fs::metadata(&path).unwrap().permissions();
        restore.set_mode(0o644);
        let _ = test_fs::set_permissions(&path, restore);

        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].slug, "noperm");
        let err = cards[0].parse_error.as_deref().unwrap_or("");
        assert!(
            err.contains("읽기 실패"),
            "expected '읽기 실패' in parse_error, got {:?}", cards[0].parse_error
        );
    }

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

    #[test]
    fn serializes_argument_hint_with_underscore_for_tauri() {
        // Tauri는 SkillCard를 serde_json으로 직렬화해 frontend로 전달.
        // TS interface가 argument_hint (underscore)를 기대하므로 JSON 키도 underscore여야 함.
        // YAML deserialize는 hyphen("argument-hint")을 받아야 함 → 양방향 mismatch가 의도된 동작.
        use serde_json;
        let card = SkillCard {
            slug: "council".to_string(),
            name: "council".to_string(),
            description: "x".to_string(),
            argument_hint: Some("<topic>".to_string()),
            ..Default::default()
        };
        let json = serde_json::to_string(&card).unwrap();
        assert!(
            json.contains("\"argument_hint\""),
            "JSON must use underscore key for TS compatibility, got: {}", json
        );
        assert!(
            !json.contains("\"argument-hint\""),
            "hyphen key must NOT appear in serialized output (would break frontend), got: {}", json
        );
    }

    #[test]
    fn frontmatter_for_write_serializes_with_hyphen_keys() {
        // RULES.md [2026-05-09] Tauri-Serde-Rename-Bidirectional-Trap regression test.
        // YAML written to disk MUST use hyphen keys (Anthropic Agent Skills standard),
        // not the underscore Rust field names.
        let fm = SkillFrontmatterWrite {
            name: "council".to_string(),
            description: "Test description that is at least 20 chars.".to_string(),
            argument_hint: Some("<topic>".to_string()),
            allowed_tools: Some("Bash(./scripts/x *)".to_string()),
            aib_version: Some("1.1".to_string()),
            upstream: None,
            growth_origin: Some("manual".to_string()),
            custom: Default::default(),
        };
        let yaml = render_frontmatter_yaml(&fm);
        assert!(yaml.contains("argument-hint:"), "must use hyphen key for argument-hint, got:\n{}", yaml);
        assert!(yaml.contains("allowed-tools:"), "must use hyphen key for allowed-tools");
        assert!(!yaml.contains("argument_hint:"), "must NOT serialize underscore form");
        assert!(!yaml.contains("allowed_tools:"), "must NOT serialize underscore form");
    }
}
