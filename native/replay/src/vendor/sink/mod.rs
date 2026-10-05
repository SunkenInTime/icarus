// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/mod.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! Sink implementation connecting `vrf-net` events to `vrf-export` records.
//!
//! # Design: no skipping
//!
//! Every field and RPC is emitted, even when its group path or field name does
//! not resolve: then `group_path = "<unknown:{guid}>"` and `field_name = None`.
//! A block an unresolved ClassNetCache function table leaves unsplittable is
//! emitted whole as one marked preservation row, never as fabricated fields, so
//! the Parquet output stays a **lossless** representation of the stream.
//!
//! `vrfkit validate` runs this whole path and writes no file, so it times the
//! sink alone: docs/PERFORMANCE_NOTES.md#what-the-whole-sink-costs.

mod blobs;
mod failure_stats;
mod intern;
mod measured_routes;
mod paths;
mod rpc;
mod stream;

pub use failure_stats::{FailureAggregate, MAX_FAILURE_CELLS};

use std::sync::Arc;

use smallvec::SmallVec;
use vrf_decode::{
    ArrayDecodeStats, GroupHashState, OVERLAY_HANDLE_TABLE, OVERLAY_TABLE, OverlayStats,
    OverlayTable, group_hash_state,
};
use vrf_export::{
    ActorRecord, CheckpointBlockRecord, CheckpointIdentity, FieldRecord, MovementRecord,
    PartialRecord,
};
use vrf_net::net_guid::GuidPathSink;
use vrf_net::types::NetworkGuid;
use vrf_schema::{FxHashMap, NetGuidCache};

use intern::NameInterner;
use measured_routes::{MeasuredArrayRoute, MeasuredArrayRoutes};
use paths::{BlockPathMemo, ChannelArchetype};
use rpc::RpcParamGroupMemo;

static TABLE: OverlayTable = OverlayTable::with_handles(&OVERLAY_TABLE, &OVERLAY_HANDLE_TABLE);

/// How many stream-failure lines to retain. See [`ChannelState::stream_failures`].
const MAX_STREAM_FAILURE_RECORDS: usize = 32;

/// One BombPlayerState actor's identity for the manifest `players` array:
/// `Subject`, the account UUID, and `SpawnedCharacter`, the character actor
/// NetGUID (equal to `movement.character_net_guid`). Together they join every
/// actor-keyed table to a stable account -- what `playerLoadouts`'
/// `characterId` cannot do when two players pick the same agent.
#[derive(Debug, Clone, Default)]
pub struct PlayerIdentity {
    pub subject: Option<String>,
    /// Every non-zero `SpawnedCharacter`, once each, ordered by its last write:
    /// the last is the current body, earlier ones pawns a reconnect replaced.
    pub character_net_guids: Vec<u32>,
}

/// State that must outlive a packet. `ExportSink` is rebuilt for every packet
/// (it borrows the `NetGuidCache` mutably), so the channel archetypes, the two
/// memos and the name pool live here, or they would never warm up.
#[derive(Debug, Clone, Default)]
pub struct ChannelState {
    /// channel_index -> archetype, stamped with its actor ([`ChannelArchetype`]).
    archetypes: FxHashMap<u32, ChannelArchetype>,
    rpc_param_groups: RpcParamGroupMemo,
    block_paths: BlockPathMemo,
    names: NameInterner,
    /// Bumped when the archetype map changes: one of [`BlockPathMemo`]'s three
    /// stamps (see [`paths`]).
    resolution_generation: u64,
    /// One line per block whose inner stream did not walk, capped at
    /// [`MAX_STREAM_FAILURE_RECORDS`]: a wrong transform fails nearly every
    /// block and the first few dozen say it all; the population is in `failures`.
    stream_failures: Vec<String>,
    /// Opt-in for `diag`; `None` elsewhere, so export pays no sampling cost.
    failures: Option<FailureAggregate>,
    /// PlayerState actor NetGUID -> [`PlayerIdentity`], filled by `on_field`.
    players: FxHashMap<u32, PlayerIdentity>,
}

