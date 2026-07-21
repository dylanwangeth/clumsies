use std::collections::HashMap;
use std::ops::Range;

use pulldown_cmark::{Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use sha2::{Digest, Sha256};

use super::models::SearchModels;
use super::{RetrievalUnit, SearchFailure, SourceLocator, SourceResource};

const TARGET_TOKENS: usize = 384;
const HARD_TOKEN_LIMIT: usize = 480;
const TOKEN_OVERLAP: usize = 48;

#[derive(Clone, Debug)]
struct Heading {
    level: u8,
    start: usize,
    path: Vec<String>,
    occurrence: usize,
}

#[derive(Clone, Debug)]
struct Section {
    range: Range<usize>,
    heading_path: Vec<String>,
    identity: String,
    occurrence: usize,
}

struct UnitDescriptor<'a> {
    heading_path: Vec<String>,
    identity: &'a str,
    occurrence: usize,
    part_index: usize,
    range: Range<usize>,
    token_count: usize,
}

pub(crate) fn build_units(
    resource: &SourceResource,
    models: &dyn SearchModels,
) -> Result<Vec<RetrievalUnit>, SearchFailure> {
    let content = resource.content.as_str();
    if content.trim().is_empty() {
        return Ok(Vec::new());
    }
    let whole_offsets = models.token_offsets(content)?;
    if whole_offsets.len() <= TARGET_TOKENS {
        return Ok(vec![make_unit(
            resource,
            0,
            UnitDescriptor {
                heading_path: Vec::new(),
                identity: "root",
                occurrence: 0,
                part_index: 0,
                range: trim_range(content, 0..content.len()),
                token_count: whole_offsets.len(),
            },
        )]);
    }

    let mut units = Vec::new();
    for section in markdown_sections(content) {
        let range = trim_range(content, section.range);
        if range.is_empty() {
            continue;
        }
        let token_offsets = models.token_offsets(&content[range.clone()])?;
        let parts = if token_offsets.len() <= HARD_TOKEN_LIMIT {
            vec![(range, token_offsets.len())]
        } else {
            split_oversized_span(content, range, models)?
        };
        for (part_index, (part_range, token_count)) in parts.into_iter().enumerate() {
            units.push(make_unit(
                resource,
                units.len(),
                UnitDescriptor {
                    heading_path: section.heading_path.clone(),
                    identity: &section.identity,
                    occurrence: section.occurrence,
                    part_index,
                    range: part_range,
                    token_count,
                },
            ));
        }
    }
    Ok(units)
}

fn make_unit(
    resource: &SourceResource,
    ordinal: usize,
    descriptor: UnitDescriptor<'_>,
) -> RetrievalUnit {
    let UnitDescriptor {
        heading_path,
        identity,
        occurrence,
        part_index,
        range,
        token_count,
    } = descriptor;
    let text = resource.content[range.clone()].to_owned();
    let text_hash = sha256(&text);
    RetrievalUnit {
        unit_key: format!(
            "{}/{identity}/{occurrence}/{part_index}",
            resource.resource_id
        ),
        resource_id: resource.resource_id.clone(),
        ordinal,
        heading_path: heading_path.clone(),
        locator: SourceLocator::MarkdownSpan {
            start_byte: range.start,
            end_byte: range.end,
            heading_path,
        },
        text,
        text_hash,
        token_count,
    }
}

fn markdown_sections(content: &str) -> Vec<Section> {
    let headings = parse_headings(content);
    if headings.is_empty() {
        return vec![Section {
            range: 0..content.len(),
            heading_path: Vec::new(),
            identity: "root".to_owned(),
            occurrence: 0,
        }];
    }

    let mut sections = Vec::new();
    if !content[..headings[0].start].trim().is_empty() {
        sections.push(Section {
            range: 0..headings[0].start,
            heading_path: Vec::new(),
            identity: "root".to_owned(),
            occurrence: 0,
        });
    }
    for (index, heading) in headings.iter().enumerate() {
        let end = headings[index + 1..]
            .iter()
            .find(|candidate| candidate.level <= heading.level)
            .map(|candidate| candidate.start)
            .unwrap_or(content.len());
        sections.push(Section {
            range: heading.start..end,
            heading_path: heading.path.clone(),
            identity: heading
                .path
                .iter()
                .map(|component| normalize_identity(component))
                .collect::<Vec<_>>()
                .join("/"),
            occurrence: heading.occurrence,
        });
    }
    sections
}

