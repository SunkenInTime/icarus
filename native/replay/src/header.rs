//! What the replay info and Header chunk say, read without decompressing a
//! byte of the stream: the probe's whole answer, and the decode's `match`
//! block and player agents.

use std::io::Read;
use std::path::Path;

use serde::Serialize;
use vrf_container::{ContainerError, Preamble, parse_preamble};
use vrf_transform::TransformVersion;

use crate::error::{ErrorCode, ReplayError};

/// Changes whenever the decoded output could: our version plus vrfkit's tag.
/// The Dart cache keys decoded replays by it.
pub const DECODER_VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "+vrfkit.0.2.5");
pub const VRFKIT_VERSION: &str = "0.2.5";

/// The facts the probe returns (docs/replay-format.md, "Probe").
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Probe {
    pub id: String,
    pub map_path: Option<String>,
    pub build: String,
    pub duration_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recorded_at: Option<String>,
    pub supported: bool,
    pub decoder_version: &'static str,
    pub players: Vec<HeaderPlayer>,
}

/// One `playerLoadouts` entry of the header's game-specific data.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HeaderPlayer {
    pub subject: String,
    pub agent_id: Option<String>,
}

impl Probe {
    pub fn from_preamble(preamble: &Preamble) -> Self {
        let build = preamble.header.replay_version.branch.clone();
        Self {
            id: preamble.info.friendly_name.clone(),
            map_path: preamble
                .header
                .level_names_and_times
                .first()
                .map(|(name, _)| name.clone()),
            supported: TransformVersion::from_branch(&build).is_some(),
            build,
            duration_ms: i64::from(preamble.info.length_in_ms),
            recorded_at: ticks_to_iso8601(preamble.info.timestamp),
            decoder_version: DECODER_VERSION,
            players: header_players(&preamble.header.game_specific_data),
        }
    }
}

/// `playerLoadouts` from the game-specific data entries; entries that are not
/// JSON or carry no loadouts contribute nothing.
pub fn header_players(game_specific_data: &[String]) -> Vec<HeaderPlayer> {
    let mut players = Vec::new();
    for entry in game_specific_data {
        let Ok(json) = serde_json::from_str::<serde_json::Value>(entry) else {
            continue;
        };
        for loadout in json["playerLoadouts"].as_array().into_iter().flatten() {
            if let Some(subject) = loadout["subject"].as_str() {
                players.push(HeaderPlayer {
                    subject: subject.to_ascii_lowercase(),
                    agent_id: loadout["characterId"].as_str().map(str::to_ascii_lowercase),
                });
            }
        }
    }
    players
}

/// Unreal `FDateTime` ticks (100 ns since 0001-01-01) as an ISO-8601 second.
/// The wire carries no zone; the contract labels it UTC.
pub fn ticks_to_iso8601(ticks: i64) -> Option<String> {
    const TICKS_PER_SECOND: i64 = 10_000_000;
    /// Seconds from 0001-01-01 to 1970-01-01.
    const UNIX_EPOCH_SECONDS: i64 = 62_135_596_800;
    if ticks <= 0 {
        return None;
    }
    let unix = ticks / TICKS_PER_SECOND - UNIX_EPOCH_SECONDS;
    let (days, secs) = (unix.div_euclid(86_400), unix.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    if !(1..=9999).contains(&y) {
        return None;
    }
    Some(format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        secs / 3600,
        secs / 60 % 60,
        secs % 60
    ))
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
/// `civil_from_days`).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// Map a container failure onto the contract's codes: a file that is not a
/// replay at all, versus a replay that is damaged.
pub fn container_error(error: &ContainerError) -> ReplayError {
    let code = match error {
        ContainerError::FileMagicMismatch { .. }
        | ContainerError::NetworkMagicMismatch { .. }
        | ContainerError::UnsupportedFileVersion { .. }
        | ContainerError::MissingHeaderChunk
        | ContainerError::DataBeforeHeader
        | ContainerError::ChunkBeforeHeader { .. } => ErrorCode::NotAReplay,
        ContainerError::EncryptedWithoutKey | ContainerError::EncryptedNotSupported => {
            ErrorCode::UnsupportedBuild
        }
        ContainerError::OodleUnsupported { .. } => ErrorCode::UnsupportedCompression,
        _ => ErrorCode::Corrupt,
    };
    ReplayError::new(code, error.to_string())
}

/// Parse the preamble from the start of `path`, reading only as much of the
/// file as the Header chunk needs.
pub fn read_preamble(path: &Path) -> Result<Preamble, ReplayError> {
    let mut file = std::fs::File::open(path)?;
    // Past the cap a decode refuses the file anyway.
    let len = file.metadata()?.len().min(crate::limits::MAX_FILE_BYTES);
    let mut data = Vec::new();
    let mut want: u64 = 64 * 1024;
    loop {
        let target = want.min(len) as usize;
        if data.len() < target {
            let mut more = vec![0; target - data.len()];
            file.read_exact(&mut more)?;
            data.extend(more);
        }
        match parse_preamble(&data) {
            Ok(preamble) => return Ok(preamble),
            Err(ContainerError::Truncated { .. }) if (data.len() as u64) < len => want *= 4,
            Err(ContainerError::InvalidChunkSize { .. }) if (data.len() as u64) < len => {
                // A chunk that runs past the bytes read so far reads as an
                // invalid size until the rest of it is loaded.
                want *= 4;
            }
            Err(e) => return Err(container_error(&e)),
        }
    }
}

/// The probe for one file.
pub fn probe(path: &Path) -> Result<Probe, ReplayError> {
    Ok(Probe::from_preamble(&read_preamble(path)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticks_read_as_utc_seconds() {
        // 2026-07-08 00:35:45.074, from dc078274's header.
        assert_eq!(
            ticks_to_iso8601(639_190_677_450_740_000).as_deref(),
            Some("2026-07-08T00:35:45Z")
        );
        assert_eq!(
            ticks_to_iso8601(621_355_968_000_000_000).as_deref(),
            Some("1970-01-01T00:00:00Z")
        );
        assert_eq!(ticks_to_iso8601(0), None);
    }

    #[test]
    fn decoder_version_names_both_versions() {
        assert_eq!(DECODER_VERSION, "0.1.0+vrfkit.0.2.5");
    }

    #[test]
    fn loadouts_come_from_any_game_data_entry() {
        let data = vec![
            "{\"serializedVersion\": 2}".to_owned(),
            "not json".to_owned(),
            r#"{"playerLoadouts":[{"subject":"AB-1","characterId":"CD-2"},{"subject":"x"}]}"#
                .to_owned(),
        ];
        assert_eq!(
            header_players(&data),
            vec![
                HeaderPlayer {
                    subject: "ab-1".into(),
                    agent_id: Some("cd-2".into())
                },
                HeaderPlayer {
                    subject: "x".into(),
                    agent_id: None
                },
            ]
        );
    }

    #[test]
    fn a_file_that_is_not_a_replay_says_so() {
        let path = std::env::temp_dir().join(format!("not-a-replay-{}.vrf", std::process::id()));
        std::fs::write(&path, b"hello, this is not a replay file at all").unwrap();
        let err = probe(&path).unwrap_err();
        std::fs::remove_file(&path).unwrap();
        assert_eq!(err.code, ErrorCode::NotAReplay, "{err}");
    }

    #[test]
    fn a_missing_file_is_io() {
        let err = probe(Path::new("this/does/not/exist.vrf")).unwrap_err();
        assert_eq!(err.code, ErrorCode::Io);
    }
}
