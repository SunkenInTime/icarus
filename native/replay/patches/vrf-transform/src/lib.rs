//! Payload transforms for VALORANT replay content blocks.
//!
//! Only a content block's payload is transformed; block headers and their
//! declared bit lengths are plaintext, so a replay is framed sequentially and
//! each block's transform is independent of the others. The key comes from the stream:
//! `seed = (bit_count as u32) ^ actor_net_guid` ([`seed_for`]).
//!
//! The skeleton is shared from release-11.06 to release-13.08; a build is one
//! line of the `transforms!` registry at the end of this file.
//!
//! # Example
//!
//! ```
//! use vrf_bitio::BitReader;
//! use vrf_transform::{TransformVersion, seed_for};
//!
//! let payload = [0xBFu8, 0xDF, 0x6F];
//! let bit_count = 20;
//! let version = TransformVersion::from_branch("++Ares-Core+release-13.01").unwrap();
//!
//! let mut reader = BitReader::new(&payload);
//! let mut out = vec![0u8; TransformVersion::output_byte_count(bit_count)];
//! version.decode_from(&mut reader, bit_count, seed_for(bit_count, 2), &mut out).unwrap();
//! ```
//!
//! No Cargo features: gating a build would remove a public [`TransformVersion`]
//! variant, and the only sizeable data is the three shared S-box tables.

#![forbid(unsafe_code)]

pub mod helpers;
pub mod sbox;

use vrf_bitio::{BitError, BitReader, Result as BitResult};

/// The transform seed for a content block: its declared payload length in
/// bits, XOR the network GUID of the actor channel carrying it.
#[must_use]
#[inline]
pub const fn seed_for(bit_count: usize, actor_net_guid: u32) -> u32 {
    (bit_count as u32) ^ actor_net_guid
}

/// One build's payload transform.
pub trait SeededTransform {
    /// Replay branch string this transform decodes, e.g. `++Ares-Core+release-13.01`.
    const BRANCH: &'static str;
    /// Added to the seed when deriving the first PRNG lane.
    const SEED_ADDEND: u32;
    /// Offset applied to the raw seed when deriving the first PRNG lane.
    const INIT_A_OFFSET: u32;
    /// Whether the offset is added (`true`) or subtracted (`false`).
    const ADD_OFFSET: bool = false;
    /// XORed into the final partial byte alongside the keystream byte. Equals
    /// `SEED_ADDEND as u8` in all 24 builds; a build that broke that would
    /// fail its 1- and 7-bit vectors.
    const TAIL_XOR: u8 = Self::SEED_ADDEND as u8;

    /// Seed the first PRNG lane.
    #[must_use]
    fn initial_prng_a(seed: u32) -> u64 {
        helpers::initial_prng_a(
            seed,
            Self::SEED_ADDEND,
            Self::INIT_A_OFFSET,
            Self::ADD_OFFSET,
        )
    }

    /// Transform one aligned 64-bit word.
    #[must_use]
    fn word64(value: u64, state: u32) -> u64;
    /// Transform one aligned 32-bit word.
    #[must_use]
    fn word32(value: u32, state: u32) -> u32;
    /// Transform one byte.
    #[must_use]
    fn byte(value: u8, state: u32) -> u8;
}

/// Run a build's transform over `buf`, which holds the payload's bits
/// LSB-first as [`BitReader::copy_bits_to`] writes them. The final byte's
/// padding is left as found (the tail XOR is masked); callers that hand that
/// byte on whole rely on `copy_bits_to` having zeroed it.
///
/// Staged 64 bits at a time, then 32, then 8, then the last 1..7, with one PRNG
/// advance per stage iteration. The staging order is part of the format.
pub fn transform_in_place<T: SeededTransform>(
    buf: &mut [u8],
    bit_count: usize,
    seed: u32,
) -> BitResult<()> {
    if bit_count == 0 {
        return Ok(());
    }
    let available = (buf.len() as u64).saturating_mul(8);
    if bit_count as u64 > available {
        return Err(BitError::InvalidBitLength {
            requested: bit_count as u64,
            available,
        });
    }

    let mut state = seed;
    // A payload under 8 bits never advances, so its keystream byte is the seed's low byte.
    let mut stream_byte = seed as u8;
    let mut prng_a = T::initial_prng_a(seed);
    let mut prng_b = helpers::initial_prng_b(seed);
    let mut offset = 0usize;
    let mut left = bit_count;

    while left > 63 {
        let value = T::word64(helpers::read_u64(buf, offset), state);
        helpers::write_u64(buf, offset, value);
        stream_byte = helpers::advance_state(&mut state, &mut prng_a, &mut prng_b);
        offset += 8;
        left -= 64;
    }
    while left > 31 {
        let value = T::word32(helpers::read_u32(buf, offset), state);
        helpers::write_u32(buf, offset, value);
        stream_byte = helpers::advance_state(&mut state, &mut prng_a, &mut prng_b);
        offset += 4;
        left -= 32;
    }
    while left > 7 {
        buf[offset] = T::byte(buf[offset], state);
        stream_byte = helpers::advance_state(&mut state, &mut prng_a, &mut prng_b);
        offset += 1;
        left -= 8;
    }
    if left != 0 {
        let mask = 0xffu8 >> (7 - ((bit_count - 1) & 7));
        buf[offset] ^= mask & (stream_byte ^ T::TAIL_XOR);
    }
    Ok(())
}