fn parse_headings(content: &str) -> Vec<Heading> {
    let parser = Parser::new_ext(content, Options::all()).into_offset_iter();
    let mut raw = Vec::<(u8, usize, String)>::new();
    let mut active: Option<(u8, usize, String)> = None;
    for (event, range) in parser {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                active = Some((heading_level(level), range.start, String::new()));
            }
            Event::Text(text) | Event::Code(text) if active.is_some() => {
                let (_, _, title) = active.as_mut().expect("checked above");
                if !title.is_empty() {
                    title.push(' ');
                }
                title.push_str(&text);
            }
            Event::End(TagEnd::Heading(_)) => {
                if let Some((level, start, title)) = active.take() {
                    raw.push((level, start, collapse_whitespace(&title)));
                }
            }
            _ => {}
        }
    }

    let mut stack = Vec::<(u8, String)>::new();
    let mut occurrences = HashMap::<String, usize>::new();
    raw.into_iter()
        .map(|(level, start, title)| {
            while stack.last().is_some_and(|(parent, _)| *parent >= level) {
                stack.pop();
            }
            let title = if title.is_empty() {
                "Untitled".to_owned()
            } else {
                title
            };
            stack.push((level, title.clone()));
            let path = stack
                .iter()
                .map(|(_, component)| component.clone())
                .collect::<Vec<_>>();
            let identity = path
                .iter()
                .map(|component| normalize_identity(component))
                .collect::<Vec<_>>()
                .join("/");
            let occurrence = occurrences.entry(identity).or_default();
            let current = *occurrence;
            *occurrence += 1;
            Heading {
                level,
                start,
                path,
                occurrence: current,
            }
        })
        .collect()
}

fn split_oversized_span(
    content: &str,
    range: Range<usize>,
    models: &dyn SearchModels,
) -> Result<Vec<(Range<usize>, usize)>, SearchFailure> {
    let slice = &content[range.clone()];
    let boundaries = markdown_block_boundaries(slice);
    let mut parts = Vec::<Range<usize>>::new();
    let mut start = 0usize;
    let mut cursor = 0usize;
    for boundary in boundaries {
        let candidate = trim_range(slice, start..boundary);
        let count = models.token_offsets(&slice[candidate.clone()])?.len();
        if count > TARGET_TOKENS && cursor > start {
            let committed = trim_range(slice, start..cursor);
            if !committed.is_empty() {
                parts.push(committed);
            }
            start = cursor;
        }
        cursor = boundary;
    }
    let tail = trim_range(slice, start..slice.len());
    if !tail.is_empty() {
        parts.push(tail);
    }

    let mut output = Vec::new();
    for part in parts {
        let offsets = models.token_offsets(&slice[part.clone()])?;
        if offsets.len() <= HARD_TOKEN_LIMIT {
            output.push((
                (range.start + part.start)..(range.start + part.end),
                offsets.len(),
            ));
            continue;
        }
        for (window, count) in token_windows(&slice[part.clone()], &offsets) {
            output.push((
                (range.start + part.start + window.start)..(range.start + part.start + window.end),
                count,
            ));
        }
    }
    Ok(output)
}

fn markdown_block_boundaries(content: &str) -> Vec<usize> {
    let mut boundaries = Parser::new_ext(content, Options::all())
        .into_offset_iter()
        .filter_map(|(event, range)| match event {
            Event::End(
                TagEnd::Paragraph
                | TagEnd::CodeBlock
                | TagEnd::List(_)
                | TagEnd::BlockQuote(_)
                | TagEnd::Table,
            ) => Some(range.end),
            _ => None,
        })
        .collect::<Vec<_>>();
    boundaries.push(content.len());
    boundaries.sort_unstable();
    boundaries.dedup();
    boundaries
}

fn token_windows(content: &str, offsets: &[(usize, usize)]) -> Vec<(Range<usize>, usize)> {
    let mut windows = Vec::new();
    let mut token_start = 0usize;
    while token_start < offsets.len() {
        let token_end = (token_start + TARGET_TOKENS).min(offsets.len());
        let byte_start = if token_start == 0 {
            0
        } else {
            offsets[token_start].0
        };
        let byte_end = if token_end == offsets.len() {
            content.len()
        } else {
            offsets[token_end - 1].1
        };
        let range = trim_range(content, byte_start..byte_end);
        if !range.is_empty() {
            windows.push((range, token_end - token_start));
        }
        if token_end == offsets.len() {
            break;
        }
        token_start = token_end.saturating_sub(TOKEN_OVERLAP);
    }
    windows
}

