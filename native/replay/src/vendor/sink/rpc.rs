// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/rpc.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! The ClassNetCache RPC payload walker. A ClassNetCache block carries function
//! calls, each payload a sub-archive in the RepLayout `FunctionParameters`
//! grammar; walking it turns one opaque blob into one row per named parameter
//! (their share of all rows: docs/PERFORMANCE_NOTES.md#rpc-parameter-walking).

use std::collections::HashSet;
use std::sync::Arc;

use smallvec::{SmallVec, smallvec};
use vrf_bitio::BitReader;
use vrf_decode::{
    ArrayFieldSchema, DecodeErrorKind, EffectArrayKind, EffectBlobError, FieldType,
    LIFE_CHANGE_BY_SECTION_SCHEMA, LIFE_CHANGE_DAMAGE_SCHEMA, LIFE_CHANGE_SECTION_SCHEMA,
    apply_overlay_with_checksum, decode_effect_blob_json, decode_struct_array,
    decode_struct_array_exact, group_hash_state,
};
use vrf_schema::{FxHashMap, NetGuidCache};

use super::intern::put;
use super::{ExportSink, FieldValues, MeasuredArrayRoute, TABLE};

/// Memo for [`ExportSink::find_rpc_param_group_path`], a pure function of (block
/// group path, function name, declared group paths); clearing it when
/// `NetGuidCache::schema_generation` moves keeps it exact. It spares a scan of
/// every declared group per RPC. The outer key is the interned group path, so a
/// hit allocates nothing.
#[derive(Debug, Clone, Default)]
pub(super) struct RpcParamGroupMemo {
    generation: u64,
    by_group: FxHashMap<Arc<str>, FxHashMap<String, Option<Arc<str>>>>,
}