/// A replay branch with no registered transform: reported, never guessed,
/// because a guessed transform yields plausible garbage instead of an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsupportedBranch {
    /// The replay branch that could not be matched.
    pub branch: String,
}

impl core::fmt::Display for UnsupportedBranch {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(
            f,
            "no payload transform is registered for replay branch '{}'; known branches: {}",
            self.branch,
            ALL_VERSIONS
                .iter()
                .copied()
                .map(TransformVersion::branch)
                .collect::<Vec<_>>()
                .join(", ")
        )
    }
}

impl core::error::Error for UnsupportedBranch {}

impl TransformVersion {
    /// Look up a transform by exact replay branch string.
    #[must_use]
    pub fn from_branch(branch: &str) -> Option<Self> {
        ALL_VERSIONS.iter().copied().find(|v| v.branch() == branch)
    }

    /// Look up a transform, returning a descriptive error when unknown.
    pub fn require(branch: &str) -> core::result::Result<Self, UnsupportedBranch> {
        Self::from_branch(branch).ok_or_else(|| UnsupportedBranch {
            branch: branch.to_owned(),
        })
    }

    /// Bytes needed to hold `bit_count` bits.
    #[must_use]
    pub const fn output_byte_count(bit_count: usize) -> usize {
        bit_count.div_ceil(8)
    }

    /// Copy `bit_count` bits from `reader` into `out`, typically a reused
    /// scratch buffer, and transform them there.
    pub fn decode_from(
        self,
        reader: &mut BitReader<'_>,
        bit_count: usize,
        seed: u32,
        out: &mut [u8],
    ) -> BitResult<()> {
        reader.copy_bits_to(out, bit_count as u64)?;
        self.apply(
            &mut out[..Self::output_byte_count(bit_count)],
            bit_count,
            seed,
        )?;
        Ok(())
    }
}

/// Step `k` (1..=8) of a word function keys `word64` with
/// `state.rotate_right(k)`, `word32` with `state.rotate_left(k)` and `byte`
/// with `state * 11^k`; a rotation count is `key % (bits - 1) + 1` and an
/// operand is the key's low bits, except that `word64` XORs `!u64::from(key)`.
macro_rules! step {
    (u64 $s:ident $k:literal) => { $s.rotate_right($k) };
    (u32 $s:ident $k:literal) => { $s.rotate_left($k) };
    (u8 $s:ident $k:literal) => { $s.wrapping_mul(const { 11u32.pow($k) }) };
    ($t:ident $v:ident $s:ident add $k:literal) => { $v.wrapping_add(step!($t $s $k) as $t) };
    ($t:ident $v:ident $s:ident sub $k:literal) => { $v.wrapping_sub(step!($t $s $k) as $t) };
    (u64 $v:ident $s:ident xor $k:literal) => { $v ^ !u64::from(step!(u64 $s $k)) };
    ($t:ident $v:ident $s:ident xor $k:literal) => { $v ^ step!($t $s $k) as $t };
    ($t:ident $v:ident $s:ident rotl $k:literal) => {
        $v.rotate_left(step!($t $s $k) % ($t::BITS - 1) + 1)
    };
    ($t:ident $v:ident $s:ident rotr $k:literal) => {
        $v.rotate_right(step!($t $s $k) % ($t::BITS - 1) + 1)
    };
    ($t:ident $v:ident $s:ident not) => { !$v };
    (u64 $v:ident $s:ident rev) => { reverse_bits64_without_final_16bit_swap($v) };
    ($t:ident $v:ident $s:ident rev) => { $v.reverse_bits() };
    (u64 $v:ident $s:ident swap) => { swap_adjacent_bits_u64($v) };
    (u32 $v:ident $s:ident swap) => { swap_adjacent_bits_u32($v) };
    (u8 $v:ident $s:ident swap) => { swap_adjacent_bits_u8($v) };
    (u64 $v:ident $s:ident sbox) => { substitute_bytes_u64($v, &SBOX_64) };
    (u32 $v:ident $s:ident sbox) => { substitute_bytes_u32($v, &SBOX_32) };
    (u8 $v:ident $s:ident sbox) => { SBOX_8[$v as usize] };
}