impl ChannelState {
    /// Record one stream failure, up to the cap.
    pub fn push_stream_failure(&mut self, line: String) {
        if self.stream_failures.len() < MAX_STREAM_FAILURE_RECORDS {
            self.stream_failures.push(line);
        }
    }

    #[must_use]
    pub fn stream_failures(&self) -> &[String] {
        &self.stream_failures
    }

    /// Enable bounded failure aggregation for a diagnostic pass.
    pub fn enable_failure_aggregate(&mut self, retain_payloads: bool) {
        self.failures = Some(FailureAggregate::new(retain_payloads));
    }

    /// Take the failure aggregate out, leaving it empty: the checkpoint pass
    /// drains each chunk's channel state into the caller's totals.
    #[must_use]
    pub fn take_failure_aggregate(&mut self) -> FailureAggregate {
        self.failures.take().unwrap_or_default()
    }

    /// Captured player identities, for the manifest `players` array.
    // (vendor: `export` feature gate removed)
    #[must_use]
    pub fn players(&self) -> &FxHashMap<u32, PlayerIdentity> {
        &self.players
    }

    /// Declare that the archetype map changed (the cache's GUID maps have
    /// `NetGuidCache::guid_generation`): a resolution input no stamp covers is
    /// silent byte movement, not a test failure.
    fn note_resolution_input_changed(&mut self) {
        self.resolution_generation = self.resolution_generation.wrapping_add(1);
    }
}

/// Everything one pass's sink counted: `Pass::walk` lends the pass's totals
/// to each packet's sink, so they accumulate in place.
#[derive(Debug, Clone, Default)]
pub struct ExportStats {
    /// Every row `push_field` wrote: the `fields.parquet` (or
    /// `checkpoint_fields.parquet`) row count, not NetStats' `fields`.
    pub fields_emitted: u64,
    /// The sink's own count of four events vrf-net counts beside the same
    /// callbacks, so each must equal its `NetStats` twin: a difference is a
    /// missing or extra `+= 1` here, never framing. The manifest prefixes them
    /// `sink_`; `tools/verify_build_corpus.py` fails a replay whose pair differs.
    pub rpcs_emitted: u64,
    pub actor_opens: u64,
    pub actor_closes: u64,
    pub content_blocks: u64,
    /// Its `error_report` holds the pass's decode errors.
    pub overlay: OverlayStats,
    pub array: ArrayDecodeStats,
    /// Exact 24-bit `TrackedRewards` windows with the measured opaque zero
    /// byte. They preserve their parent raw row and emit no child rows.
    pub tracked_rewards_opaque_empty_variants: u64,
    /// Empty ActiveBlinds deltas whose trailing zero IntPacked was spared
    /// (`active_blind_array_bits`); the parent row keeps the byte, and no other
    /// number moves if a build makes such trailers common.
    pub active_blinds_empty_trailers: u64,
    /// EffectContainer RPC parameters turned into a `value_str` JSON array:
    /// the decoder's only success signal there, as the overlay buckets are
    /// filled first. Failures land in `overlay.decoded_err`; the
    /// `ServerActiveEffects` members it types are array leaves, not counted here.
    pub effect_blobs_decoded: u64,

    /// Struct-blob (`RoundResults`, `TeamEconomy`, `RoundInfos`) parent rows
    /// whose dedicated decoder produced elements.
    pub struct_blobs_decoded: u64,

    /// Item NetGUID rows from the `MultiItemSlot.MultiContents` decoder, one per
    /// item reference. The parent stays `Raw` (`not_in_table`), so as with
    /// [`Self::effect_blobs_decoded`] this is the decoder's only signal.
    pub multi_contents_items_emitted: u64,