fn trim_range(content: &str, mut range: Range<usize>) -> Range<usize> {
    while range.start < range.end {
        let Some(character) = content[range.start..range.end].chars().next() else {
            break;
        };
        if !character.is_whitespace() {
            break;
        }
        range.start += character.len_utf8();
    }
    while range.start < range.end {
        let Some(character) = content[range.start..range.end].chars().next_back() else {
            break;
        };
        if !character.is_whitespace() {
            break;
        }
        range.end -= character.len_utf8();
    }
    range
}

fn normalize_identity(value: &str) -> String {
    let mut output = String::new();
    let mut separator = false;
    for character in value.trim().to_lowercase().chars() {
        if character.is_alphanumeric() || character == '_' {
            if separator && !output.is_empty() {
                output.push('-');
            }
            output.push(character);
            separator = false;
        } else {
            separator = true;
        }
    }
    if output.is_empty() {
        "section".to_owned()
    } else {
        output
    }
}

fn collapse_whitespace(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

fn sha256(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("sha256:{}", hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::search::models::SearchModelRuntimeStatus;
    use crate::search::{MemoryKind, SourceScope};

    struct CharacterModels;

    impl SearchModels for CharacterModels {
        fn revision(&self) -> Result<String, SearchFailure> {
            Ok("test".to_owned())
        }

        fn token_offsets(&self, text: &str) -> Result<Vec<(usize, usize)>, SearchFailure> {
            Ok(text
                .char_indices()
                .map(|(start, character)| (start, start + character.len_utf8()))
                .collect())
        }

        fn embed_passages(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, SearchFailure> {
            Ok(texts.iter().map(|_| vec![1.0, 0.0]).collect())
        }

        fn embed_query(&self, _query: &str) -> Result<Vec<f32>, SearchFailure> {
            Ok(vec![1.0, 0.0])
        }

        fn rerank(&self, _query: &str, documents: &[String]) -> Result<Vec<f32>, SearchFailure> {
            Ok((0..documents.len()).map(|index| -(index as f32)).collect())
        }

        fn dimensions(&self) -> usize {
            2
        }

        fn status(&self) -> SearchModelRuntimeStatus {
            SearchModelRuntimeStatus::Ready
        }
    }

    fn resource(content: String) -> SourceResource {
        SourceResource {
            resource_id: "ctx_test".to_owned(),
            project_id: "prj_test".to_owned(),
            scope: SourceScope::Project,
            kind: MemoryKind::Context,
            path: "architecture/search.md".to_owned(),
            title: "Search".to_owned(),
            content_hash: sha256(&content),
            content,
            source_commit_id: Some("commit_test".to_owned()),
            draft_id: None,
            draft_revision: None,
        }
    }

    #[test]
    fn short_documents_remain_one_root_unit() {
        let units = build_units(
            &resource("# One\n\nBody\n\n## Two\n\nMore".to_owned()),
            &CharacterModels,
        )
        .unwrap();
        assert_eq!(units.len(), 1);
        assert_eq!(units[0].unit_key, "ctx_test/root/0/0");
        assert_eq!(units[0].locator.start_byte(), 0);
    }

    #[test]
    fn long_documents_keep_heading_paths_and_utf8_byte_ranges() {
        let content = format!(
            "前言{}\n\n# 检索\n\n{}\n\n## Delta\n\n{}",
            "甲".repeat(400),
            "乙".repeat(420),
            "丙".repeat(520)
        );
        let units = build_units(&resource(content.clone()), &CharacterModels).unwrap();
        assert!(units.len() >= 4);
        assert!(
            units
                .iter()
                .any(|unit| unit.heading_path == ["检索", "Delta"])
        );
        for unit in units {
            let SourceLocator::MarkdownSpan {
                start_byte,
                end_byte,
                ..
            } = unit.locator;
            assert!(content.is_char_boundary(start_byte));
            assert!(content.is_char_boundary(end_byte));
            assert_eq!(unit.text, content[start_byte..end_byte]);
        }
    }

    #[test]
    fn duplicate_headings_receive_stable_occurrences() {
        let body = "x".repeat(500);
        let content = format!("# A\n{body}\n# A\n{body}");
        let units = build_units(&resource(content), &CharacterModels).unwrap();
        assert!(units.iter().any(|unit| unit.unit_key.contains("/a/0/")));
        assert!(units.iter().any(|unit| unit.unit_key.contains("/a/1/")));
    }

    #[test]
    fn test_model_is_send_and_sync() {
        let _: Arc<dyn SearchModels> = Arc::new(CharacterModels);
    }
}
