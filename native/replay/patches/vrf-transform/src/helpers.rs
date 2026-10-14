//! Primitives shared by every build's payload transform, identical from
//! release-11.06 through release-13.06: the PRNG, its seed mixing, the bit
//! permutations the steps use and little-endian word IO.

/// Multiplier used by both PRNG seeds.
pub const MULTIPLIER: u64 = 0x2545_f491_4f6c_dd1d;

/// Seed the second PRNG lane.
#[inline]
#[must_use]
pub const fn initial_prng_b(seed: u32) -> u64 {
    let mixed = (((seed >> 15) ^ seed) >> 12) ^ (seed << 25) ^ seed;
    (mixed as u64).wrapping_mul(MULTIPLIER)
}

/// Seed the first PRNG lane. Builds vary only `seed_addend`, `init_a_offset`
/// and the offset's sign ([`SeededTransform::ADD_OFFSET`](crate::SeededTransform::ADD_OFFSET)).
#[inline]
#[must_use]
pub const fn initial_prng_a(
    seed: u32,
    seed_addend: u32,
    init_a_offset: u32,
    add_offset: bool,
) -> u64 {
    let seed_plus = seed.wrapping_add(seed_addend);
    let offset_term = if add_offset {
        seed.wrapping_add(init_a_offset)
    } else {
        seed.wrapping_sub(init_a_offset)
    }
    .wrapping_mul(0x0200_0000);
    let mixed = (((seed_plus >> 15) ^ seed_plus) >> 12) ^ offset_term ^ seed_plus;
    (mixed as u64).wrapping_mul(MULTIPLIER)
}

/// Advance the PRNG one step. The high 32 bits of the lane sum become the next
/// `state`, which keys the next word; its low byte is returned as the keystream byte.
#[inline]
pub fn advance_state(state: &mut u32, prng_a: &mut u64, prng_b: &mut u64) -> u8 {
    let sum = prng_b.wrapping_add(*prng_a);
    *prng_b ^= *prng_a;
    *prng_a = prng_a.rotate_right(9) ^ (*prng_b << 14) ^ *prng_b;
    *prng_b = prng_b.rotate_left(36);
    *state = (sum >> 32) as u32;
    *state as u8
}

/// Swap each even/odd bit pair (all three widths).
#[inline]
#[must_use]
pub const fn swap_adjacent_bits_u64(v: u64) -> u64 {
    ((v & 0x5555_5555_5555_5555) << 1) | ((v >> 1) & 0x5555_5555_5555_5555)
}

#[inline]
#[must_use]
pub const fn swap_adjacent_bits_u32(v: u32) -> u32 {
    ((v & 0x5555_5555) << 1) | ((v >> 1) & 0x5555_5555)
}

#[inline]
#[must_use]
pub const fn swap_adjacent_bits_u8(v: u8) -> u8 {
    ((v & 0x55) << 1) | ((v >> 1) & 0x55)
}

/// A 64-bit reversal without its 16-bit swap stage: the 1/2/4/8-bit swaps,
/// then the halves exchanged. Not [`u64::reverse_bits`], which silently
/// produces wrong plaintext.
#[inline]
#[must_use]
pub const fn reverse_bits64_without_final_16bit_swap(mut v: u64) -> u64 {
    v = ((v & 0x5555_5555_5555_5555) << 1) | ((v >> 1) & 0x5555_5555_5555_5555);
    v = ((v & 0x3333_3333_3333_3333) << 2) | ((v >> 2) & 0x3333_3333_3333_3333);
    v = ((v & 0x0F0F_0F0F_0F0F_0F0F) << 4) | ((v >> 4) & 0x0F0F_0F0F_0F0F_0F0F);
    v = ((v & 0x00FF_00FF_00FF_00FF) << 8) | ((v >> 8) & 0x00FF_00FF_00FF_00FF);
    v.rotate_left(32)
}

/// Apply a byte substitution table to each byte of a 64-bit word.
#[inline]
#[must_use]
pub fn substitute_bytes_u64(v: u64, table: &[u8; 256]) -> u64 {
    let mut out = 0u64;
    let mut i = 0;
    while i < 8 {
        let b = ((v >> (i * 8)) & 0xFF) as u8;
        out |= u64::from(table[b as usize]) << (i * 8);
        i += 1;
    }
    out
}

/// Apply a byte substitution table to each byte of a 32-bit word.
#[inline]
#[must_use]
pub fn substitute_bytes_u32(v: u32, table: &[u8; 256]) -> u32 {
    let mut out = 0u32;
    let mut i = 0;
    while i < 4 {
        let b = ((v >> (i * 8)) & 0xFF) as u8;
        out |= u32::from(table[b as usize]) << (i * 8);
        i += 1;
    }
    out
}

/// Read a little-endian `u64` at `offset`. The staging loop guarantees the
/// bounds (here and in `read_u32`), so the `expect` cannot fire.
#[inline]
#[must_use]
pub fn read_u64(buf: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(
        buf[offset..offset + 8]
            .try_into()
            .expect("8 bytes in range"),
    )
}

/// Read a little-endian `u32` at `offset`.
#[inline]
#[must_use]
pub fn read_u32(buf: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(
        buf[offset..offset + 4]
            .try_into()
            .expect("4 bytes in range"),
    )
}

/// Write a little-endian `u64` at `offset`.
#[inline]
pub fn write_u64(buf: &mut [u8], offset: usize, value: u64) {
    buf[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
}

/// Write a little-endian `u32` at `offset`.
#[inline]
pub fn write_u32(buf: &mut [u8], offset: usize, value: u32) {
    buf[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}