    /// RPC rows from the fc=34 ClassNetCache decoder for
    /// `AbilitiesAndBuffsComponent` -- extra rows beside an unresolved
    /// payload's preservation row, and verified RepLayout-tail bodies. The only
    /// signal that decoder produced RPC structure.
    pub cnc_rpcs_emitted: u64,

    /// Unresolved `AbilitiesAndBuffsComponent` payloads offered to that
    /// brute-force walk: the denominator [`Self::cnc_rpcs_emitted`] does not
    /// have, since that counter also counts RepLayout-tail decodes.
    pub cnc_bruteforce_payloads_attempted: u64,

    /// Of those, payloads the fc=34 walk did not fit: only the preservation row,
    /// which keeps every bit. 34 is empirical, so if an update breaks the walk
    /// `CNC RPC rows` shrinks and this says why.
    pub cnc_bruteforce_payloads_unwalked: u64,

    /// Post-RepLayout ClassNetCache tails decoded under verified component
    /// provenance and strict one-RPC framing.
    pub rep_layout_cnc_tails_decoded: u64,

    /// Post-RepLayout tails retained whole because their provenance or framing
    /// was not sufficient for the verified decoder.
    pub rep_layout_cnc_tails_preserved: u64,

    /// Struct-blob decodes that returned an error: additive, so no row or bit is
    /// lost, but a moved `RoundResults` handle would otherwise export a clean
    /// run with no match score.
    pub struct_blobs_failed: u64,

    /// The first failure verbatim, never overwritten: it names the member and
    /// handle a build moved.
    pub struct_blob_first_error: Option<String>,

    /// Movement-decode problems: soft errors counted per occurrence
    /// (`RpcDecodeResult.error_count`) plus hard `Err`s. Without it a changed
    /// section format shortens `movement.parquet` with every counter clean.
    pub movement_rpc_errors: u64,

    /// The first movement-decode problem verbatim, for the summary to name.
    pub movement_first_error: Option<String>,

    /// Sections in a `movementBitCount`-sized window that stopped with bits
    /// unread, and those bits (`vrf_movement::RpcDecodeResult::sized_section_tails`).
    /// A soft tally: the batch still counts as clean, so no Parquet row moves.
    pub movement_sized_section_tails: u64,
    pub movement_sized_section_tail_bits: u64,
    /// The same for windows that ran to the end of the component stream, where
    /// what follows may be other data: kept apart, never summed with the above.
    pub movement_open_section_tails: u64,
    pub movement_open_section_tail_bits: u64,
    /// Byte-wrapped movement streams and the bits after their envelopes,
    /// which nothing reads (`vrf_movement::RpcDecodeResult::envelope_trailer_bits`):
    /// 24 per stream on every measured replay. A soft tally like the tails.
    pub movement_envelope_trailers: u64,
    pub movement_envelope_trailer_bits: u64,

    /// RPC payloads whose parameter loop broke on a malformed read before the
    /// zero-handle terminator. The walk keeps its rows and reports success, so
    /// this is the only signal of an abandoned walk. Zero on valid replays.
    pub truncated_rpcs: u64,

    /// RPC parameter walks begun (a function name resolved): the work whose
    /// zero `truncated_rpcs` is evidence of.
    pub rpc_param_walks: u64,

    /// Bits after an RPC's zero-handle terminator beyond the one alignment bit
    /// `FunctionParameters` allows. Counted, not rejected, and not lost: the
    /// payload also gets a whole-payload row, so every counted bit is in
    /// `raw_bits`. Nonzero on the main pass of 21 of 24 corpus builds, all from
    /// `ActiveGameplayEffects` on `AresAbilitySystemComponent_ClassNetCache`
    /// (custom-delta data past the zero handle; see `ActiveGameplayEffects` in
    /// docs/DATA.md); a suffix on any other handle would be new.
    pub rpc_suffix_bits_dropped: u64,

    /// Flattened array leaves whose resolved type failed to decode; the raw leaf
    /// rows are still emitted, this counts the typed values lost.
    pub array_leaf_decode_errors: u64,

