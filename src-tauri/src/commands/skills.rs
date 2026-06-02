use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Backend slug validator (defense-in-depth; frontend also validates).
/// Accepts: lowercase ASCII letter followed by lowercase letters, digits, or '-'.
/// Rejects: uppercase, dot-prefixed, empty, leading hyphen, slashes, `..`, etc.
fn validate_slug(slug: &str) -> Result<(), String> {
    if slug.is_empty() {
        return Err("slug is empty".into());
    }
    let bytes = slug.as_bytes();
    if !bytes[0].is_ascii_lowercase() {
        return Err(format!(
            "invalid slug '{}': must start with a lowercase letter [a-z]",
            slug
        ));
    }
    for &b in &bytes[1..] {
        let ok = b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-';
        if !ok {
            return Err(format!(
                "invalid slug '{}': only [a-z0-9-] allowed after the first char",
                slug
            ));
        }
    }
    Ok(())
}

/// Resolve `<barrack>/skills` to its canonical path if it exists.
/// Returns `Ok(None)` when the entry is genuinely missing (caller may create it).
/// Returns `Err` when the entry is present but unsafe — a broken symlink, a
/// non-directory, or a symlink whose canonical target escapes the canonical
/// barrack root. `symlink_metadata` is used so a broken symlink at the
/// `skills/` slot is detected as *present* rather than silently treated as
/// missing (which would otherwise let `create_dir_all` follow it and create
/// the dangling target outside the barrack).
fn lookup_skills_root(barrack: &Path) -> Result<Option<PathBuf>, String> {
    let skills_dir = barrack.join("skills");
    match fs::symlink_metadata(&skills_dir) {
        Ok(md) => {
            // Non-symlink entries must already be directories. Symlinks are
            // validated by the canonical-prefix check below.
            if !md.file_type().is_symlink() && !md.is_dir() {
                return Err("skills 경로가 디렉터리가 아님".into());
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("skills 디렉터리 확인 실패: {}", e)),
    }
    let canon_barrack = fs::canonicalize(barrack)
        .map_err(|e| format!("barrack 정규화 실패: {}", e))?;
    let canon_skills = fs::canonicalize(&skills_dir)
        .map_err(|e| format!("skills 디렉터리 정규화 실패: {}", e))?;
    if !canon_skills.starts_with(&canon_barrack) {
        return Err("skills 디렉터리가 barrack 루트를 벗어남".into());
    }
    if !canon_skills.is_dir() {
        return Err("skills 경로가 디렉터리가 아님".into());
    }
    Ok(Some(canon_skills))
}

/// Defense-in-depth: ensure the resolved `<barrack>/skills/<slug>` path stays
/// under the canonical `<barrack>/skills` directory. `validate_slug` already
/// rejects any traversal pattern, but this catches symlink-based escapes too.
/// Returns the canonical skills_dir on success so callers can reuse it.
fn ensure_under_skills(barrack: &Path, slug: &str) -> Result<PathBuf, String> {
    let canon_skills = match lookup_skills_root(barrack)? {
        Some(p) => p,
        None => {
            // Truly missing — create as a regular directory under barrack.
            let skills_dir = barrack.join("skills");
            fs::create_dir_all(&skills_dir)
                .map_err(|e| format!("skills 디렉터리 생성 실패: {}", e))?;
            match lookup_skills_root(barrack)? {
                Some(p) => p,
                None => return Err("skills 디렉터리 생성 후에도 해석 실패".into()),
            }
        }
    };
    // If the candidate exists (regular dir/file OR a symlink, including a
    // broken one), follow symlinks and verify the real target stays inside.
    // Using symlink_metadata here means a broken symlink is treated as present
    // and rejected by the canonicalize failure below, rather than silently
    // appearing as "missing" via the symlink-following `exists()`.
    let candidate = canon_skills.join(slug);
    match fs::symlink_metadata(&candidate) {
        Ok(_) => {
            let canon = fs::canonicalize(&candidate)
                .map_err(|e| format!("skill 경로 정규화 실패: {}", e))?;
            if !canon.starts_with(&canon_skills) {
                return Err("경로가 skills 디렉터리를 벗어남".into());
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(format!("skill 경로 확인 실패: {}", e)),
    }
    Ok(canon_skills)
}

/// Defense-in-depth: when an existing `<canon_skills>/<slug>/SKILL.md` is about
/// to be read or written, verify it canonicalizes inside the canonical skill
/// directory. `ensure_under_skills` only validates the slug *directory*; a
/// SKILL.md file inside that directory could still be a symlink that points
/// outside, letting an attacker make us read or overwrite arbitrary files.
/// Uses `symlink_metadata` so a broken SKILL.md symlink is detected as present
/// (and rejected when canonicalize fails) rather than misclassified as missing.
/// No-op when SKILL.md does not yet exist (used by create path).
fn ensure_skill_md_inside(canon_skills: &Path, slug: &str) -> Result<(), String> {
    let skill_dir = canon_skills.join(slug);
    let skill_md = skill_dir.join("SKILL.md");
    match fs::symlink_metadata(&skill_md) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("SKILL.md 확인 실패: {}", e)),
    }
    let canon_skill_dir = fs::canonicalize(&skill_dir)
        .map_err(|e| format!("skill 디렉터리 정규화 실패: {}", e))?;
    if !canon_skill_dir.starts_with(canon_skills) {
        return Err("skill 디렉터리가 skills 루트를 벗어남".into());
    }
    let canon_md = fs::canonicalize(&skill_md)
        .map_err(|e| format!("SKILL.md 정규화 실패: {}", e))?;
    if !canon_md.starts_with(&canon_skill_dir) {
        return Err("SKILL.md 경로가 skill 디렉터리를 벗어남".into());
    }
    Ok(())
}

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
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "argument-hint")]
    pub argument_hint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "allowed-tools")]
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

