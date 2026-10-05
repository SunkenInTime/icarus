// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/stream.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! The `vrf-net` callbacks: `FieldSink` takes replicated properties and RPCs,
//! `ReplicationSink` actor lifecycle, content-block framing and the failure
//! paths. Every row goes through `ExportSink::push_field`, so the six
//! block-context columns are stamped in exactly one place.

use std::sync::Arc;

use smallvec::SmallVec;
use vrf_bitio::BitReader;
use vrf_decode::apply_overlay_with_checksum;
use vrf_decode::cnc::{CncRpc, decode_cnc_payload};
use vrf_export::{
    ActorRecord, CheckpointBlockRecord, MovementRecord, PartialRecord,
    UNRESOLVED_CLASS_NET_CACHE_PAYLOAD_FIELD_NAME,
};
use vrf_net::content::ContentBlockHeader;
use vrf_net::field::FieldSink;
use vrf_net::pipeline::{
    ActorChannelState, PartialPayloadReason, RejectedPartialFragment, RepLayoutTailOutcome,
    ReplicationSink, StreamFailure, StreamFailureCause,
};
use vrf_net::types::{FVector, NetworkGuid};

use super::intern::put;
use super::paths::{
    channel_archetype, combined_candidate, retire_channel_archetype, set_channel_archetype,
};
use super::rpc::copy_raw_bits;
use super::{ExportSink, FieldValues, TABLE};

/// The RPC whose payload is a movement batch rather than a parameter list.
const MOVEMENT_RPC: &str = "ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous";
const ABILITIES_AND_BUFFS_COMPONENT: &str = "AbilitiesAndBuffsComponent";
const CHAINED_CNC_H1_FIELD_NAME: &str = "__vrfkit_chained_cnc_h1__";
const UNPARSED_REP_LAYOUT_TAIL_FIELD_NAME: &str = "__vrfkit_unparsed_rep_layout_tail__";

impl ExportSink<'_> {
    fn record_checkpoint_block(
        &mut self,
        channel_index: u32,
        actor_net_guid: NetworkGuid,
        header: &ContentBlockHeader,
        function_count: u32,
        resolved: bool,
    ) {
        let Some((checkpoint, field_offset, block_offset)) = self.checkpoint_block_scope.clone()
        else {
            return;
        };
        let (actor_archetype_outer_path, actor_archetype_path) = if header.is_actor {
            let archetype = channel_archetype(self.channel_state, channel_index, actor_net_guid);
            self.archetype_paths(archetype)
        } else {
            (None, None)
        };
        let cache = &*self.cache;
        let guid_path = |guid: u32| cache.get_path_by_guid(guid).map(str::to_owned);
        let object_guid = (!header.is_actor).then_some(header.object_net_guid.0);
        let block_index = block_offset + self.records.checkpoint_blocks.len() as u32;
        let field_row_start = field_offset + self.records.fields.len() as u64;
        self.records.checkpoint_blocks.push(CheckpointBlockRecord {
            checkpoint,
            block_index,
            time_ms: self.time_ms,
            packet_id: self.packet_id,
            channel_index,
            actor_net_guid: actor_net_guid.0,
            object_net_guid: object_guid,
            class_net_guid: header.has_class_net_guid.then_some(header.class_net_guid.0),
            outer_net_guid: Some(header.outer_net_guid.0),
            has_rep_layout: header.has_rep_layout,
            is_actor: header.is_actor,
            is_deleted: header.is_deleted,
            is_stably_named: header.is_stably_named,
            delete_flags: header.delete_flags,
            resolved_group_path: if resolved {
                Arc::clone(&self.current_group_path)
            } else {
                Arc::from("<not-resolved:deleted>")
            },
            group_resolution_source: if resolved {
                self.current_group_resolution_source
            } else {
                "not_resolved_deleted"
            },
            group_declared: resolved && cache.get_group_by_path(&self.current_group_path).is_some(),
            resolution_memo_hit: resolved && self.current_resolution_memo_hit,
            function_count,
            function_count_source: if resolved {
                self.current_function_count_source
            } else {
                "not_applicable_deleted"
            },
            actor_archetype_path,
            actor_archetype_outer_path,
            actor_guid_path: guid_path(actor_net_guid.0),
            class_guid_path: header
                .has_class_net_guid
                .then(|| guid_path(header.class_net_guid.0))
                .flatten(),
            object_guid_path: object_guid.and_then(guid_path),
            object_outer_path: object_guid
                .and_then(|guid| cache.get_outer_path(guid))
                .map(str::to_owned),
            field_row_start,
            field_row_count: 0,
        });
    }

    /// The current group's name and `compatible_checksum` for `handle`, from one
    /// schema walk (the checksum feeds the overlay's last-resort lookup; asking
    /// separately would double the hottest loop's cost). The name is interned.
    fn resolve_field_name_and_checksum(&mut self, handle: u32) -> (Option<Arc<str>>, Option<u32>) {
        let Self {
            cache,
            channel_state,
            current_group_path,
            ..
        } = self;
        if let Some(group) = cache.get_group_by_path(current_group_path) {
            if let Some(field) = group.get_field(handle) {
                return (
                    Some(channel_state.names.intern(field.name.as_str())),
                    Some(field.compatible_checksum),
                );
            }
        }
        // Groups declared without field names (e.g. `MagazineAmmo`) fall back to
        // the overlay's handle table, or the row stays unnamed though typed.
        let Some(name) = TABLE.lookup_handle(current_group_path, handle) else {
            return (None, None);
        };
        (Some(channel_state.names.intern(name)), None)
    }
}

impl FieldSink for ExportSink<'_> {
    fn on_field(&mut self, handle: u32, bit_count: u32, reader: BitReader<'_>) {
        let (field_name, field_checksum) = self.resolve_field_name_and_checksum(handle);
        let raw_bits = copy_raw_bits(reader, bit_count);

        // Additive passes, each a no-op unless it owns the field; the parent row
        // with the whole payload is still emitted below.
        if let Some(raw) = raw_bits.as_deref() {
            let name = field_name.as_deref();
            self.emit_flattened_array(name, field_checksum, raw, bit_count);
            self.decode_struct_blob(name, raw, bit_count);
            self.emit_multi_contents(name, raw, bit_count);
        }

        let (value_i64, value_f64, value_bool, value_str) = apply_overlay_with_checksum(
            &TABLE,
            &self.current_group_path,
            self.current_group_hash,
            field_name.as_deref(),
            handle,
            field_checksum,
            raw_bits.as_deref(),
            bit_count,
            &mut self.stats.overlay,
        )
        .map(|result| result.into_columns())
        .unwrap_or_default();

        self.record_player_identity(field_name.as_deref(), value_str.as_deref(), value_i64);

        self.push_field(FieldValues {
            handle,
            field_name,
            compatible_checksum: field_checksum,
            bit_count,
            raw_bits,
            value_i64,
            value_f64,
            value_bool,
            value_str,
        });
    }

    fn on_rpc(&mut self, handle: u32, bit_count: u32, reader: BitReader<'_>) {
        let field_name = self.resolve_field_name_and_checksum(handle).0;

        if field_name.as_deref() == Some(MOVEMENT_RPC) && bit_count > 0 {
            let fallback_reader = reader.clone();
            let failed = self.decode_movement_rpc(reader);
            // A clean batch is movement.parquet row for row; a failed or partial
            // one cannot reproduce its input, so the whole payload is kept. Bits
            // a section leaves unread in a clean batch are only tallied
            // (`movement_*_section_tail*`).
            self.push_field(FieldValues {
                handle,
                field_name,
                bit_count,
                raw_bits: failed
                    .then(|| copy_raw_bits(fallback_reader, bit_count))
                    .flatten(),
                ..FieldValues::default()
            });
        } else if bit_count > 0 {
            let fallback_reader = reader.clone();
            let parsed = self.try_parse_rpc_params(handle, reader, field_name.as_deref());
            if !parsed {
                // Nothing walked (no function name, or no parameter before the
                // stream ended): one raw row for the whole payload.
                self.push_field(FieldValues {
                    handle,
                    field_name,
                    bit_count,
                    raw_bits: copy_raw_bits(fallback_reader, bit_count),
                    ..FieldValues::default()
                });
            }
        } else {
            // A zero-bit RPC: one marker row.
            self.push_field(FieldValues {
                handle,
                field_name,
                ..FieldValues::default()
            });
        }
        self.stats.rpcs_emitted += 1;
    }
}

/// Bomb-mode PlayerState, whose `Subject` and `SpawnedCharacter` feed the
/// manifest `players` array (see `PlayerIdentity`).
const BOMB_PLAYER_STATE: &str = "/Game/GameModes/Bomb/BombPlayerState.BombPlayerState_C";

/// The ClassNetCache function count for `AbilitiesAndBuffsComponent`, whose
/// `_ClassNetCache` group no VALORANT replay declares: the minimum fc that walks
/// all 9,274 payloads of a reference replay as one handle-1 RPC (every fc in
/// 34-65 gives handle 1 the same 6-bit width). One constant, not a per-payload
/// search: smaller fc values also walk simple payloads, with garbage handles.
/// A clean walk proves neither the width nor the group (the inner FastArray
/// framing is the stronger evidence: `tools/extract_fastarray_observations.py`),
/// so consumers keep the raw parent and validate the inner structure.
const ABILITIES_AND_BUFFS_FC: u32 = 34;

