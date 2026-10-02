// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/failure_stats.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! The opt-in, bounded aggregate of stream failures. Only `diag` enables and
//! reads it; it feeds no verdict, summary counter or table row.
//!
//! [`ChannelState::push_stream_failure`](super::ChannelState::push_stream_failure)
//! keeps 32 lines, which every corpus replay fills from the match's opening
//! seconds: a biased sample. This counts every failure, one cell per (kind,
//! cause, group path, function count, handle, consumed bits, preservation):
//! totals exact, cells and payload samples capped against malformed input.
//!
//! Invariants, per pass:
//!
//! 1. `total_failures == field_stream_failures + rpc_stream_failures`: every
//!    site that bumps either also calls [`FailureAggregate::note_failure`]
//!    (`framing.rs` in `vrf-net`, `stream.rs` here), so a mismatch is a wiring
//!    bug, not sampling noise.
//! 2. `preserved_unresolved` (every failure whose whole stream reached a raw
//!    preservation row, post-RepLayout tails included) is a subset of
//!    `total_failures`, reconciles with `unresolved_rpc_payloads_preserved` and
//!    is never loss: `real_loss() == total_failures - preserved_unresolved`.
//!
//! `diag` prints both as `reconciled` ([`FailureAggregate::reconciles`]).

use std::sync::Arc;

use vrf_net::pipeline::{StreamFailure, StreamFailureCause, StreamKind};
use vrf_net::stats::NetStats;
use vrf_schema::FxHashMap;

/// Detailed failure records retained per cell. Counts continue after sample
/// retention stops.
pub const MAX_SAMPLES_PER_CELL: usize = 3;

/// Distinct keyed cells retained per pass; past it exact totals continue in
/// `overflow`, so hostile group paths cannot grow the map without bound.
pub const MAX_FAILURE_CELLS: usize = 4096;

/// Longest payload a sample keeps whole, in bytes; a longer one keeps this
/// prefix, flagged `payload_truncated`.
pub const MAX_SAMPLE_PAYLOAD_BYTES: usize = 96;

/// One aggregate cell: every failure sharing one key.
#[derive(Debug, Default, Clone)]
pub struct FailureCell {
    pub count: u64,
    pub bit_count_total: u64,
    pub consumed_bits_total: u64,
    pub abandoned_bits_total: u64,
    pub samples: Vec<FailureSample>,
}

impl FailureCell {
    /// Add `other`'s count and sums; samples are the caller's business.
    fn add(&mut self, other: &Self) {
        self.count += other.count;
        self.bit_count_total += other.bit_count_total;
        self.consumed_bits_total += other.consumed_bits_total;
        self.abandoned_bits_total += other.abandoned_bits_total;
    }
}

/// One representative failure: its cell's key holds the consumed bits and
/// preservation it shares; `payload_hex` is the block's decoded bytes, up to
/// [`MAX_SAMPLE_PAYLOAD_BYTES`] (always `Some`: samples come only with one).
#[derive(Debug, Clone)]
pub struct FailureSample {
    pub actor_net_guid: u32,
    pub bit_count: u32,
    pub abandoned_bits: u64,
    pub record_offset: Option<u64>,
    pub payload_hex: Option<String>,
    pub payload_truncated: bool,
}

/// The dimensions every failure is aggregated under. `consumed_bits` is a key,
/// not a sum: it separates a drift that always stops at one offset (a field
/// stream consuming 185 of 200 bits) from random offsets, which a sum would
/// average away. A group fails at very few distinct offsets, so cells stay few.
/// Ordered field by field, for a deterministic tie-break.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FailureKey {
    pub kind: StreamKind,
    pub cause: StreamFailureCause,
    /// As the resolver left it -- a bare instance name or `<unknown:{guid}>`
    /// stays as-is, never guessed into a class.
    pub group_path: Arc<str>,
    /// The function count the RPC handle read used (0 for RepLayout and for
    /// unresolved groups).
    pub function_count: u32,
    /// Handle of the failing record, when the walk tracked one.
    pub record_handle: Option<u32>,
    pub consumed_bits: u64,
    /// Whether every bit in the failed stream reached a raw preservation row.
    pub payload_preserved: bool,
}