/// Emits one `versions` struct per build, [`TransformVersion`],
/// [`ALL_VERSIONS`] and the per-build dispatch. The three word functions run
/// the same step list.
macro_rules! transforms {
    ($($variant:ident $name:ident $build:literal $addend:literal $offset:literal:
        $($op:ident $($k:literal)?),+;)+) => {
        /// One unit struct per build.
        pub mod versions {
            pub use crate::SeededTransform;
            use crate::{helpers::*, sbox::*};
            $(
                pub struct $name;

                impl SeededTransform for $name {
                    const BRANCH: &'static str = concat!("++Ares-Core+release-", $build);
                    const SEED_ADDEND: u32 = $addend;
                    const INIT_A_OFFSET: u32 = i32::unsigned_abs($offset);
                    const ADD_OFFSET: bool = $offset > 0;

                    fn word64(v: u64, state: u32) -> u64 {
                        $(let v = step!(u64 v state $op $($k)?);)+
                        v
                    }

                    fn word32(v: u32, state: u32) -> u32 {
                        $(let v = step!(u32 v state $op $($k)?);)+
                        v
                    }

                    fn byte(v: u8, state: u32) -> u8 {
                        $(let v = step!(u8 v state $op $($k)?);)+
                        v
                    }
                }
            )+
        }

        /// A game build's payload transform, selected by replay branch string.
        /// Dispatch is once per content block; each arm calls a monomorphised
        /// [`transform_in_place`], so the word loops carry no indirection.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        #[non_exhaustive]
        pub enum TransformVersion {
            $(#[doc = concat!("`++Ares-Core+release-", $build, "`")] $variant,)+
        }

        /// Every transform this crate knows about. A slice, so adding a build
        /// does not change the public type; [`TransformVersion`] is
        /// non-exhaustive for the same reason.
        pub const ALL_VERSIONS: &[TransformVersion] = &[$(TransformVersion::$variant),+];

        impl TransformVersion {
            /// The replay branch string this transform decodes.
            #[must_use]
            pub const fn branch(self) -> &'static str {
                match self {
                    $(Self::$variant => <versions::$name as SeededTransform>::BRANCH,)+
                }
            }

            /// Transform `buf` in place.
            pub fn apply(self, buf: &mut [u8], bit_count: usize, seed: u32) -> BitResult<()> {
                match self {
                    $(Self::$variant => transform_in_place::<versions::$name>(buf, bit_count, seed),)+
                }
            }
        }
    };
}