    /// Typed world-location children emitted from the guarded map-click array.
    pub targeting_world_locations_decoded: u64,

    /// Child rows each measured array route emitted ([`Self::route_children`]):
    /// a route whose layout moved refuses every leaf while the others keep the
    /// array totals up.
    pub route_children_player_information: u64,
    pub route_children_tracked_rewards: u64,
    pub route_children_selected_v2: u64,
    pub route_children_kill_data: u64,
    pub route_children_server_active_effects: u64,
    pub route_children_requested_ignore_actors: u64,
    pub route_children_active_blinds: u64,
    pub route_children_projectile_path: u64,
}

/// `counters` and `counters_mut` over one list per struct. Each destructure
/// has no `..`, so a new counter does not compile until it is listed, and each
/// name is its field's (the decoder structs' prefixed).
macro_rules! export_counters {
    ($($prefix:literal $ty:ident $(.$place:ident)? { $($field:ident),* } except { $($skip:ident),* })*) => {
        impl ExportStats {
            /// Every counter by its published name; the two first-error strings
            /// and the overlay's error report are not counters.
            pub(crate) fn counters(&self) -> Vec<(&'static str, u64)> {
                let mut all = Vec::new();
                $({
                    let $ty { $(ref $field,)* $($skip: _,)* } = (*self)$(.$place)?;
                    all.extend([$((concat!($prefix, stringify!($field)), *$field)),*]);
                })*
                all
            }

            /// [`Self::counters`], writable.
            #[cfg(test)]
            pub(crate) fn counters_mut(&mut self) -> Vec<(&'static str, &mut u64)> {
                let mut all = Vec::new();
                $({
                    let $ty { $(ref mut $field,)* $($skip: _,)* } = (*self)$(.$place)?;
                    all.extend([$((concat!($prefix, stringify!($field)), $field)),*]);
                })*
                all
            }
        }
    };
}

export_counters! {
    "" ExportStats {
        fields_emitted, rpcs_emitted, actor_opens, actor_closes, content_blocks,
        tracked_rewards_opaque_empty_variants, active_blinds_empty_trailers, effect_blobs_decoded,
        struct_blobs_decoded, multi_contents_items_emitted, cnc_rpcs_emitted,
        cnc_bruteforce_payloads_attempted, cnc_bruteforce_payloads_unwalked,
        rep_layout_cnc_tails_decoded, rep_layout_cnc_tails_preserved, struct_blobs_failed,
        movement_rpc_errors, movement_sized_section_tails, movement_sized_section_tail_bits,
        movement_open_section_tails, movement_open_section_tail_bits, movement_envelope_trailers,
        movement_envelope_trailer_bits, truncated_rpcs, rpc_param_walks, rpc_suffix_bits_dropped,
        array_leaf_decode_errors, targeting_world_locations_decoded,
        route_children_player_information, route_children_tracked_rewards,
        route_children_selected_v2, route_children_kill_data, route_children_server_active_effects,
        route_children_requested_ignore_actors, route_children_active_blinds,
        route_children_projectile_path
    } except { overlay, array, struct_blob_first_error, movement_first_error }
    "overlay_" OverlayStats.overlay {
        decoded_ok, decoded_err, raw_or_skip, not_in_table, no_field_name, handle_conflicts_refused
    } except { error_report }
    "array_" ArrayDecodeStats.array {
        elements_decoded, fields_emitted, truncations, errors, unconsumed_nested_bits,
        unconsumed_root_bits, implicit_terminations
    } except {}
}