impl FailureKey {
    fn new(failure: &StreamFailure, group_path: Arc<str>) -> Self {
        Self {
            kind: failure.kind,
            cause: failure.cause,
            group_path,
            function_count: failure.function_count,
            record_handle: failure.record_handle,
            consumed_bits: failure.consumed_bits,
            payload_preserved: failure.payload_preserved,
        }
    }
}

/// The bounded aggregate for one pass (main ReplayData or checkpoint).
#[derive(Debug, Clone)]
pub struct FailureAggregate {
    cells: FxHashMap<FailureKey, FailureCell>,
    /// Failures whose key arrived after the distinct-cell cap was reached.
    overflow: FailureCell,
    /// The two reconciled totals; see the module doc.
    total_failures: u64,
    preserved_unresolved: u64,
    /// Whether decoded payload bytes may be retained in bounded samples.
    retain_payloads: bool,
}

impl Default for FailureAggregate {
    fn default() -> Self {
        Self::new(false)
    }
}

impl FailureAggregate {
    /// Payload retention is off unless the caller opts in; all counters and
    /// non-payload dimensions remain either way.
    pub fn new(retain_payloads: bool) -> Self {
        Self {
            cells: FxHashMap::default(),
            overflow: FailureCell::default(),
            total_failures: 0,
            preserved_unresolved: 0,
            retain_payloads,
        }
    }

    /// Count one failure. Samples come only from [`Self::note_payload`], whose
    /// callers hold the decoded bytes. Preservation is read from `failure`, so
    /// the key and the reconciled counter cannot disagree.
    pub fn note_failure(&mut self, failure: &StreamFailure, group_path: Arc<str>) {
        let key = FailureKey::new(failure, group_path);
        let cell = Self::cell(&mut self.cells, key).unwrap_or(&mut self.overflow);
        cell.count += 1;
        cell.bit_count_total += u64::from(failure.bit_count);
        cell.consumed_bits_total += failure.consumed_bits;
        cell.abandoned_bits_total += failure.remaining_bits;
        self.total_failures += 1;
        if failure.payload_preserved {
            self.preserved_unresolved += 1;
        }
    }

    /// Attach one real-payload sample to a cell, from the three payload
    /// callbacks framing makes after a block's `on_stream_failure`. Never
    /// counts: that is one [`Self::note_failure`] per failure.
    pub fn note_payload(&mut self, failure: &StreamFailure, group_path: Arc<str>, payload: &[u8]) {
        if !self.retain_payloads {
            return;
        }
        let Some(cell) = Self::cell(&mut self.cells, FailureKey::new(failure, group_path)) else {
            return;
        };
        if cell.samples.len() >= MAX_SAMPLES_PER_CELL {
            return;
        }
        let take = payload.len().min(MAX_SAMPLE_PAYLOAD_BYTES);
        cell.samples.push(FailureSample {
            actor_net_guid: failure.actor_net_guid.0,
            bit_count: failure.bit_count,
            abandoned_bits: failure.remaining_bits,
            record_offset: failure.record_offset,
            payload_hex: Some(hex(&payload[..take])),
            payload_truncated: payload.len() > MAX_SAMPLE_PAYLOAD_BYTES,
        });
    }

    /// The cell for `key`, created while the map is under the distinct-cell
    /// cap; `None` for a new key once it is full.
    fn cell(
        cells: &mut FxHashMap<FailureKey, FailureCell>,
        key: FailureKey,
    ) -> Option<&mut FailureCell> {
        if cells.len() < MAX_FAILURE_CELLS || cells.contains_key(&key) {
            Some(cells.entry(key).or_default())
        } else {
            None
        }
    }

    /// Merge another pass's aggregate in (each checkpoint chunk has its own
    /// channel state): counts and sums add, samples fill up to the cap.
    pub fn absorb(&mut self, other: &mut Self) {
        self.total_failures += other.total_failures;
        self.preserved_unresolved += other.preserved_unresolved;
        self.overflow.add(&other.overflow);
        let mut other_cells: Vec<_> = other.cells.drain().collect();
        other_cells.sort_by(|(a, _), (b, _)| a.cmp(b));
        for (key, mut other_cell) in other_cells {
            let Some(cell) = Self::cell(&mut self.cells, key) else {
                self.overflow.add(&other_cell);
                continue;
            };
            cell.add(&other_cell);
            let take = if self.retain_payloads {
                MAX_SAMPLES_PER_CELL
                    .saturating_sub(cell.samples.len())
                    .min(other_cell.samples.len())
            } else {
                0
            };
            cell.samples.extend(other_cell.samples.drain(..take));
        }
    }

