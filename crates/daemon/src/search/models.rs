use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use fastembed::{
    EmbeddingModel, RerankInitOptions, RerankerModel, TextEmbedding, TextInitOptions, TextRerank,
};
use sha2::{Digest, Sha256};

use super::SearchFailure;

const EMBEDDING_MODEL_ID: &str = "intfloat/multilingual-e5-small";
const RERANKER_MODEL_ID: &str = "BAAI/bge-reranker-base";
const EMBEDDING_DIMENSIONS: usize = 384;
const MODEL_REPOSITORIES: [&str; 2] = [EMBEDDING_MODEL_ID, RERANKER_MODEL_ID];

pub(crate) trait SearchModels: Send + Sync {
    fn revision(&self) -> Result<String, SearchFailure>;
    fn token_offsets(&self, text: &str) -> Result<Vec<(usize, usize)>, SearchFailure>;
    fn embed_passages(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, SearchFailure>;
    fn embed_query(&self, query: &str) -> Result<Vec<f32>, SearchFailure>;
    fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<f32>, SearchFailure>;
    fn dimensions(&self) -> usize;
    fn status(&self) -> SearchModelRuntimeStatus;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SearchModelRuntimeStatus {
    Missing,
    Ready,
    Failed,
}

pub(crate) struct FastEmbedSearchModels {
    cache_dir: PathBuf,
    embedding: Mutex<Option<TextEmbedding>>,
    reranker: Mutex<Option<TextRerank>>,
    last_error: Mutex<Option<String>>,
    revision: Mutex<Option<String>>,
}

impl FastEmbedSearchModels {
    pub(crate) fn new(cache_dir: PathBuf) -> Self {
        Self {
            cache_dir,
            embedding: Mutex::new(None),
            reranker: Mutex::new(None),
            last_error: Mutex::new(None),
            revision: Mutex::new(None),
        }
    }

    fn with_embedding<T>(
        &self,
        operation: impl FnOnce(&mut TextEmbedding) -> Result<T, SearchFailure>,
    ) -> Result<T, SearchFailure> {
        let mut guard = self
            .embedding
            .lock()
            .map_err(|_| SearchFailure::model("embedding model lock is poisoned"))?;
        if guard.is_none() {
            let options = TextInitOptions::new(EmbeddingModel::MultilingualE5Small)
                .with_cache_dir(self.cache_dir.clone())
                .with_show_download_progress(false);
            match TextEmbedding::try_new(options) {
                Ok(model) => *guard = Some(model),
                Err(error) => {
                    let failure = SearchFailure::model(format!(
                        "failed to initialize {EMBEDDING_MODEL_ID}: {error}"
                    ));
                    self.record_error(&failure);
                    return Err(failure);
                }
            }
        }
        operation(guard.as_mut().expect("embedding initialized above"))
    }

    fn with_reranker<T>(
        &self,
        operation: impl FnOnce(&mut TextRerank) -> Result<T, SearchFailure>,
    ) -> Result<T, SearchFailure> {
        let mut guard = self
            .reranker
            .lock()
            .map_err(|_| SearchFailure::model("reranker model lock is poisoned"))?;
        if guard.is_none() {
            let options = RerankInitOptions::new(RerankerModel::BGERerankerBase)
                .with_cache_dir(self.cache_dir.clone())
                .with_show_download_progress(false);
            match TextRerank::try_new(options) {
                Ok(model) => *guard = Some(model),
                Err(error) => {
                    let failure = SearchFailure::model(format!(
                        "failed to initialize {RERANKER_MODEL_ID}: {error}"
                    ));
                    self.record_error(&failure);
                    return Err(failure);
                }
            }
        }
        operation(guard.as_mut().expect("reranker initialized above"))
    }

    fn record_error(&self, error: &SearchFailure) {
        if let Ok(mut guard) = self.last_error.lock() {
            *guard = Some(error.message.clone());
        }
    }

    fn artifact_root(&self) -> PathBuf {
        std::env::var_os("HF_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| self.cache_dir.clone())
    }

    fn artifact_revision(&self) -> Result<String, SearchFailure> {
        let root = self.artifact_root();
        let mut files = Vec::new();
        for repository in MODEL_REPOSITORIES {
            let directory = root.join(format!("models--{}", repository.replace('/', "--")));
            let revision_path = directory.join("refs/main");
            let revision = fs::read_to_string(&revision_path).map_err(|error| {
                SearchFailure::model(format!(
                    "failed to read model revision for {repository}: {error}"
                ))
            })?;
            let revision = revision.trim();
            if revision.is_empty() || revision.contains(['/', '\\']) {
                return Err(SearchFailure::model(format!(
                    "model revision for {repository} is invalid"
                )));
            }
            files.push((format!("{repository}/revision"), revision_path));
            collect_files(
                &root,
                &directory.join("snapshots").join(revision),
                &mut files,
            )?;
        }
        files.sort_by(|left, right| left.0.cmp(&right.0));
        if files.is_empty() {
            return Err(SearchFailure::model(format!(
                "model cache {} contains no artifacts",
                root.display()
            )));
        }

        let mut hasher = Sha256::new();
        for (relative, absolute) in files {
            hasher.update(relative.as_bytes());
            hasher.update([0]);
            let bytes = fs::read(&absolute).map_err(|error| {
                SearchFailure::model(format!(
                    "failed to hash model artifact {}: {error}",
                    absolute.display()
                ))
            })?;
            hasher.update((bytes.len() as u64).to_le_bytes());
            hasher.update(&bytes);
        }
        Ok(hex::encode(hasher.finalize()))
    }
}

impl SearchModels for FastEmbedSearchModels {
    fn revision(&self) -> Result<String, SearchFailure> {
        if let Some(revision) = self
            .revision
            .lock()
            .map_err(|_| SearchFailure::model("model revision lock is poisoned"))?
            .clone()
        {
            return Ok(revision);
        }

        self.with_embedding(|_| Ok(()))?;
        self.with_reranker(|_| Ok(()))?;
        let digest = match self.artifact_revision() {
            Ok(digest) => digest,
            Err(error) => {
                self.record_error(&error);
                return Err(error);
            }
        };
        let revision = format!(
            "fastembed-5.17.3:{EMBEDDING_MODEL_ID}:{RERANKER_MODEL_ID}:dim-{EMBEDDING_DIMENSIONS}:l2:{digest}"
        );
        *self
            .revision
            .lock()
            .map_err(|_| SearchFailure::model("model revision lock is poisoned"))? =
            Some(revision.clone());
        if let Ok(mut guard) = self.last_error.lock() {
            *guard = None;
        }
        Ok(revision)
    }

    fn token_offsets(&self, text: &str) -> Result<Vec<(usize, usize)>, SearchFailure> {
        self.with_embedding(|model| {
            let previous_truncation = model.tokenizer.get_truncation().cloned();
            model.tokenizer.with_truncation(None).map_err(|error| {
                SearchFailure::model(format!("failed to disable tokenizer truncation: {error}"))
            })?;

            let encoding = model.tokenizer.encode(text, true);
            model
                .tokenizer
                .with_truncation(previous_truncation)
                .map_err(|error| {
                    SearchFailure::model(format!("failed to restore tokenizer truncation: {error}"))
                })?;

            let encoding = encoding.map_err(|error| {
                SearchFailure::model(format!("failed to tokenize memory content: {error}"))
            })?;
            Ok(encoding
                .get_offsets()
                .iter()
                .copied()
                .filter(|(start, end)| end > start)
                .collect())
        })
    }

    fn embed_passages(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, SearchFailure> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        let prefixed = texts
            .iter()
            .map(|text| format!("passage: {text}"))
            .collect::<Vec<_>>();
        self.with_embedding(|model| {
            let embeddings = model.embed(&prefixed, Some(32)).map_err(|error| {
                SearchFailure::model(format!("passage embedding failed: {error}"))
            })?;
            validate_and_normalize_embeddings(embeddings, EMBEDDING_DIMENSIONS)
        })
    }

    fn embed_query(&self, query: &str) -> Result<Vec<f32>, SearchFailure> {
        let prefixed = [format!("query: {query}")];
        self.with_embedding(|model| {
            let embeddings = model.embed(&prefixed, Some(1)).map_err(|error| {
                SearchFailure::model(format!("query embedding failed: {error}"))
            })?;
            validate_and_normalize_embeddings(embeddings, EMBEDDING_DIMENSIONS)?
                .into_iter()
                .next()
                .ok_or_else(|| SearchFailure::model("query embedding returned no vector"))
        })
    }

    fn rerank(&self, query: &str, documents: &[String]) -> Result<Vec<f32>, SearchFailure> {
        if documents.is_empty() {
            return Ok(Vec::new());
        }
        self.with_reranker(|model| {
            let documents = documents.iter().map(String::as_str).collect::<Vec<_>>();
            let results = model
                .rerank(query, &documents, false, Some(16))
                .map_err(|error| SearchFailure::model(format!("reranking failed: {error}")))?;
            let mut scores = vec![f32::NEG_INFINITY; documents.len()];
            for result in results {
                let Some(score) = scores.get_mut(result.index) else {
                    return Err(SearchFailure::model(
                        "reranker returned an out-of-range document index",
                    ));
                };
                if !result.score.is_finite() {
                    return Err(SearchFailure::model("reranker returned a non-finite score"));
                }
                *score = result.score;
            }
            if scores.iter().any(|score| !score.is_finite()) {
                return Err(SearchFailure::model(
                    "reranker did not return a score for every document",
                ));
            }
            Ok(scores)
        })
    }

    fn dimensions(&self) -> usize {
        EMBEDDING_DIMENSIONS
    }

    fn status(&self) -> SearchModelRuntimeStatus {
        if self
            .last_error
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
            .is_some()
        {
            return SearchModelRuntimeStatus::Failed;
        }
        let embedding_ready = self
            .embedding
            .lock()
            .map(|guard| guard.is_some())
            .unwrap_or(false);
        let reranker_ready = self
            .reranker
            .lock()
            .map(|guard| guard.is_some())
            .unwrap_or(false);
        if embedding_ready && reranker_ready {
            SearchModelRuntimeStatus::Ready
        } else {
            SearchModelRuntimeStatus::Missing
        }
    }
}

fn collect_files(
    root: &Path,
    directory: &Path,
    output: &mut Vec<(String, PathBuf)>,
) -> Result<(), SearchFailure> {
    if !directory.exists() {
        return Ok(());
    }
    let entries = fs::read_dir(directory).map_err(|error| {
        SearchFailure::model(format!(
            "failed to inspect model cache {}: {error}",
            directory.display()
        ))
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| {
            SearchFailure::model(format!("failed to inspect model cache entry: {error}"))
        })?;
        let path = entry.path();
        let metadata = fs::metadata(&path).map_err(|error| {
            SearchFailure::model(format!(
                "failed to inspect model artifact {}: {error}",
                path.display()
            ))
        })?;
        if metadata.is_dir() {
            collect_files(root, &path, output)?;
        } else if metadata.is_file() {
            let relative = path
                .strip_prefix(root)
                .map_err(|_| SearchFailure::model("model artifact escaped its cache root"))?
                .to_string_lossy()
                .replace('\\', "/");
            output.push((relative, path));
        }
    }
    Ok(())
}

fn validate_and_normalize_embeddings(
    embeddings: Vec<Vec<f32>>,
    dimensions: usize,
) -> Result<Vec<Vec<f32>>, SearchFailure> {
    embeddings
        .into_iter()
        .map(|embedding| {
            if embedding.len() != dimensions || embedding.iter().any(|value| !value.is_finite()) {
                return Err(SearchFailure::vector(
                    "embedding has an invalid dimension or non-finite value",
                ));
            }
            let norm = embedding
                .iter()
                .map(|value| value * value)
                .sum::<f32>()
                .sqrt();
            if !norm.is_finite() || norm <= f32::EPSILON {
                return Err(SearchFailure::vector("embedding has an invalid norm"));
            }
            Ok(embedding.into_iter().map(|value| value / norm).collect())
        })
        .collect()
}