impl ExportSink<'_> {
    /// Walk an RPC payload as a RepLayout parameter stream, naming each
    /// parameter from the group [`Self::compute_rpc_param_group_path`] finds, or
    /// `{func}._h{N}` without one.
    ///
    /// The `FunctionParameters` grammar:
    /// ```text
    ///   propertyChecksum : 1 bit (ignored)
    ///   loop:
    ///     encodedHandle  : IntPacked
    ///     [if 0 -> break]
    ///     handle = encodedHandle - 1
    ///     payloadBits    : IntPacked
    ///     fieldPayload   : sub-reader of payloadBits bits
    /// ```
    /// plus one trailing alignment bit, consumed when exactly one remains
    /// (`FunctionParameters && BitsRemaining == 1 -> SkipBits(1)`).
    ///
    /// `false` only when no parameter row was emitted (the caller then emits the
    /// raw row). A walk that breaks on a malformed read keeps its rows and bumps
    /// `truncated_rpcs`; after such a break, or a suffix past the terminator, the
    /// whole payload is added as one more row.
    pub(super) fn try_parse_rpc_params(
        &mut self,
        rpc_handle: u32,
        reader: BitReader<'_>,
        function_name: Option<&str>,
    ) -> bool {
        let Some(func_name) = function_name else {
            return false;
        };
        let whole_reader = reader.clone();
        let Ok(whole_bit_count) = u32::try_from(reader.bits_remaining()) else {
            return false;
        };

        let param_group_path = self.find_rpc_param_group_path(func_name);
        let mut rpc_reader = reader;

        if rpc_reader.read_bit().is_err() {
            return false;
        }
        self.stats.rpc_param_walks += 1;

        let mut emitted_any = false;
        // Set only on the three malformed-read breaks below, never on the
        // normal exits (end of stream, alignment bit, zero-handle terminator).
        let mut truncated = false;
        let mut unexplained_suffix = false;
        let param_group_path_ref = param_group_path.as_deref();

        loop {
            if rpc_reader.at_end() {
                break;
            }

            if rpc_reader.bits_remaining() == 1 {
                let _ = rpc_reader.read_bit();
                break;
            }

            let Ok(encoded_handle) = rpc_reader.read_int_packed() else {
                truncated = true;
                break;
            };
            if encoded_handle == 0 {
                // "No more parameters": one trailing alignment bit is grammar,
                // anything more is a suffix this walk cannot explain, counted
                // (not rejected; see `ExportStats::rpc_suffix_bits_dropped`).
                let leftover = rpc_reader.bits_remaining();
                if leftover > 1 {
                    self.stats.rpc_suffix_bits_dropped =
                        self.stats.rpc_suffix_bits_dropped.saturating_add(leftover);
                    unexplained_suffix = true;
                }
                break;
            }

            let param_handle = encoded_handle - 1;
            let Ok(payload_bits) = rpc_reader.read_int_packed() else {
                truncated = true;
                break;
            };

            // Fails when more bits are declared than remain.
            let Ok(sub) = rpc_reader.sub_reader(u64::from(payload_bits)) else {
                truncated = true;
                break;
            };

            // One schema walk for the name and the overlay's last-resort checksum.
            let param_export = param_group_path_ref.and_then(|gp| {
                self.cache
                    .get_group_by_path(gp)
                    .and_then(|g| g.get_field(param_handle))
            });
            let param_name: Option<&str> = param_export.map(|f| f.name.as_str());
            let param_checksum: Option<u32> = param_export.map(|f| f.compatible_checksum);

            // "Function.Param", or "Function._h{N}" unnamed: a dot, because group
            // paths already use ':' and downstream splits on the first '.'.
            let full_field_name = self.channel_state.names.intern_fmt(|out| match param_name {
                Some(pn) => put(out, format_args!("{func_name}.{pn}")),
                None => put(out, format_args!("{func_name}._h{param_handle}")),
            });

            let raw_bits = copy_raw_bits(sub, payload_bits);

            // The overlay keys on the parameter group; only the
            // `current_group_path` fallback has a cached hash.
            let overlay_group = param_group_path_ref.unwrap_or(&self.current_group_path);
            let group_state = match param_group_path_ref {
                Some(gp) => group_hash_state(gp),
                None => self.current_group_hash,
            };
            // `param_name`, not `full_field_name`: the synthesized `{func}._h{N}`
            // is no wire-declared name, and passed as one it would trip
            // `resolve_in_group`'s conflict guard against its own placeholder,
            // refusing the handle fallback that guard exists to allow.
            let (value_i64, value_f64, value_bool, mut value_str) = apply_overlay_with_checksum(
                &TABLE,
                overlay_group,
                group_state,
                param_name,
                param_handle,
                param_checksum,
                raw_bits.as_deref(),
                payload_bits,
                &mut self.stats.overlay,
            )
            .map(|result| result.into_columns())
            .unwrap_or_default();

            // Additive pass: an EffectContainer array the overlay left untyped
            // becomes a JSON `value_str`, `raw_bits` kept. A declared type that
            // decoded outranks this name-driven decode. The match is on the
            // parameter name: a `_h{N}` handle does not identify the element type.
            if value_i64.is_none()
                && value_f64.is_none()
                && value_bool.is_none()
                && value_str.is_none()
            {
                if let (Some(kind), Some(raw)) = (
                    param_name.and_then(EffectArrayKind::from_param_name),
                    raw_bits.as_deref(),
                ) {
                    // `payload_bits`, not `raw.len() * 8`: the padding is not data.
                    match decode_effect_blob_json(kind, raw, payload_bits) {
                        Ok(json) => {
                            value_str = Some(json);
                            self.stats.effect_blobs_decoded += 1;
                        }
                        Err(err) => {
                            // Reaches "Decode errors": `stats.overlay` is the only
                            // channel that survives the packet, so "Rows offered"
                            // over-reports by the failure count (0 measured).
                            self.stats.overlay.decoded_err += 1;
                            self.stats.overlay.error_report.record(
                                overlay_group,
                                &full_field_name,
                                FieldType::Raw,
                                payload_bits,
                                effect_error_kind(&err),
                            );
                        }
                    }
                }
            }

            let targeting_world_location_array = func_name == "MulticastRespondToValidMapClick"
                && param_handle == 0
                && param_name == Some("WorldLocation")
                && param_checksum == Some(2052180909)
                && param_group_path_ref
                    == Some(
                        "/Script/ShooterGame.MapTargetingStateComponent:MulticastRespondToValidMapClick",
                    )
                && param_group_path_ref
                    .and_then(|path| self.cache.get_group_by_path(path))
                    .and_then(|group| group.get_field(1))
                    .is_some_and(|field| {
                        field.name == "WorldLocation" && field.compatible_checksum == 3965480401
                    });
            let projectile_path_array = self.admits(MeasuredArrayRoute::NetworkedProjectilePath)
                && self.current_group_path.as_ref()
                    == "/Script/ShooterGame.PrecalculatedProjectileMovementComponent_ClassNetCache"
                && param_group_path_ref
                    == Some(
                        "/Script/ShooterGame.PrecalculatedProjectileMovementComponent:MulticastSetPath",
                    )
                && func_name == "MulticastSetPath"
                && param_handle == 0
                && param_name == Some("NetworkedProjectilePath")
                && param_checksum == Some(2_930_105_559);

            // Additive pass: the life-change arrays, outside the value gate on
            // purpose. That gate ranks decodes of the same bits; this pass only
            // adds rows, so typing the parent one day must not stop the children.
            if let (Some(schema), Some(raw)) = (
                life_change_schema_for_param(func_name, param_name),
                raw_bits.as_deref(),
            ) {
                self.emit_life_change_array(
                    schema,
                    &full_field_name,
                    rpc_handle,
                    raw,
                    payload_bits,
                );
            }

            // The multi-click RPC's flat array of 192-bit world locations. Every
            // identity is the replay's declaration, so a lookalike stays raw.
            if let (true, Some(raw)) = (targeting_world_location_array, raw_bits.as_deref()) {
                self.stats.targeting_world_locations_decoded += self.emit_exact_array_leaves(
                    &full_field_name,
                    rpc_handle,
                    (raw, payload_bits),
                    &[None, Some("WorldLocation")],
                    &[(1, 192, ".WorldLocation", FieldType::VectorDouble)],
                );
            }

            // The projectile path's element handles come from the PathPoint
            // descriptor (the replay's handles 1-3 are unrelated siblings), so
            // the route is scoped to the observed parent identity.
            if let (true, Some(raw)) = (projectile_path_array, raw_bits.as_deref()) {
                if super::blobs::strict_nested_array_preflight(raw, payload_bits, &[1, 2, 3]) {
                    self.stats.route_children_projectile_path += self.emit_exact_array_leaves(
                        &full_field_name,
                        rpc_handle,
                        (raw, payload_bits),
                        &[
                            None,
                            Some("ElapsedSeconds"),
                            Some("Location"),
                            Some("Velocity"),
                        ],
                        &[
                            (1, 32, ".ElapsedSeconds", FieldType::Float),
                            (2, 192, ".Location", FieldType::VectorDouble),
                            (3, 192, ".Velocity", FieldType::VectorDouble),
                        ],
                    );
                } else {
                    self.stats.array.errors += 1;
                }
            }

            self.push_field(FieldValues {
                handle: rpc_handle,
                field_name: Some(full_field_name),
                compatible_checksum: param_checksum,
                bit_count: payload_bits,
                raw_bits,
                value_i64,
                value_f64,
                value_bool,
                value_str,
            });

            emitted_any = true;
        }

        if truncated {
            self.stats.truncated_rpcs = self.stats.truncated_rpcs.saturating_add(1);
        }

        // Emitted parameter rows cannot stand in for bits the walk did not
        // explain, and they suppress the caller's raw fallback, so add the
        // whole payload as one more row; the typed rows stay.
        if emitted_any && (truncated || unexplained_suffix) {
            let field_name = self.channel_state.names.intern(func_name);
            self.push_field(FieldValues {
                handle: rpc_handle,
                field_name: Some(field_name),
                bit_count: whole_bit_count,
                raw_bits: copy_raw_bits(whole_reader, whole_bit_count),
                ..FieldValues::default()
            });
        }

        emitted_any
    }

    /// Emit one row per member of a life-change array element; additive, the
    /// caller pushes the parent row either way. The rows carry `rpc_handle`, not
    /// the member's own handle: `tools/to_valplay_bundle.py` groups a call's
    /// parameters by `(packet, actor, group, handle)`, so member handles would
    /// split one call into several events.
    fn emit_life_change_array(
        &mut self,
        schema: &'static ArrayFieldSchema,
        prefix: &str,
        rpc_handle: u32,
        raw: &[u8],
        bit_count: u32,
    ) {
        let flattened =
            decode_struct_array(raw, bit_count, Some(schema), &[], &mut self.stats.array);
        for field in &flattened {
            let columns = match life_change_member_type(&field.path) {
                Some(ft) => super::blobs::decode_leaf_with_stats(
                    ft,
                    &field.raw_bits,
                    field.bit_count,
                    &mut self.stats.array_leaf_decode_errors,
                ),
                None => (None, None, None, None),
            };
            self.push_child(
                rpc_handle,
                &[prefix, &field.path],
                field.bit_count,
                &field.raw_bits,
                columns,
            );
        }
    }

    /// Emit an RPC struct array's leaves when every element holds exactly
    /// `members` (handle, width, path suffix, type), else none: a walker
    /// diagnostic, a short element (the walker calls a missing member clean), an
    /// unexpected leaf, a duplicate path or a non-finite number keeps only the
    /// raw parent. A refused clean walk counts once in
    /// `array_leaf_decode_errors`. Returns the children pushed.
    fn emit_exact_array_leaves(
        &mut self,
        prefix: &str,
        rpc_handle: u32,
        (raw, bit_count): (&[u8], u32),
        declared: &[Option<&str>],
        members: &[(u32, u32, &str, FieldType)],
    ) -> u64 {
        let mut isolated = vrf_decode::ArrayDecodeStats::default();
        let flattened = decode_struct_array_exact(raw, bit_count, declared, &mut isolated);
        self.stats.array.merge_from(&isolated);
        if !isolated.is_clean() {
            return 0;
        }
        let len = flattened.len() as u64;
        let complete = isolated.fields_emitted == len
            && isolated
                .elements_decoded
                .saturating_mul(members.len() as u64)
                == len;
        let prior_errors = self.stats.array_leaf_decode_errors;
        let mut paths = HashSet::new();
        let children: Option<Vec<_>> = complete
            .then(|| {
                flattened
                    .into_iter()
                    .map(|field| {
                        let &(.., kind) = members.iter().find(|&&(handle, width, suffix, _)| {
                            field.handle == handle
                                && field.bit_count == width
                                && field.path.ends_with(suffix)
                        })?;
                        let finite = kind != FieldType::VectorDouble
                            || field.raw_bits.chunks_exact(8).all(|chunk| {
                                f64::from_le_bytes(chunk.try_into().expect("eight-byte chunk"))
                                    .is_finite()
                            });
                        if !finite || !paths.insert(field.path.clone()) {
                            return None;
                        }
                        let columns = super::blobs::decode_leaf_with_stats(
                            kind,
                            &field.raw_bits,
                            field.bit_count,
                            &mut self.stats.array_leaf_decode_errors,
                        );
                        let typed = match kind {
                            FieldType::Float => columns.1.is_some_and(f64::is_finite),
                            _ => columns.3.is_some(),
                        };
                        typed.then_some((field, columns))
                    })
                    .collect()
            })
            .flatten();
        let Some(children) = children else {
            if self.stats.array_leaf_decode_errors == prior_errors {
                self.stats.array_leaf_decode_errors += 1;
            }
            return 0;
        };
        let pushed = children.len() as u64;
        for (field, columns) in children {
            self.push_child(
                rpc_handle,
                &[prefix, &field.path],
                field.bit_count,
                &field.raw_bits,
                columns,
            );
        }
        pushed
    }

    /// [`Self::compute_rpc_param_group_path`], memoised in [`RpcParamGroupMemo`].
    fn find_rpc_param_group_path(&mut self, function_name: &str) -> Option<Arc<str>> {
        let Self {
            cache,
            channel_state,
            current_group_path,
            ..
        } = self;
        let memo = &mut channel_state.rpc_param_groups;
        let generation = cache.schema_generation();
        if memo.generation != generation {
            memo.by_group.clear();
            memo.generation = generation;
        }

        if let Some(by_function) = memo.by_group.get(&**current_group_path) {
            if let Some(hit) = by_function.get(function_name) {
                return hit.clone();
            }
        }

        let resolved = Self::compute_rpc_param_group_path(cache, current_group_path, function_name);
        memo.by_group
            // Cloning the interned handle, not the string.
            .entry(Arc::clone(current_group_path))
            .or_default()
            .insert(function_name.to_owned(), resolved.clone());
        resolved
    }

    /// The RPC's parameter group: `<class>:<function>` from the block's
    /// `_ClassNetCache` group when the class itself declares it (e.g.
    /// `DamageableComponent`), else the one declared group ending in
    /// `:<function>`, which covers inheritance (`Wushu_PC_C_ClassNetCache`'s
    /// `MulticastNotifyKilledEnemy` is declared as
    /// `ShooterCharacter:MulticastNotifyKilledEnemy`). Most of the 84 RPC
    /// parameter groups have a unique function name; an ambiguous one is `None`,
    /// and its parameters are named `{func}._h{N}`.
    fn compute_rpc_param_group_path(
        cache: &NetGuidCache,
        current_group_path: &str,
        function_name: &str,
    ) -> Option<Arc<str>> {
        if let Some(base) = current_group_path.strip_suffix(vrf_schema::CLASS_NET_CACHE_SUFFIX) {
            let candidate = format!("{base}:{function_name}");
            if cache.get_group_by_path(&candidate).is_some() {
                return Some(Arc::from(candidate));
            }
        }

        let suffix = format!(":{function_name}");
        let mut found: Option<&str> = None;
        for group in cache.groups() {
            if group.path.ends_with(&suffix) {
                if found.is_some() {
                    // Ambiguous: multiple groups match this function name.
                    return None;
                }
                found = Some(&group.path);
            }
        }
        found.map(Arc::from)
    }
}

