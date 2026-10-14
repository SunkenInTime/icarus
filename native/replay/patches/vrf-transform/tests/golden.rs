//! Every registered transform against vectors this port did not produce:
//! extracted from the C# reference parser's test fixture or captured from the
//! original executables (`tools/capture_native_transforms.py`). A failure here
//! invalidates everything downstream.

include!("data/golden_vectors.rs");
include!("data/native_vectors.rs");

use vrf_bitio::BitReader;
use vrf_transform::sbox::{SBOX_8, SBOX_32, SBOX_64};
use vrf_transform::{ALL_VERSIONS, TransformVersion, seed_for};

/// Every staging boundary (64 -> 32 -> 8 -> tail) plus a multi-word payload
/// with and without a partial tail.
const BOUNDARIES: [usize; 11] = [0, 1, 7, 8, 31, 32, 63, 64, 65, 287, 288];

/// `(branch, bits, seed, input hex, expected hex)`. The golden vectors share
/// one payload and derive their seed from the bit count.
fn vectors() -> impl Iterator<Item = (&'static str, usize, u32, &'static str, &'static str)> {
    VECTORS
        .iter()
        .map(|&(branch, bits, expected)| {
            let seed = seed_for(bits, ACTOR_NET_GUID);
            (branch, bits, seed, PAYLOAD_HEX, expected)
        })
        .chain(NATIVE_VECTORS.iter().copied())
}

fn from_hex(hex: &str) -> Vec<u8> {
    assert!(hex.len() % 2 == 0, "odd-length hex: {hex}");
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("valid hex"))
        .collect()
}

#[test]
fn transforms_match_the_golden_and_native_vectors() {
    let mut failures = Vec::new();
    let mut total = 0;
    for (branch, bits, seed, input, expected) in vectors() {
        total += 1;
        let version = TransformVersion::require(branch).expect("branch is registered");
        let mut out = vec![0u8; TransformVersion::output_byte_count(bits)];
        version
            .decode_from(&mut BitReader::new(&from_hex(input)), bits, seed, &mut out)
            .expect("input is long enough for the vector");
        if out != from_hex(expected) {
            let actual: String = out.iter().map(|b| format!("{b:02X}")).collect();
            failures.push(format!(
                "{branch} @ {bits} bits, seed {seed:#x}\n     expected {expected}\n     actual   {actual}"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {total} vectors mismatched:\n  {}",
        failures.len(),
        failures.join("\n  ")
    );
}

#[test]
fn vectors_cover_the_staging_boundaries() {
    // A build with no vectors fails at the first boundary.
    for version in ALL_VERSIONS.iter().copied() {
        let bits: Vec<usize> = vectors()
            .filter(|v| v.0 == version.branch())
            .map(|v| v.1)
            .collect();
        for required in BOUNDARIES {
            assert!(
                bits.contains(&required),
                "{} lacks a vector at {required} bits (have {bits:?})",
                version.branch()
            );
        }
    }
}

#[test]
fn extracted_tables_are_intact() {
    // A mistyped S-box byte duplicates a value.
    for sbox in [&SBOX_8, &SBOX_32, &SBOX_64] {
        let mut sorted = *sbox;
        sorted.sort_unstable();
        assert!(sorted.iter().copied().eq(0..=255), "{sbox:?}");
    }
    // The golden vectors are 8 builds x BOUNDARIES, each pair exactly once.
    let mut pairs: Vec<(&str, usize)> = VECTORS.iter().map(|v| (v.0, v.1)).collect();
    pairs.sort_unstable();
    let mut builds: Vec<&str> = pairs.iter().map(|p| p.0).collect();
    builds.dedup();
    let expected: Vec<(&str, usize)> = builds
        .iter()
        .flat_map(|&b| BOUNDARIES.map(|bits| (b, bits)))
        .collect();
    assert_eq!(builds.len(), 8, "{builds:?}");
    assert_eq!(pairs, expected);
}
