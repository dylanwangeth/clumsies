use std::env;
use std::path::PathBuf;

use crate::DaemonDraftResourceKind;
use crate::DaemonError;
use crate::DaemonTextReplacement;
use crate::MemoryKind;
use crate::config::ProjectConfig;

pub(crate) fn home_dir() -> Result<PathBuf, DaemonError> {
    env::var_os("HOME").map(PathBuf::from).ok_or_else(|| {
        DaemonError::InvalidConfig(
            "HOME is required when daemon runtime paths are not configured".to_owned(),
        )
    })
}

pub(crate) fn non_empty_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

pub(crate) fn canonical_server_url(server_url: &str) -> Result<String, DaemonError> {
    ProjectConfig {
        server_url: server_url.to_owned(),
        project_id: None,
    }
    .validate()?;
    Ok(server_url.trim().trim_end_matches('/').to_owned())
}

pub(crate) fn canonical_workspace_directory(path: &str) -> Result<PathBuf, DaemonError> {
    let path = path.trim();
    if path.is_empty() {
        return Err(DaemonError::InvalidRequest(
            "workspace path must not be empty".to_owned(),
        ));
    }
    let canonical = std::fs::canonicalize(path).map_err(|error| {
        DaemonError::InvalidRequest(format!("workspace path {path} cannot be resolved: {error}"))
    })?;
    if !canonical.is_dir() {
        return Err(DaemonError::InvalidRequest(format!(
            "workspace path {} is not a directory",
            canonical.display()
        )));
    }
    Ok(canonical)
}

pub(crate) fn parse_bool_env(name: &str) -> Result<Option<bool>, DaemonError> {
    let Some(value) = env::var(name).ok() else {
        return Ok(None);
    };
    match value.as_str() {
        "1" | "true" | "TRUE" | "yes" | "YES" => Ok(Some(true)),
        "0" | "false" | "FALSE" | "no" | "NO" => Ok(Some(false)),
        _ => Err(DaemonError::InvalidConfig(format!(
            "{name} must be a boolean value"
        ))),
    }
}

pub(crate) fn parse_u64_env(name: &str) -> Result<Option<u64>, DaemonError> {
    let Some(value) = env::var(name).ok() else {
        return Ok(None);
    };
    value.parse::<u64>().map(Some).map_err(|error| {
        DaemonError::InvalidConfig(format!("{name} must be a positive integer: {error}"))
    })
}

pub(crate) fn is_normalized_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.ends_with('/')
        && path.split('/').all(is_portable_path_segment)
}

fn is_portable_path_segment(segment: &str) -> bool {
    if segment.is_empty()
        || segment == "."
        || segment == ".."
        || segment.trim() != segment
        || segment.ends_with('.')
        || segment.chars().any(|character| {
            character.is_control()
                || matches!(character, '\\' | '<' | '>' | ':' | '"' | '|' | '?' | '*')
        })
    {
        return false;
    }
    let stem = segment
        .split('.')
        .next()
        .unwrap_or_default()
        .to_ascii_uppercase();
    !matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        && !reserved_numbered_name(&stem, "COM")
        && !reserved_numbered_name(&stem, "LPT")
}

fn reserved_numbered_name(stem: &str, prefix: &str) -> bool {
    stem.strip_prefix(prefix)
        .is_some_and(|suffix| matches!(suffix, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"))
}

pub(crate) fn validate_draft_resource_path(
    resource: DaemonDraftResourceKind,
    path: &str,
) -> Result<(), DaemonError> {
    if !is_normalized_relative_path(path) {
        return Err(DaemonError::InvalidRequest(format!(
            "resource path is not a portable normalized relative path: {path}"
        )));
    }
    match resource {
        DaemonDraftResourceKind::Workflow if !path.starts_with("workflow/") => {
            Err(DaemonError::InvalidRequest(
                "workflow path must use the workflow/ namespace".to_owned(),
            ))
        }
        DaemonDraftResourceKind::Rule if path.to_ascii_lowercase().starts_with("workflow/") => Err(
            DaemonError::InvalidRequest("rule path cannot use the workflow/ namespace".to_owned()),
        ),
        _ => Ok(()),
    }
}

pub(crate) fn memory_kind_matches_resource(
    kind: MemoryKind,
    resource: DaemonDraftResourceKind,
) -> bool {
    matches!(
        (kind, resource),
        (MemoryKind::Context, DaemonDraftResourceKind::Context)
            | (MemoryKind::Rule, DaemonDraftResourceKind::Rule)
            | (MemoryKind::Workflow, DaemonDraftResourceKind::Workflow)
    )
}

pub(crate) fn apply_exact_text_replacements(
    source: &str,
    replacements: &[DaemonTextReplacement],
) -> Result<String, DaemonError> {
    struct ReplacementSpan<'a> {
        start: usize,
        end: usize,
        new_text: &'a str,
        input_index: usize,
    }

    let mut spans = Vec::with_capacity(replacements.len());
    for (index, replacement) in replacements.iter().enumerate() {
        let mut matches = source.match_indices(&replacement.old_text);
        let Some((start, _)) = matches.next() else {
            return Err(DaemonError::State {
                code: "text_replacement_not_found",
                message: format!(
                    "Text replacement {} did not match the current resource",
                    index + 1
                ),
            });
        };
        if matches.next().is_some() {
            return Err(DaemonError::State {
                code: "text_replacement_ambiguous",
                message: format!(
                    "Text replacement {} matched more than once; include more surrounding text",
                    index + 1
                ),
            });
        }
        spans.push(ReplacementSpan {
            start,
            end: start + replacement.old_text.len(),
            new_text: &replacement.new_text,
            input_index: index,
        });
    }
    spans.sort_by_key(|span| span.start);
    for pair in spans.windows(2) {
        if pair[1].start < pair[0].end {
            return Err(DaemonError::State {
                code: "text_replacement_overlap",
                message: format!(
                    "Text replacements {} and {} overlap",
                    pair[0].input_index + 1,
                    pair[1].input_index + 1
                ),
            });
        }
    }

    let mut result = source.to_owned();
    for span in spans.into_iter().rev() {
        result.replace_range(span.start..span.end, span.new_text);
    }
    if result == source {
        return Err(DaemonError::State {
            code: "text_replacement_no_change",
            message: "Text replacements did not change the resource".to_owned(),
        });
    }
    Ok(result)
}