/// Copy `bit_count` bits out of `reader` into a fresh byte buffer. `None` for a
/// zero-bit field -- an empty blob is not "no payload" to the valplay adapter,
/// whose capture predicate keys on `raw_bits` -- and for a short reader.
pub(super) fn copy_raw_bits(
    mut reader: BitReader<'_>,
    bit_count: u32,
) -> Option<SmallVec<[u8; 16]>> {
    if bit_count == 0 {
        return None;
    }
    let mut buf = smallvec![0u8; (bit_count as usize).div_ceil(8)];
    reader.copy_bits_to(&mut buf, u64::from(bit_count)).ok()?;
    Some(buf)
}

/// Which life-change schema an RPC parameter takes, if any. Keyed on the
/// function too: each struct array has its own handle space, so the same four
/// members sit at 10-13, 1-4 or 2-5. `MulticastNotifyHeal` and
/// `MulticastNotifyOverhealDecay`, more than half the calls, name theirs
/// `LifeChangeBySection`, not `LifeChangeEvents`.
/// `MulticastReceivePlayerTemporaryDeathEvent_Point` and
/// `MulticastReceivePlayerDownedEvent_Point` (the same array at 12-15) are left
/// out: 9 and 2 calls across twenty replays cannot check a schema.
fn life_change_schema_for_param(
    function_name: &str,
    param_name: Option<&str>,
) -> Option<&'static ArrayFieldSchema> {
    match (function_name, param_name?) {
        ("MulticastNotifyDamage_Point" | "MulticastNotifyDamage_Base", "LifeChangeEvents") => {
            Some(&LIFE_CHANGE_DAMAGE_SCHEMA)
        }
        ("MulticastSectionLifeChange", "LifeChangeEvents") => Some(&LIFE_CHANGE_SECTION_SCHEMA),
        ("MulticastNotifyHeal" | "MulticastNotifyOverhealDecay", "LifeChangeBySection") => {
            Some(&LIFE_CHANGE_BY_SECTION_SCHEMA)
        }
        _ => None,
    }
}