/// Inner implementation testable without Tauri runtime. Takes a `Path` (not String) so unit tests
/// can use tempdir paths directly.
pub fn create_skill_impl(
    barrack: &Path,
    slug: &str,
    frontmatter: &SkillFrontmatterWrite,
    body: &str,
) -> Result<(), String> {
    validate_slug(slug)?;
    let canon_skills = ensure_under_skills(barrack, slug)?;
    let skill_dir = canon_skills.join(slug);
    if skill_dir.exists() {
        return Err(format!("skill already exists: {}", slug));
    }
    fs::create_dir_all(&skill_dir).map_err(|e| format!("create_dir_all failed: {}", e))?;
    let yaml = render_frontmatter_yaml(frontmatter);
    let mut content = String::with_capacity(yaml.len() + body.len() + 16);
    content.push_str("---\n");
    content.push_str(&yaml);
    content.push_str("---\n\n");
    content.push_str(body);
    if !body.ends_with('\n') {
        content.push('\n');
    }
    fs::write(skill_dir.join("SKILL.md"), content)
        .map_err(|e| format!("write SKILL.md failed: {}", e))
}

#[tauri::command]
pub fn create_skill(
    barrack_path: String,
    slug: String,
    frontmatter: SkillFrontmatterWrite,
    body: String,
) -> Result<(), String> {
    create_skill_impl(Path::new(&barrack_path), &slug, &frontmatter, &body)
}

pub fn update_skill_impl(
    barrack: &Path,
    slug: &str,
    frontmatter: &SkillFrontmatterWrite,
    body: &str,
) -> Result<(), String> {
    validate_slug(slug)?;
    let canon_skills = ensure_under_skills(barrack, slug)?;
    let skill_md = canon_skills.join(slug).join("SKILL.md");
    // symlink_metadata so a broken SKILL.md symlink registers as "present" and
    // is rejected by ensure_skill_md_inside below, not silently mis-reported
    // as "not found" via the symlink-following exists().
    match fs::symlink_metadata(&skill_md) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(format!("skill not found: {}", slug));
        }
        Err(e) => return Err(format!("SKILL.md 확인 실패: {}", e)),
    }
    // Catch SKILL.md symlinks that point outside the skill dir before writing.
    ensure_skill_md_inside(&canon_skills, slug)?;
    let yaml = render_frontmatter_yaml(frontmatter);
    let mut content = String::with_capacity(yaml.len() + body.len() + 16);
    content.push_str("---\n");
    content.push_str(&yaml);
    content.push_str("---\n\n");
    content.push_str(body);
    if !body.ends_with('\n') {
        content.push('\n');
    }
    fs::write(&skill_md, content).map_err(|e| format!("write SKILL.md failed: {}", e))
}

#[tauri::command]
pub fn update_skill(
    barrack_path: String,
    slug: String,
    frontmatter: SkillFrontmatterWrite,
    body: String,
) -> Result<(), String> {
    update_skill_impl(Path::new(&barrack_path), &slug, &frontmatter, &body)
}