    /// Every failure counted (invariant 1).
    pub fn total_failures(&self) -> u64 {
        self.total_failures
    }

    /// The wholly preserved subset (invariant 2).
    pub fn preserved_unresolved(&self) -> u64 {
        self.preserved_unresolved
    }

    /// Failures not wholly preserved (invariant 2). A block count: earlier
    /// fields of a failed block may still have emitted rows.
    pub fn real_loss(&self) -> u64 {
        self.total_failures - self.preserved_unresolved
    }

    /// Whether both invariants hold against the same pass's `NetStats`.
    pub fn reconciles(&self, net: &NetStats) -> bool {
        self.total_failures == net.field_stream_failures + net.rpc_stream_failures
            && self.preserved_unresolved == net.unresolved_rpc_payloads_preserved
    }

    /// Failures counted exactly but omitted from keyed cells after the cap.
    pub fn overflow(&self) -> &FailureCell {
        &self.overflow
    }

    /// Whether raw decoded payload bytes were explicitly enabled.
    pub fn retains_payloads(&self) -> bool {
        self.retain_payloads
    }

    /// The cells by count descending, then key ascending, so ties in count
    /// cannot shuffle between runs.
    pub fn cells_sorted(&self) -> Vec<(&FailureKey, &FailureCell)> {
        let mut cells: Vec<(&FailureKey, &FailureCell)> = self.cells.iter().collect();
        cells.sort_by(|(a, ac), (b, bc)| bc.count.cmp(&ac.count).then_with(|| a.cmp(b)));
        cells
    }
}