impl ExportStats {
    /// `route`'s child-row counter; no wildcard, so a new route does not
    /// compile until it has one.
    fn route_children(&mut self, route: MeasuredArrayRoute) -> &mut u64 {
        match route {
            MeasuredArrayRoute::AllPlayersObfuscatedPlayerInformation => {
                &mut self.route_children_player_information
            }
            MeasuredArrayRoute::TrackedRewards => &mut self.route_children_tracked_rewards,
            MeasuredArrayRoute::SelectedV2 => &mut self.route_children_selected_v2,
            MeasuredArrayRoute::KillData => &mut self.route_children_kill_data,
            MeasuredArrayRoute::ServerActiveEffects => {
                &mut self.route_children_server_active_effects
            }
            MeasuredArrayRoute::RequestedIgnoreActors => {
                &mut self.route_children_requested_ignore_actors
            }
            MeasuredArrayRoute::ActiveBlinds => &mut self.route_children_active_blinds,
            MeasuredArrayRoute::NetworkedProjectilePath => &mut self.route_children_projectile_path,
        }
    }

    /// Record a movement-RPC decode outcome: soft per-update errors and hard
    /// `Err`s both count, and the first is kept verbatim for the summary.
    pub fn record_movement_decode(
        &mut self,
        result: Result<&vrf_movement::RpcDecodeResult, &vrf_movement::MovementError>,
    ) {
        match result {
            Ok(r) => {
                // No `..`: a counter added to the decoder's result must be
                // read here, or it would reach nothing.
                let vrf_movement::RpcDecodeResult {
                    total_moves: _,
                    update_count: _,
                    error_count,
                    sized_section_tails,
                    sized_section_tail_bits,
                    open_section_tails,
                    open_section_tail_bits,
                    envelope_trailer_streams,
                    envelope_trailer_bits,
                } = *r;
                self.movement_sized_section_tails += u64::from(sized_section_tails);
                self.movement_sized_section_tail_bits += sized_section_tail_bits;
                self.movement_open_section_tails += u64::from(open_section_tails);
                self.movement_open_section_tail_bits += open_section_tail_bits;
                self.movement_envelope_trailers += u64::from(envelope_trailer_streams);
                self.movement_envelope_trailer_bits += envelope_trailer_bits;
                if error_count > 0 {
                    self.movement_rpc_errors = self
                        .movement_rpc_errors
                        .saturating_add(u64::from(error_count));
                    self.movement_first_error.get_or_insert(format!(
                        "{error_count} movement decode error(s) in one RPC batch"
                    ));
                }
            }
            Err(e) => {
                self.movement_rpc_errors = self.movement_rpc_errors.saturating_add(1);
                self.movement_first_error
                    .get_or_insert_with(|| e.to_string());
            }
        }
    }
}

#[cfg(test)]
mod stats_tests {
    use super::ExportStats;
    use vrf_movement::{MovementError, RpcDecodeResult};

    /// A clean-framed batch with `error_count` soft errors and the six tallies
    /// (sized tails, bits, open tails, bits, envelope trailers, bits).
    fn batch(error_count: u32, t: [u32; 6]) -> Result<RpcDecodeResult, MovementError> {
        Ok(RpcDecodeResult {
            error_count,
            sized_section_tails: t[0],
            sized_section_tail_bits: t[1].into(),
            open_section_tails: t[2],
            open_section_tail_bits: t[3].into(),
            envelope_trailer_streams: t[4],
            envelope_trailer_bits: t[5].into(),
            ..Default::default()
        })
    }

    /// Each tail and trailer tally sums into its own counter from every `Ok`
    /// decode, soft errors or not, and none is a movement error (which would
    /// keep the batch as a raw row); an `Err` carries no tally.
    #[test]
    fn tallies_sum_field_by_field_and_are_not_errors() {
        let mut s = ExportStats::default();
        s.record_movement_decode(batch(0, [1, 2, 3, 4, 5, 6]).as_ref());
        s.record_movement_decode(batch(1, [10, 20, 30, 40, 50, 60]).as_ref());
        s.record_movement_decode(Err(MovementError::ErrorSentinel).as_ref());
        let tallies = [
            s.movement_sized_section_tails,
            s.movement_sized_section_tail_bits,
            s.movement_open_section_tails,
            s.movement_open_section_tail_bits,
            s.movement_envelope_trailers,
            s.movement_envelope_trailer_bits,
        ];
        assert_eq!(tallies, [11, 22, 33, 44, 55, 66]);
        assert_eq!(s.movement_rpc_errors, 2, "the soft error and the Err");
    }