pub fn delete_skill_impl(barrack: &Path, slug: &str) -> Result<(), String> {
    validate_slug(slug)?;
    let canon_skills = ensure_under_skills(barrack, slug)?;
    let skill_dir = canon_skills.join(slug);
    if !skill_dir.exists() {
        return Err(format!("skill not found: {}", slug));
    }
    fs::remove_dir_all(&skill_dir).map_err(|e| format!("remove_dir_all failed: {}", e))
}

#[tauri::command]
pub fn delete_skill(barrack_path: String, slug: String) -> Result<(), String> {
    delete_skill_impl(Path::new(&barrack_path), &slug)
}

pub fn rename_skill_impl(barrack: &Path, old_slug: &str, new_slug: &str) -> Result<(), String> {
    validate_slug(old_slug)?;
    validate_slug(new_slug)?;
    let canon_skills = ensure_under_skills(barrack, old_slug)?;
    // Also re-check the new slug for symlink-escape (its target may already exist).
    let _ = ensure_under_skills(barrack, new_slug)?;
    let old_dir = canon_skills.join(old_slug);
    let new_dir = canon_skills.join(new_slug);
    if !old_dir.exists() {
        return Err(format!("skill not found: {}", old_slug));
    }
    if new_dir.exists() {
        return Err(format!("target slug already exists: {}", new_slug));
    }
    // Validate the existing SKILL.md is not a symlink escape before renaming;
    // post-rename we'd have to read+write through the same symlink for the
    // `name:` update, which would touch an out-of-tree file.
    ensure_skill_md_inside(&canon_skills, old_slug)?;
    fs::rename(&old_dir, &new_dir).map_err(|e| format!("rename failed: {}", e))?;

    // Update the `name:` line inside the moved SKILL.md.
    let skill_md = new_dir.join("SKILL.md");
    if skill_md.exists() {
        // Defense-in-depth: re-verify under the new slug post-rename in case
        // anything raced. (The pre-rename check already validated the file.)
        ensure_skill_md_inside(&canon_skills, new_slug)?;
        let content = fs::read_to_string(&skill_md).map_err(|e| format!("read SKILL.md failed: {}", e))?;
        let updated = update_name_in_frontmatter(&content, new_slug);
        fs::write(&skill_md, updated).map_err(|e| format!("write SKILL.md failed: {}", e))?;
    }
    Ok(())
}

/// Replaces the `name:` line inside a SKILL.md frontmatter block with the new slug.
/// Operates only on the first frontmatter block (between leading --- fences). If no
/// frontmatter exists, returns the input unchanged. The body is left untouched.
fn update_name_in_frontmatter(content: &str, new_name: &str) -> String {
    let normalized = content.replace("\r\n", "\n");
    let after_open = match normalized.strip_prefix("---\n") {
        Some(s) => s,
        None => return content.to_string(),
    };
    let close_idx = match after_open.find("\n---\n") {
        Some(i) => i,
        None => return content.to_string(),
    };
    let frontmatter = &after_open[..close_idx];
    let rest = &after_open[close_idx..]; // starts with "\n---\n"

    let mut new_fm = String::with_capacity(frontmatter.len() + new_name.len());
    let mut name_replaced = false;
    for line in frontmatter.lines() {
        if !name_replaced && line.trim_start().starts_with("name:") {
            new_fm.push_str(&format!("name: {}", new_name));
            new_fm.push('\n');
            name_replaced = true;
        } else {
            new_fm.push_str(line);
            new_fm.push('\n');
        }
    }
    // Strip the trailing extra newline that would otherwise duplicate
    if new_fm.ends_with('\n') {
        new_fm.pop();
    }

    let mut out = String::with_capacity(content.len() + 16);
    out.push_str("---\n");
    out.push_str(&new_fm);
    out.push_str(rest);
    out
}