/// Lowercase hex without separators.
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use vrf_net::types::NetworkGuid;

    fn failure(kind: StreamKind, cause: StreamFailureCause, consumed: u64) -> StreamFailure {
        StreamFailure {
            kind,
            actor_net_guid: NetworkGuid(7),
            bit_count: 200,
            function_count: 0,
            consumed_bits: consumed,
            remaining_bits: 200 - consumed,
            cause,
            record_handle: Some(3),
            record_offset: Some(consumed),
            payload_preserved: false,
        }
    }

    /// A RepLayout failure and a genuinely lost RPC failure are both real
    /// loss, separated by kind.
    #[test]
    fn real_loss_keeps_rep_layout_and_rpc_apart() {
        let mut agg = FailureAggregate::default();
        let field = failure(
            StreamKind::RepLayout,
            StreamFailureCause::AbandonedTail,
            185,
        );
        let rpc = failure(StreamKind::Rpc, StreamFailureCause::ReadError, 0);
        agg.note_failure(
            &field,
            Arc::from("/Script/ShooterGame.AresAbilitySystemComponent"),
        );
        agg.note_failure(&rpc, Arc::from("SomeUnresolved"));
        assert_eq!(agg.total_failures(), 2);
        assert_eq!(agg.preserved_unresolved(), 0);
        assert_eq!(agg.real_loss(), 2);
        let cells = agg.cells_sorted();
        assert_eq!(cells.len(), 2);
        assert_eq!(cells[0].0.kind, StreamKind::RepLayout);
        assert_eq!(cells[0].0.cause, StreamFailureCause::AbandonedTail);
        assert_eq!(cells[1].0.kind, StreamKind::Rpc);
        assert_eq!(cells[1].0.cause, StreamFailureCause::ReadError);
    }

    /// Both invariants against the pass's `NetStats`: a failure framing
    /// counted but the aggregate missed, or a preservation it did not see,
    /// is a wiring bug and reads `false`.
    #[test]
    fn reconciles_checks_both_invariants_against_net_stats() {
        let mut agg = FailureAggregate::default();
        let mut rpc = failure(StreamKind::Rpc, StreamFailureCause::ReadError, 0);
        rpc.payload_preserved = true;
        let field = failure(StreamKind::RepLayout, StreamFailureCause::ReadError, 9);
        agg.note_failure(&field, "A".into());
        agg.note_failure(&rpc, "B".into());
        let net = |field, rpc, preserved| NetStats {
            field_stream_failures: field,
            rpc_stream_failures: rpc,
            unresolved_rpc_payloads_preserved: preserved,
            ..NetStats::default()
        };
        assert!(agg.reconciles(&net(1, 1, 1)));
        for wrong in [net(1, 2, 1), net(0, 1, 1), net(1, 1, 0)] {
            assert!(!agg.reconciles(&wrong));
        }
    }

    /// Absorb adds counts and moves samples up to the cap, so a checkpoint
    /// pass merged into a main pass cannot duplicate or lose a total.
    #[test]
    fn absorb_adds_counts_and_fills_samples() {
        let path = Arc::from("/Script/ShooterGame.X");
        let f = failure(
            StreamKind::RepLayout,
            StreamFailureCause::AbandonedTail,
            100,
        );
        let mut main = FailureAggregate::new(true);
        for _ in 0..4 {
            main.note_payload(&f, Arc::clone(&path), &[0xAA]);
            main.note_failure(&f, Arc::clone(&path));
        }
        let mut cp = FailureAggregate::new(true);
        for _ in 0..6 {
            cp.note_payload(&f, Arc::clone(&path), &[0xBB]);
            cp.note_failure(&f, Arc::clone(&path));
        }
        main.absorb(&mut cp);
        assert_eq!(main.total_failures(), 10);
        assert_eq!(main.real_loss(), 10);
        let (_, cell) = &main.cells_sorted()[0];
        assert_eq!(cell.count, 10);
        assert_eq!(cell.samples.len(), MAX_SAMPLES_PER_CELL);
        assert!(cp.cells_sorted().is_empty(), "absorb drains the source");
    }

    /// A payload up to the cap is kept whole; any longer one, however long,
    /// keeps the cap's prefix and says so.
    #[test]
    fn a_long_payload_keeps_a_flagged_prefix() {
        let mut agg = FailureAggregate::new(true);
        let f = failure(StreamKind::Rpc, StreamFailureCause::ReadError, 0);
        for len in [MAX_SAMPLE_PAYLOAD_BYTES, MAX_SAMPLE_PAYLOAD_BYTES + 1, 2000] {
            agg.note_payload(&f, Arc::from("Group"), &vec![0x7a; len]);
        }
        let samples = &agg.cells[&FailureKey::new(&f, Arc::from("Group"))].samples;
        let kept: Vec<_> = (samples.iter())
            .map(|s| (s.payload_hex.as_deref(), s.payload_truncated))
            .collect();
        let prefix = "7a".repeat(MAX_SAMPLE_PAYLOAD_BYTES);
        let prefix = Some(prefix.as_str());
        assert_eq!(kept, [(prefix, false), (prefix, true), (prefix, true)]);
    }

    #[test]
    fn default_does_not_retain_payloads() {
        let mut agg = FailureAggregate::default();
        let f = failure(StreamKind::Rpc, StreamFailureCause::ReadError, 0);
        agg.note_payload(&f, Arc::from("Group"), &[0xAA]);
        agg.note_failure(&f, Arc::from("Group"));
        assert!(agg.cells_sorted()[0].1.samples.is_empty());
    }

    #[test]
    fn distinct_cell_cap_preserves_exact_totals_in_overflow() {
        let mut agg = FailureAggregate::default();
        let f = failure(StreamKind::RepLayout, StreamFailureCause::ReadError, 0);
        for index in 0..=MAX_FAILURE_CELLS {
            agg.note_failure(&f, Arc::from(format!("Group{index}")));
        }

        assert_eq!(agg.total_failures(), (MAX_FAILURE_CELLS + 1) as u64);
        assert_eq!(agg.cells_sorted().len(), MAX_FAILURE_CELLS);
        assert_eq!(agg.overflow().count, 1);
        let retained: u64 = agg.cells_sorted().iter().map(|(_, cell)| cell.count).sum();
        assert_eq!(retained + agg.overflow().count, agg.total_failures());
    }
}