    /// A clean decode records nothing; soft errors count per occurrence and
    /// keep the first text; a later hard error adds one without overwriting
    /// it; a first hard error records its Display.
    #[test]
    fn movement_errors_count_every_occurrence_and_keep_the_first() {
        let mut s = ExportStats::default();
        s.record_movement_decode(batch(0, [0; 6]).as_ref());
        assert_eq!(s.movement_rpc_errors, 0);
        assert!(s.movement_first_error.is_none());
        s.record_movement_decode(batch(3, [0; 6]).as_ref());
        s.record_movement_decode(Err(MovementError::InvalidMagic(0x00)).as_ref());
        assert_eq!(s.movement_rpc_errors, 4);
        assert_eq!(
            s.movement_first_error.as_deref(),
            Some("3 movement decode error(s) in one RPC batch")
        );

        let mut hard = ExportStats::default();
        hard.record_movement_decode(Err(MovementError::ErrorSentinel).as_ref());
        assert_eq!(hard.movement_rpc_errors, 1);
        let msg = hard.movement_first_error.expect("first error recorded");
        assert!(msg.contains("sentinel"), "got: {msg}");
    }

    /// Two struct blobs that fail differently: both are counted and the first
    /// failure's text stays (`Pass::walk` lends one `ExportStats` to every
    /// packet, so this holds across packets too).
    #[test]
    fn a_later_struct_blob_failure_keeps_the_first_error() {
        use std::sync::Arc;
        use vrf_bitio::BitReader;
        use vrf_net::field::FieldSink;
        let group = "/Game/GameModes/Bomb/BombGameState.BombGameState_C";
        let mut rig = super::test_fixtures::Rig::default();
        let export_group = vrf_schema::NetFieldExportGroup::new(group.into(), 7, 8);
        rig.cache.add_export_group(export_group).unwrap();
        let field = vrf_schema::NetFieldExport {
            handle: 1,
            compatible_checksum: 0,
            name: "RoundResults".into(),
        };
        assert!(rig.cache.set_field_on_group(7, field));
        let mut sink = rig.sink();
        sink.set_current_group_path(Arc::from(group));
        for bits in [3u32, 40] {
            sink.on_field(
                1,
                bits,
                BitReader::with_bit_len(&[0xFF; 8], u64::from(bits)).unwrap(),
            );
        }
        assert_eq!(sink.stats.struct_blobs_failed, 2);
        let first = sink.stats.struct_blob_first_error.as_deref().unwrap();
        assert!(
            first.contains("needed 8 bit(s) at position 0 of 3"),
            "{first}"
        );
    }
}

/// The record buffers a sink fills for one packet, lent so their capacity
/// survives it (docs/PERFORMANCE_NOTES.md#recordbuffers-are-lent-not-owned).
/// [`ExportSink::new`] clears them, so a caller that never drains them does not
/// accumulate the whole replay.
#[derive(Debug, Default)]
pub struct RecordBuffers {
    pub fields: Vec<FieldRecord>,
    pub movement: Vec<MovementRecord>,
    pub actors: Vec<ActorRecord>,
    pub partials: Vec<PartialRecord>,
    pub checkpoint_blocks: Vec<CheckpointBlockRecord>,
}