#[tauri::command]
pub fn rename_skill(
    barrack_path: String,
    old_slug: String,
    new_slug: String,
) -> Result<(), String> {
    rename_skill_impl(Path::new(&barrack_path), &old_slug, &new_slug)
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
        // symlink_metadata so we never follow a symlinked skill dir or
        // SKILL.md (defense against symlink-escape reads). Skipping the
        // entry is the least disruptive choice: a hostile symlink simply
        // does not appear in the index.
        let md = match fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if md.file_type().is_symlink() || !md.is_dir() {
            continue;
        }
        let skill_md = path.join("SKILL.md");
        let md_md = match fs::symlink_metadata(&skill_md) {
            Ok(m) => m,
            Err(_) => continue, // SKILL.md 없는 디렉터리는 skill 후보 아님
        };
        if md_md.file_type().is_symlink() || !md_md.is_file() {
            continue;
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
    let barrack = PathBuf::from(&barrack_path);
    // lookup_skills_root rejects an escaping/broken/non-dir skills entry and
    // returns None only when the directory is genuinely absent. Walking the
    // canonical path guarantees we never read across a symlinked skills root.
    let canon_skills = match lookup_skills_root(&barrack)? {
        Some(p) => p,
        None => {
            return Ok(SkillsIndex {
                skills: Vec::new(),
                skills_dir_exists: false,
            });
        }
    };
    let skills = walk_skills_dir(&canon_skills);
    Ok(SkillsIndex {
        skills,
        skills_dir_exists: true,
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

pub fn get_skill_content_impl(barrack: &Path, slug: &str) -> Result<String, String> {
    validate_slug(slug)?;
    let canon_skills = ensure_under_skills(barrack, slug)?;
    // Catch SKILL.md symlinks that point outside the skill dir before reading.
    ensure_skill_md_inside(&canon_skills, slug)?;
    let path = canon_skills.join(slug).join("SKILL.md");
    let content = fs::read_to_string(&path).map_err(|e| format!("SKILL.md 읽기 실패: {}", e))?;
    Ok(extract_body(&content))
}

#[tauri::command]
pub fn get_skill_content(barrack_path: String, slug: String) -> Result<String, String> {
    get_skill_content_impl(Path::new(&barrack_path), &slug)
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

    #[test]
    fn create_skill_writes_md_with_frontmatter_and_body() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        // Pre-create skills/ so create_skill doesn't have to mkdir parent
        test_fs::create_dir_all(barrack.join("skills")).unwrap();

        let fm = SkillFrontmatterWrite {
            name: "kanban".into(),
            description: "Lightweight kanban board for the barrack.".into(),
            argument_hint: Some("[--limit N]".into()),
            ..Default::default()
        };
        let body = "# Kanban\n\n## When to invoke\n- Daily standup planning\n";

        create_skill_impl(barrack, "kanban", &fm, body).expect("create should succeed");

        let written = test_fs::read_to_string(barrack.join("skills/kanban/SKILL.md")).unwrap();
        assert!(written.starts_with("---\n"));
        assert!(written.contains("name: kanban"));
        assert!(written.contains("description: Lightweight kanban"));
        assert!(written.contains("argument-hint:"));  // hyphen key (Task 1 invariant)
        assert!(written.contains("\n---\n"));          // closing fence
        assert!(written.contains("# Kanban"));         // body
    }

    #[test]
    fn create_skill_errors_on_collision() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        test_fs::create_dir_all(barrack.join("skills/kanban")).unwrap();
        File::create(barrack.join("skills/kanban/SKILL.md")).unwrap();

        let fm = SkillFrontmatterWrite {
            name: "kanban".into(),
            description: "x".repeat(20),
            ..Default::default()
        };
        let err = create_skill_impl(barrack, "kanban", &fm, "body").expect_err("must reject existing slug");
        assert!(err.contains("already exists"), "expected 'already exists' in error, got: {}", err);
    }

    #[test]
    fn update_skill_overwrites_md_when_exists() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        // Seed an existing skill via create_skill_impl
        let fm0 = SkillFrontmatterWrite {
            name: "council".into(),
            description: "Original description meeting min length.".into(),
            ..Default::default()
        };
        create_skill_impl(barrack, "council", &fm0, "old body").unwrap();

        // Update with new content
        let fm1 = SkillFrontmatterWrite {
            name: "council".into(),
            description: "New description with at least twenty chars.".into(),
            ..Default::default()
        };
        update_skill_impl(barrack, "council", &fm1, "## New body\n").unwrap();

        let written = test_fs::read_to_string(barrack.join("skills/council/SKILL.md")).unwrap();
        assert!(written.contains("New description"));
        assert!(written.contains("## New body"));
        assert!(!written.contains("Original description"));
        assert!(!written.contains("old body"));
    }

    #[test]
    fn update_skill_errors_on_missing_slug() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        test_fs::create_dir_all(barrack.join("skills")).unwrap();
        let fm = SkillFrontmatterWrite {
            name: "ghost".into(),
            description: "Ghost skill must not be writable as update.".into(),
            ..Default::default()
        };
        let err = update_skill_impl(barrack, "ghost", &fm, "body").expect_err("must reject missing slug");
        assert!(err.contains("not found"));
    }

    #[test]
    fn delete_skill_removes_dir_recursive() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        let skill_dir = barrack.join("skills/oldskill");
        let scripts_dir = skill_dir.join("scripts");
        test_fs::create_dir_all(&scripts_dir).unwrap();
        File::create(skill_dir.join("SKILL.md")).unwrap();
        File::create(scripts_dir.join("run.sh")).unwrap();

        delete_skill_impl(barrack, "oldskill").unwrap();

        assert!(!skill_dir.exists(), "skill dir should be removed recursively");
    }

    #[test]
    fn delete_skill_errors_on_missing_slug() {
        let tmp = tempfile::tempdir().unwrap();
        let err = delete_skill_impl(tmp.path(), "nonexistent").expect_err("must reject missing slug");
        assert!(err.contains("not found"));
    }

    #[test]
    fn rename_skill_moves_dir_and_updates_name_field() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        let fm = SkillFrontmatterWrite {
            name: "oldname".into(),
            description: "Original twenty-char description.".into(),
            argument_hint: Some("<arg>".into()),
            ..Default::default()
        };
        create_skill_impl(barrack, "oldname", &fm, "body content").unwrap();

        rename_skill_impl(barrack, "oldname", "newname").unwrap();

        assert!(!barrack.join("skills/oldname").exists(), "old dir should be gone");
        assert!(barrack.join("skills/newname/SKILL.md").exists(), "new dir should exist");
        let content = test_fs::read_to_string(barrack.join("skills/newname/SKILL.md")).unwrap();
        assert!(content.contains("name: newname"), "name field must be updated");
        assert!(!content.contains("name: oldname"), "old name must be replaced");
        assert!(content.contains("argument-hint:"), "other frontmatter fields preserved");
        assert!(content.contains("body content"), "body preserved");
    }

    #[test]
    fn rename_skill_errors_on_target_collision() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        let fm = SkillFrontmatterWrite {
            name: "a".into(),
            description: "x".repeat(20),
            ..Default::default()
        };
        create_skill_impl(barrack, "a", &fm, "body").unwrap();
        create_skill_impl(barrack, "b", &fm, "body").unwrap();

        let err = rename_skill_impl(barrack, "a", "b").expect_err("must reject existing target slug");
        assert!(err.contains("already exists") || err.contains("collision"));
        // Source preserved on error
        assert!(barrack.join("skills/a").exists(), "source must remain on error");
    }

    #[test]
    fn frontmatter_write_deserializes_hyphen_keys_from_json() {
        // Critical regression: when frontend invokes create_skill/update_skill, JSON keys
        // are hyphen-cased ("argument-hint", "allowed-tools") to match the Anthropic Agent
        // Skills standard. Without #[serde(rename = "...")] on the underscore Rust fields,
        // these are silently dropped during deserialization, losing user input.
        //
        // This is the inverse direction of RULES.md [2026-05-09] Tauri-Serde-Rename-
        // Bidirectional-Trap (which originally addressed Rust→frontend serialize).
        let json = r#"{
            "name":"x",
            "description":"twenty-char description!!",
            "argument-hint":"<a>",
            "allowed-tools":"Bash(*)"
        }"#;
        let fm: SkillFrontmatterWrite = serde_json::from_str(json).expect("deserialize must succeed");
        assert_eq!(fm.argument_hint.as_deref(), Some("<a>"), "argument-hint must deserialize into Rust argument_hint");
        assert_eq!(fm.allowed_tools.as_deref(), Some("Bash(*)"), "allowed-tools must deserialize into Rust allowed_tools");
    }

    // ---- AIBCC-002: slug validation + traversal defense-in-depth ----

    #[test]
    fn validate_slug_accepts_well_formed() {
        for slug in ["a", "ab", "a1", "kanban", "kanban-board", "council-x-2"] {
            validate_slug(slug).unwrap_or_else(|e| panic!("slug {} should pass: {}", slug, e));
        }
    }

    #[test]
    fn validate_slug_rejects_malformed() {
        let bad = [
            "",          // empty
            ".hidden",   // dot prefix
            "..",        // dotdot
            "../evil",   // traversal
            "a/b",       // slash
            "a\\b",      // backslash
            "Aupper",    // uppercase first
            "abC",       // uppercase mid
            "-bad",      // leading hyphen
            "1bad",      // leading digit
            "name_us",   // underscore
            "name space",// space
            "name.ext",  // dot
        ];
        for slug in bad {
            assert!(
                validate_slug(slug).is_err(),
                "slug {:?} should be rejected",
                slug
            );
        }
    }

    #[test]
    fn create_update_delete_get_rename_reject_invalid_slugs() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        let fm = SkillFrontmatterWrite {
            name: "x".into(),
            description: "x".repeat(20),
            ..Default::default()
        };
        for bad in ["../evil", "a/b", ".hidden", "", "Aupper", "-bad"] {
            assert!(
                create_skill_impl(barrack, bad, &fm, "body").is_err(),
                "create must reject {:?}",
                bad
            );
            assert!(
                update_skill_impl(barrack, bad, &fm, "body").is_err(),
                "update must reject {:?}",
                bad
            );
            assert!(
                delete_skill_impl(barrack, bad).is_err(),
                "delete must reject {:?}",
                bad
            );
            assert!(
                get_skill_content_impl(barrack, bad).is_err(),
                "get_skill_content must reject {:?}",
                bad
            );
            assert!(
                rename_skill_impl(barrack, bad, "valid").is_err(),
                "rename (old={:?}) must reject",
                bad
            );
            assert!(
                rename_skill_impl(barrack, "valid", bad).is_err(),
                "rename (new={:?}) must reject",
                bad
            );
        }
    }

    #[test]
    fn traversal_attempts_do_not_escape_skills_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        // Create a decoy file outside the barrack to confirm we never touch it.
        let sentinel_dir = tempfile::tempdir().unwrap();
        let sentinel = sentinel_dir.path().join("agent.yaml");
        test_fs::write(&sentinel, "untouched").unwrap();

        let fm = SkillFrontmatterWrite {
            name: "x".into(),
            description: "x".repeat(20),
            ..Default::default()
        };

        // Even if attacker passes a slug that string-concatenates outside, validation rejects.
        let escape = "../../foo";
        assert!(create_skill_impl(barrack, escape, &fm, "body").is_err());
        assert!(delete_skill_impl(barrack, escape).is_err());

        // The decoy is unchanged
        let after = test_fs::read_to_string(&sentinel).unwrap();
        assert_eq!(after, "untouched");

        // No directory was created at the escape target
        assert!(
            !barrack
                .parent()
                .map(|p| p.join("foo").exists())
                .unwrap_or(false),
            "must not have created sibling 'foo' dir"
        );
    }

    /// Test helper: build `<barrack>/skills/<slug>/` with `SKILL.md` as a
    /// symlink to a file outside the barrack. Returns (barrack tmpdir,
    /// outside tmpdir, outside file path) so tests can assert the outside
    /// file is left untouched.
    #[cfg(unix)]
    fn setup_skill_with_md_symlink_escape(slug: &str) -> (TempDir, TempDir, PathBuf) {
        use std::os::unix::fs::symlink;
        let outside = TempDir::new().unwrap();
        let outside_file = outside.path().join("evil.md");
        test_fs::write(&outside_file, "untouched").unwrap();

        let barrack = TempDir::new().unwrap();
        let skill_dir = barrack.path().join("skills").join(slug);
        test_fs::create_dir_all(&skill_dir).unwrap();
        symlink(&outside_file, skill_dir.join("SKILL.md")).unwrap();

        (barrack, outside, outside_file)
    }

    #[test]
    fn update_skill_rejects_skill_md_symlink_escape() {
        #[cfg(unix)]
        {
            let (barrack, _outside, outside_file) =
                setup_skill_with_md_symlink_escape("council");
            let fm = SkillFrontmatterWrite {
                name: "council".into(),
                description: "x".repeat(20),
                ..Default::default()
            };
            let err = update_skill_impl(barrack.path(), "council", &fm, "pwn")
                .expect_err("update must reject SKILL.md symlink escape");
            assert!(err.contains("벗어남"), "got: {}", err);
            // Outside file unchanged.
            let after = test_fs::read_to_string(&outside_file).unwrap();
            assert_eq!(after, "untouched");
        }
    }

    #[test]
    fn get_skill_content_rejects_skill_md_symlink_escape() {
        #[cfg(unix)]
        {
            let (barrack, _outside, outside_file) =
                setup_skill_with_md_symlink_escape("council");
            let err = get_skill_content_impl(barrack.path(), "council")
                .expect_err("get must reject SKILL.md symlink escape");
            assert!(err.contains("벗어남"), "got: {}", err);
            // Outside file unchanged (read attempt didn't happen).
            let after = test_fs::read_to_string(&outside_file).unwrap();
            assert_eq!(after, "untouched");
        }
    }

    #[test]
    fn rename_skill_rejects_skill_md_symlink_escape() {
        #[cfg(unix)]
        {
            let (barrack, _outside, outside_file) =
                setup_skill_with_md_symlink_escape("oldname");
            let err = rename_skill_impl(barrack.path(), "oldname", "newname")
                .expect_err("rename must reject SKILL.md symlink escape");
            assert!(err.contains("벗어남"), "got: {}", err);
            // Outside file unchanged: the `name:` update never executed.
            let after = test_fs::read_to_string(&outside_file).unwrap();
            assert_eq!(after, "untouched");
            // Source dir preserved on error (pre-rename validation).
            assert!(
                barrack.path().join("skills/oldname").exists(),
                "old slug dir must remain when rename is rejected"
            );
            assert!(
                !barrack.path().join("skills/newname").exists(),
                "new slug dir must not have been created"
            );
        }
    }

    #[test]
    fn create_skill_path_unchanged_by_skill_md_check() {
        // Regression: ensure_skill_md_inside is a no-op when SKILL.md does not
        // exist, so create_skill_impl still works on a fresh slug.
        let tmp = tempfile::tempdir().unwrap();
        let fm = SkillFrontmatterWrite {
            name: "fresh".into(),
            description: "twenty-char description here.".into(),
            ..Default::default()
        };
        create_skill_impl(tmp.path(), "fresh", &fm, "body").unwrap();
        assert!(tmp.path().join("skills/fresh/SKILL.md").exists());
    }

    #[test]
    fn valid_existing_skill_paths_still_pass() {
        // Regression: make sure legitimate slugs continue to work end-to-end.
        let tmp = tempfile::tempdir().unwrap();
        let barrack = tmp.path();
        let fm = SkillFrontmatterWrite {
            name: "council".into(),
            description: "A perfectly valid skill description.".into(),
            ..Default::default()
        };
        create_skill_impl(barrack, "council", &fm, "Body").unwrap();
        get_skill_content_impl(barrack, "council").unwrap();
        update_skill_impl(barrack, "council", &fm, "New body").unwrap();
        rename_skill_impl(barrack, "council", "council-2").unwrap();
        delete_skill_impl(barrack, "council-2").unwrap();
    }

    // ---- AIBCC-001/002 follow-up: residual symlink-traversal coverage ----

    /// (1) CRUD/get/index must reject when `<barrack>/skills` is itself a
    /// symlink to an outside directory. Even though the outside dir contains
    /// a real "evil-skill" entry, no operation may write to it or surface
    /// its content.
    #[test]
    fn cruds_reject_when_skills_dir_is_symlink_escape() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;

            // Outside dir pre-populated with a skill-shaped entry.
            let outside = TempDir::new().unwrap();
            let outside_skill = outside.path().join("evil-skill");
            test_fs::create_dir_all(&outside_skill).unwrap();
            let outside_md = outside_skill.join("SKILL.md");
            test_fs::write(
                &outside_md,
                "---\nname: evil\ndescription: outside-content-must-not-leak.\n---\nsecret body\n",
            )
            .unwrap();

            // Barrack with skills/ → outside.
            let barrack = TempDir::new().unwrap();
            symlink(outside.path(), barrack.path().join("skills")).unwrap();

            let fm = SkillFrontmatterWrite {
                name: "fresh".into(),
                description: "twenty-char description here.".into(),
                ..Default::default()
            };

            // Every mutating command must refuse.
            assert!(
                create_skill_impl(barrack.path(), "fresh", &fm, "body").is_err(),
                "create must reject symlinked skills root"
            );
            assert!(
                update_skill_impl(barrack.path(), "evil-skill", &fm, "pwn").is_err(),
                "update must reject symlinked skills root"
            );
            assert!(
                delete_skill_impl(barrack.path(), "evil-skill").is_err(),
                "delete must reject symlinked skills root"
            );
            assert!(
                rename_skill_impl(barrack.path(), "evil-skill", "renamed").is_err(),
                "rename must reject symlinked skills root"
            );
            // Read commands must refuse too.
            assert!(
                get_skill_content_impl(barrack.path(), "evil-skill").is_err(),
                "get_skill_content must reject symlinked skills root"
            );
            assert!(
                get_skills_index(barrack.path().to_string_lossy().to_string()).is_err(),
                "get_skills_index must reject symlinked skills root"
            );

            // The outside SKILL.md must be byte-for-byte untouched.
            let after = test_fs::read_to_string(&outside_md).unwrap();
            assert!(
                after.contains("secret body"),
                "outside file content was modified: {}",
                after
            );
            // The outside dir must not have gained a "fresh" or "renamed" entry.
            assert!(
                !outside.path().join("fresh").exists(),
                "create must not have written into outside dir"
            );
            assert!(
                !outside.path().join("renamed").exists(),
                "rename must not have written into outside dir"
            );
        }
    }

    /// (2) `get_skills_index` must not surface content read through a
    /// symlinked skill directory or a symlinked SKILL.md. The legitimate
    /// regular-file skill in the same dir must still appear.
    #[test]
    fn get_skills_index_skips_skill_dir_and_md_symlink_escapes() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;

            // Outside material with telltale secret strings.
            let outside = TempDir::new().unwrap();
            let outside_skill = outside.path().join("evil");
            test_fs::create_dir_all(&outside_skill).unwrap();
            test_fs::write(
                outside_skill.join("SKILL.md"),
                "---\nname: evil\ndescription: SECRET-DIR-CONTENT\n---\n",
            )
            .unwrap();
            let outside_md = outside.path().join("evil-md.md");
            test_fs::write(
                &outside_md,
                "---\nname: evil2\ndescription: SECRET-MD-CONTENT\n---\n",
            )
            .unwrap();

            let barrack = TempDir::new().unwrap();
            let skills_dir = barrack.path().join("skills");
            test_fs::create_dir_all(&skills_dir).unwrap();

            // Case A: a whole skill dir is a symlink to outside.
            symlink(&outside_skill, skills_dir.join("dir-link")).unwrap();

            // Case B: a real skill dir hosts a symlinked SKILL.md.
            let mixed = skills_dir.join("mixed");
            test_fs::create_dir_all(&mixed).unwrap();
            symlink(&outside_md, mixed.join("SKILL.md")).unwrap();

            // Case C: a fully legitimate skill that must still show up.
            write_skill(
                &skills_dir,
                "legit",
                "---\nname: legit\ndescription: legitimate skill description here.\n---\n",
            );

            let result =
                get_skills_index(barrack.path().to_string_lossy().to_string()).unwrap();

            // Only the legit skill appears — symlinked entries are skipped.
            let slugs: Vec<&str> = result.skills.iter().map(|c| c.slug.as_str()).collect();
            assert_eq!(slugs, vec!["legit"], "symlinked entries must not appear");

            // No outside secret content leaked through any card.
            for c in &result.skills {
                assert!(
                    !c.name.contains("SECRET") && !c.description.contains("SECRET"),
                    "outside content leaked into card: {:?}",
                    c
                );
            }
        }
    }

    /// (3) Broken SKILL.md symlink must be rejected for update/get *before*
    /// any write or read. We verify both that the call errors and that the
    /// dangling symlink target was never materialized on disk.
    #[test]
    fn broken_skill_md_symlink_rejected_before_io() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;

            let outside = TempDir::new().unwrap();
            // Target deliberately does NOT exist — broken symlink.
            let broken_target = outside.path().join("nonexistent-target.md");

            let barrack = TempDir::new().unwrap();
            let skill_dir = barrack.path().join("skills").join("council");
            test_fs::create_dir_all(&skill_dir).unwrap();
            symlink(&broken_target, skill_dir.join("SKILL.md")).unwrap();

            let fm = SkillFrontmatterWrite {
                name: "council".into(),
                description: "twenty-char description here.".into(),
                ..Default::default()
            };

            let err = update_skill_impl(barrack.path(), "council", &fm, "pwn body")
                .expect_err("update must reject broken SKILL.md symlink");
            // Rejection reason: either escape ("벗어남") or canonicalize failure ("정규화").
            assert!(
                err.contains("벗어남") || err.contains("정규화"),
                "got: {}",
                err
            );

            let err = get_skill_content_impl(barrack.path(), "council")
                .expect_err("get must reject broken SKILL.md symlink");
            assert!(
                err.contains("벗어남") || err.contains("정규화"),
                "got: {}",
                err
            );

            // Most important: if the broken symlink had been followed by
            // fs::write(), the dangling target would be created on disk.
            assert!(
                !broken_target.exists(),
                "broken symlink target must not have been created at {:?}",
                broken_target
            );
        }
    }
}
