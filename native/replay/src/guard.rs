//! The transform guard. vrfkit refuses a build it has no transform for, but a
//! registered transform that is wrong for this file (a mislabelled build, a
//! hotfix that rotated the transform) decodes into plausible noise. Decoded
//! replication payloads are mostly small integers, flags and padding, so
//! zeros dominate them; noise has about 1/256 zero bytes and half its bits
//! set. The guard samples the start of every decoded field payload.

/// Bytes taken from the front of each field payload.
const PREFIX_BYTES: usize = 8;
/// Stop sampling after this many bytes: enough for a stable share.
const SAMPLE_LIMIT: u64 = 4 << 20;

#[derive(Debug, Default, Clone)]
pub struct GuardSample {
    pub bytes: u64,
    pub zero_bytes: u64,
    pub set_bits: u64,
    /// Field payloads sampled.
    pub payloads: u64,
}

/// What the guard concluded.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GuardVerdict {
    pub zero_share: f64,
    pub bit_density: f64,
    pub verified: bool,
}

/// The 7 replays of the corpus test measure 27.8-32.8% zero bytes over field
/// prefixes; read with another build's transform, 0.21-0.23%.
pub const MIN_ZERO_SHARE: f64 = 0.10;
/// The same replays: 24.1-26.9% of bits set; with the wrong transform, 51%.
pub const MAX_BIT_DENSITY: f64 = 0.35;
/// Fewer sampled bytes than this proves nothing either way.
pub const MIN_SAMPLE_BYTES: u64 = 4096;

impl GuardSample {
    pub fn add(&mut self, raw: &[u8], bit_count: u32) {
        if self.bytes >= SAMPLE_LIMIT {
            return;
        }
        // Whole bytes only: a trailing partial byte is zero-padded by the
        // exporter and would bias the share upwards.
        let whole = (bit_count / 8) as usize;
        let prefix = &raw[..raw.len().min(whole).min(PREFIX_BYTES)];
        if prefix.is_empty() {
            return;
        }
        self.payloads += 1;
        self.bytes += prefix.len() as u64;
        for &b in prefix {
            self.zero_bytes += u64::from(b == 0);
            self.set_bits += u64::from(b.count_ones());
        }
    }

    pub fn verdict(&self) -> GuardVerdict {
        let bytes = self.bytes.max(1) as f64;
        let zero_share = self.zero_bytes as f64 / bytes;
        let bit_density = self.set_bits as f64 / (bytes * 8.0);
        GuardVerdict {
            zero_share,
            bit_density,
            verified: self.bytes >= MIN_SAMPLE_BYTES
                && zero_share >= MIN_ZERO_SHARE
                && bit_density <= MAX_BIT_DENSITY,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// xorshift: deterministic noise standing in for a wrong transform.
    fn noise(n: usize) -> Vec<u8> {
        let mut x: u32 = 0x9E37_79B9;
        (0..n)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                x as u8
            })
            .collect()
    }

    #[test]
    fn noise_fails_the_guard() {
        let mut sample = GuardSample::default();
        for chunk in noise(64 * 1024).chunks(8) {
            sample.add(chunk, 64);
        }
        let v = sample.verdict();
        assert!(!v.verified, "{v:?}");
        assert!(
            v.zero_share < 0.01 && (0.45..0.55).contains(&v.bit_density),
            "{v:?}"
        );
    }

    #[test]
    fn payload_shaped_data_passes() {
        // Small little-endian integers and flags: what replicated fields hold.
        let mut sample = GuardSample::default();
        for i in 0..8192u32 {
            let value = (i % 300).to_le_bytes();
            sample.add(&[value[0], value[1], 0, 0, 1, 0, 0, 0], 64);
        }
        assert!(sample.verdict().verified, "{:?}", sample.verdict());
    }

    #[test]
    fn too_small_a_sample_proves_nothing() {
        let mut sample = GuardSample::default();
        sample.add(&[0; 8], 64);
        assert!(!sample.verdict().verified);
    }

    #[test]
    fn partial_trailing_bytes_are_not_sampled() {
        let mut sample = GuardSample::default();
        sample.add(&[0xFF, 0x01], 9);
        assert_eq!(sample.bytes, 1);
    }
}