/// The export sink: turns `vrf-net` events into records for the Parquet
/// writers. It borrows the `NetGuidCache` mutably because `vrf-net` calls
/// `GuidPathSink::register_path` mid-packet, for package-map export bunches
/// that declare GUID -> path mappings inline.
pub struct ExportSink<'a> {
    pub cache: &'a mut NetGuidCache,
    channel_state: &'a mut ChannelState,
    pub time_ms: u32,
    pub packet_id: u32,
    records: &'a mut RecordBuffers,
    pub stats: ExportStats,
    /// The checksum-gated structured-array routes this replay's branch admits.
    /// See [`measured_routes`]; empty until `enable_measured_array_routes`.
    measured_array_routes: MeasuredArrayRoutes,
    checkpoint_block_scope: Option<(CheckpointIdentity, u64, u32)>,

    // -- per-content-block context (set by on_content_block) ----------------
    current_channel: u32,
    current_actor_guid: u32,
    /// Subobject GUID of the block being walked; `None` for actor blocks.
    current_object_guid: Option<u32>,
    /// True only when the replay's direct, pre-remap object path is exactly the
    /// measured component that carries the chained fc=34 ClassNetCache stream.
    current_is_abilities_and_buffs: bool,
    /// Interned: a block's rows share one allocation of the path ([`intern`]).
    current_group_path: Arc<str>,
    /// The half-finished overlay key hash for [`current_group_path`](Self::current_group_path),
    /// so each of ~2M probes per replay hashes only the field name. A stale
    /// value turns hits into misses (`raw_bits` only), never a wrong type.
    current_group_hash: GroupHashState,
    current_group_resolution_source: &'static str,
    current_function_count_source: &'static str,
    current_resolution_memo_hit: bool,
}

impl<'a> ExportSink<'a> {
    /// Build a sink for one packet; clears `records` (see [`RecordBuffers`]).
    pub fn new(
        cache: &'a mut NetGuidCache,
        channel_state: &'a mut ChannelState,
        records: &'a mut RecordBuffers,
    ) -> Self {
        records.fields.clear();
        records.movement.clear();
        records.actors.clear();
        records.partials.clear();
        records.checkpoint_blocks.clear();
        let current_group_path = empty_group_path();
        let current_group_hash = group_hash_state(&current_group_path);
        Self {
            cache,
            channel_state,
            time_ms: 0,
            packet_id: 0,
            records,
            stats: ExportStats::default(),
            measured_array_routes: MeasuredArrayRoutes::NONE,
            checkpoint_block_scope: None,
            current_channel: 0,
            current_actor_guid: 0,
            current_object_guid: None,
            current_is_abilities_and_buffs: false,
            current_group_path,
            current_group_hash,
            current_group_resolution_source: "unset",
            current_function_count_source: "unset",
            current_resolution_memo_hit: false,
        }
    }

    /// Admit the structured-array routes measured for `branch` ([`measured_routes`]).
    pub(super) fn enable_measured_array_routes(&mut self, branch: &str) {
        self.measured_array_routes = MeasuredArrayRoutes::for_branch(branch);
    }

    /// Whether `route` may expand its parent in this replay.
    fn admits(&self, route: MeasuredArrayRoute) -> bool {
        self.measured_array_routes.admits(route)
    }

    // (vendor: `export` feature gate removed)
    pub(super) fn enable_checkpoint_block_context(
        &mut self,
        checkpoint: CheckpointIdentity,
        field_row_offset: u64,
        block_index_offset: u32,
    ) {
        self.checkpoint_block_scope = Some((checkpoint, field_row_offset, block_index_offset));
    }

    /// Set `current_group_path` and refresh its cached hash together; every
    /// assignment goes through here, or
    /// [`current_group_hash`](Self::current_group_hash) goes stale.
    fn set_current_group_path(&mut self, path: Arc<str>) {
        self.current_group_hash = group_hash_state(&path);
        self.current_group_path = path;
    }

