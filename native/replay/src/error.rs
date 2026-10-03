//! The error object of docs/replay-format.md ("Errors").

use serde::Serialize;

/// The `code` of an error object, spelled as the contract spells it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorCode {
    NotAReplay,
    UnsupportedBuild,
    UnsupportedCompression,
    TransformCheckFailed,
    Corrupt,
    Io,
    Cancelled,
}

/// Why a probe or decode produced no replay.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReplayError {
    pub code: ErrorCode,
    pub message: String,
    /// The replay's build, when the header got far enough to name it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub build: Option<String>,
}

impl ReplayError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            build: None,
        }
    }

    #[must_use]
    pub fn with_build(mut self, build: &str) -> Self {
        self.build = Some(build.to_owned());
        self
    }

    pub fn cancelled() -> Self {
        Self::new(ErrorCode::Cancelled, "decode cancelled")
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("an error object always serializes")
    }
}

impl std::fmt::Display for ReplayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}

impl std::error::Error for ReplayError {}

impl From<std::io::Error> for ReplayError {
    fn from(e: std::io::Error) -> Self {
        Self::new(ErrorCode::Io, e.to_string())
    }
}
