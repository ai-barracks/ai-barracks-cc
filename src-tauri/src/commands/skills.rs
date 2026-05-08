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
    #[serde(rename = "argument-hint", default, skip_serializing_if = "Option::is_none")]
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
}
