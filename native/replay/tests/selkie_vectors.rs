//! Selkie against the recorded Oodle archives: set `ICARUS_OODLE_VECTORS` to
//! the vectors directory (skipped otherwise). Every archive in its
//! `manifest.json`, and the `quick.json` smoke set, must inflate to its
//! recorded output byte for byte. With `--features dev-vectors` the outputs
//! are also checked against the manifest's sha256.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use icarus_replay::oodle::Decompressor;
use icarus_replay::selkie::Selkie;

fn vectors() -> Option<PathBuf> {
    let dir = std::env::var_os("ICARUS_OODLE_VECTORS");
    if dir.is_none() {
        eprintln!("ICARUS_OODLE_VECTORS unset: Selkie vector test skipped");
    }
    dir.map(PathBuf::from)
}

/// Inflate every archive `list` names, panicking on the first mismatch.
/// Returns the output bytes and time spent decoding.
fn check_all(dir: &Path, list: &str) -> (usize, usize, Duration) {
    let text = std::fs::read_to_string(dir.join(list)).expect("archive list");
    let json: serde_json::Value = serde_json::from_str(&text).expect("archive list JSON");
    let archives = json["archives"].as_array().expect("archives");
    let (mut bytes, mut elapsed) = (0, Duration::ZERO);
    for archive in archives {
        let id = archive["id"].as_str().expect("id");
        let size = archive["decompressedSize"].as_u64().expect("size") as usize;
        let input = std::fs::read(dir.join(archive["input"]["file"].as_str().unwrap())).unwrap();
        let expected =
            std::fs::read(dir.join(archive["output"]["file"].as_str().unwrap())).unwrap();
        assert_eq!(
            input.len() as u64,
            archive["compressedSize"].as_u64().unwrap(),
            "{id} input"
        );
        let started = Instant::now();
        let output = Selkie
            .decompress(&input, size)
            .unwrap_or_else(|e| panic!("{id}: {e}"));
        elapsed += started.elapsed();
        assert_eq!(output.len(), size, "{id} length");
        #[cfg(feature = "dev-vectors")]
        assert_eq!(
            sha256_hex(&output),
            archive["output"]["sha256"].as_str().unwrap(),
            "{id} sha256"
        );
        if let Some(at) = output.iter().zip(&expected).position(|(a, b)| a != b) {
            panic!("{id}: first differing output byte at {at}");
        }
        assert_eq!(output.len(), expected.len(), "{id} recorded length");
        bytes += size;
    }
    (archives.len(), bytes, elapsed)
}

#[test]
fn every_recorded_archive_inflates_byte_for_byte() {
    let Some(dir) = vectors() else { return };
    let (archives, bytes, elapsed) = check_all(&dir, "manifest.json");
    eprintln!(
        "Selkie: {archives} archives, {bytes} bytes in {elapsed:?} ({:.0} MB/s)",
        bytes as f64 / 1e6 / elapsed.as_secs_f64()
    );
    assert_eq!(archives, 259);
}

#[test]
fn the_quick_set_inflates_byte_for_byte() {
    let Some(dir) = vectors() else { return };
    let (archives, _, _) = check_all(&dir, "quick.json");
    assert_eq!(archives, 3);
}

#[cfg(feature = "dev-vectors")]
fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
