//! The Oodle seam. Every compressed archive in a replay goes through one
//! [`Decompressor`]; nothing else in the crate knows how Oodle works.
//!
//! The production decoder is our own clean-room Selkie decoder, which fills
//! this seam when it lands. Until then a build has either no decoder
//! ([`Unavailable`], which reports `unsupportedCompression`) or, with the
//! `dev-vectors` feature, [`VectorDecompressor`], which looks each archive up
//! in a directory of recorded input/output pairs.

use vrf_container::parse_replay_data_meta;

use crate::error::{ErrorCode, ReplayError};

/// Inflates one Oodle archive body (the bytes after its 8-byte header) to
/// exactly `decompressed_size` bytes.
pub trait Decompressor: Send + Sync {
    fn decompress(&self, input: &[u8], decompressed_size: usize) -> Result<Vec<u8>, ReplayError>;
}

/// No decoder in this build: every compressed archive is refused.
pub struct Unavailable;

impl Decompressor for Unavailable {
    fn decompress(&self, _input: &[u8], decompressed_size: usize) -> Result<Vec<u8>, ReplayError> {
        Err(ReplayError::new(
            ErrorCode::UnsupportedCompression,
            format!(
                "this build has no Oodle decoder (a {decompressed_size}-byte archive needs one)"
            ),
        ))
    }
}

/// The decompressor this build ships with: the dev vectors when the feature
/// is on and `ICARUS_OODLE_VECTORS` names a directory, otherwise none.
pub fn default_decompressor() -> Box<dyn Decompressor> {
    #[cfg(feature = "dev-vectors")]
    if let Some(dir) = std::env::var_os("ICARUS_OODLE_VECTORS") {
        return match VectorDecompressor::open(std::path::Path::new(&dir)) {
            Ok(vectors) => Box::new(vectors),
            Err(error) => Box::new(Broken(error)),
        };
    }
    Box::new(Unavailable)
}

/// A vectors directory that could not be indexed: every archive reports why.
#[cfg(feature = "dev-vectors")]
struct Broken(ReplayError);

#[cfg(feature = "dev-vectors")]
impl Decompressor for Broken {
    fn decompress(&self, _input: &[u8], _size: usize) -> Result<Vec<u8>, ReplayError> {
        Err(self.0.clone())
    }
}

/// Bytes of ReplayData prologue ahead of the archive: Time1, Time2,
/// SizeInBytes, MemorySizeInBytes.
const REPLAY_DATA_PROLOGUE_BYTES: usize = 16;
/// Bytes of Oodle archive header: decompressed size, then compressed size.
const OODLE_HEADER_BYTES: usize = 8;

/// Decompress one ReplayData chunk payload (from Time1 on). The framing
/// checks mirror vrfkit's `decompress_replay_data_with_trailing`, which we
/// cannot call with its `oodle` feature off; only the codec is ours.
pub fn inflate_replay_data(
    payload: &[u8],
    compressed: bool,
    decompressor: &dyn Decompressor,
) -> Result<Vec<u8>, ReplayError> {
    let corrupt = |m: String| ReplayError::new(ErrorCode::Corrupt, m);
    let meta = parse_replay_data_meta(payload).map_err(|e| corrupt(e.to_string()))?;
    let data = &payload[REPLAY_DATA_PROLOGUE_BYTES..];
    let declared = usize::try_from(meta.size_in_bytes)
        .map_err(|_| corrupt(format!("negative ReplayData size {}", meta.size_in_bytes)))?;
    let memory = meta.memory_size_in_bytes as usize; // checked non-negative by vrf-container
    if data.len() < declared {
        return Err(corrupt(format!(
            "ReplayData declares {declared} bytes, {} remain",
            data.len()
        )));
    }
    if !compressed {
        if declared != memory {
            return Err(corrupt(format!(
                "uncompressed ReplayData of {declared} bytes declares {memory} in memory"
            )));
        }
        return Ok(data[..declared].to_vec());
    }
    if declared < OODLE_HEADER_BYTES {
        return Err(corrupt(format!(
            "Oodle archive of {declared} bytes has no header"
        )));
    }
    let le = |at: usize| u32::from_le_bytes(data[at..at + 4].try_into().expect("4 bytes"));
    let (archive_size, archive_compressed) = (le(0) as usize, le(4) as usize);
    if archive_size != memory {
        return Err(corrupt(format!(
            "Oodle archive inflates to {archive_size} bytes, ReplayData says {memory}"
        )));
    }
    if archive_compressed != declared - OODLE_HEADER_BYTES {
        return Err(corrupt(format!(
            "Oodle archive holds {archive_compressed} bytes, ReplayData says {}",
            declared - OODLE_HEADER_BYTES
        )));
    }
    let plain = decompressor.decompress(&data[OODLE_HEADER_BYTES..declared], archive_size)?;
    if plain.len() != archive_size {
        return Err(corrupt(format!(
            "Oodle produced {} bytes, the archive declares {archive_size}",
            plain.len()
        )));
    }
    Ok(plain)
}

/// Dev-only: recorded archive pairs, keyed by the sha256 of the input bytes.
///
/// The directory holds `<id>.in` / `<id>.out` pairs. With a `manifest.json`
/// (`archives[].input.sha256`, `.input.file`, `.output.file`) the index is
/// read from it; otherwise every `*.in` is hashed once at open.
#[cfg(feature = "dev-vectors")]
pub struct VectorDecompressor {
    dir: std::path::PathBuf,
    /// Input sha256 (lowercase hex) -> output file name.
    outputs: std::collections::HashMap<String, String>,
}

