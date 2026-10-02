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
pub mod oodle;
mod vendor;

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
    let data = std::fs::read(path).map_err(|e| named(e.into()))?;
    decode_bytes(&data, &build, decompressor, control).map_err(named)
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
    control.report(1.0);
    Ok(container::write(&json, &analysed.blob))
}