// variant, struct, build, SEED_ADDEND, INIT_A_OFFSET (negative: subtracted): steps
transforms! {
    V1106 V11_06 "11.06" 0x3325_e3bd  0x3d: add 8, sbox, xor 6, sbox, sbox, rev, swap;
    V1107 V11_07 "11.07" 0x17b0_77d3 -0x2d: xor 8, sbox, rev, not, swap, xor 1;
    V1108 V11_08 "11.08" 0xacf2_cdff -0x01: not, rotr 7, rotl 6, rotl 5, sub 2, swap;
    V1109 V11_09 "11.09" 0x12cf_14e5 -0x1b: sbox, xor 7, xor 6, swap, rotl 3, swap, xor 1;
    V1110 V11_10 "11.10" 0x34e9_d3ec -0x14: sub 8, xor 7, sub 6, rotl 5, sub 4, rev, sbox, not;
    V1111 V11_11 "11.11" 0xc444_5c41 -0x3f: xor 8, sbox, rotl 6, swap, sbox, rotl 1;
    V1200 V12_00 "12.00" 0x7087_6679 -0x07: rotr 8, rev, xor 6, sub 5, xor 4, xor 3, not;
    V1201 V12_01 "12.01" 0x13fd_d831  0x31: sbox, xor 7, sub 6, swap, rotl 4, sbox, xor 2, add 1;
    V1202 V12_02 "12.02" 0x9830_d09d  0x1d: rotl 8, rotr 7, rev, swap, sbox, rev, sub 2, rev;
    V1203 V12_03 "12.03" 0x33d5_9dff -0x01: swap, sub 7, add 6, rotl 5, rotl 4, sbox, rotl 2, add 1;
    V1204 V12_04 "12.04" 0xa568_4b42 -0x3e: rotr 8, rotr 7, rotl 6, rotr 5, add 4, sbox, rotl 1;
    V1205 V12_05 "12.05" 0xc21d_548c  0x0c: rotr 8, not, rev, sub 4, rotr 3, sbox, not;
    V1206 V12_06 "12.06" 0x8d68_6ca6  0x26: xor 8, rotr 7, sub 6, rev, rotl 3, rev, sub 1;
    V1207 V12_07 "12.07" 0x2d21_d7c3 -0x3d: xor 8, add 7, xor 6, swap, sbox, sub 3;
    V1208 V12_08 "12.08" 0xce2e_33e5 -0x1b: rotl 7, sbox, xor 4, rev, add 2, rotr 1;
    V1209 V12_09 "12.09" 0x7ff2_feec -0x14: rotl 8, xor 7, rotl 6, rotl 5, not, xor 3, rotl 2, rotl 1;
    V1210 V12_10 "12.10" 0x12fd_0ee5 -0x1b: rotr 8, swap, sub 6, rotr 5, xor 4, swap;
    V1211 V12_11 "12.11" 0x409d_36a3  0x23: rotr 8, swap, add 6, rev, sub 4, sub 3, sub 2, swap;
    V1300 V13_00 "13.00" 0x2949_b6ef -0x11: add 8, rev, add 6, not, xor 3, sbox, rotr 1;
    V1301 V13_01 "13.01" 0xe62f_cd5c -0x24: not, swap, xor 5, rotr 4, not, add 1;
    V1302 V13_02 "13.02" 0x9e81_a37c -0x04: sbox, rev, sub 6, not, rev, rotl 3, rotr 2;
    V1304 V13_04 "13.04" 0x076d_c658 -0x28: rotr 7, xor 6, sub 5, swap, add 3, add 2, rotl 1;
    V1305 V13_05 "13.05" 0x48c2_6613  0x13: xor 8, sub 7, rotl 6, sub 5, xor 4, xor 3, rotl 2, rotl 1;
    V1306 V13_06 "13.06" 0xe974_593c  0x3c: swap, xor 7, swap, rev, sbox, not, add 2, sbox;
    // Added by Icarus: read from the 13.08 VALORANT-Win64-Shipping.exe reader
    // (RVA 0x4539860) and checked against its native vectors.
    V1308 V13_08 "13.08" 0x3c17_a9fa -0x06: add 8, rev, rotl 6, sbox, rotr 4, sbox, sbox, rev;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_is_bit_count_xor_actor_guid() {
        assert_eq!(seed_for(287, 2), 287 ^ 2);
        assert_eq!(seed_for(0, 0), 0);
    }

    #[test]
    fn branch_lookup_round_trips() {
        for v in ALL_VERSIONS.iter().copied() {
            assert_eq!(TransformVersion::from_branch(v.branch()), Some(v));
            // check_docs reads the registry's builds from the variant names.
            let build = v.branch().trim_start_matches("++Ares-Core+release-");
            assert_eq!(format!("{v:?}"), format!("V{}", build.replace('.', "")));
        }
    }

    #[test]
    fn public_registry_type_does_not_encode_its_length() {
        // Fails to compile if the registry becomes a `[TransformVersion; N]`,
        // whose length would then be public API.
        let _: &'static [TransformVersion] = ALL_VERSIONS;
    }

    #[test]
    fn unknown_branch_is_an_error_naming_the_branch() {
        let err = TransformVersion::require("++Ares-Core+release-99.99").unwrap_err();
        assert_eq!(err.branch, "++Ares-Core+release-99.99");
        let text = err.to_string();
        assert!(text.contains("release-99.99"), "{text}");
        for v in ALL_VERSIONS {
            assert!(text.contains(v.branch()), "{text}");
        }
    }

    #[test]
    fn zero_bits_is_a_noop() {
        let mut buf = [0xAAu8; 4];
        for v in ALL_VERSIONS.iter().copied() {
            v.apply(&mut buf, 0, 1234).unwrap();
            assert_eq!(buf, [0xAAu8; 4]);
        }
    }

    #[test]
    fn apply_does_not_panic_on_an_undersized_buffer() {
        let mut buf = [0u8; 1];
        assert_eq!(
            TransformVersion::V1301.apply(&mut buf, 65, 0).unwrap_err(),
            BitError::InvalidBitLength {
                requested: 65,
                available: 8,
            }
        );
    }
}