impl ExportSink<'_> {
    /// Decode a movement RPC payload into `movement.parquet` rows.
    fn decode_movement_rpc(&mut self, reader: BitReader<'_>) -> bool {
        let mut rpc_reader = reader;
        let time_ms = self.time_ms;
        let packet_id = self.packet_id;
        let movement = &mut self.records.movement;
        let result = vrf_movement::decode_movement_rpc(&mut rpc_reader, |mv| {
            movement.push(MovementRecord {
                time_ms,
                packet_id,
                character_net_guid: mv.shooter_character_net_guid,
                pos_x: mv.pos_x as f32,
                pos_y: mv.pos_y as f32,
                pos_z: mv.pos_z as f32,
                yaw: mv.yaw as f32,
                pitch: mv.pitch as f32,
                vel_x: mv.vel_x as f32,
                vel_y: mv.vel_y as f32,
                vel_z: mv.vel_z as f32,
                timestamp: mv.timestamp,
                movement_state: mv.movement_state,
                // mv.mode_flags is intentionally not carried: the decoder
                // assigns it from the same local as movement_state, so it
                // can never hold a different value.
                move_type: mv.move_type,
            });
        });
        let failed = match &result {
            Ok(decoded) => decoded.error_count != 0,
            Err(_) => true,
        };
        self.stats.record_movement_decode(result.as_ref());
        failed
    }

    /// The `(class_path, archetype_path)` an actor channel is labelled with,
    /// shared by open and close so the two cannot drift into a join key that
    /// silently does not join.
    fn actor_paths(&self, archetype: Option<NetworkGuid>) -> (Option<String>, Option<String>) {
        let (outer, arch_path) = self.archetype_paths(archetype);
        let combined = combined_candidate(outer.as_deref(), arch_path.as_deref());
        (combined.or(outer), arch_path)
    }

    /// Capture one `PlayerIdentity` field of the current BombPlayerState actor.
    fn record_player_identity(
        &mut self,
        field_name: Option<&str>,
        subject: Option<&str>,
        character: Option<i64>,
    ) {
        // Through `canonical_group`: Swiftplay replicates these fields under
        // `Swiftplay_EoRCredits_PlayerState_C`.
        if vrf_decode::canonical_group(&self.current_group_path) != BOMB_PLAYER_STATE {
            return;
        }
        let Some(name) = field_name else {
            return;
        };
        let entry = self
            .channel_state
            .players
            .entry(self.current_actor_guid)
            .or_default();
        match name {
            "Subject" => {
                if let Some(s) = subject {
                    entry.subject = Some(s.to_owned());
                }
            }
            // A disconnect replicates it again as 0, which is not a NetGUID.
            "SpawnedCharacter" => {
                if let Some(c) = character.filter(|c| *c != 0).map(|c| c as u32) {
                    entry.character_net_guids.retain(|&g| g != c);
                    entry.character_net_guids.push(c);
                }
            }
            // PossessedCharacter can be a camera, drone or other ability pawn.
            // It must never replace the body used to identify effect targets.
            _ => {}
        }
    }

    /// Walk an unresolved `AbilitiesAndBuffsComponent` payload's ClassNetCache
    /// stream at [`ABILITIES_AND_BUFFS_FC`] and emit one `_cnc_h{N}` row per RPC
    /// beside the preservation row. The framing can carry custom-delta
    /// properties as well as RPCs, so this legacy name does not establish an
    /// ability cast; the inner bits are kept, not typed.
    fn emit_brute_forced_cnc_rpcs(&mut self, payload: &[u8], bit_count: u32) {
        if !self
            .current_group_path
            .contains(ABILITIES_AND_BUFFS_COMPONENT)
        {
            return;
        }

        self.stats.cnc_bruteforce_payloads_attempted += 1;
        let Some(rpcs) = decode_cnc_payload(payload, bit_count, ABILITIES_AND_BUFFS_FC) else {
            // The preservation row already holds the payload whole; what the
            // caller must not lose is that the walk failed.
            self.stats.cnc_bruteforce_payloads_unwalked += 1;
            return;
        };

        for rpc in &rpcs {
            // A zero-bit RPC keeps an empty blob here, where `copy_raw_bits`
            // gives null; none has been observed, and switching changes output.
            let raw_bits = cnc_body(payload, bit_count, rpc).and_then(|body| {
                if rpc.payload_bits == 0 {
                    return Some(SmallVec::new());
                }
                copy_raw_bits(body, rpc.payload_bits)
            });

            let field_name = self.channel_state.names.intern_fmt(|out| {
                put(out, format_args!("_cnc_h{}", rpc.handle));
            });

            self.push_field(FieldValues {
                handle: rpc.handle,
                field_name: Some(field_name),
                bit_count: rpc.payload_bits,
                raw_bits,
                ..FieldValues::default()
            });
            self.stats.cnc_rpcs_emitted += 1;
        }
    }
}

/// Three optional spawn components from one optional vector: all or none.
fn transpose(v: Option<[f32; 3]>) -> [Option<f32>; 3] {
    v.map_or([None; 3], |v| v.map(Some))
}

/// One walked CNC RPC's body: a reader over its `payload_bits` bits.
fn cnc_body<'p>(payload: &'p [u8], bit_count: u32, rpc: &CncRpc) -> Option<BitReader<'p>> {
    let mut reader = BitReader::with_bit_len(payload, u64::from(bit_count)).ok()?;
    reader.skip_bits(rpc.payload_offset).ok()?;
    reader.sub_reader(u64::from(rpc.payload_bits)).ok()
}