#[cfg(feature = "dev-vectors")]
impl VectorDecompressor {
    pub fn open(dir: &std::path::Path) -> Result<Self, ReplayError> {
        let unavailable = |m: String| ReplayError::new(ErrorCode::UnsupportedCompression, m);
        let mut outputs = std::collections::HashMap::new();
        let manifest = dir.join("manifest.json");
        if manifest.is_file() {
            let text = std::fs::read_to_string(&manifest)?;
            let json: serde_json::Value = serde_json::from_str(&text)
                .map_err(|e| unavailable(format!("{}: {e}", manifest.display())))?;
            for archive in json["archives"].as_array().into_iter().flatten() {
                let (Some(sha), Some(out)) = (
                    archive["input"]["sha256"].as_str(),
                    archive["output"]["file"].as_str(),
                ) else {
                    continue;
                };
                outputs.insert(sha.to_ascii_lowercase(), out.to_owned());
            }
        } else {
            for entry in std::fs::read_dir(dir)? {
                let path = entry?.path();
                if path.extension().is_some_and(|e| e == "in") {
                    let out = path.with_extension("out");
                    let name = out
                        .file_name()
                        .expect("a file")
                        .to_string_lossy()
                        .into_owned();
                    outputs.insert(sha256_hex(&std::fs::read(&path)?), name);
                }
            }
        }
        if outputs.is_empty() {
            return Err(unavailable(format!(
                "no Oodle vectors in {}",
                dir.display()
            )));
        }
        Ok(Self {
            dir: dir.to_owned(),
            outputs,
        })
    }
}

#[cfg(feature = "dev-vectors")]
impl Decompressor for VectorDecompressor {
    fn decompress(&self, input: &[u8], decompressed_size: usize) -> Result<Vec<u8>, ReplayError> {
        let sha = sha256_hex(input);
        let Some(name) = self.outputs.get(&sha) else {
            return Err(ReplayError::new(
                ErrorCode::UnsupportedCompression,
                format!("no Oodle vector for archive {sha} ({} bytes)", input.len()),
            ));
        };
        let plain = std::fs::read(self.dir.join(name))?;
        if plain.len() != decompressed_size {
            return Err(ReplayError::new(
                ErrorCode::Corrupt,
                format!(
                    "vector {name} holds {} bytes, the archive declares {decompressed_size}",
                    plain.len()
                ),
            ));
        }
        Ok(plain)
    }
}

#[cfg(feature = "dev-vectors")]
fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    let mut hex = String::with_capacity(64);
    for byte in digest {
        hex.push_str(&format!("{byte:02x}"));
    }
    hex
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A ReplayData payload around an Oodle archive of `body`, declaring
    /// `memory` decompressed bytes.
    fn replay_data(body: &[u8], memory: u32) -> Vec<u8> {
        let size = (body.len() + OODLE_HEADER_BYTES) as u32;
        let mut buf = Vec::new();
        for word in [0, 1000, size, memory, memory, body.len() as u32] {
            buf.extend(word.to_le_bytes());
        }
        buf.extend(body);
        buf
    }

    struct Fixed(Vec<u8>);
    impl Decompressor for Fixed {
        fn decompress(&self, _: &[u8], _: usize) -> Result<Vec<u8>, ReplayError> {
            Ok(self.0.clone())
        }
    }

    #[test]
    fn no_decoder_reports_unsupported_compression_not_a_panic() {
        let err = inflate_replay_data(&replay_data(&[1, 2, 3], 9), true, &Unavailable).unwrap_err();
        assert_eq!(err.code, ErrorCode::UnsupportedCompression);
    }

    #[test]
    fn the_codec_sees_exactly_the_archive_body() {
        struct Echo;
        impl Decompressor for Echo {
            fn decompress(&self, input: &[u8], size: usize) -> Result<Vec<u8>, ReplayError> {
                let mut out = input.to_vec();
                out.resize(size, 0);
                Ok(out)
            }
        }
        let plain = inflate_replay_data(&replay_data(&[7, 8, 9], 4), true, &Echo).unwrap();
        assert_eq!(plain, [7, 8, 9, 0]);
    }

    #[test]
    fn a_short_codec_output_is_corrupt() {
        let err = inflate_replay_data(&replay_data(&[1], 4), true, &Fixed(vec![0; 3])).unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
    }

    #[test]
    fn archive_header_disagreeing_with_the_prologue_is_corrupt() {
        let mut data = replay_data(&[1, 2], 4);
        data[16] = 5; // archive decompressed size
        let err = inflate_replay_data(&data, true, &Fixed(vec![0; 4])).unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
    }

    #[test]
    fn a_truncated_chunk_is_corrupt() {
        let mut data = replay_data(&[1, 2, 3, 4], 4);
        data.truncate(data.len() - 2);
        let err = inflate_replay_data(&data, true, &Fixed(vec![0; 4])).unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
    }

    #[test]
    fn uncompressed_data_passes_through() {
        let mut buf = Vec::new();
        for word in [0u32, 10, 3, 3] {
            buf.extend(word.to_le_bytes());
        }
        buf.extend([4, 5, 6]);
        assert_eq!(
            inflate_replay_data(&buf, false, &Unavailable).unwrap(),
            [4, 5, 6]
        );
    }

    #[cfg(feature = "dev-vectors")]
    #[test]
    fn vectors_are_found_by_input_hash() {
        let dir = std::env::temp_dir().join(format!("icarus-vectors-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.in"), [1, 2, 3]).unwrap();
        std::fs::write(dir.join("a.out"), [9, 9, 9, 9]).unwrap();
        let vectors = VectorDecompressor::open(&dir).unwrap();
        assert_eq!(vectors.decompress(&[1, 2, 3], 4).unwrap(), [9, 9, 9, 9]);
        let miss = vectors.decompress(&[1, 2], 4).unwrap_err();
        assert_eq!(miss.code, ErrorCode::UnsupportedCompression);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