    /// Push one field row, stamped with the current block context. Every
    /// `FieldRecord` this crate produces is built and counted here, so no call
    /// site can get the six block-context columns or `fields_emitted` wrong.
    fn push_field(&mut self, row: FieldValues) {
        self.stats.fields_emitted += 1;
        self.records.fields.push(FieldRecord {
            time_ms: self.time_ms,
            packet_id: self.packet_id,
            channel_index: self.current_channel,
            actor_net_guid: self.current_actor_guid,
            object_net_guid: self.current_object_guid,
            // A refcount bump, not a copy: the column the interning exists for.
            group_path: Arc::clone(&self.current_group_path),
            handle: row.handle,
            field_name: row.field_name,
            compatible_checksum: row.compatible_checksum,
            bit_count: row.bit_count,
            raw_bits: row.raw_bits,
            value_i64: row.value_i64,
            value_f64: row.value_f64,
            value_bool: row.value_bool,
            value_str: row.value_str,
        });
        if self.checkpoint_block_scope.is_some() {
            if let Some(block) = self.records.checkpoint_blocks.last_mut() {
                block.field_row_count += 1;
            }
        }
    }
}

/// A field row minus its block context; see [`ExportSink::push_field`].
#[derive(Debug, Default)]
struct FieldValues {
    handle: u32,
    field_name: Option<Arc<str>>,
    /// The replay's declared checksum for this handle; `None` (the default) for
    /// rows addressed inside a payload, such as array leaves and struct blobs.
    compatible_checksum: Option<u32>,
    bit_count: u32,
    raw_bits: Option<SmallVec<[u8; 16]>>,
    value_i64: Option<i64>,
    value_f64: Option<f64>,
    value_bool: Option<bool>,
    value_str: Option<String>,
}

/// The group path a sink starts with: one process-wide empty `Arc`, not an
/// allocation per packet. Observable only if a field arrived before its
/// content block, which the framer never does.
fn empty_group_path() -> Arc<str> {
    use std::sync::OnceLock;
    static EMPTY: OnceLock<Arc<str>> = OnceLock::new();
    Arc::clone(EMPTY.get_or_init(|| Arc::from("")))
}

impl GuidPathSink for ExportSink<'_> {
    /// Record a GUID -> path mapping the wire declared inline.
    fn register_path(&mut self, guid: u32, path: &str, outer_guid: NetworkGuid) {
        self.cache.set_net_guid_path(guid, path, Some(outer_guid));
    }

    fn path_for_guid(&self, guid: u32) -> Option<&str> {
        self.cache.get_path_by_guid(guid)
    }
}

/// Builders shared by the sink's test modules.
#[cfg(test)]
mod test_fixtures {
    use vrf_net::content::ContentBlockHeader;
    use vrf_net::pipeline::ActorChannelState;
    use vrf_net::types::NetworkGuid;
    use vrf_schema::NetGuidCache;

    use super::{ChannelState, ExportSink, RecordBuffers};

    /// What a sink borrows, owned by one test.
    #[derive(Default)]
    pub(super) struct Rig {
        pub(super) cache: NetGuidCache,
        pub(super) state: ChannelState,
        pub(super) records: RecordBuffers,
    }

    impl Rig {
        pub(super) fn sink(&mut self) -> ExportSink<'_> {
            ExportSink::new(&mut self.cache, &mut self.state, &mut self.records)
        }
    }

    pub(super) fn actor_block(has_rep_layout: bool) -> ContentBlockHeader {
        ContentBlockHeader {
            has_rep_layout,
            is_actor: true,
            ..ContentBlockHeader::default()
        }
    }

    pub(super) fn subobject_block(guid: u32, has_rep_layout: bool) -> ContentBlockHeader {
        ContentBlockHeader {
            has_rep_layout,
            object_net_guid: NetworkGuid(guid),
            ..ContentBlockHeader::default()
        }
    }

    /// An `ActorChannelState` for one channel open.
    pub(super) fn channel_open(
        channel_index: u32,
        actor: u32,
        archetype: u32,
    ) -> ActorChannelState {
        ActorChannelState {
            channel_index,
            is_open: true,
            actor_net_guid: NetworkGuid(actor),
            archetype_net_guid: NetworkGuid(archetype),
            ..ActorChannelState::default()
        }
    }
}
