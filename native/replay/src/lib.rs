//! Decodes a Valorant `.vrf` replay into the buffer docs/replay-format.md
//! describes. Built on vrfkit (docs/adr/0006-replay-decoder.md).

mod analysis;
mod collect;
pub mod container;
pub mod decode;
pub mod document;
pub mod error;
mod ffi;
mod fieldpath;
pub mod guard;
pub mod header;
pub mod limits;
pub mod oodle;
pub mod selkie;
mod vendor;

use std::io::Read;
use std::path::Path;

pub use error::{ErrorCode, ReplayError};
pub use vendor::sink::RecordBuffers;

use decode::Control;
use oodle::Decompressor;

/// Decode the replay at `path` into an `.icrp` buffer, decompressing with
/// this build's Oodle decoder.
pub fn decode_file(path: &Path, control: Control<'_>) -> Result<Vec<u8>, ReplayError> {
    decode_file_with(path, oodle::default_decompressor().as_ref(), control)
}

/// [`decode_file`] with an explicit decompressor.
pub fn decode_file_with(
    path: &Path,
    decompressor: &dyn Decompressor,
    control: Control<'_>,
) -> Result<Vec<u8>, ReplayError> {
    // The header alone settles a build we cannot read, before 100 MB of reading.
    let preamble = header::read_preamble(path)?;
    let build = preamble.header.replay_version.branch.clone();
    if !header::Probe::from_preamble(&preamble).supported {
        return Err(ReplayError::new(
            ErrorCode::UnsupportedBuild,
            format!("no payload transform is registered for {build}"),
        )
        .with_build(&build));
    }
    let named = |e: ReplayError| match e.build {
        Some(_) => e,
        None => e.with_build(&build),
    };
    control.check().map_err(named)?;
    let data = read_replay(path).map_err(named)?;
    decode_bytes(&data, &build, decompressor, control).map_err(named)
}

/// The whole file, unless it is larger than [`limits::MAX_FILE_BYTES`].
fn read_replay(path: &Path) -> Result<Vec<u8>, ReplayError> {
    let too_large = || limits::exceeded("replay file bytes", limits::MAX_FILE_BYTES);
    let file = std::fs::File::open(path)?;
    let length = file.metadata()?.len();
    if length > limits::MAX_FILE_BYTES {
        return Err(too_large());
    }
    let mut data = Vec::with_capacity(length as usize);
    // Bounded again in case the file grows while it is read.
    file.take(limits::MAX_FILE_BYTES + 1)
        .read_to_end(&mut data)?;
    if data.len() as u64 > limits::MAX_FILE_BYTES {
        return Err(too_large());
    }
    Ok(data)
}

/// What the transform guard measures on `data` read with `transform_branch`'s
/// transform: the walk without the analysis, for tests and diagnostics.
pub fn measure_guard(
    data: &[u8],
    transform_branch: &str,
    decompressor: &dyn Decompressor,
) -> Result<(guard::GuardVerdict, guard::GuardSample), ReplayError> {
    let preamble = vrf_container::parse_preamble(data).map_err(|e| header::container_error(&e))?;
    let mut collector = collect::Collector::default();
    decode::walk(
        data,
        &preamble,
        transform_branch,
        decompressor,
        Control::default(),
        &mut collector,
    )?;
    Ok((collector.guard.verdict(), collector.guard))
}

/// Decode a whole file already in memory, reading its payloads with the
/// transform registered for `transform_branch` (the header's own branch,
/// except in the guard's tests).
pub fn decode_bytes(
    data: &[u8],
    transform_branch: &str,
    decompressor: &dyn Decompressor,
    control: Control<'_>,
) -> Result<Vec<u8>, ReplayError> {
    let preamble = vrf_container::parse_preamble(data).map_err(|e| header::container_error(&e))?;
    let build = preamble.header.replay_version.branch.clone();
    let mut collector = collect::Collector::default();
    let walked = decode::walk(
        data,
        &preamble,
        transform_branch,
        decompressor,
        control,
        &mut collector,
    )?;
    let verdict = collector.guard.verdict();
    if !verdict.verified {
        return Err(ReplayError::new(
            ErrorCode::TransformCheckFailed,
            format!(
                "decoded payloads look like noise: {:.2}% zero bytes, {:.1}% bits set over {} bytes",
                verdict.zero_share * 100.0,
                verdict.bit_density * 100.0,
                collector.guard.bytes
            ),
        )
        .with_build(&build));
    }
    control.check()?;
    let analysed = analysis::analyse(&preamble, &collector, &walked, verdict);
    let json = serde_json::to_string(&analysed.document)
        .map_err(|e| ReplayError::new(ErrorCode::Corrupt, format!("document: {e}")))?;
    limits::check_output(json.len(), analysed.blob.len())?;
    control.report(1.0);
    Ok(container::write(&json, &analysed.blob))
}

#[cfg(test)]
mod tests {
    use super::*;
    use vrf_testkit::{Info, chunk, header_payload_for_branch, replay_info};

    #[test]
    fn a_file_past_the_size_cap_is_refused_unread() {
        let path = std::env::temp_dir().join(format!("icarus-huge-{}.vrf", std::process::id()));
        let mut head = replay_info(&Info::default());
        head.extend(chunk(
            0,
            &header_payload_for_branch("++Ares-Core+release-13.00", 0, &[3, 0, 0, 0, 49, 56, 0]),
        ));
        std::fs::write(&path, &head).unwrap();
        // Only the length grows; nothing past the header is written.
        let file = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        file.set_len(limits::MAX_FILE_BYTES + 1).unwrap();
        drop(file);

        let result = decode_file_with(&path, &oodle::Unavailable, Control::default());
        std::fs::remove_file(&path).unwrap();
        let err = result.unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt, "{err}");
        assert!(err.message.contains("file"), "{err}");
        assert_eq!(err.build.as_deref(), Some("++Ares-Core+release-13.00"));
    }
}