/// The member type of a life-change leaf, matched on the schema's name (handles
/// move between functions, names do not). `ChangedComponent` resolves through
/// `net_guids` to a `*DamageSection` actor on >99.98% of rows, `sum(DeltaLife)`
/// matches the RPC's own scalar total on 69,818 of 69,818 calls, and
/// `bAliveAfterChange` is one bit on every row and agrees with the sibling
/// `bAliveAfterDamage` 17,550/17,550.
fn life_change_member_type(path: &str) -> Option<FieldType> {
    if path.ends_with("ChangedComponent") {
        Some(FieldType::ObjectNetGuid)
    } else if path.ends_with("LifeResult") || path.ends_with("DeltaLife") {
        Some(FieldType::Float)
    } else if path.ends_with("bAliveAfterChange") {
        Some(FieldType::Bool)
    } else {
        None
    }
}

/// Map an effect-blob failure onto the overlay report's error kinds, which must
/// mean the same here as for overlay failures: the kind is the report's only
/// "why" column. No wildcard, so a new `EffectBlobError` does not compile until
/// it is classified.
fn effect_error_kind(err: &EffectBlobError) -> DecodeErrorKind {
    match err {
        EffectBlobError::BitIo(bit) => DecodeErrorKind::from_bit_error(bit),
        // The bits ran out before the structure did: the window ended before
        // the terminator, or a member's type read past the end of its own
        // field.
        EffectBlobError::MissingTerminator { .. } | EffectBlobError::PayloadOverread { .. } => {
            DecodeErrorKind::Eof
        }
        // Bits the structure did not account for, after the terminator or
        // inside a field whose type read short of it.
        EffectBlobError::ResidualBits { .. } | EffectBlobError::PayloadUnderread { .. } => {
            DecodeErrorKind::Residual
        }
        // Decoded values refused: a count over the configured maximum, a
        // float JSON cannot carry.
        EffectBlobError::ArrayCountTooLarge { .. } | EffectBlobError::NonFiniteFloat { .. } => {
            DecodeErrorKind::Rejected
        }
        // The bits break a rule of this framing. `PayloadTooLarge` is a field
        // width past the window or the decoder's 65,536-bit cap, refused before
        // the payload is read: an overlong length prefix, `Malformed` for an
        // overlay string or byte array too, not a reader running out.
        EffectBlobError::PayloadTooLarge { .. }
        | EffectBlobError::IndexOutOfBounds { .. }
        | EffectBlobError::NonAscendingIndex { .. }
        | EffectBlobError::TooManyFields { .. }
        | EffectBlobError::BitLengthExceedsBuffer { .. }
        | EffectBlobError::UnexpectedPayloadWidth { .. }
        | EffectBlobError::ElementFieldCount { .. }
        | EffectBlobError::NonAdjacentHandles { .. }
        | EffectBlobError::InconsistentHandleBase { .. }
        | EffectBlobError::NonZeroTerminator { .. } => DecodeErrorKind::Malformed,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use vrf_bitio::BitError;

    use super::{EffectBlobError, effect_error_kind};

    /// Effect-blob failures share the overlay's error report, so each cause
    /// prints its own label. Every variant has a case, checked against the list
    /// the variant match below is generated from: the match has no wildcard, so
    /// a new variant does not compile until listed, and a listed variant without
    /// a case fails here.
    #[test]
    fn effect_failures_print_the_label_of_their_cause() {
        // Generated from one list, so the list and the match cannot disagree.
        macro_rules! variants {
            ($($variant:ident),+ $(,)?) => {
                (
                    [$(stringify!($variant)),+],
                    |err: &EffectBlobError| -> &'static str {
                        match err {
                            $(EffectBlobError::$variant { .. } => stringify!($variant),)+
                        }
                    },
                )
            };
        }
        let (every_variant, variant_of) = variants!(
            BitIo,
            ArrayCountTooLarge,
            IndexOutOfBounds,
            NonAscendingIndex,
            PayloadTooLarge,
            TooManyFields,
            BitLengthExceedsBuffer,
            ResidualBits,
            NonFiniteFloat,
            UnexpectedPayloadWidth,
            ElementFieldCount,
            NonAdjacentHandles,
            InconsistentHandleBase,
            PayloadOverread,
            PayloadUnderread,
            MissingTerminator,
            NonZeroTerminator,
        );
        let cases = [
            (
                EffectBlobError::BitIo(BitError::Eof {
                    position: 0,
                    length: 8,
                    requested: 8,
                }),
                "EOF",
            ),
            (
                EffectBlobError::BitIo(BitError::MalformedIntPacked { position: 0 }),
                "Malformed",
            ),
            (
                EffectBlobError::BitIo(BitError::InvalidString { position: 0 }),
                "Malformed",
            ),
            (
                EffectBlobError::MissingTerminator { context: "array" },
                "EOF",
            ),
            (
                EffectBlobError::PayloadOverread {
                    declared: 16,
                    consumed: 32,
                },
                "EOF",
            ),
            (EffectBlobError::ResidualBits { remaining: 16 }, "Residual"),
            (
                EffectBlobError::PayloadUnderread {
                    declared: 32,
                    consumed: 16,
                },
                "Residual",
            ),
            (EffectBlobError::NonFiniteFloat { index: 0 }, "Rejected"),
            (
                EffectBlobError::ArrayCountTooLarge {
                    count: 300,
                    max: 256,
                },
                "Rejected",
            ),
            (EffectBlobError::NonZeroTerminator { value: 1 }, "Malformed"),
            (EffectBlobError::ElementFieldCount { found: 3 }, "Malformed"),
            // A declared width past the window is an overlong length prefix,
            // `Malformed` like an overlay string's, not an EOF.
            (
                EffectBlobError::PayloadTooLarge {
                    bits: 64,
                    remaining: 32,
                },
                "Malformed",
            ),
            (
                EffectBlobError::IndexOutOfBounds { index: 2, count: 2 },
                "Malformed",
            ),
            (
                EffectBlobError::NonAscendingIndex {
                    index: 0,
                    previous: 0,
                },
                "Malformed",
            ),
            (
                EffectBlobError::TooManyFields { context: "element" },
                "Malformed",
            ),
            (
                EffectBlobError::BitLengthExceedsBuffer {
                    bits: 64,
                    available: 32,
                },
                "Malformed",
            ),
            (
                EffectBlobError::UnexpectedPayloadWidth {
                    context: "float value",
                    expected: 32,
                    found: 16,
                },
                "Malformed",
            ),
            (
                EffectBlobError::NonAdjacentHandles {
                    first: 1,
                    second: 3,
                },
                "Malformed",
            ),
            (
                EffectBlobError::InconsistentHandleBase {
                    expected: 1,
                    found: 3,
                },
                "Malformed",
            ),
        ];
        let printed: Vec<(String, String)> = cases
            .iter()
            .map(|(err, _)| (format!("{err:?}"), effect_error_kind(err).to_string()))
            .collect();
        let wanted: Vec<(String, String)> = cases
            .iter()
            .map(|(err, want)| (format!("{err:?}"), (*want).to_owned()))
            .collect();
        assert_eq!(printed, wanted);

        let reached: BTreeSet<&str> = cases.iter().map(|(err, _)| variant_of(err)).collect();
        assert_eq!(
            reached,
            every_variant.into_iter().collect::<BTreeSet<_>>(),
            "every EffectBlobError needs a case"
        );
    }
}