impl ReplicationSink for ExportSink<'_> {
    fn on_rejected_partial(&mut self, p: RejectedPartialFragment<'_>) {
        let reason = match p.reason {
            PartialPayloadReason::MissingInitial => "missing_initial",
            PartialPayloadReason::OverlappingInitial => "overlapping_initial",
            PartialPayloadReason::MismatchedContinuation => "mismatched_continuation",
            PartialPayloadReason::NonByteAlignedFragment => "non_byte_aligned_fragment",
            PartialPayloadReason::ActiveStateLimit => "active_state_limit",
            PartialPayloadReason::BufferedBitsLimit => "buffered_bits_limit",
            PartialPayloadReason::AllocationFailure => "allocation_failure",
            PartialPayloadReason::ChannelStateLimit => "channel_state_limit",
            PartialPayloadReason::ChannelClosed => "channel_closed",
            PartialPayloadReason::EndOfStream => "end_of_stream",
        };
        let mut raw_bits = p.payload.to_vec();
        if p.bit_count % 8 != 0 {
            if let Some(last) = raw_bits.last_mut() {
                *last &= (1u8 << (p.bit_count % 8)) - 1;
            }
        }
        let h = p.header;
        self.records.partials.push(PartialRecord {
            source: "",
            checkpoint_id: None,
            payload_kind: p.payload_kind,
            reason,
            source_packet_id: h.packet_id,
            source_payload_bit_offset: h.payload_bit_offset,
            rejection_packet_id: p.rejection_packet_id,
            channel_index: h.ch_index,
            channel_sequence: h.ch_sequence,
            open: h.b_open,
            close: h.b_close,
            dormant: h.b_dormant,
            replication_paused: h.b_is_replication_paused,
            reliable: h.b_reliable,
            partial: h.b_partial,
            partial_initial: h.b_partial_initial,
            partial_final: h.b_partial_final,
            has_package_map_exports: h.b_has_package_map_exports,
            has_must_be_mapped_guids: h.b_has_must_be_mapped_guids,
            close_reason: h.close_reason as u8,
            source_payload_bit_count: h.payload_bit_count,
            bit_count: p.bit_count as u64,
            raw_bits,
        });
    }
    fn on_actor_open(&mut self, state: &ActorChannelState) {
        self.stats.actor_opens += 1;
        // Stamped with its actor, because channel numbers are recycled; see
        // `paths::ChannelArchetype`.
        if state.archetype_net_guid.is_valid() {
            set_channel_archetype(
                self.channel_state,
                state.channel_index,
                state.actor_net_guid,
                state.archetype_net_guid,
            );
        }

        // A static actor has no archetype, so its class and archetype paths
        // stay null: its GUID path is the level's instance name
        // (`Ascent_C_0`), not a class.
        let (class_path, archetype_path) = self.actor_paths(Some(state.archetype_net_guid));

        let xyz = |v: Option<FVector>| v.map(|v| [v.x, v.y, v.z].map(|c| c as f32));
        let [spawn_x, spawn_y, spawn_z] = transpose(xyz(state.spawn_location));
        let [spawn_vx, spawn_vy, spawn_vz] = transpose(xyz(state.spawn_velocity));
        let rotation = state.spawn_rotation.map(|r| [r.pitch, r.yaw, r.roll]);
        let [spawn_pitch, spawn_yaw, spawn_roll] = transpose(rotation);

        self.records.actors.push(ActorRecord {
            time_ms: self.time_ms,
            packet_id: self.packet_id,
            channel_index: state.channel_index,
            actor_net_guid: state.actor_net_guid.0,
            event: "open",
            class_path,
            archetype_path,
            spawn_x,
            spawn_y,
            spawn_z,
            spawn_pitch,
            spawn_yaw,
            spawn_roll,
            spawn_vx,
            spawn_vy,
            spawn_vz,
        });
    }

    fn on_actor_close(&mut self, channel_index: u32, actor_net_guid: NetworkGuid, dormant: bool) {
        self.stats.actor_closes += 1;

        // As in `on_actor_open`, a static actor gets no class_path, so its open
        // and close rows agree.
        let archetype = channel_archetype(self.channel_state, channel_index, actor_net_guid);
        let (class_path, archetype_path) = self.actor_paths(archetype);

        // `ChannelCloseReason::Dormancy` (vrf-net's `b_dormant`) stops
        // replication of a live actor; every other reason is the actor going
        // away. Both emit a row; only the label differs.
        let event = if dormant { "dormant" } else { "close" };

        self.records.actors.push(ActorRecord {
            time_ms: self.time_ms,
            packet_id: self.packet_id,
            channel_index,
            actor_net_guid: actor_net_guid.0,
            event,
            class_path,
            archetype_path,
            ..ActorRecord::default()
        });
        if !dormant {
            retire_channel_archetype(self.channel_state, channel_index);
        }
    }

    fn on_content_block(
        &mut self,
        channel_index: u32,
        actor_net_guid: NetworkGuid,
        header: &ContentBlockHeader,
    ) -> u32 {
        self.current_channel = channel_index;
        self.current_actor_guid = actor_net_guid.0;
        // An actor block carries no subobject GUID; a subobject block's GUID
        // tells a character's inventory slots apart (merged, a player seems to
        // hold one item). A GUID of 0 stays `Some(0)`: downstream `None` means
        // "actor block", and the block would collapse onto the actor.
        self.current_object_guid = if header.is_actor {
            None
        } else {
            Some(header.object_net_guid.0)
        };
        self.current_is_abilities_and_buffs = !header.is_actor
            && self.cache.get_path_by_guid(header.object_net_guid.0)
                == Some(ABILITIES_AND_BUFFS_COMPONENT);
        self.stats.content_blocks += 1;
        let function_count = self.resolve_block(channel_index, actor_net_guid, header);
        self.record_checkpoint_block(channel_index, actor_net_guid, header, function_count, true);
        function_count
    }

    fn on_rep_layout_tail(
        &mut self,
        _actor_net_guid: NetworkGuid,
        bit_count: u32,
        reader: BitReader<'_>,
    ) -> RepLayoutTailOutcome {
        let Some(raw_tail) = copy_raw_bits(reader, bit_count) else {
            return RepLayoutTailOutcome::Unpreserved {
                cause: StreamFailureCause::ReadError,
            };
        };

        if self.current_is_abilities_and_buffs {
            // 34 is the minimum of the measured 34..=65 band, not a declared
            // count: safe only with the direct pre-remap component identity
            // above and the strict checks below (one handle-1 RPC, exact end,
            // set body flag).
            let rpcs = decode_cnc_payload(&raw_tail, bit_count, ABILITIES_AND_BUFFS_FC);
            if let Some([rpc]) = rpcs.as_deref() {
                let body = cnc_body(&raw_tail, bit_count, rpc)
                    .filter(|body| rpc.handle == 1 && body.clone().read_bit().is_ok_and(|bit| bit));
                if let Some(raw_body) = body.and_then(|body| copy_raw_bits(body, rpc.payload_bits))
                {
                    let field_name = self.channel_state.names.intern(CHAINED_CNC_H1_FIELD_NAME);
                    self.push_field(FieldValues {
                        handle: rpc.handle,
                        field_name: Some(field_name),
                        bit_count: rpc.payload_bits,
                        raw_bits: Some(raw_body),
                        ..FieldValues::default()
                    });
                    self.stats.rpcs_emitted += 1;
                    self.stats.cnc_rpcs_emitted += 1;
                    self.stats.rep_layout_cnc_tails_decoded += 1;
                    return RepLayoutTailOutcome::Decoded { rpc_count: 1 };
                }
            }
        }

        let field_name = self
            .channel_state
            .names
            .intern(UNPARSED_REP_LAYOUT_TAIL_FIELD_NAME);
        self.push_field(FieldValues {
            field_name: Some(field_name),
            bit_count,
            raw_bits: Some(raw_tail),
            ..FieldValues::default()
        });
        self.stats.rep_layout_cnc_tails_preserved += 1;
        RepLayoutTailOutcome::Preserved {
            cause: StreamFailureCause::UnverifiedRepLayoutTail,
        }
    }

    fn on_rep_layout_tail_failure_payload(
        &mut self,
        failure: StreamFailure,
        reader: BitReader<'_>,
    ) {
        let Some(raw) = copy_raw_bits(reader, failure.bit_count) else {
            return;
        };
        if let Some(failures) = self.channel_state.failures.as_mut() {
            failures.note_payload(&failure, Arc::clone(&self.current_group_path), &raw);
        }
    }

    fn on_deleted_block(
        &mut self,
        channel_index: u32,
        actor_net_guid: NetworkGuid,
        header: &ContentBlockHeader,
    ) {
        self.stats.content_blocks += 1;
        self.record_checkpoint_block(channel_index, actor_net_guid, header, 0, false);
    }

    fn on_unresolved_class_net_cache_payload(&mut self, failure: StreamFailure, payload: &[u8]) {
        if let Some(failures) = self.channel_state.failures.as_mut() {
            failures.note_payload(&failure, Arc::clone(&self.current_group_path), payload);
        }

        let field_name = self
            .channel_state
            .names
            .intern(UNRESOLVED_CLASS_NET_CACHE_PAYLOAD_FIELD_NAME);
        self.push_field(FieldValues {
            handle: u32::MAX,
            field_name: Some(field_name),
            bit_count: failure.bit_count,
            raw_bits: Some(SmallVec::from_slice(payload)),
            ..FieldValues::default()
        });

        // Additive: the fc=34 walk adds RPC rows; the row above stays.
        self.emit_brute_forced_cnc_rpcs(payload, failure.bit_count);
    }

    /// Sample the payload of a block whose inner stream failed to walk; framing
    /// calls it after that block's `on_stream_failure`.
    fn on_stream_failure_payload(&mut self, failure: StreamFailure, payload: &[u8]) {
        if let Some(failures) = self.channel_state.failures.as_mut() {
            failures.note_payload(&failure, Arc::clone(&self.current_group_path), payload);
        }
    }

    fn wants_stream_failure_details(&self) -> bool {
        self.channel_state.failures.is_some()
    }

    /// Attach the resolved group path to a stream failure: the only place both
    /// the bit offsets and the class to investigate are known. `function_count`
    /// 0 names an unresolved group; 1 and 2 both read at the parser's minimum
    /// of 2, so this line cannot tell them apart. With diagnostics on, the
    /// failure also goes to the bounded
    /// [`FailureAggregate`](super::failure_stats::FailureAggregate).
    fn on_stream_failure(&mut self, failure: StreamFailure) {
        let line = format!(
            "{:?} actor={} bits={} function_count={} consumed={} skipped={} group={}",
            failure.kind,
            failure.actor_net_guid.0,
            failure.bit_count,
            failure.function_count,
            failure.consumed_bits,
            failure.remaining_bits,
            self.current_group_path,
        );
        self.channel_state.push_stream_failure(line);
        if let Some(failures) = self.channel_state.failures.as_mut() {
            failures.note_failure(&failure, Arc::clone(&self.current_group_path));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vendor::sink::test_fixtures::{Rig, actor_block, channel_open, subobject_block};
    use crate::vendor::sink::{ExportStats, RecordBuffers};
    use vrf_testkit::{BitWrite, pack, unpack};

    /// The subobject GUID a block records for its fields: `None` for an actor
    /// block whatever the header says, `Some(0)` for a subobject whose GUID is
    /// the invalid 0 (see `on_content_block` and `FieldRecord::object_net_guid`).
    #[test]
    fn only_subobject_blocks_record_an_object_guid_zero_included() {
        for (is_actor, guid, want) in [
            (true, 0, None),
            (true, 99, None),
            (false, 0, Some(0)),
            (false, 99, Some(99)),
        ] {
            let mut rig = Rig::default();
            let mut sink = rig.sink();
            let header = ContentBlockHeader {
                is_actor,
                ..subobject_block(guid, true)
            };
            sink.on_content_block(7, NetworkGuid(1234), &header);
            assert_eq!(sink.current_object_guid, want, "{is_actor} {guid}");
        }
    }

    fn rejected_partial_row(
        reason: PartialPayloadReason,
        bit_count: usize,
        payload: &[u8],
    ) -> PartialRecord {
        let mut rig = Rig::default();
        {
            let mut sink = rig.sink();
            let header = vrf_net::bunch::RawBunchHeader {
                packet_id: 41,
                ch_index: 7,
                ch_sequence: 9,
                b_reliable: true,
                b_partial: true,
                b_partial_initial: true,
                payload_bit_count: 13,
                payload_bit_offset: 57,
                ..Default::default()
            };
            sink.on_rejected_partial(RejectedPartialFragment {
                header: &header,
                payload_kind: "accumulated_payload",
                reason,
                bit_count,
                payload,
                rejection_packet_id: Some(44),
            });
        }
        assert_eq!(rig.records.partials.len(), 1);
        rig.records.partials.remove(0)
    }

    /// A rejected partial keeps the bits it declares and no more: bits past
    /// `bit_count` in the last byte are staging residue, not payload.
    #[test]
    fn a_rejected_partial_row_masks_its_last_byte_and_keeps_its_header() {
        let row = rejected_partial_row(PartialPayloadReason::ChannelClosed, 13, &[0xFF, 0xFF]);
        assert_eq!(
            row.raw_bits,
            vec![0xFF, 0x1F],
            "bits past bit_count are masked"
        );
        assert_eq!(
            (row.reason, row.payload_kind, row.bit_count),
            ("channel_closed", "accumulated_payload", 13)
        );
        assert_eq!(
            (
                row.source_packet_id,
                row.rejection_packet_id,
                row.channel_index,
                row.channel_sequence
            ),
            (41, Some(44), 7, 9)
        );
        assert_eq!(
            (row.source_payload_bit_offset, row.source_payload_bit_count),
            (57, 13)
        );
        assert!(row.reliable && row.partial && row.partial_initial && !row.partial_final);

        let aligned = rejected_partial_row(PartialPayloadReason::EndOfStream, 16, &[0xFF, 0xFF]);
        assert_eq!(
            aligned.raw_bits,
            vec![0xFF, 0xFF],
            "a whole last byte is kept"
        );
    }

    /// Every rejection cause reaches the table under its own name, the
    /// variant's in snake case. A relabelled cause is a plausible wrong value:
    /// the row still looks well-formed.
    #[test]
    fn every_rejected_partial_reason_has_a_distinct_name() {
        use PartialPayloadReason::*;
        for reason in [
            MissingInitial,
            OverlappingInitial,
            MismatchedContinuation,
            NonByteAlignedFragment,
            ActiveStateLimit,
            BufferedBitsLimit,
            AllocationFailure,
            ChannelStateLimit,
            ChannelClosed,
            EndOfStream,
        ] {
            let mut snake = String::new();
            for (i, c) in format!("{reason:?}").char_indices() {
                if c.is_ascii_uppercase() && i > 0 {
                    snake.push('_');
                }
                snake.push(c.to_ascii_lowercase());
            }
            assert_eq!(rejected_partial_row(reason, 8, &[0]).reason, snake);
        }
    }
    #[test]
    fn on_field_keeps_exact_parent_raw_bits_for_unknown_and_typed_failures() {
        let mut rig = Rig::default();
        let mut sink = rig.sink();
        let payload = [0b1110_1101];

        sink.on_field(
            999,
            5,
            BitReader::with_bit_len(&payload, 5).expect("bounded field reader"),
        );

        sink.set_current_group_path(Arc::from(
            "/Script/ShooterGame.DamageableComponent:MulticastNotifyDamage_Base",
        ));
        sink.on_field(
            0,
            5,
            BitReader::with_bit_len(&payload, 5).expect("bounded field reader"),
        );

        assert_eq!(sink.records.fields.len(), 2);
        for row in &sink.records.fields {
            assert_eq!(row.bit_count, 5);
            assert_eq!(row.raw_bits.as_deref(), Some(&[0b0000_1101][..]));
        }
        assert_eq!(sink.records.fields[0].field_name, None);
        assert_eq!(
            sink.records.fields[1].field_name.as_deref(),
            Some("DamageTaken")
        );
        assert!(sink.records.fields[1].value_f64.is_none());
        assert_eq!(sink.stats.overlay.decoded_err, 1);
    }

    /// The failure framing reports for an unresolved ClassNetCache block of
    /// `bit_count` bits: nothing consumed, the whole payload preserved.
    fn unresolved_failure(actor: u32, bit_count: u32) -> StreamFailure {
        StreamFailure {
            kind: vrf_net::pipeline::StreamKind::Rpc,
            actor_net_guid: NetworkGuid(actor),
            bit_count,
            function_count: 0,
            consumed_bits: 0,
            remaining_bits: u64::from(bit_count),
            cause: StreamFailureCause::UnresolvedFunctionCount,
            record_handle: None,
            record_offset: Some(0),
            payload_preserved: true,
        }
    }

    /// A 200-bit RepLayout stream on actor 7 abandoned at `consumed`, in
    /// handle 3's record.
    fn abandoned_tail(consumed: u64) -> StreamFailure {
        StreamFailure {
            kind: vrf_net::pipeline::StreamKind::RepLayout,
            actor_net_guid: NetworkGuid(7),
            bit_count: 200,
            function_count: 0,
            consumed_bits: consumed,
            remaining_bits: 200 - consumed,
            cause: StreamFailureCause::AbandonedTail,
            record_handle: Some(3),
            record_offset: Some(consumed),
            payload_preserved: false,
        }
    }

    fn assert_untyped(row: &vrf_export::FieldRecord) {
        assert!(row.compatible_checksum.is_none());
        assert!(row.value_i64.is_none() && row.value_f64.is_none());
        assert!(row.value_bool.is_none() && row.value_str.is_none());
    }

    /// A sink inside an `AbilitiesAndBuffsComponent` block (object 144,
    /// actor 89, channel 3).
    fn abilities_block(rig: &mut Rig, has_rep_layout: bool) -> ExportSink<'_> {
        rig.cache
            .set_net_guid_path(144, ABILITIES_AND_BUFFS_COMPONENT, None);
        let mut sink = rig.sink();
        sink.on_content_block(3, NetworkGuid(89), &subobject_block(144, has_rep_layout));
        sink
    }

    /// A whole unresolved block is one preservation row, not an RPC or a set
    /// of invented fields. The reserved field name is its sole discriminator.
    #[test]
    fn unresolved_class_net_cache_payload_emits_one_distinguished_row() {
        let mut rig = Rig::default();
        let mut sink = abilities_block(&mut rig, false);
        assert_eq!(
            sink.current_function_count_source,
            "unresolved_class_net_cache"
        );
        sink.time_ms = 1234;
        sink.packet_id = 56;

        let failure = unresolved_failure(89, 7);
        sink.on_unresolved_class_net_cache_payload(failure, &[0x66]);

        assert_eq!(sink.records.fields.len(), 1);
        let row = &sink.records.fields[0];
        assert_eq!(row.time_ms, 1234);
        assert_eq!(row.packet_id, 56);
        assert_eq!(row.channel_index, 3);
        assert_eq!(row.actor_net_guid, 89);
        assert_eq!(row.object_net_guid, Some(144));
        assert_eq!(&*row.group_path, "AbilitiesAndBuffsComponent");
        assert_eq!(row.handle, u32::MAX);
        assert_eq!(
            row.field_name.as_deref(),
            Some(UNRESOLVED_CLASS_NET_CACHE_PAYLOAD_FIELD_NAME)
        );
        assert_eq!(row.bit_count, 7);
        assert_eq!(row.raw_bits.as_deref(), Some(&[0x66][..]));
        assert_untyped(row);
        assert_eq!(sink.stats.fields_emitted, 1);
        assert_eq!(sink.stats.rpcs_emitted, 0);
        assert_eq!(sink.stats.overlay.decoded_ok, 0);
        assert_eq!(sink.stats.overlay.decoded_err, 0);
        assert_eq!(sink.stats.overlay.raw_or_skip, 0);
        assert_eq!(sink.stats.overlay.not_in_table, 0);
        assert_eq!(sink.stats.overlay.no_field_name, 0);
    }

    fn one_h1_cnc_tail(body: &[bool]) -> Vec<bool> {
        let mut bits = Vec::new();
        bits.serialized_int(1, ABILITIES_AND_BUFFS_FC);
        bits.int_packed(body.len() as u32);
        bits.extend_from_slice(body);
        bits
    }

    #[test]
    fn verified_abilities_tail_emits_one_raw_structural_h1_row() {
        let body = [true, false, true, false, true, false, true, false, true];
        let tail = one_h1_cnc_tail(&body);
        let tail_bytes = pack(&tail);
        let mut rig = Rig::default();
        let mut sink = abilities_block(&mut rig, true);

        let outcome = sink.on_rep_layout_tail(
            NetworkGuid(89),
            tail.len() as u32,
            BitReader::with_bit_len(&tail_bytes, tail.len() as u64).unwrap(),
        );

        assert_eq!(outcome, RepLayoutTailOutcome::Decoded { rpc_count: 1 });
        assert_eq!(sink.records.fields.len(), 1);
        let row = &sink.records.fields[0];
        assert_eq!(row.handle, 1);
        assert_eq!(row.field_name.as_deref(), Some(CHAINED_CNC_H1_FIELD_NAME));
        assert_eq!(row.bit_count, body.len() as u32);
        assert_eq!(row.raw_bits.as_deref(), Some(pack(&body).as_slice()));
        assert_untyped(row);
        assert_eq!(sink.stats.rep_layout_cnc_tails_decoded, 1);
        assert_eq!(sink.stats.rep_layout_cnc_tails_preserved, 0);
    }

    #[test]
    fn matching_tail_shape_without_raw_component_provenance_stays_whole_and_raw() {
        let body = [true, false, true, false, true, false, true, false, true];
        let tail = one_h1_cnc_tail(&body);
        let tail_bytes = pack(&tail);
        let mut rig = Rig::default();
        rig.cache
            .set_net_guid_path(145, ABILITIES_AND_BUFFS_COMPONENT, None);
        let mut sink = rig.sink();
        let known_header = subobject_block(145, true);
        sink.on_content_block(3, NetworkGuid(89), &known_header);
        assert!(sink.current_is_abilities_and_buffs);

        let header = subobject_block(144, true);
        sink.on_content_block(3, NetworkGuid(89), &header);
        assert!(
            !sink.current_is_abilities_and_buffs,
            "a following unresolved block must clear prior provenance"
        );

        let outcome = sink.on_rep_layout_tail(
            NetworkGuid(89),
            tail.len() as u32,
            BitReader::with_bit_len(&tail_bytes, tail.len() as u64).unwrap(),
        );

        assert_eq!(
            outcome,
            RepLayoutTailOutcome::Preserved {
                cause: StreamFailureCause::UnverifiedRepLayoutTail,
            }
        );
        assert_eq!(sink.records.fields.len(), 1);
        let row = &sink.records.fields[0];
        assert_eq!(
            row.field_name.as_deref(),
            Some(UNPARSED_REP_LAYOUT_TAIL_FIELD_NAME)
        );
        assert_eq!(row.bit_count, tail.len() as u32);
        assert_eq!(row.raw_bits.as_deref(), Some(tail_bytes.as_slice()));
        assert_untyped(row);
        assert_eq!(sink.stats.rep_layout_cnc_tails_decoded, 0);
        assert_eq!(sink.stats.rep_layout_cnc_tails_preserved, 1);
    }

    #[test]
    fn verified_component_preserves_exact_but_unverified_tail_shapes_whole() {
        let first = one_h1_cnc_tail(&[true, false, true]);
        let mut two_rpcs = first.clone();
        two_rpcs.extend(one_h1_cnc_tail(&[true, true, false]));
        let false_flag = one_h1_cnc_tail(&[false, true, true]);

        let mut rig = Rig::default();
        let mut sink = abilities_block(&mut rig, true);

        for tail in [&two_rpcs, &false_flag] {
            let raw = pack(tail);
            let outcome = sink.on_rep_layout_tail(
                NetworkGuid(89),
                tail.len() as u32,
                BitReader::with_bit_len(&raw, tail.len() as u64).unwrap(),
            );
            assert_eq!(
                outcome,
                RepLayoutTailOutcome::Preserved {
                    cause: StreamFailureCause::UnverifiedRepLayoutTail,
                }
            );
            let row = sink.records.fields.last().unwrap();
            assert_eq!(
                row.field_name.as_deref(),
                Some(UNPARSED_REP_LAYOUT_TAIL_FIELD_NAME)
            );
            assert_eq!(row.bit_count, tail.len() as u32);
            assert_eq!(row.raw_bits.as_deref(), Some(raw.as_slice()));
        }
        assert_eq!(sink.stats.rep_layout_cnc_tails_decoded, 0);
        assert_eq!(sink.stats.rep_layout_cnc_tails_preserved, 2);
    }

    /// A first parameter declaring more bits than remain bumps `truncated_rpcs`:
    /// no row lands, so the counter alone tells this from a payload with no
    /// parameters. `rpc_param_walks` counts the walks that could set it, and
    /// not a payload with no function name, which never starts one.
    #[test]
    fn a_truncated_rpc_payload_increments_truncated_rpcs() {
        let mut bits = Vec::new();
        bits.push(false); // property checksum
        bits.int_packed(1); // encodedHandle = 1 -> handle 0
        bits.int_packed(100); // payload_bits = 100 (exceeds remaining)
        // No payload data follows: the walker breaks here.
        let data = pack(&bits);
        let reader = BitReader::with_bit_len(&data, bits.len() as u64).unwrap();

        let mut rig = Rig::default();
        let mut sink = rig.sink();

        assert!(!sink.try_parse_rpc_params(7, reader.clone(), None));
        assert_eq!(sink.stats.rpc_param_walks, 0);
        let emitted = sink.try_parse_rpc_params(7, reader, Some("SomeFunction"));
        assert!(!emitted, "no parameter rows are emitted before the break");
        assert_eq!(sink.stats.truncated_rpcs, 1);
        assert_eq!(sink.stats.rpc_param_walks, 1);
    }

    fn targeting_rpc(
        group: &str,
        parent_handle: u32,
        parent_name: &str,
        parent_checksum: u32,
        child_name: &str,
        child_checksum: u32,
        array_bits: &[bool],
    ) -> (RecordBuffers, ExportStats) {
        let mut rig = Rig::default();
        rig.cache
            .add_export_group(vrf_schema::NetFieldExportGroup::new(group.into(), 7, 3))
            .unwrap();
        for (handle, name, checksum) in [
            (parent_handle, parent_name, parent_checksum),
            (1, child_name, child_checksum),
        ] {
            assert!(rig.cache.set_field_on_group(
                7,
                vrf_schema::NetFieldExport {
                    handle,
                    compatible_checksum: checksum,
                    name: name.into(),
                },
            ));
        }
        let mut rpc_bits = vec![false];
        rpc_bits.int_packed(parent_handle + 1);
        rpc_bits.int_packed(array_bits.len() as u32);
        rpc_bits.extend_from_slice(array_bits);
        rpc_bits.int_packed(0);
        let raw = pack(&rpc_bits);
        let mut sink = rig.sink();
        assert!(sink.try_parse_rpc_params(
            3,
            BitReader::with_bit_len(&raw, rpc_bits.len() as u64).unwrap(),
            Some("MulticastRespondToValidMapClick"),
        ));
        let stats = sink.stats.clone();
        (rig.records, stats)
    }

    const TARGETING_GROUP: &str =
        "/Script/ShooterGame.MapTargetingStateComponent:MulticastRespondToValidMapClick";

    /// `targeting_rpc` with the measured parent and child declarations.
    fn valid_targeting(array_bits: &[bool]) -> (RecordBuffers, ExportStats) {
        targeting_rpc(
            TARGETING_GROUP,
            0,
            "WorldLocation",
            2052180909,
            "WorldLocation",
            3965480401,
            array_bits,
        )
    }

    fn append_world_location(bits: &mut Vec<bool>, values: [f64; 3]) {
        bits.int_packed(2);
        bits.int_packed(192);
        for value in values {
            bits.extend(unpack(&value.to_le_bytes()));
        }
    }

    fn world_locations(values: &[[f64; 3]]) -> Vec<bool> {
        let mut bits = Vec::new();
        bits.int_packed(values.len() as u32);
        for (index, values) in values.iter().copied().enumerate() {
            bits.int_packed(index as u32 + 1);
            append_world_location(&mut bits, values);
            bits.int_packed(0);
        }
        bits.int_packed(0);
        bits
    }

    fn one_world_location(values: [f64; 3]) -> Vec<bool> {
        world_locations(&[values])
    }

    #[test]
    fn guarded_targeting_array_emits_vector_child_and_raw_parent() {
        let array = one_world_location([12.5, -9.25, 3.0]);
        let (records, stats) = valid_targeting(&array);
        assert_eq!(records.fields.len(), 2);
        assert_eq!(
            records.fields[0].field_name.as_deref(),
            Some("MulticastRespondToValidMapClick.WorldLocation[0].WorldLocation")
        );
        assert_eq!(records.fields[0].bit_count, 192);
        assert_eq!(records.fields[0].handle, 3);
        assert_eq!(
            records.fields[0].value_str.as_deref(),
            Some("(12.5,-9.25,3)")
        );
        let expected_raw: Vec<u8> = [12.5f64, -9.25, 3.0]
            .into_iter()
            .flat_map(f64::to_le_bytes)
            .collect();
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some(expected_raw.as_slice())
        );
        assert_eq!(
            records.fields[1].raw_bits.as_deref(),
            Some(pack(&array).as_slice())
        );
        assert_eq!(stats.targeting_world_locations_decoded, 1);
        assert_eq!(stats.fields_emitted, 2, "the child row is counted");

        let signed_zero = one_world_location([-0.0, 0.0, -0.0]);
        let (records, stats) = valid_targeting(&signed_zero);
        let expected_raw: Vec<u8> = [-0.0f64, 0.0, -0.0]
            .into_iter()
            .flat_map(f64::to_le_bytes)
            .collect();
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some(expected_raw.as_slice())
        );
        assert_eq!(records.fields[0].handle, 3);
        assert_eq!(stats.targeting_world_locations_decoded, 1);
    }

    #[test]
    fn targeting_array_requires_exact_child_declaration_and_complete_grammar() {
        let array = one_world_location([1.0, 2.0, 3.0]);
        let empty = world_locations(&[]);
        let (records, stats) = valid_targeting(&empty);
        assert_eq!(records.fields.len(), 1);
        assert_eq!(stats.targeting_world_locations_decoded, 0);
        assert_eq!(stats.array_leaf_decode_errors, 0);
        for (name, checksum) in [("Other", 3965480401), ("WorldLocation", 7)] {
            let (records, stats) = targeting_rpc(
                TARGETING_GROUP,
                0,
                "WorldLocation",
                2052180909,
                name,
                checksum,
                &array,
            );
            assert_eq!(records.fields.len(), 1);
            assert_eq!(stats.targeting_world_locations_decoded, 0);
        }
        for (candidate_group, handle, name, checksum) in [
            (TARGETING_GROUP, 0, "WorldLocation", 7),
            (TARGETING_GROUP, 0, "Other", 2052180909),
            (TARGETING_GROUP, 2, "WorldLocation", 2052180909),
            (
                "/Script/ShooterGame.Other:MulticastRespondToValidMapClick",
                0,
                "WorldLocation",
                2052180909,
            ),
        ] {
            let (records, stats) = targeting_rpc(
                candidate_group,
                handle,
                name,
                checksum,
                "WorldLocation",
                3965480401,
                &array,
            );
            assert_eq!(records.fields.len(), 1);
            assert_eq!(stats.targeting_world_locations_decoded, 0);
        }
        let truncated = &array[..array.len() - 8];
        let (records, stats) = valid_targeting(truncated);
        assert_eq!(records.fields.len(), 1);
        assert_eq!(stats.targeting_world_locations_decoded, 0);
        assert!(
            stats.array.errors > 0
                || stats.array.unconsumed_root_bits > 0
                || stats.array.implicit_terminations > 0
        );

        let mut residual = array.clone();
        residual.push(true);
        let (records, stats) = valid_targeting(&residual);
        assert_eq!(records.fields.len(), 1);
        assert!(stats.array.unconsumed_root_bits > 0);

        let wrong_handle = {
            let mut bits = Vec::new();
            for value in [1, 1, 3, 192] {
                bits.int_packed(value);
            }
            bits.extend(std::iter::repeat_n(false, 192));
            bits.int_packed(0);
            bits.int_packed(0);
            bits
        };
        let (records, stats) = valid_targeting(&wrong_handle);
        assert_eq!(records.fields.len(), 1);
        assert!(stats.array_leaf_decode_errors > 0);

        let wrong_width = {
            let mut bits = Vec::new();
            for value in [1, 1, 2, 191] {
                bits.int_packed(value);
            }
            bits.extend(std::iter::repeat_n(false, 191));
            bits.int_packed(0);
            bits.int_packed(0);
            bits
        };
        let (records, stats) = valid_targeting(&wrong_width);
        assert_eq!(records.fields.len(), 1);
        assert!(stats.array_leaf_decode_errors > 0);

        let nonfinite = one_world_location([f64::NAN, 0.0, -0.0]);
        let (records, stats) = valid_targeting(&nonfinite);
        assert_eq!(records.fields.len(), 1);
        assert!(stats.array_leaf_decode_errors > 0);

        let mut duplicate_member = Vec::new();
        duplicate_member.int_packed(1);
        duplicate_member.int_packed(1);
        append_world_location(&mut duplicate_member, [1.0, 2.0, 3.0]);
        append_world_location(&mut duplicate_member, [4.0, 5.0, 6.0]);
        duplicate_member.int_packed(0);
        duplicate_member.int_packed(0);
        let (records, stats) = valid_targeting(&duplicate_member);
        assert_eq!(records.fields.len(), 1);
        assert!(stats.array_leaf_decode_errors > 0);

        let mixed = world_locations(&[[1.0, 2.0, 3.0], [f64::NAN, 5.0, 6.0]]);
        let (records, stats) = valid_targeting(&mixed);
        assert_eq!(
            records.fields.len(),
            1,
            "children are emitted transactionally"
        );
        assert!(stats.array_leaf_decode_errors > 0);
    }

    /// Build an RPC payload of one parameter, the zero-handle terminator, and
    /// `suffix_bits` bits of whatever follows it.
    fn rpc_payload_with_suffix(suffix_bits: usize) -> Vec<bool> {
        let mut bits = Vec::new();
        bits.push(false); // property checksum
        bits.int_packed(1); // encodedHandle = 1 -> handle 0
        bits.int_packed(8); // payload_bits = 8
        bits.extend(std::iter::repeat_n(false, 8)); // payload
        bits.int_packed(0); // terminator handle
        bits.extend(std::iter::repeat_n(true, suffix_bits));
        bits
    }

    /// Bits after the zero-handle terminator are counted, not rejected, and the
    /// rows already parsed stay (see `ExportStats::rpc_suffix_bits_dropped`).
    #[test]
    fn bits_after_the_rpc_terminator_are_counted_not_discarded() {
        let bits = rpc_payload_with_suffix(16);
        let data = pack(&bits);
        let reader = BitReader::with_bit_len(&data, bits.len() as u64).unwrap();

        let mut rig = Rig::default();
        let mut sink = rig.sink();

        let emitted = sink.try_parse_rpc_params(7, reader, Some("SomeFunction"));
        assert!(emitted, "the parameter that did parse is still emitted");
        assert_eq!(
            sink.stats.rpc_suffix_bits_dropped, 16,
            "the bits after the terminator must reach a counter"
        );
        // Not a truncation: the walk ended where the wire told it to.
        assert_eq!(sink.stats.truncated_rpcs, 0);
        assert_eq!(
            rig.records.fields.len(),
            2,
            "parameter plus whole raw fallback"
        );
        let fallback = rig.records.fields.last().unwrap();
        assert_eq!(fallback.bit_count, bits.len() as u32);
        assert_eq!(fallback.raw_bits.as_deref(), Some(data.as_slice()));
    }

    #[test]
    fn a_partially_parsed_truncated_rpc_retains_the_whole_payload() {
        let mut bits = Vec::new();
        bits.push(false); // property checksum
        bits.int_packed(1);
        bits.int_packed(8);
        bits.extend(std::iter::repeat_n(false, 8)); // one complete parameter
        bits.int_packed(2);
        bits.int_packed(100); // second parameter overruns
        bits.extend(std::iter::repeat_n(true, 8));
        let data = pack(&bits);
        let reader = BitReader::with_bit_len(&data, bits.len() as u64).unwrap();
        let mut rig = Rig::default();
        let mut sink = rig.sink();

        assert!(sink.try_parse_rpc_params(7, reader, Some("SomeFunction")));
        assert_eq!(sink.stats.truncated_rpcs, 1);
        assert_eq!(
            rig.records.fields.len(),
            2,
            "parameter plus whole raw fallback"
        );
        let fallback = rig.records.fields.last().unwrap();
        assert_eq!(fallback.bit_count, bits.len() as u32);
        assert_eq!(fallback.raw_bits.as_deref(), Some(data.as_slice()));
    }

    #[test]
    fn a_failed_movement_decode_retains_the_whole_rpc_payload() {
        let mut update = Vec::new();
        update.int_packed(3); // shooter GUID handle 2
        update.int_packed(32);
        for bit in 0..32 {
            update.push((4321u32 & (1 << bit)) != 0);
        }
        update.int_packed(4); // component stream handle 3
        update.int_packed(8);
        update.extend(std::iter::repeat_n(false, 8)); // short u16 header
        update.int_packed(0);

        let mut array = Vec::new();
        array.int_packed(1);
        array.int_packed(1);
        array.extend(update);
        array.int_packed(0);

        let mut bits = vec![false]; // top-level ignored bit
        bits.int_packed(2); // updates-array handle 1
        bits.int_packed(array.len() as u32);
        bits.extend(array);
        bits.int_packed(0);
        let data = pack(&bits);

        let path = "/Script/Test.Movement_ClassNetCache";
        let mut rig = Rig::default();
        rig.cache
            .add_export_group(vrf_schema::NetFieldExportGroup::new(path.into(), 7, 1))
            .unwrap();
        assert!(rig.cache.set_field_on_group(
            7,
            vrf_schema::NetFieldExport {
                handle: 0,
                compatible_checksum: 0,
                name: MOVEMENT_RPC.into(),
            },
        ));
        let mut sink = rig.sink();
        sink.set_current_group_path(Arc::from(path));
        let reader = BitReader::with_bit_len(&data, bits.len() as u64).unwrap();

        sink.on_rpc(0, bits.len() as u32, reader);

        assert_eq!(sink.stats.movement_rpc_errors, 1);
        assert_eq!(rig.records.fields.len(), 1);
        assert_eq!(rig.records.fields[0].bit_count, bits.len() as u32);
        assert_eq!(
            rig.records.fields[0].raw_bits.as_deref(),
            Some(data.as_slice())
        );
    }

    const PROJECTILE_CNC: &str =
        "/Script/ShooterGame.PrecalculatedProjectileMovementComponent_ClassNetCache";
    const PROJECTILE_PARAMS: &str =
        "/Script/ShooterGame.PrecalculatedProjectileMovementComponent:MulticastSetPath";
    const PROJECTILE_PARENT: &str = "MulticastSetPath.NetworkedProjectilePath";

    /// One path point: ElapsedSeconds, Location and Velocity at handles 1-3,
    /// optionally without the velocity or with an unknown zero-width member.
    fn path_point_array(elapsed: f32, omit_velocity: bool, extra_zero_width: bool) -> Vec<bool> {
        let mut array = Vec::new();
        array.int_packed(1); // one path point
        array.int_packed(1); // index zero
        for (handle, payload) in [
            (1, elapsed.to_le_bytes().to_vec()),
            (2, vec![0; 24]),
            (3, vec![0; 24]),
        ] {
            if omit_velocity && handle == 3 {
                continue;
            }
            array.int_packed(handle + 1);
            array.int_packed((payload.len() * 8) as u32);
            array.extend(unpack(&payload));
        }
        if extra_zero_width {
            array.int_packed(5); // unknown handle 4
            array.int_packed(0);
        }
        array.int_packed(0); // element terminator
        array.int_packed(0); // array terminator
        array
    }

    /// Send `array` as `MulticastSetPath`'s only parameter through `on_rpc`,
    /// with the measured routes of `branch` admitted.
    fn projectile_path_rpc(array: &[bool], branch: &str) -> (RecordBuffers, ExportStats) {
        let mut rpc = vec![false]; // FunctionParameters checksum bit
        rpc.int_packed(1); // parameter handle zero
        rpc.int_packed(array.len() as u32);
        rpc.extend_from_slice(array);
        rpc.int_packed(0); // parameter terminator
        let rpc_raw = pack(&rpc);

        let mut rig = Rig::default();
        for (index, path) in [(7, PROJECTILE_CNC), (8, PROJECTILE_PARAMS)] {
            rig.cache
                .add_export_group(vrf_schema::NetFieldExportGroup::new(path.into(), index, 1))
                .unwrap();
        }
        for (index, checksum, name) in [
            (7, 2_336_552_129, "MulticastSetPath"),
            (8, 2_930_105_559, "NetworkedProjectilePath"),
        ] {
            assert!(rig.cache.set_field_on_group(
                index,
                vrf_schema::NetFieldExport {
                    handle: 0,
                    compatible_checksum: checksum,
                    name: name.into(),
                }
            ));
        }
        let mut sink = rig.sink();
        sink.set_current_group_path(Arc::from(PROJECTILE_CNC));
        sink.enable_measured_array_routes(branch);
        sink.on_rpc(
            0,
            rpc.len() as u32,
            BitReader::with_bit_len(&rpc_raw, rpc.len() as u64).unwrap(),
        );
        let stats = sink.stats.clone();
        (rig.records, stats)
    }

    #[test]
    fn projectile_path_rpc_rejects_unknown_missing_and_nonfinite_members() {
        for (
            case,
            elapsed,
            extra_zero_width,
            omit_velocity,
            wanted_children,
            wanted_array_errors,
            wanted_leaf_errors,
        ) in [
            ("valid", 1.5f32, false, false, 3, 0, 0),
            ("unknown_zero_width", 1.5f32, true, false, 0, 1, 0),
            ("missing_velocity", 1.5f32, false, true, 0, 0, 1),
            ("nan_elapsed", f32::NAN, false, false, 0, 0, 1),
        ] {
            let array = path_point_array(elapsed, omit_velocity, extra_zero_width);
            let (records, stats) = projectile_path_rpc(&array, "++Ares-Core+release-13.05");
            assert_eq!(stats.array.errors, wanted_array_errors, "{case}");
            assert_eq!(stats.array_leaf_decode_errors, wanted_leaf_errors, "{case}");
            assert_eq!(records.fields.len(), wanted_children + 1, "{case}");
            let parent = records.fields.last().unwrap();
            assert_eq!(
                parent.field_name.as_deref(),
                Some(PROJECTILE_PARENT),
                "{case}"
            );
            assert_eq!(parent.bit_count, array.len() as u32, "{case}");
            assert_eq!(
                parent.raw_bits.as_deref(),
                Some(pack(&array).as_slice()),
                "{case}"
            );
            assert!(
                records.fields[..records.fields.len() - 1]
                    .iter()
                    .all(|row| row
                        .field_name
                        .as_deref()
                        .is_some_and(|name| name.starts_with(PROJECTILE_PARENT)))
            );
        }
    }

    /// The projectile path is admitted per branch like the flattened arrays:
    /// a valid path point expands on the builds whose samples held one, and
    /// stays a single raw parameter row where the route was never observed.
    #[test]
    fn projectile_path_rpc_expands_only_on_admitting_branches() {
        let array = path_point_array(2.5, false, false);
        for (branch, want_children) in [
            ("++Ares-Core+release-11.06", 0),
            ("++Ares-Core+release-11.07", 3),
            ("++Ares-Core+release-12.06", 0),
            ("++Ares-Core+release-12.09", 3),
            ("++Ares-Core+release-12.10", 0),
            ("++Ares-Core+release-13.05", 3),
        ] {
            let (records, stats) = projectile_path_rpc(&array, branch);
            assert_eq!(stats.route_children_projectile_path, want_children as u64);
            assert_eq!(stats.array.errors, 0, "{branch}");
            assert_eq!(stats.array_leaf_decode_errors, 0, "{branch}");
            assert_eq!(records.fields.len(), want_children + 1, "{branch}");
            let parent = records.fields.last().unwrap();
            assert_eq!(
                parent.field_name.as_deref(),
                Some(PROJECTILE_PARENT),
                "{branch}"
            );
            assert_eq!(parent.bit_count, array.len() as u32, "{branch}");
            if want_children > 0 {
                assert_eq!(records.fields[0].value_f64, Some(2.5), "{branch}");
            }
        }
    }

    /// A completed walk, with or without the one trailing alignment bit the
    /// grammar allows, is neither a truncation nor a dropped suffix: either
    /// counter firing on it would fire on every well-formed payload.
    #[test]
    fn a_completed_rpc_payload_is_neither_truncated_nor_a_drop() {
        for suffix in [0, 1] {
            let bits = rpc_payload_with_suffix(suffix);
            let data = pack(&bits);
            let reader = BitReader::with_bit_len(&data, bits.len() as u64).unwrap();
            let mut rig = Rig::default();
            let mut sink = rig.sink();
            assert!(sink.try_parse_rpc_params(7, reader, Some("SomeFunction")));
            assert_eq!(sink.stats.truncated_rpcs, 0, "{suffix}");
            assert_eq!(sink.stats.rpc_suffix_bits_dropped, 0, "{suffix}");
        }
    }
    /// An unresolved `AbilitiesAndBuffsComponent` payload that walks cleanly
    /// under fc=34 must emit one additive `_cnc_h1` row alongside the
    /// preservation row. The RPC handle and payload bits must be correct.
    #[test]
    fn unresolved_abilities_and_buffs_emits_cnc_rpc_row() {
        // fc=34, handle 1, a 32-bit payload of 1s (no walk at lower fc values).
        let bits = one_h1_cnc_tail(&[true; 32]);

        let data = pack(&bits);
        let bit_count = bits.len() as u32;

        let mut rig = Rig::default();
        let mut sink = abilities_block(&mut rig, false);
        let failure = unresolved_failure(89, bit_count);
        sink.on_unresolved_class_net_cache_payload(failure, &data);

        // Two rows: the preservation row + one additive CNC RPC row.
        assert_eq!(
            sink.records.fields.len(),
            2,
            "preservation row + one CNC RPC row"
        );

        // Row 0: preservation.
        let pres = &sink.records.fields[0];
        assert_eq!(
            pres.field_name.as_deref(),
            Some(UNRESOLVED_CLASS_NET_CACHE_PAYLOAD_FIELD_NAME)
        );

        // Row 1: the CNC RPC.
        let rpc = &sink.records.fields[1];
        assert_eq!(rpc.handle, 1, "handle should be 1");
        assert_eq!(rpc.bit_count, 32, "payload_bits should be 32");
        assert_eq!(
            rpc.field_name.as_deref(),
            Some("_cnc_h1"),
            "field name should identify the RPC handle"
        );
        assert!(rpc.raw_bits.is_some(), "raw bits should be extracted");
        assert_eq!(sink.stats.cnc_rpcs_emitted, 1);
        assert_eq!(sink.stats.cnc_bruteforce_payloads_attempted, 1);
        assert_eq!(sink.stats.cnc_bruteforce_payloads_unwalked, 0);
    }

    /// An `AbilitiesAndBuffsComponent` payload the fc=34 walk cannot fit is
    /// counted in `cnc_bruteforce_payloads_unwalked`. It declares 64 payload bits
    /// and carries 32, the shape a misread handle width leaves; the preservation
    /// row still carries every bit.
    #[test]
    fn unresolved_abilities_and_buffs_that_does_not_walk_is_counted() {
        let mut bits = Vec::new();
        bits.serialized_int(1, 34); // handle=1, 6 bits
        bits.int_packed(64); // declares 64 payload bits ...
        bits.extend(std::iter::repeat_n(true, 32)); // ... but carries 32
        let data = pack(&bits);
        let bit_count = bits.len() as u32;
        assert!(
            decode_cnc_payload(&data, bit_count, ABILITIES_AND_BUFFS_FC).is_none(),
            "the fixture must not walk under fc=34, or this tests nothing"
        );

        let mut rig = Rig::default();
        let mut sink = abilities_block(&mut rig, false);
        let failure = unresolved_failure(89, bit_count);
        sink.on_unresolved_class_net_cache_payload(failure, &data);

        assert_eq!(sink.stats.cnc_bruteforce_payloads_attempted, 1);
        assert_eq!(sink.stats.cnc_bruteforce_payloads_unwalked, 1);
        assert_eq!(sink.stats.cnc_rpcs_emitted, 0);
        assert_eq!(sink.records.fields.len(), 1, "only the preservation row");
        let preserved = &sink.records.fields[0];
        assert_eq!(
            preserved.field_name.as_deref(),
            Some(UNRESOLVED_CLASS_NET_CACHE_PAYLOAD_FIELD_NAME)
        );
        assert_eq!(preserved.raw_bits.as_deref(), Some(data.as_slice()));
    }

    /// An unresolved payload for a group OTHER than AbilitiesAndBuffsComponent
    /// produces no CNC rows: the brute force is gated. The payload walks under
    /// fc=34 (`unresolved_abilities_and_buffs_emits_cnc_rpc_row`), so only the
    /// group-path guard can stop it.
    #[test]
    fn unresolved_payload_for_other_group_emits_no_cnc_rows() {
        let bits = one_h1_cnc_tail(&[true; 32]);
        let data = pack(&bits);
        let bit_count = bits.len() as u32;

        let mut rig = Rig::default();
        let mut sink = rig.sink();

        let header = subobject_block(200, false);
        sink.on_content_block(3, NetworkGuid(89), &header);
        // current_group_path resolves to a bare name that is NOT
        // AbilitiesAndBuffsComponent.

        let failure = unresolved_failure(89, bit_count);
        sink.on_unresolved_class_net_cache_payload(failure, &data);

        // Only the preservation row, no CNC rows: the payload walks (proven
        // above), so only the group-path gate can be what stops it here.
        assert_eq!(sink.records.fields.len(), 1);
        assert_eq!(sink.stats.cnc_rpcs_emitted, 0);
        // Gated out before the walk, so it was never attempted -- and an
        // attempt that did not walk is not what happened either.
        assert_eq!(sink.stats.cnc_bruteforce_payloads_attempted, 0);
        assert_eq!(sink.stats.cnc_bruteforce_payloads_unwalked, 0);
    }
    /// A dormancy close is exported as `dormant`, not as a despawn; both still
    /// emit a row and count as closes.
    #[test]
    fn a_dormancy_close_is_not_recorded_as_a_despawn() {
        let mut rig = Rig::default();
        let mut sink = rig.sink();

        sink.on_actor_close(3, NetworkGuid(42), false);
        sink.on_actor_close(4, NetworkGuid(43), true);

        assert_eq!(sink.records.actors.len(), 2, "both closes are still rows");
        assert_eq!(
            sink.records.actors[0].event, "close",
            "a real despawn keeps the name every consumer already reads"
        );
        assert_eq!(
            sink.records.actors[1].event, "dormant",
            "a dormancy close must be distinguishable from a despawn"
        );
        // Both still count as closes: the actor channel did close.
        assert_eq!(sink.stats.actor_closes, 2);
    }

    /// Deleted and live blocks are both content blocks, as in vrf-net's
    /// `NetStats::content_blocks`, which `tools/verify_build_corpus.py` checks
    /// `sink_content_blocks` against: a replay without deleted blocks cannot
    /// notice `on_deleted_block` forgetting its count.
    #[test]
    fn deleted_and_live_blocks_both_advance_the_sink_block_tally() {
        let mut rig = Rig::default();
        let mut sink = rig.sink();
        let header = actor_block(true);

        sink.on_content_block(7, NetworkGuid(1234), &header);
        assert_eq!(sink.stats.content_blocks, 1);
        sink.on_deleted_block(7, NetworkGuid(1234), &header);
        assert_eq!(sink.stats.content_blocks, 2);
    }

    /// Every RPC callback advances `rpcs_emitted` exactly once, whatever row
    /// shape it produces, because vrf-net counts `NetStats::rpcs` once per
    /// callback. The zero-bit marker row is the branch a misplaced increment
    /// would most easily skip.
    #[test]
    fn every_rpc_shape_advances_the_sink_rpc_tally_once() {
        let mut rig = Rig::default();
        let mut sink = rig.sink();

        sink.on_rpc(5, 0, BitReader::with_bit_len(&[], 0).unwrap());
        assert_eq!(sink.stats.rpcs_emitted, 1, "zero-bit marker row");
        sink.on_rpc(6, 8, BitReader::with_bit_len(&[0xA5], 8).unwrap());
        assert_eq!(sink.stats.rpcs_emitted, 2, "whole-payload fallback row");
        assert_eq!(sink.records.fields.len(), 2);
    }

    /// A dynamic open carries its spawn location, rotation and velocity, each
    /// in its own columns; a static open and every close carry none.
    #[test]
    fn spawn_vectors_reach_their_own_columns_on_opens_only() {
        use vrf_net::types::FRotator;
        let v = |x, y, z| Some(FVector { x, y, z });
        let mut rig = Rig::default();
        let mut sink = rig.sink();
        sink.on_actor_open(&ActorChannelState {
            spawn_location: v(1.5, -2.0, 3.0),
            spawn_rotation: Some(FRotator {
                pitch: 4.0,
                yaw: 5.0,
                roll: 6.0,
            }),
            spawn_velocity: v(-1000.0, 0.0, 3200.0),
            ..channel_open(3, 42, 8)
        });
        sink.on_actor_open(&channel_open(4, 43, 0));
        sink.on_actor_close(3, NetworkGuid(42), false);
        let spawn = |row: &ActorRecord| {
            [
                [row.spawn_x, row.spawn_y, row.spawn_z],
                [row.spawn_pitch, row.spawn_yaw, row.spawn_roll],
                [row.spawn_vx, row.spawn_vy, row.spawn_vz],
            ]
        };
        let rows: Vec<_> = sink.records.actors.iter().map(spawn).collect();
        assert_eq!(
            rows[0],
            [
                [Some(1.5), Some(-2.0), Some(3.0)],
                [Some(4.0), Some(5.0), Some(6.0)],
                [Some(-1000.0), Some(0.0), Some(3200.0)],
            ]
        );
        assert_eq!(rows[1..], [[[None; 3]; 3]; 2]);
    }

    /// A static actor's close row, like its open row, gets no class_path from
    /// its own GUID path (the level's instance name, not a class).
    #[test]
    fn a_static_actors_close_row_does_not_fabricate_a_class_path_from_its_own_guid() {
        let mut rig = Rig::default();
        // The actor's own GUID path -- an instance name, e.g. what a level
        // placement looks like on the wire -- must not read back as a class.
        rig.cache.set_net_guid_path(42, "WindowShieldA1", None);
        let mut sink = rig.sink();

        // No archetype: `NetworkGuid(0)` is invalid, so `on_actor_open` never
        // registers a channel archetype for it.
        sink.on_actor_open(&channel_open(3, 42, 0));
        sink.on_actor_close(3, NetworkGuid(42), false);

        assert_eq!(sink.records.actors[0].class_path, None, "open row");
        assert_eq!(
            sink.records.actors[1].class_path, None,
            "close row must agree with the open row, not fabricate a class \
             from the actor's own instance-name path"
        );
    }

    #[test]
    fn destroyed_channel_archetypes_are_retired_but_dormant_ones_survive() {
        let mut rig = Rig::default();
        let mut sink = rig.sink();

        sink.on_actor_open(&channel_open(3, 42, 8));
        sink.on_actor_open(&channel_open(4, 43, 9));
        sink.on_actor_close(3, NetworkGuid(42), false);
        sink.on_actor_close(4, NetworkGuid(43), true);

        assert!(
            channel_archetype(sink.channel_state, 3, NetworkGuid(42)).is_none(),
            "destroyed channels must not accumulate sink-side archetypes"
        );
        assert_eq!(
            channel_archetype(sink.channel_state, 4, NetworkGuid(43)),
            Some(NetworkGuid(9)),
            "dormancy preserves the class needed when the same actor wakes"
        );
    }

    /// `Subject` and `SpawnedCharacter` are captured on the bomb PlayerState and
    /// on Swiftplay's (through `canonical_group`). A 0 is a disconnect, never a
    /// body; a reconnect's pawn is appended and a repeat moves to the end, so
    /// the last is the current body; `PossessedCharacter` (a camera, drone or
    /// ability pawn) never enters the history.
    #[test]
    fn player_identity_keeps_the_spawned_body() {
        const SWIFT: &str = "/Game/GameModes/_Development/Swiftplay_EndOfRoundCredits/Swiftplay_EoRCredits_PlayerState.Swiftplay_EoRCredits_PlayerState_C";
        const SPAWNED: &str = "SpawnedCharacter";
        const POSSESSED: &str = "PossessedCharacter";
        for (path, writes, want) in [
            (BOMB_PLAYER_STATE, vec![(SPAWNED, 576)], vec![576]),
            (SWIFT, vec![(SPAWNED, 576)], vec![576]),
            (
                BOMB_PLAYER_STATE,
                vec![(SPAWNED, 1368), (SPAWNED, 0)],
                vec![1368],
            ),
            (
                BOMB_PLAYER_STATE,
                vec![(SPAWNED, 1510), (SPAWNED, 0), (SPAWNED, 45530)],
                vec![1510, 45530],
            ),
            (
                BOMB_PLAYER_STATE,
                vec![(SPAWNED, 7), (SPAWNED, 8), (SPAWNED, 7), (SPAWNED, 7)],
                vec![8, 7],
            ),
            (BOMB_PLAYER_STATE, vec![(SPAWNED, 0)], vec![]),
            (BOMB_PLAYER_STATE, vec![(POSSESSED, 412)], vec![]),
            (
                BOMB_PLAYER_STATE,
                vec![(SPAWNED, 20), (POSSESSED, 20), (POSSESSED, 412)],
                vec![20],
            ),
        ] {
            let mut rig = Rig::default();
            let mut sink = rig.sink();
            sink.current_group_path = Arc::from(path);
            sink.current_actor_guid = 42;
            sink.record_player_identity(Some("Subject"), Some("uuid-here"), None);
            for &(name, guid) in &writes {
                sink.record_player_identity(Some(name), None, Some(guid));
            }
            let entry = &sink.channel_state.players[&42];
            assert_eq!(entry.subject.as_deref(), Some("uuid-here"), "{path}");
            assert_eq!(entry.character_net_guids, want, "{path} {writes:?}");
        }
    }

    /// The aggregate does not inherit the 32-line window's cap: 100 failed
    /// blocks stay 100 in the aggregate while the line list stops at 32.
    #[test]
    fn failures_past_the_line_cap_are_all_aggregated() {
        let mut rig = Rig::default();
        rig.state.enable_failure_aggregate(false);
        let mut sink = rig.sink();
        sink.set_current_group_path(Arc::from("/Script/ShooterGame.AresAbilitySystemComponent"));
        for i in 0..100 {
            sink.on_stream_failure(abandoned_tail(i % 2));
        }

        assert_eq!(
            sink.channel_state.stream_failures().len(),
            32,
            "the line window stays capped"
        );
        let agg = sink.channel_state.failures.as_ref().unwrap();
        assert_eq!(agg.total_failures(), 100, "the aggregate never caps");
        assert_eq!(agg.real_loss(), 100);
        // Two cells: consumed_bits is a key dimension, so the 50 failures that
        // stopped at 0 and the 50 that stopped at 1 stay apart, and each cell
        // still counts its whole population.
        let cells = agg.cells_sorted();
        assert_eq!(cells.len(), 2, "two distinct consumed values, two cells");
        let counted: u64 = cells.iter().map(|(_, cell)| cell.count).sum();
        assert_eq!(counted, 100, "the cells together hold every failure");
        for (key, cell) in &cells {
            assert_eq!(cell.count, 50, "{:?}", key.consumed_bits);
        }
        assert_eq!(
            cells[0].0.cause,
            vrf_net::pipeline::StreamFailureCause::AbandonedTail
        );
        assert_eq!(cells[0].0.record_handle, Some(3));
    }

    /// A preserved unresolved RPC failure and a genuinely lost RepLayout
    /// failure must land in separate aggregate buckets, so real loss is never
    /// inflated by payloads that are on disk as preservation rows.
    #[test]
    fn preserved_unresolved_failures_are_separated_from_real_loss() {
        let mut rig = Rig::default();
        rig.state.enable_failure_aggregate(true);
        let mut sink = rig.sink();
        sink.set_current_group_path(Arc::from("AbilitiesAndBuffsComponent"));

        // The framing layer's exact sequence for an unresolved block:
        // on_stream_failure, then on_unresolved_class_net_cache_payload.
        let unresolved = unresolved_failure(9, 64);
        for _ in 0..40 {
            sink.on_stream_failure(unresolved);
            sink.on_unresolved_class_net_cache_payload(unresolved, &[0xDE, 0xAD]);
        }

        // ...plus a real RepLayout loss.
        sink.set_current_group_path(Arc::from("/Script/ShooterGame.AresAbilitySystemComponent"));
        sink.on_stream_failure(abandoned_tail(185));

        let agg = sink.channel_state.failures.as_ref().unwrap();
        assert_eq!(agg.total_failures(), 41);
        assert_eq!(agg.preserved_unresolved(), 40);
        assert_eq!(agg.real_loss(), 1, "only the RepLayout block is loss");
        let cells = agg.cells_sorted();
        assert_eq!(cells.len(), 2);
        // Sorted by count: the preserved cell first, its samples carrying the
        // real payload bytes recorded by on_unresolved.
        assert_eq!(
            cells[0].0.cause,
            vrf_net::pipeline::StreamFailureCause::UnresolvedFunctionCount
        );
        assert_eq!(cells[0].1.samples.len(), 3, "sample cap, not 40");
        assert_eq!(cells[0].1.samples[0].payload_hex.as_deref(), Some("dead"));
        assert_eq!(cells[1].0.kind, vrf_net::pipeline::StreamKind::RepLayout);
        assert_eq!(
            cells[1].0.group_path.as_ref(),
            "/Script/ShooterGame.AresAbilitySystemComponent"
        );
    }

    /// Taking the aggregate drains it, so a checkpoint pass that creates one
    /// channel state per chunk cannot double-count a chunk's failures into
    /// the caller's totals.
    #[test]
    fn taking_the_aggregate_drains_it() {
        let mut rig = Rig::default();
        rig.state.enable_failure_aggregate(false);
        let mut sink = rig.sink();
        sink.set_current_group_path(Arc::from("SomeGroup"));
        sink.on_stream_failure(abandoned_tail(8));

        let taken = sink.channel_state.take_failure_aggregate();
        assert_eq!(taken.total_failures(), 1);
        assert!(
            sink.channel_state.failures.is_none(),
            "taking disables the drained aggregate"
        );
    }

    // (vendor: `export` feature gate removed)
    #[test]
    fn checkpoint_block_spans_include_every_emitted_child_and_empty_block() {
        let mut rig = Rig::default();
        rig.cache
            .add_export_group(vrf_schema::NetFieldExportGroup::new(
                "ActorGroup".to_owned(),
                1,
                4,
            ))
            .unwrap();
        rig.cache.set_net_guid_path(9, "ActorGroup", None);
        let mut sink = rig.sink();
        sink.enable_checkpoint_block_context(
            vrf_export::CheckpointIdentity {
                checkpoint_index: 2,
                checkpoint_id: Arc::from("duplicate-id"),
            },
            100,
            7,
        );
        sink.time_ms = 12;
        sink.packet_id = 3;
        let header = actor_block(true);
        sink.on_content_block(4, NetworkGuid(9), &header);
        sink.push_field(FieldValues {
            field_name: Some(Arc::from("raw-parent")),
            bit_count: 8,
            raw_bits: Some(SmallVec::from_slice(&[0xaa])),
            ..Default::default()
        });
        sink.push_field(FieldValues {
            field_name: Some(Arc::from("typed-child")),
            value_i64: Some(5),
            ..Default::default()
        });
        sink.on_content_block(4, NetworkGuid(9), &header);
        assert_eq!(sink.records.checkpoint_blocks.len(), 2);
        let first = &sink.records.checkpoint_blocks[0];
        assert_eq!(
            (
                first.block_index,
                first.field_row_start,
                first.field_row_count
            ),
            (7, 100, 2)
        );
        assert_eq!(first.checkpoint.checkpoint_index, 2);
        assert_eq!(first.group_resolution_source, "actor_guid_path");
        assert!(!first.resolution_memo_hit);
        let empty = &sink.records.checkpoint_blocks[1];
        assert_eq!(
            (
                empty.block_index,
                empty.field_row_start,
                empty.field_row_count
            ),
            (8, 102, 0)
        );
        assert!(empty.resolution_memo_hit);
        assert_eq!(empty.group_resolution_source, "actor_guid_path");
        let explicit_delete = ContentBlockHeader {
            is_deleted: true,
            object_net_guid: NetworkGuid(10),
            outer_net_guid: NetworkGuid(9),
            ..Default::default()
        };
        sink.on_deleted_block(4, NetworkGuid(9), &explicit_delete);
        let invalid_class_delete = ContentBlockHeader {
            has_class_net_guid: true,
            ..explicit_delete
        };
        sink.on_deleted_block(4, NetworkGuid(9), &invalid_class_delete);
        assert_eq!(sink.records.checkpoint_blocks[2].class_net_guid, None);
        assert_eq!(sink.records.checkpoint_blocks[3].class_net_guid, Some(0));
        assert_eq!(
            sink.records.fields[0].raw_bits.as_deref(),
            Some(&[0xaa][..])
        );
        assert_eq!(sink.records.fields[1].value_i64, Some(5));
    }
}
