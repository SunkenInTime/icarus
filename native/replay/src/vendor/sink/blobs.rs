// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/blobs.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! Additive decoders for two payload shapes the field stream hands over whole:
//! the parent row keeps its `raw_bits` and is emitted either way, these only
//! add rows, and a decoder that fails leaves the export as it would have been.
//!
//! - **Flattened arrays.** UE flattens a `TArray` element's members onto
//!   consecutive handles of the enclosing group, whose net field exports name
//!   them; `decode_struct_array` walks that, and this module types the leaves.
//! - **Struct blobs.** `RoundResults`, `TeamEconomy` and `RoundInfos`, opaque
//!   to the overlay, have dedicated decoders in `vrf-decode`.

use smallvec::SmallVec;
use vrf_bitio::BitReader;
use vrf_decode::{
    ABILITY_CASTS_SCHEMA, ArrayDecodeStats, COMBAT_ROUNDS_SCHEMA, EffectArrayKind, FieldType,
    FlattenedField, structs,
};
use vrf_schema::NetGuidCache;

use super::intern::put;
use super::{ExportSink, FieldValues, MeasuredArrayRoute, TABLE};

/// The four typed columns a decoded value lands in. At most one is ever
/// populated; `vrf_export`'s crate doc ("sparse value columns vs. Union") says
/// why this is four nullable columns rather than a union.
type DecodedColumns = (Option<i64>, Option<f64>, Option<bool>, Option<String>);

/// What the replay declares at `handle`.
fn declared_at<T: Copy>(slots: &[Option<T>], handle: u32) -> Option<T> {
    slots.get(handle as usize).copied().flatten()
}

/// How a measured-route leaf is typed.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Leaf {
    Field(FieldType),
    /// KillData `WeaponTheme`: an FString that must carry its null terminator.
    WeaponTheme,
    /// An `FEffectData*` array, as the RPC parameters of the same name.
    Effect(EffectArrayKind),
    /// A raw container whose own array is typed by [`NESTED_RULES`].
    Nested,
}

/// What the overlay may say about a leaf a rule types.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Overlay {
    NoEntry,
    NoneOrSame,
    SameType,
    /// Exactly `Raw`: a descriptor kept raw in the table that the rule reads.
    RawEntry,
}

/// `(route, handle, declared name, declared checksum, leaf, overlay, widths)`.
/// A leaf is typed only when every column matches; `None` and `&[]` leave that
/// column unchecked. Anything else stays an exact raw child.
type LeafRule = (
    MeasuredArrayRoute,
    u32,
    Option<&'static str>,
    Option<u32>,
    Leaf,
    Overlay,
    &'static [u32],
);

/// The leaf windows the measured routes type: wire types measured across the
/// corpus (the nested and KillData identities with exact consumption on all
/// 714 replays), not the values' meaning or units.
#[rustfmt::skip]
const LEAF_RULES: &[LeafRule] = {
    use FieldType::{Bool, Byte, EnumByte, FName, FTextTree, Float, Int32, Int64, ObjectNetGuid, UInt32, VectorDouble};
    use EffectArrayKind::{Float as Floats, Object as Objects};
    use Leaf::{Effect, Field, Nested, WeaponTheme};
    use MeasuredArrayRoute::*;
    use Overlay::*;
    &[
        (AllPlayersObfuscatedPlayerInformation, 49, None, None, Field(Bool), SameType, &[]),
        (AllPlayersObfuscatedPlayerInformation, 50, None, None, Field(EnumByte), SameType, &[]),
        (TrackedRewards, 28, Some("RewardName"), Some(1_337_472_711), Field(FName), SameType, &[]),
        (TrackedRewards, 29, Some("LocalizedRewardName"), Some(483_770_233), Field(FTextTree), RawEntry, &[]),
        (TrackedRewards, 30, Some("InstancesOfReward"), Some(2_922_243_316), Field(Int32), SameType, &[]),
        (TrackedRewards, 31, Some("RewardGrantStrategy"), Some(3_589_631_714), Field(EnumByte), SameType, &[]),
        (TrackedRewards, 32, Some("Source"), Some(1_118_571_008), Field(EnumByte), SameType, &[]),
        (SelectedV2, 3, Some("EquippableDataAsset"), Some(1_793_937_854), Field(ObjectNetGuid), NoneOrSame, &[]),
        (SelectedV2, 4, Some("EquippableSkinDataAsset"), Some(3_765_038_216), Field(ObjectNetGuid), NoneOrSame, &[]),
        (SelectedV2, 5, Some("EquippableSkinLevelDataAsset"), Some(603_923_741), Field(ObjectNetGuid), NoneOrSame, &[]),
        (SelectedV2, 6, Some("EquippableSkinChromaDataAsset"), Some(3_166_589_204), Field(ObjectNetGuid), NoneOrSame, &[]),
        (SelectedV2, 7, Some("EquippableCharmDataAsset"), Some(3_345_806_642), Field(ObjectNetGuid), NoneOrSame, &[]),
        (SelectedV2, 8, Some("EquippableCharmLevelDataAsset"), Some(1_087_985_310), Field(ObjectNetGuid), NoneOrSame, &[]),
        (SelectedV2, 13, Some("EquippableAttachments"), Some(3_137_596_882), Nested, NoEntry, &[]),
        (KillData, 3, Some("Victim"), Some(3_990_035_472), Field(ObjectNetGuid), NoneOrSame, &[]),
        (KillData, 4, Some("KillingEquippableClass"), Some(2_071_131_011), Field(ObjectNetGuid), NoneOrSame, &[]),
        (KillData, 5, Some("WeaponTheme"), Some(1_839_952_321), WeaponTheme, NoEntry, &[]),
        (KillData, 6, Some("AssistingPlayers"), Some(1_689_463_717), Nested, NoEntry, &[]),
        (KillData, 9, Some("DamageType"), Some(2_992_423_760), Field(ObjectNetGuid), NoneOrSame, &[]),
        (KillData, 10, Some("DamageTaken"), Some(2_001_471_495), Field(Float), NoneOrSame, &[]),
        // The observed byte code; no enum label is claimed.
        (KillData, 11, Some("DamageRegion"), Some(3_229_265_809), Field(Byte), NoneOrSame, &[]),
        (KillData, 12, Some("GameTimeElapsed"), Some(3_684_431_363), Field(Float), NoneOrSame, &[]),
        (KillData, 13, Some("RoundTimestamp"), Some(2_328_473_242), Field(Float), NoneOrSame, &[]),
        (KillData, 14, Some("RoundNumber"), Some(843_024_485), Field(Int32), NoneOrSame, &[]),
        (KillData, 15, Some("bDidKillTriggerFinisher"), Some(2_795_684_046), Field(Bool), NoneOrSame, &[]),
        (ServerActiveEffects, 5, None, None, Field(Bool), SameType, &[]),
        (ServerActiveEffects, 6, None, None, Field(Bool), SameType, &[]),
        (ServerActiveEffects, 7, None, None, Field(ObjectNetGuid), SameType, &[]),
        (ServerActiveEffects, 8, None, None, Field(ObjectNetGuid), SameType, &[]),
        (ServerActiveEffects, 9, Some("FloatValues"), Some(3_597_032_544), Effect(Floats), NoEntry, &[]),
        (ServerActiveEffects, 17, Some("ObjectValues"), Some(865_691_585), Effect(Objects), NoEntry, &[]),
        // No top-level overlay; the exact 192-bit windows decode on every measured build.
        (ServerActiveEffects, 30, Some("Translation"), None, Field(VectorDouble), NoneOrSame, &[]),
        (ServerActiveEffects, 31, Some("Scale3D"), None, Field(VectorDouble), NoneOrSame, &[]),
        (ServerActiveEffects, 33, None, None, Field(Float), SameType, &[]),
        (ServerActiveEffects, 34, None, None, Field(EnumByte), SameType, &[]),
        (RequestedIgnoreActors, 5, Some("RequestedIgnoreActors"), Some(3_344_674_359), Field(ObjectNetGuid), NoneOrSame, &[]),
        // All or nothing (`emit_flattened_array`), at the measured widths.
        (ActiveBlinds, 3, Some("BlindId"), Some(2_836_858_544), Field(UInt32), NoneOrSame, &[32]),
        // Signed: 3321413110 reproduces only as int64 (uint64 gives 2854897423),
        // recomputed in tools/tests/test_compatible_checksum_facts.py.
        (ActiveBlinds, 4, Some("EffectID"), Some(3_321_413_110), Field(Int64), NoneOrSame, &[64]),
        (ActiveBlinds, 5, Some("SourceID"), Some(4_130_766_059), Field(FName), NoneOrSame, &[297]),
        (ActiveBlinds, 6, Some("bLocalEffect"), Some(2_802_682_995), Field(Bool), NoneOrSame, &[1]),
        (ActiveBlinds, 7, Some("bTransient"), Some(815_378_154), Field(Bool), NoneOrSame, &[1]),
        (ActiveBlinds, 8, Some("InitialDuration"), Some(1_370_668_337), Field(Float), NoneOrSame, &[32]),
        (ActiveBlinds, 9, Some("StartNetMovementTime"), Some(2_358_118_895), Field(Float), NoneOrSame, &[32]),
        (ActiveBlinds, 10, Some("BlindConfig"), Some(4_121_438_116), Field(ObjectNetGuid), NoneOrSame, &[16]),
        // A null actor is the one-byte IntPacked zero (59 windows in the 81-file audit).
        (ActiveBlinds, 11, Some("CausingActor"), Some(2_370_661_694), Field(ObjectNetGuid), NoneOrSame, &[8, 16, 24]),
    ]
};

/// The members of a [`Leaf::Nested`] container's array, apart from
/// [`LEAF_RULES`] so a top-level leaf at the same handle is never typed.
#[rustfmt::skip]
const NESTED_RULES: &[LeafRule] = {
    use FieldType::ObjectNetGuid;
    use Leaf::Field;
    use MeasuredArrayRoute::{KillData, SelectedV2};
    use Overlay::NoneOrSame;
    &[
        (SelectedV2, 14, Some("SocketAsset"), Some(3_666_994_016), Field(ObjectNetGuid), NoneOrSame, &[]),
        (SelectedV2, 15, Some("AttachmentAsset"), Some(856_446_005), Field(ObjectNetGuid), NoneOrSame, &[]),
        (KillData, 7, Some("AssistingPlayers"), Some(1_417_448_159), Field(ObjectNetGuid), NoneOrSame, &[]),
    ]
};

/// The rule in `rules` for `route`'s `handle`, if the leaf meets every column.
fn leaf_rule(
    rules: &[LeafRule],
    route: MeasuredArrayRoute,
    handle: u32,
    width: u32,
    name: Option<&str>,
    checksum: Option<u32>,
    resolved: Option<FieldType>,
) -> Option<Leaf> {
    let &(_, _, want_name, want_checksum, leaf, overlay, widths) = rules
        .iter()
        .find(|rule| rule.0 == route && rule.1 == handle)?;
    let wanted = match leaf {
        Leaf::Field(field_type) => Some(field_type),
        _ => None,
    };
    let overlay_agrees = match overlay {
        Overlay::NoEntry => resolved.is_none(),
        Overlay::NoneOrSame => resolved.is_none() || resolved == wanted,
        Overlay::SameType => resolved.is_some() && resolved == wanted,
        Overlay::RawEntry => resolved == Some(FieldType::Raw),
    };
    (overlay_agrees
        && want_name.is_none_or(|want| name == Some(want))
        && want_checksum.is_none_or(|want| checksum == Some(want))
        && (widths.is_empty() || widths.contains(&width)))
    .then_some(leaf)
}

/// The handles `rules` types for `route`: all a strict preflight admits.
fn rule_handles(rules: &[LeafRule], route: MeasuredArrayRoute) -> SmallVec<[u32; 16]> {
    rules
        .iter()
        .filter(|rule| rule.0 == route)
        .map(|rule| rule.1)
        .collect()
}

pub(super) fn strict_nested_array_preflight(raw: &[u8], bit_count: u32, allowed: &[u32]) -> bool {
    // The generic walker tolerates EOF terminators and skips zero-width members;
    // these routes demand explicit terminators and check every handle before a
    // zero-width member could vanish.
    if bit_count == 0 {
        return false;
    }
    let Ok(mut reader) = BitReader::with_bit_len(raw, u64::from(bit_count)) else {
        return false;
    };
    let Ok(capacity) = reader.read_int_packed() else {
        return false;
    };
    if capacity > vrf_decode::MAX_ELEMENTS {
        return false;
    }
    let mut elements = 0;
    loop {
        if reader.at_end() {
            return false;
        }
        let Ok(encoded_index) = reader.read_int_packed() else {
            return false;
        };
        if encoded_index == 0 {
            return reader.at_end();
        }
        if encoded_index > capacity || elements == vrf_decode::MAX_ELEMENTS {
            return false;
        }
        elements += 1;
        let mut fields = 0;
        loop {
            if reader.at_end() {
                return false;
            }
            let Ok(encoded_handle) = reader.read_int_packed() else {
                return false;
            };
            if encoded_handle == 0 {
                break;
            }
            if fields == vrf_decode::MAX_FIELDS_PER_ELEMENT {
                return false;
            }
            fields += 1;
            let handle = encoded_handle - 1;
            if !allowed.contains(&handle) {
                return false;
            }
            let Ok(payload_bits) = reader.read_int_packed() else {
                return false;
            };
            if payload_bits == 0 || reader.skip_bits(u64::from(payload_bits)).is_err() {
                return false;
            }
        }
    }
}

/// The array inside a [`Leaf::Nested`] container, all or nothing: the strict
/// preflight, a clean exact walk, then every member matching [`NESTED_RULES`]
/// and decoding. A member refused after a clean walk counts once in `failures`.
fn decode_nested(
    route: MeasuredArrayRoute,
    container: &FlattenedField,
    names: &[Option<&str>],
    checksums: &[Option<u32>],
    group_path: &str,
    array: &mut ArrayDecodeStats,
    failures: &mut u64,
) -> Option<Vec<(FlattenedField, DecodedColumns)>> {
    let (raw, bit_count) = (&container.raw_bits, container.bit_count);
    if !strict_nested_array_preflight(raw, bit_count, &rule_handles(NESTED_RULES, route)) {
        array.errors += 1;
        return None;
    }
    let mut walk = ArrayDecodeStats::default();
    let flattened = vrf_decode::decode_struct_array_exact(raw, bit_count, names, &mut walk);
    array.merge_from(&walk);
    if !walk.is_clean() {
        return None;
    }
    let mut members = Vec::with_capacity(flattened.len());
    for leaf in flattened {
        let name = declared_at(names, leaf.handle);
        let resolved = vrf_decode::resolve_field_type(&TABLE, group_path, name, Some(leaf.handle));
        let checksum = declared_at(checksums, leaf.handle);
        let rule = leaf_rule(
            NESTED_RULES,
            route,
            leaf.handle,
            leaf.bit_count,
            name,
            checksum,
            resolved,
        );
        let Some(Leaf::Field(field_type)) = rule else {
            *failures += 1;
            return None;
        };
        // A failed decode is all-`None` and already counted.
        let columns = decode_leaf_with_stats(field_type, &leaf.raw_bits, leaf.bit_count, failures);
        if columns == (None, None, None, None) {
            return None;
        }
        members.push((leaf, columns));
    }
    Some(members)
}

/// The array bits minus the one extra zero IntPacked an empty ActiveBlinds delta
/// may carry after its index terminator (60 windows in 41 of the 1,018 corpus
/// replays, all main pass). The parent keeps its bits and each spared byte is
/// counted (`ExportStats::active_blinds_empty_trailers`); every other shape
/// keeps the exact-window checks.
fn active_blind_array_bits(raw: &[u8], bit_count: u32) -> u32 {
    let without_empty_trailer = (|| {
        let mut reader = BitReader::with_bit_len(raw, u64::from(bit_count)).ok()?;
        let capacity = reader.read_int_packed().ok()?;
        if capacity > vrf_decode::MAX_ELEMENTS || reader.read_int_packed().ok()? != 0 {
            return None;
        }
        if reader.bits_remaining() != 8 || reader.read_int_packed().ok()? != 0 {
            return None;
        }
        Some(bit_count - 8)
    })();
    without_empty_trailer.unwrap_or(bit_count)
}

/// Decode a leaf a rule typed; a failure counts in `failures` and leaves the
/// columns null.
fn decode_leaf(leaf: Leaf, raw: &[u8], bit_count: u32, failures: &mut u64) -> DecodedColumns {
    let text = match leaf {
        Leaf::Field(field_type) => {
            return decode_leaf_with_stats(field_type, raw, bit_count, failures);
        }
        Leaf::Nested => return (None, None, None, None),
        Leaf::WeaponTheme => kill_weapon_theme(raw, bit_count),
        Leaf::Effect(kind) => vrf_decode::decode_effect_blob_json(kind, raw, bit_count).ok(),
    };
    if text.is_none() {
        *failures = failures.saturating_add(1);
    }
    (None, None, None, text)
}

/// A set bit, then an FString whose null terminator is required for every
/// nonzero length (the generic reader tolerates its absence) and checked, a
/// valid character in its slot included, before decoding; nothing may follow.
fn kill_weapon_theme(raw: &[u8], bit_count: u32) -> Option<String> {
    let mut reader = BitReader::with_bit_len(raw, u64::from(bit_count)).ok()?;
    if !reader.read_bit().ok()? {
        return None;
    }
    let mut framing = reader.clone();
    let length = framing.read_i32().ok()?;
    let units = i64::from(length).unsigned_abs();
    let unit_bits = if length < 0 { 16 } else { 8 };
    if units * (unit_bits / 8) > 64 * 1024 {
        return None;
    }
    if units != 0 {
        framing.skip_bits((units - 1) * unit_bits).ok()?;
        if framing.read_bits(unit_bits as u32).ok()? != 0 {
            return None;
        }
    }
    if framing.bits_remaining() != 0 {
        return None;
    }
    let value = reader.read_fstring(64 * 1024).ok()?;
    (reader.bits_remaining() == 0).then_some(value)
}

/// The measured route a flattened-array parent belongs to, from its exact
/// group, name and checksum. Whether the replay's branch admits that route is
/// a separate question, answered by `ExportSink::admits`.
fn measured_array_route(
    group: &str,
    parent: &str,
    checksum: Option<u32>,
) -> Option<MeasuredArrayRoute> {
    let route = match (group, parent, checksum) {
        (
            "/Script/ShooterGame.OwnerExclusivePlayerInfo",
            "AllPlayersObfuscatedPlayerInformation",
            Some(1_349_268_968),
        ) => MeasuredArrayRoute::AllPlayersObfuscatedPlayerInformation,
        ("/Script/ShooterGame.OwnerExclusivePlayerInfo", "TrackedRewards", Some(976_048_801)) => {
            MeasuredArrayRoute::TrackedRewards
        }
        ("/Script/ShooterGame.PersonalizationComponent", "SelectedV2", Some(4_218_721_055)) => {
            MeasuredArrayRoute::SelectedV2
        }
        ("/Script/ShooterGame.PlayerMatchStatsComponent", "KillData", Some(1_493_759_848)) => {
            MeasuredArrayRoute::KillData
        }
        (
            "/Script/ShooterGame.EffectManagerComponent",
            "ServerActiveEffects",
            Some(3_301_618_856),
        ) => MeasuredArrayRoute::ServerActiveEffects,
        (
            "/Script/ShooterGame.FiniteSpeedMovementComponent",
            "RequestedIgnoreActors",
            Some(1_063_739_204),
        ) => MeasuredArrayRoute::RequestedIgnoreActors,
        ("/Script/ShooterGame.BlindManagerComponent", "ActiveBlinds", Some(3_853_965_310)) => {
            MeasuredArrayRoute::ActiveBlinds
        }
        _ => return None,
    };
    Some(route)
}

/// A flattened array this module expands.
#[derive(Clone, Copy, PartialEq)]
enum ArrayKind {
    /// `CombatReportComponent.Rounds`: the overlay, then [`decode_array_leaf`].
    Rounds,
    /// `AbilityCastsThisRound`, whose `Effects` array the walker sees only
    /// through [`ABILITY_CASTS_SCHEMA`].
    AbilityCasts,
    /// A checksum-gated route this replay's branch admits.
    Measured(MeasuredArrayRoute),
}

/// The struct-blob fields that have a dedicated decoder in `vrf-decode`.
#[derive(Clone, Copy)]
enum StructBlob {
    RoundResults,
    TeamEconomy,
    RoundInfos,
}

/// One struct-blob element's `(member, value_i64, value_str)` rows.
type BlobMembers = Vec<(&'static str, Option<i64>, Option<String>)>;

impl ExportSink<'_> {
    /// The replay's declared name and checksum for every handle of
    /// `group_path` (empty for an unknown group), borrowed from `cache` alone so
    /// `&mut self.stats` stays free.
    fn declared_handles<'g>(
        cache: &'g NetGuidCache,
        group_path: &str,
    ) -> (Vec<Option<&'g str>>, Vec<Option<u32>>) {
        let Some(group) = cache.get_group_by_path(group_path) else {
            return Default::default();
        };
        group
            .fields
            .iter()
            .map(|slot| match slot {
                Some(field) => (Some(field.name.as_str()), Some(field.compatible_checksum)),
                None => (None, None),
            })
            .unzip()
    }

    /// Which array `parent` is on this group, if any: one classifier for the
    /// schema, the walker and the leaf typing.
    fn array_kind(&self, parent: &str, checksum: Option<u32>) -> Option<ArrayKind> {
        let group = &*self.current_group_path;
        match parent {
            "Rounds" if group.contains("CombatReportComponent") => Some(ArrayKind::Rounds),
            "AbilityCastsThisRound" if group.contains("Comp_AbilityStatisticsReplicator") => {
                Some(ArrayKind::AbilityCasts)
            }
            _ => measured_array_route(group, parent, checksum)
                .filter(|&route| self.admits(route))
                .map(ArrayKind::Measured),
        }
    }

    /// Flatten a known array field and emit one row per leaf, each nested row
    /// after its raw container.
    pub(super) fn emit_flattened_array(
        &mut self,
        field_name: Option<&str>,
        checksum: Option<u32>,
        raw: &[u8],
        bit_count: u32,
    ) {
        let Some(parent) = field_name else {
            return;
        };
        let Some(kind) = self.array_kind(parent, checksum) else {
            return;
        };
        let (names, checksums) = Self::declared_handles(self.cache, &self.current_group_path);
        let route = match kind {
            ArrayKind::Measured(route) => Some(route),
            ArrayKind::Rounds | ArrayKind::AbilityCasts => None,
        };
        let flattened = match route {
            None => {
                let schema = if kind == ArrayKind::Rounds {
                    &COMBAT_ROUNDS_SCHEMA
                } else {
                    &ABILITY_CASTS_SCHEMA
                };
                vrf_decode::decode_struct_array(
                    raw,
                    bit_count,
                    Some(schema),
                    &names,
                    &mut self.stats.array,
                )
            }
            Some(route) => {
                let blinds = route == MeasuredArrayRoute::ActiveBlinds;
                let array_bits = if blinds {
                    active_blind_array_bits(raw, bit_count)
                } else {
                    bit_count
                };
                if array_bits != bit_count {
                    self.stats.active_blinds_empty_trailers += 1;
                }
                if blinds
                    && !strict_nested_array_preflight(
                        raw,
                        array_bits,
                        &rule_handles(LEAF_RULES, route),
                    )
                {
                    self.stats.array.errors += 1;
                    return;
                }
                // The sole measured empty variant: capacity one, the index-zero
                // terminator and an opaque zero byte. A literal, not a relaxation.
                if route == MeasuredArrayRoute::TrackedRewards
                    && bit_count == 24
                    && raw == [2, 0, 0]
                {
                    self.stats.tracked_rewards_opaque_empty_variants += 1;
                    return;
                }
                let mut walk = ArrayDecodeStats::default();
                let flattened =
                    vrf_decode::decode_struct_array_exact(raw, array_bits, &names, &mut walk);
                self.stats.array.merge_from(&walk);
                if !walk.is_clean() {
                    return;
                }
                flattened
            }
        };

        // Every leaf is typed before any row is pushed, by the overlay keyed on
        // the declared name: an ordinary field's resolution order minus the
        // checksum-keyed steps (scoped types, checksum fallback), which type
        // none of the untyped array leaves measured.
        let group_path = &*self.current_group_path;
        let (array, leaf_errors) = (
            &mut self.stats.array,
            &mut self.stats.array_leaf_decode_errors,
        );
        let leaves: Vec<_> = flattened
            .iter()
            .map(|f| {
                let name = declared_at(&names, f.handle);
                let resolved =
                    vrf_decode::resolve_field_type(&TABLE, group_path, name, Some(f.handle));
                let Some(route) = route else {
                    let typed = resolved.filter(|t| !matches!(t, FieldType::Raw | FieldType::Skip));
                    return (typed.map(Leaf::Field), None);
                };
                let checksum = declared_at(&checksums, f.handle);
                let leaf = leaf_rule(
                    LEAF_RULES,
                    route,
                    f.handle,
                    f.bit_count,
                    name,
                    checksum,
                    resolved,
                );
                let nested = if leaf == Some(Leaf::Nested) {
                    decode_nested(route, f, &names, &checksums, group_path, array, leaf_errors)
                } else {
                    None
                };
                (leaf, nested)
            })
            .collect();
        if route == Some(MeasuredArrayRoute::ActiveBlinds)
            && leaves.iter().any(|(leaf, _)| leaf.is_none())
        {
            self.stats.array_leaf_decode_errors += 1;
            return;
        }

        let rows_before = self.stats.fields_emitted;
        for (f, (leaf, nested)) in flattened.iter().zip(leaves) {
            let errors = &mut self.stats.array_leaf_decode_errors;
            let columns = match leaf {
                Some(leaf) => decode_leaf(leaf, &f.raw_bits, f.bit_count, errors),
                // CombatReport-only: handle 3 is Int32 there and an FString in
                // AbilityCastsThisRound.
                None if kind == ArrayKind::Rounds => {
                    decode_array_leaf(f.handle, &f.raw_bits, f.bit_count, errors)
                }
                None => (None, None, None, None),
            };
            // `f.path` carries its own leading separator: "Rounds[0].RoundNumber".
            self.push_child(
                f.handle,
                &[parent, &f.path],
                f.bit_count,
                &f.raw_bits,
                columns,
            );
            for (member, columns) in nested.into_iter().flatten() {
                let (handle, bits) = (member.handle, member.bit_count);
                let name: [&str; 3] = [parent, &f.path, &member.path];
                self.push_child(handle, &name, bits, &member.raw_bits, columns);
            }
        }
        if let Some(route) = route {
            *self.stats.route_children(route) += self.stats.fields_emitted - rows_before;
        }
    }

    /// Push one row decoded out of a parent payload, named by concatenating
    /// `name`. Addressed inside the payload, not by a declared handle, so its
    /// checksum is null.
    pub(super) fn push_child(
        &mut self,
        handle: u32,
        name: &[&str],
        bit_count: u32,
        raw: &[u8],
        (value_i64, value_f64, value_bool, value_str): DecodedColumns,
    ) {
        let field_name = self
            .channel_state
            .names
            .intern_fmt(|out| name.iter().for_each(|part| out.push_str(part)));
        self.push_field(FieldValues {
            handle,
            field_name: Some(field_name),
            compatible_checksum: None,
            bit_count,
            raw_bits: Some(SmallVec::from_slice(raw)),
            value_i64,
            value_f64,
            value_bool,
            value_str,
        });
    }

    /// Which dedicated decoder owns this field on this group, if any. The
    /// group goes through `vrf_decode::canonical_group`, the overlay's own
    /// alias table: Swiftplay carries `RoundResults` and `TeamEconomy` on
    /// `Swiftplay_EoRCredits_GameState_C`, which a bare `BombGameState` test
    /// misses.
    fn struct_blob_kind(&self, field_name: Option<&str>) -> Option<StructBlob> {
        let game_state =
            || vrf_decode::canonical_group(&self.current_group_path).contains("BombGameState");
        match field_name? {
            "RoundResults" if game_state() => Some(StructBlob::RoundResults),
            "TeamEconomy" if game_state() => Some(StructBlob::TeamEconomy),
            "RoundInfos" if self.current_group_path.contains("OwnerExclusivePlayerInfo") => {
                Some(StructBlob::RoundInfos)
            }
            _ => None,
        }
    }

    /// Decode a `MultiItemSlot.MultiContents` blob (`TArray<AAresItem*>`) into
    /// one `MultiContents[index]` row per item, the NetGUID in `value_i64` as
    /// for `ItemSlot.Contents`; the parent stays `Raw`. The wire element index
    /// labels the row: arrays are delta-replicated per element, so a re-send may
    /// carry only the changed slot, which arrival order would put in slot 0.
    pub(super) fn emit_multi_contents(
        &mut self,
        field_name: Option<&str>,
        raw: &[u8],
        bit_count: u32,
    ) {
        if field_name != Some("MultiContents") || !self.current_group_path.contains("MultiItemSlot")
        {
            return;
        }
        let guids =
            vrf_decode::decode_object_ref_array_with_stats(raw, bit_count, &mut self.stats.array);
        for (index, guid) in &guids {
            self.emit_struct_sub_field(
                |out| put(out, format_args!("MultiContents[{index}]")),
                Some(i64::from(*guid)),
                None,
            );
            self.stats.multi_contents_items_emitted += 1;
        }
    }

    /// Decode a struct blob with its dedicated decoder and emit one
    /// `{field}[{index}].{member}` row per member that has a value.
    pub(super) fn decode_struct_blob(
        &mut self,
        field_name: Option<&str>,
        raw: &[u8],
        bit_count: u32,
    ) {
        let (Some(name), Some(kind)) = (field_name, self.struct_blob_kind(field_name)) else {
            return;
        };
        let elements: Option<Vec<(u32, BlobMembers)>> = match kind {
            StructBlob::RoundResults => {
                let decoded = self.decode_blob(raw, bit_count, structs::decode_round_results);
                decoded.map(|rows| {
                    rows.into_iter()
                        .map(|rr| {
                            let role = rr.winning_team_role.map(|r| r.as_str().to_owned());
                            let outcome = rr.round_result.map(|o| o.as_str().to_owned());
                            let members = vec![
                                ("RoundNumber", Some(i64::from(rr.round_number)), None),
                                ("WinningTeam", None, rr.winning_team),
                                ("WinningTeamRole", None, role),
                                ("RoundResult", None, outcome),
                            ];
                            (rr.round_number, members)
                        })
                        .collect()
                })
            }
            StructBlob::TeamEconomy => {
                let decoded =
                    self.decode_blob(raw, bit_count, structs::decode_team_economy_declared);
                decoded.map(|rows| {
                    rows.into_iter()
                        .map(|te| {
                            let members = vec![
                                ("Index", Some(i64::from(te.index)), None),
                                ("ReplicationId", te.replication_id.map(i64::from), None),
                                ("LoadoutValue", te.loadout_value.map(i64::from), None),
                                (
                                    "AverageLoadoutValue",
                                    te.average_loadout_value.map(i64::from),
                                    None,
                                ),
                            ];
                            (te.index, members)
                        })
                        .collect()
                })
            }
            StructBlob::RoundInfos => {
                let decoded = self.decode_blob(raw, bit_count, structs::decode_round_infos);
                decoded.map(|rows| {
                    rows.into_iter()
                        .map(|ri| {
                            let members = [
                                ("RoundNumber", ri.round_number),
                                ("StartOfRoundMoney", ri.start_of_round_money),
                                ("StartOfRoundLoadoutValue", ri.start_of_round_loadout_value),
                                ("EndOfRoundMoney", ri.end_of_round_money),
                                ("EndOfRoundLoadoutValue", ri.end_of_round_loadout_value),
                            ];
                            let members =
                                members.map(|(member, v)| (member, v.map(i64::from), None));
                            (ri.index, Vec::from(members))
                        })
                        .collect()
                })
            }
        };
        let Some(elements) = elements else {
            return;
        };
        if !elements.is_empty() {
            self.stats.struct_blobs_decoded += 1;
        }
        for (index, members) in elements {
            for (member, value_i64, value_str) in members {
                if value_i64.is_some() || value_str.is_some() {
                    self.emit_struct_sub_field(
                        |out| put(out, format_args!("{name}[{index}].{member}")),
                        value_i64,
                        value_str,
                    );
                }
            }
        }
    }

    /// Count a struct-blob failure rather than drop it: it costs no rows (the
    /// decoders are additive), but it must not go unsaid.
    fn record_blob_failure(&mut self, err: &dyn std::fmt::Display) {
        self.stats.struct_blobs_failed += 1;
        if self.stats.struct_blob_first_error.is_none() {
            self.stats.struct_blob_first_error = Some(err.to_string());
        }
    }

    /// Run one struct-blob decoder over the blob's declared bit length and
    /// the group's declared names. Every failure, the reader's included, is
    /// recorded here, so the wording cannot drift between the decoders.
    fn decode_blob<T>(
        &mut self,
        raw: &[u8],
        bit_count: u32,
        decode: impl FnOnce(&mut BitReader<'_>, &[Option<&str>]) -> structs::Result<Vec<T>>,
    ) -> Option<Vec<T>> {
        let Ok(mut reader) = BitReader::with_bit_len(raw, u64::from(bit_count)) else {
            self.record_blob_failure(&"declared bit length exceeds buffer");
            return None;
        };
        // The decoded elements own their strings, so once `decode` returns
        // nothing borrows `self.cache` and a failure can be recorded.
        let (names, _) = Self::declared_handles(self.cache, &self.current_group_path);
        match decode(&mut reader, &names) {
            Ok(results) => Some(results),
            Err(err) => {
                self.record_blob_failure(&err);
                None
            }
        }
    }

    /// Emit one struct-blob member row, its name built by `name` straight into
    /// the interner's scratch buffer (no allocation). Only i64 and str are
    /// parameters: no member decodes to a float or a bool.
    fn emit_struct_sub_field(
        &mut self,
        name: impl FnOnce(&mut String),
        value_i64: Option<i64>,
        value_str: Option<String>,
    ) {
        let field_name = self.channel_state.names.intern_fmt(name);
        self.push_field(FieldValues {
            handle: 0,
            field_name: Some(field_name),
            bit_count: 0,
            raw_bits: None,
            value_i64,
            value_str,
            ..FieldValues::default()
        });
    }
}

/// Decode one array leaf with a type the caller already resolved: the one
/// decode-and-widen every typing path shares.
pub(super) fn decode_leaf_with_stats(
    field_type: FieldType,
    raw: &[u8],
    bit_count: u32,
    failures: &mut u64,
) -> DecodedColumns {
    vrf_decode::decode_field(field_type, raw, bit_count).map_or_else(
        |_| {
            *failures = failures.saturating_add(1);
            DecodedColumns::default()
        },
        vrf_decode::DecodedValue::into_columns,
    )
}

/// A handle -> type map derived from the CombatRoundReports descriptors: the
/// floor for leaves the overlay cannot name (the caller asks it first). All
/// `None` for an unknown handle or a failed decode.
fn decode_array_leaf(
    handle: u32,
    raw: &[u8],
    bit_count: u32,
    failures: &mut u64,
) -> DecodedColumns {
    let field_type = match handle {
        3 | 5 | 19 | 21 | 46 | 81 | 96 => FieldType::Int32,
        18 | 20 | 47 | 82 => FieldType::Float,
        22 | 25 | 48 | 49 | 83 | 84 | 103 => FieldType::Bool,
        23 | 45 | 80 => FieldType::EnumByte,
        13 | 24 | 50 | 85 | 98 => FieldType::ObjectNetGuid,
        11 => FieldType::FString,
        12 => FieldType::FName,
        _ => return (None, None, None, None),
    };

    decode_leaf_with_stats(field_type, raw, bit_count, failures)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vendor::sink::test_fixtures::Rig;
    use crate::vendor::sink::{ExportStats, MeasuredArrayRoutes, RecordBuffers};
    use std::sync::Arc;
    use vrf_export::FieldRecord;
    use vrf_net::field::FieldSink;
    use vrf_testkit::{BitWrite, pack, unpack};

    const OWNER: &str = "/Script/ShooterGame.OwnerExclusivePlayerInfo";
    const OWNER_PARENT: &str = "AllPlayersObfuscatedPlayerInformation";
    const OWNER_CHECKSUM: u32 = 1_349_268_968;
    const REWARDS_PARENT: &str = "TrackedRewards";
    const REWARDS_CHECKSUM: u32 = 976_048_801;
    const SELECTED_GROUP: &str = "/Script/ShooterGame.PersonalizationComponent";
    const SELECTED_PARENT: &str = "SelectedV2";
    const SELECTED_CHECKSUM: u32 = 4_218_721_055;
    const KILL_GROUP: &str = "/Script/ShooterGame.PlayerMatchStatsComponent";
    const KILL_PARENT: &str = "KillData";
    const KILL_CHECKSUM: u32 = 1_493_759_848;
    const MEASURED_BUILD: &str = "++Ares-Core+release-13.05";
    const EFFECTS_GROUP: &str = "/Script/ShooterGame.EffectManagerComponent";
    const IGNORE_GROUP: &str = "/Script/ShooterGame.FiniteSpeedMovementComponent";
    const BLINDS: (&str, &str, u32) = (
        "/Script/ShooterGame.BlindManagerComponent",
        "ActiveBlinds",
        3_853_965_310,
    );
    /// The nine measured ActiveBlinds member declarations.
    const BLIND_MEMBERS: [(u32, &str, u32); 9] = [
        (3, "BlindId", 2_836_858_544),
        (4, "EffectID", 3_321_413_110),
        (5, "SourceID", 4_130_766_059),
        (6, "bLocalEffect", 2_802_682_995),
        (7, "bTransient", 815_378_154),
        (8, "InitialDuration", 1_370_668_337),
        (9, "StartNetMovementTime", 2_358_118_895),
        (10, "BlindConfig", 4_121_438_116),
        (11, "CausingActor", 2_370_661_694),
    ];

    /// A row's four typed columns.
    fn values(row: &FieldRecord) -> (Option<i64>, Option<f64>, Option<bool>, Option<&str>) {
        (
            row.value_i64,
            row.value_f64,
            row.value_bool,
            row.value_str.as_deref(),
        )
    }

    /// `leaf_rule` for a top-level leaf whose width no rule checks.
    fn typed(
        route: MeasuredArrayRoute,
        handle: u32,
        name: &str,
        checksum: u32,
        resolved: Option<FieldType>,
    ) -> Option<Leaf> {
        leaf_rule(
            LEAF_RULES,
            route,
            handle,
            0,
            Some(name),
            Some(checksum),
            resolved,
        )
    }

    fn one_leaf(handle: u32, payload: &[bool]) -> Vec<bool> {
        let mut bits = Vec::new();
        for value in [1, 1, handle + 1, payload.len() as u32] {
            bits.int_packed(value);
        }
        bits.extend_from_slice(payload);
        bits.int_packed(0);
        bits.int_packed(0);
        bits
    }

    fn one_element(fields: &[(u32, Vec<bool>)]) -> Vec<bool> {
        let mut bits = Vec::new();
        bits.int_packed(1);
        bits.int_packed(1);
        for (handle, payload) in fields {
            bits.int_packed(handle + 1);
            bits.int_packed(payload.len() as u32);
            bits.extend_from_slice(payload);
        }
        bits.int_packed(0);
        bits.int_packed(0);
        bits
    }

    /// One ActiveBlinds element with every member at its measured width.
    fn blind_element(effect_id: i64) -> Vec<bool> {
        let mut source_id = vec![false];
        source_id.extend(unpack(&(29i32).to_le_bytes()));
        source_id.extend(unpack(b"DedicatedServerWorldSourceID\0"));
        source_id.extend(unpack(&0i32.to_le_bytes()));
        assert_eq!(source_id.len(), 297);
        let mut blind_config = Vec::new();
        blind_config.int_packed(256);
        let mut causing_actor = Vec::new();
        causing_actor.int_packed(257);
        one_element(&[
            (3, unpack(&7u32.to_le_bytes())),
            (4, unpack(&effect_id.to_le_bytes())),
            (5, source_id),
            (6, vec![true]),
            (7, vec![false]),
            (8, unpack(&1.5f32.to_le_bytes())),
            (9, unpack(&10.0f32.to_le_bytes())),
            (10, blind_config),
            (11, causing_actor),
        ])
    }

    fn kill_weapon_theme_payload(value: &str, utf16: bool) -> Vec<bool> {
        let mut bits = vec![true];
        let (length, body) = if value.is_empty() && !utf16 {
            (0, Vec::new())
        } else if utf16 {
            let units: Vec<u16> = value.encode_utf16().chain([0]).collect();
            let body = units.iter().flat_map(|v| v.to_le_bytes()).collect();
            (-(units.len() as i32), body)
        } else {
            let mut body = value.as_bytes().to_vec();
            body.push(0);
            (body.len() as i32, body)
        };
        bits.extend(unpack(&length.to_le_bytes()));
        bits.extend(unpack(&body));
        bits
    }

    fn export_array(
        identity: (&str, &str, u32),
        leaves: &[(u32, &str, u32)],
        bits: &[bool],
        branch: Option<&str>,
    ) -> (RecordBuffers, ExportStats) {
        let (group, parent, checksum) = identity;
        let mut rig = Rig::default();
        rig.cache
            .add_export_group(vrf_schema::NetFieldExportGroup::new(group.into(), 7, 128))
            .unwrap();
        for (handle, name, compatible_checksum) in
            std::iter::once((0, parent, checksum)).chain(leaves.iter().copied())
        {
            assert!(rig.cache.set_field_on_group(
                7,
                vrf_schema::NetFieldExport {
                    handle,
                    compatible_checksum,
                    name: name.into(),
                }
            ));
        }
        let mut sink = rig.sink();
        sink.set_current_group_path(Arc::from(group));
        if let Some(branch) = branch {
            sink.enable_measured_array_routes(branch);
        }
        let raw = pack(bits);
        sink.on_field(
            0,
            bits.len() as u32,
            BitReader::with_bit_len(&raw, bits.len() as u64).unwrap(),
        );
        let stats = sink.stats;
        (rig.records, stats)
    }

    #[test]
    fn measured_array_emits_typed_child_before_exact_raw_parent() {
        let bits = one_leaf(49, &[true]);
        let (records, stats) = export_array(
            (OWNER, OWNER_PARENT, OWNER_CHECKSUM),
            &[(49, "bIsAfk", 0)],
            &bits,
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 2);
        let child = &records.fields[0];
        assert_eq!(
            child.field_name.as_deref(),
            Some("AllPlayersObfuscatedPlayerInformation[0].bIsAfk")
        );
        assert_eq!(child.value_bool, Some(true));
        assert_eq!(child.raw_bits.as_deref(), Some([1u8].as_slice()));
        assert_eq!(child.bit_count, 1);
        assert_eq!(child.compatible_checksum, None);
        let parent = &records.fields[1];
        assert_eq!(parent.field_name.as_deref(), Some(OWNER_PARENT));
        assert_eq!(parent.raw_bits.as_deref(), Some(pack(&bits).as_slice()));
        assert_eq!(parent.bit_count, bits.len() as u32);
        assert_eq!(stats.array.fields_emitted, 1);
        assert_eq!(stats.fields_emitted, 2);
    }

    #[test]
    fn tracked_rewards_types_only_the_four_verified_leaf_identities() {
        let fname_zero = vec![true, false, false, false, false, false, false, false, false];
        for (handle, name, checksum, payload, want_i64, want_str) in [
            (28, "RewardName", 1_337_472_711, fname_zero, None, Some("0")),
            (
                30,
                "InstancesOfReward",
                2_922_243_316,
                vec![false; 32],
                Some(0),
                None,
            ),
            (
                31,
                "RewardGrantStrategy",
                3_589_631_714,
                vec![false; 2],
                Some(0),
                None,
            ),
            (
                32,
                "Source",
                1_118_571_008,
                vec![true, true, false],
                Some(3),
                None,
            ),
        ] {
            let bits = one_leaf(handle, &payload);
            let (records, _) = export_array(
                (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM),
                &[(handle, name, checksum)],
                &bits,
                Some(MEASURED_BUILD),
            );
            let child = &records.fields[0];
            assert_eq!(child.value_i64, want_i64, "{name}");
            assert_eq!(child.value_str.as_deref(), want_str, "{name}");
            assert_eq!(child.raw_bits.as_deref(), Some(pack(&payload).as_slice()));
        }
    }

    #[test]
    fn tracked_rewards_refuses_wrong_child_identity_or_resolved_type() {
        let bits = one_leaf(30, &[false; 32]);
        for (name, checksum) in [("OtherName", 2_922_243_316), ("InstancesOfReward", 0)] {
            let (records, _) = export_array(
                (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM),
                &[(30, name, checksum)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields[0].value_i64, None, "{name}/{checksum}");
        }
        assert_eq!(
            typed(
                MeasuredArrayRoute::TrackedRewards,
                30,
                "InstancesOfReward",
                2_922_243_316,
                Some(FieldType::Float),
            ),
            None
        );
    }

    #[test]
    fn tracked_rewards_localized_text_requires_its_raw_declaration() {
        let rewards = MeasuredArrayRoute::TrackedRewards;
        assert_eq!(
            typed(
                rewards,
                29,
                "LocalizedRewardName",
                483_770_233,
                Some(FieldType::Raw)
            ),
            Some(Leaf::Field(FieldType::FTextTree))
        );
        for (handle, name, checksum, resolved) in [
            (29, "Other", 483_770_233, FieldType::Raw),
            (29, "LocalizedRewardName", 0, FieldType::Raw),
            (29, "LocalizedRewardName", 483_770_233, FieldType::Skip),
            (29, "LocalizedRewardName", 483_770_233, FieldType::FText),
            (28, "LocalizedRewardName", 483_770_233, FieldType::Raw),
        ] {
            assert_eq!(typed(rewards, handle, name, checksum, Some(resolved)), None);
        }
    }

    #[test]
    fn tracked_rewards_bad_typed_width_keeps_raw_leaf_and_counts_error() {
        let bits = one_leaf(30, &[false; 8]);
        let (records, stats) = export_array(
            (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM),
            &[(30, "InstancesOfReward", 2_922_243_316)],
            &bits,
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 2);
        assert_eq!(records.fields[0].raw_bits.as_deref(), Some([0].as_slice()));
        assert_eq!(records.fields[0].value_i64, None);
        assert_eq!(stats.array_leaf_decode_errors, 1);
    }

    #[test]
    fn localized_reward_text_keeps_raw_on_success_and_failure() {
        let empty = unpack(&[0, 0, 0, 0, 255, 0, 0, 0, 0]);
        for (payload, errors, expected) in [
            (
                empty.clone(),
                0,
                Some(r#"{"flags":0,"history":255,"kind":"empty"}"#),
            ),
            (empty[..empty.len() - 1].to_vec(), 1, None),
        ] {
            let bits = one_leaf(29, &payload);
            let (records, stats) = export_array(
                (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM),
                &[(29, "LocalizedRewardName", 483_770_233)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields.len(), 2);
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(&payload).as_slice())
            );
            assert_eq!(values(&records.fields[0]), (None, None, None, expected));
            assert_eq!(stats.array_leaf_decode_errors, errors);
            assert_eq!(
                records.fields[1].raw_bits.as_deref(),
                Some(pack(&bits).as_slice())
            );
        }
    }

    #[test]
    fn selected_v2_types_only_the_six_qualified_object_net_guid_leaves() {
        let mut multi_byte = Vec::new();
        multi_byte.int_packed(128);
        let (records, _) = export_array(
            (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
            &[(3, "EquippableDataAsset", 1_793_937_854)],
            &one_leaf(3, &multi_byte),
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields[0].value_i64, Some(128));
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some([1, 2].as_slice())
        );

        let zero = vec![false; 8];
        let (records, _) = export_array(
            (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
            &[(8, "EquippableCharmLevelDataAsset", 1_087_985_310)],
            &one_leaf(8, &zero),
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields[0].value_i64, Some(0));

        for (name, checksum) in [("Other", 1_793_937_854), ("EquippableDataAsset", 0)] {
            let (records, _) = export_array(
                (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
                &[(3, name, checksum)],
                &one_leaf(3, &multi_byte),
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields[0].value_i64, None, "{name}/{checksum}");
        }
        for (handle, name, checksum) in [
            (9, "A", 3_055_317_389),
            (13, "EquippableAttachments", 3_137_596_882),
            (14, "SocketAsset", 3_666_994_016),
            (15, "AttachmentAsset", 856_446_005),
        ] {
            let (records, _) = export_array(
                (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
                &[(handle, name, checksum)],
                &one_leaf(handle, &multi_byte),
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields[0].value_i64, None, "{name} remains raw");
        }
        // A contradictory overlay, or an explicit Raw/Skip (not an absent
        // overlay), leaves the leaf raw.
        for blocked in [FieldType::Float, FieldType::Raw, FieldType::Skip] {
            assert_eq!(
                typed(
                    MeasuredArrayRoute::SelectedV2,
                    3,
                    "EquippableDataAsset",
                    1_793_937_854,
                    Some(blocked),
                ),
                None,
                "{blocked:?}"
            );
        }
    }

    #[test]
    fn selected_v2_bad_object_net_guid_windows_stay_raw_and_count_errors() {
        for payload in [unpack(&[1]), unpack(&[1, 1, 1, 1, 0x20])] {
            let (records, stats) = export_array(
                (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
                &[(3, "EquippableDataAsset", 1_793_937_854)],
                &one_leaf(3, &payload),
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields[0].value_i64, None);
            assert_eq!(stats.array_leaf_decode_errors, 1);
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(&payload).as_slice())
            );
        }
    }

    #[test]
    fn kill_data_types_only_qualified_primitive_leaves() {
        let mut object = Vec::new();
        object.int_packed(128);
        let float = unpack(&(-1.5f32).to_le_bytes());
        let int = unpack(&(-2i32).to_le_bytes());
        for (handle, name, checksum, payload, vi, vf, vb) in [
            (
                3,
                "Victim",
                3_990_035_472,
                object.clone(),
                Some(128),
                None,
                None,
            ),
            (
                4,
                "KillingEquippableClass",
                2_071_131_011,
                vec![false; 8],
                Some(0),
                None,
                None,
            ),
            (
                9,
                "DamageType",
                2_992_423_760,
                object.clone(),
                Some(128),
                None,
                None,
            ),
            (
                10,
                "DamageTaken",
                2_001_471_495,
                float.clone(),
                None,
                Some(-1.5),
                None,
            ),
            (
                11,
                "DamageRegion",
                3_229_265_809,
                vec![true, false, true],
                Some(5),
                None,
                None,
            ),
            (
                12,
                "GameTimeElapsed",
                3_684_431_363,
                float.clone(),
                None,
                Some(-1.5),
                None,
            ),
            (
                13,
                "RoundTimestamp",
                2_328_473_242,
                float,
                None,
                Some(-1.5),
                None,
            ),
            (14, "RoundNumber", 843_024_485, int, Some(-2), None, None),
            (
                15,
                "bDidKillTriggerFinisher",
                2_795_684_046,
                vec![false],
                None,
                None,
                Some(false),
            ),
        ] {
            let (records, _) = export_array(
                (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
                &[(handle, name, checksum)],
                &one_leaf(handle, &payload),
                Some(MEASURED_BUILD),
            );
            let child = &records.fields[0];
            assert_eq!(child.value_i64, vi, "{name}");
            assert_eq!(child.value_f64, vf, "{name}");
            assert_eq!(child.value_bool, vb, "{name}");
            assert_eq!(child.raw_bits.as_deref(), Some(pack(&payload).as_slice()));
        }
    }

    #[test]
    fn kill_data_weapon_theme_decodes_exact_prefixed_fstrings() {
        for (value, utf16) in [
            ("/Game/Themes/Standard", false),
            ("\u{d14c}\u{b9c8}", true),
            ("", false),
        ] {
            let payload = kill_weapon_theme_payload(value, utf16);
            let (records, stats) = export_array(
                (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
                &[(5, "WeaponTheme", 1_839_952_321)],
                &one_leaf(5, &payload),
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields[0].value_str.as_deref(), Some(value));
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(&payload).as_slice())
            );
            assert_eq!(stats.array_leaf_decode_errors, 0);
        }
    }

    #[test]
    fn kill_data_weapon_theme_rejects_bad_flag_terminator_and_residual() {
        let mut bad_flag = kill_weapon_theme_payload("x", false);
        bad_flag[0] = false;
        let mut bad_terminator = kill_weapon_theme_payload("x", false);
        // Use a valid UTF-8 byte so rejection cannot come from UTF decoding.
        let last = bad_terminator.len() - 8;
        bad_terminator[last] = true;
        let mut bad_wide_terminator = kill_weapon_theme_payload("x", true);
        let last_wide = bad_wide_terminator.len() - 16;
        bad_wide_terminator[last_wide] = true;
        let mut residual = kill_weapon_theme_payload("x", false);
        residual.push(false);
        let mut invalid_utf8 = vec![true];
        invalid_utf8.extend(unpack(&2i32.to_le_bytes()));
        invalid_utf8.extend(unpack(&[0xff, 0]));
        for payload in [
            bad_flag,
            bad_terminator,
            bad_wide_terminator,
            residual,
            invalid_utf8,
        ] {
            let (records, stats) = export_array(
                (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
                &[(5, "WeaponTheme", 1_839_952_321)],
                &one_leaf(5, &payload),
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields[0].value_str, None);
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(&payload).as_slice())
            );
            assert_eq!(stats.array_leaf_decode_errors, 1);
        }
    }

    #[test]
    fn kill_data_refuses_wrong_child_identity_and_any_overlay_disagreement() {
        let kill = MeasuredArrayRoute::KillData;
        assert!(typed(kill, 10, "DamageTaken", 2_001_471_495, None).is_some());
        for (name, checksum) in [("Other", 2_001_471_495), ("DamageTaken", 0)] {
            assert!(typed(kill, 10, name, checksum, None).is_none());
            let payload = unpack(&1.5f32.to_le_bytes());
            let (records, _) = export_array(
                (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
                &[(10, name, checksum)],
                &one_leaf(10, &payload),
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields[0].value_f64, None);
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(&payload).as_slice())
            );
        }
        let payload = kill_weapon_theme_payload("theme", false);
        let (records, _) = export_array(
            (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
            &[(5, "Other", 1_839_952_321)],
            &one_leaf(5, &payload),
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields[0].value_str, None);
        for blocked in [FieldType::Int32, FieldType::Raw, FieldType::Skip] {
            assert!(typed(kill, 10, "DamageTaken", 2_001_471_495, Some(blocked)).is_none());
        }
        let theme = Some(FieldType::FString);
        assert!(typed(kill, 5, "WeaponTheme", 1_839_952_321, theme).is_none());
    }

    #[test]
    fn measured_nested_arrays_emit_after_their_preserved_raw_containers() {
        let mut first = Vec::new();
        first.int_packed(128);
        let mut second = Vec::new();
        second.int_packed(9);
        let selected_nested = one_element(&[(14, first.clone()), (15, second.clone())]);
        let (records, stats) = export_array(
            (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
            &[
                (13, "EquippableAttachments", 3_137_596_882),
                (14, "SocketAsset", 3_666_994_016),
                (15, "AttachmentAsset", 856_446_005),
            ],
            &one_leaf(13, &selected_nested),
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 4);
        assert_eq!(
            records.fields[0].field_name.as_deref(),
            Some("SelectedV2[0].EquippableAttachments")
        );
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some(pack(&selected_nested).as_slice())
        );
        assert_eq!(
            records.fields[1].field_name.as_deref(),
            Some("SelectedV2[0].EquippableAttachments[0].SocketAsset")
        );
        assert_eq!(records.fields[1].value_i64, Some(128));
        assert_eq!(
            records.fields[1].raw_bits.as_deref(),
            Some(pack(&first).as_slice())
        );
        assert_eq!(
            records.fields[2].field_name.as_deref(),
            Some("SelectedV2[0].EquippableAttachments[0].AttachmentAsset")
        );
        assert_eq!(records.fields[2].value_i64, Some(9));
        assert_eq!(
            records.fields[3].field_name.as_deref(),
            Some(SELECTED_PARENT)
        );
        assert_eq!(stats.array.fields_emitted, 3);

        let kill_nested = one_element(&[(7, first.clone())]);
        let (records, stats) = export_array(
            (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
            &[
                (6, "AssistingPlayers", 1_689_463_717),
                (7, "AssistingPlayers", 1_417_448_159),
            ],
            &one_leaf(6, &kill_nested),
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 3);
        assert_eq!(
            records.fields[0].field_name.as_deref(),
            Some("KillData[0].AssistingPlayers")
        );
        assert_eq!(
            records.fields[1].field_name.as_deref(),
            Some("KillData[0].AssistingPlayers[0].AssistingPlayers")
        );
        assert_eq!(records.fields[1].value_i64, Some(128));
        assert_eq!(records.fields[2].field_name.as_deref(), Some(KILL_PARENT));
        assert_eq!(stats.array.fields_emitted, 2);
    }

    #[test]
    fn nested_array_preflight_requires_bounds_nonzero_windows_and_terminators() {
        let valid = one_element(&[(7, unpack(&[2]))]);
        assert!(strict_nested_array_preflight(
            &pack(&valid),
            valid.len() as u32,
            &[7]
        ));
        assert!(!strict_nested_array_preflight(&[], 0, &[7]));
        assert!(!strict_nested_array_preflight(
            &pack(&valid[..valid.len() - 8]),
            (valid.len() - 8) as u32,
            &[7]
        ));
        let mut suffix = valid.clone();
        suffix.extend([false; 8]);
        assert!(!strict_nested_array_preflight(
            &pack(&suffix),
            suffix.len() as u32,
            &[7]
        ));
        let zero_width = one_element(&[(7, Vec::new())]);
        assert!(!strict_nested_array_preflight(
            &pack(&zero_width),
            zero_width.len() as u32,
            &[7]
        ));
        let unexpected = one_element(&[(8, unpack(&[2]))]);
        assert!(!strict_nested_array_preflight(
            &pack(&unexpected),
            unexpected.len() as u32,
            &[7]
        ));
        // The generic array walker skips zero-width members. The projectile
        // route must reject one even when all three expected members follow.
        let path_with_unknown_zero = one_element(&[
            (4, Vec::new()),
            (1, unpack(&[0; 4])),
            (2, unpack(&[0; 24])),
            (3, unpack(&[0; 24])),
        ]);
        assert!(!strict_nested_array_preflight(
            &pack(&path_with_unknown_zero),
            path_with_unknown_zero.len() as u32,
            &[1, 2, 3]
        ));
        let mut capacity_limit = Vec::new();
        capacity_limit.int_packed(vrf_decode::MAX_ELEMENTS + 1);
        capacity_limit.int_packed(0);
        assert!(!strict_nested_array_preflight(
            &pack(&capacity_limit),
            capacity_limit.len() as u32,
            &[7]
        ));
        let mut index_range = Vec::new();
        index_range.int_packed(1);
        index_range.int_packed(2);
        assert!(!strict_nested_array_preflight(
            &pack(&index_range),
            index_range.len() as u32,
            &[7]
        ));
        let fields = (0..=vrf_decode::MAX_FIELDS_PER_ELEMENT)
            .map(|_| (7, unpack(&[0])))
            .collect::<Vec<_>>();
        let field_limit = one_element(&fields);
        assert!(!strict_nested_array_preflight(
            &pack(&field_limit),
            field_limit.len() as u32,
            &[7]
        ));
    }

    #[test]
    fn active_blinds_empty_delta_with_zero_trailer_is_complete() {
        let identity = BLINDS;
        // Captured 57 times across 13.01/13.02/13.04/13.05: capacity
        // one (56 cases) or two (one case), no changed elements, zero trailer.
        for capacity in [1, 2] {
            let mut bits = Vec::new();
            bits.int_packed(capacity);
            bits.int_packed(0);
            let (_, control) = export_array(identity, &[], &bits, Some(MEASURED_BUILD));
            assert_eq!(control.array.errors, 0);
            assert_eq!(
                control.active_blinds_empty_trailers, 0,
                "no trailer to spare"
            );
            bits.int_packed(0);
            let (records, stats) = export_array(identity, &[], &bits, Some(MEASURED_BUILD));
            assert_eq!(stats.array.errors, 0, "capacity {capacity}");
            assert_eq!(
                stats.active_blinds_empty_trailers, 1,
                "the tolerance must be seen firing"
            );
            assert_eq!(stats.array.unconsumed_root_bits, 0);
            assert_eq!(stats.array_leaf_decode_errors, 0);
            assert_eq!(
                records.fields.len(),
                1,
                "unchanged elements add no children"
            );
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(&bits).as_slice())
            );
        }
    }

    #[test]
    fn active_blinds_null_causing_actor_is_a_decoded_reference() {
        let identity = BLINDS;
        // The 59 rejected value windows contain a one-byte IntPacked zero.
        // Keep the positive reference as a control through the same sink.
        for reference in [257, 0] {
            let mut payload = Vec::new();
            payload.int_packed(reference);
            let bits = one_leaf(11, &payload);
            let (records, stats) = export_array(
                identity,
                &[(11, "CausingActor", 2_370_661_694)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(stats.array.errors, 0);
            assert_eq!(stats.array_leaf_decode_errors, 0, "reference {reference}");
            assert_eq!(records.fields.len(), 2);
            assert_eq!(records.fields[0].value_i64, Some(i64::from(reference)));
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(&payload).as_slice())
            );
            assert_eq!(
                records.fields[1].raw_bits.as_deref(),
                Some(pack(&bits).as_slice())
            );
        }
    }

    #[test]
    fn active_blinds_invalid_trailers_and_references_still_fail() {
        let identity = BLINDS;
        // An empty delta with a two-byte zero trailer; the nonzero one-byte
        // trailers are `active_blinds_empty_delta_rejects_every_nonzero_trailer_byte`.
        let bits = unpack(&[2, 0, 0, 0]);
        let (records, stats) = export_array(identity, &[], &bits, Some(MEASURED_BUILD));
        assert_eq!(stats.array.errors, 1);
        assert_eq!(stats.active_blinds_empty_trailers, 0, "refused, not spared");
        assert_eq!(records.fields.len(), 1);
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some(pack(&bits).as_slice())
        );
        for payload in [unpack(&[1]), unpack(&[0, 0]), vec![false; 7]] {
            let bits = one_leaf(11, &payload);
            let (records, stats) = export_array(
                identity,
                &[(11, "CausingActor", 2_370_661_694)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(stats.array_leaf_decode_errors, 1);
            assert!(records.fields.iter().all(|row| row.value_i64.is_none()));
            assert_eq!(
                records.fields.last().unwrap().raw_bits.as_deref(),
                Some(pack(&bits).as_slice())
            );
        }
        let mut populated = one_leaf(11, &unpack(&[0]));
        populated.int_packed(0);
        let (_, stats) = export_array(
            identity,
            &[(11, "CausingActor", 2_370_661_694)],
            &populated,
            Some(MEASURED_BUILD),
        );
        assert_eq!(
            stats.array.errors, 1,
            "only empty deltas admit the zero trailer"
        );
        assert_eq!(stats.active_blinds_empty_trailers, 0);
        assert!(
            !strict_nested_array_preflight(&[2, 0, 0], 24, &[11]),
            "other array routes retain the exact-window contract"
        );
    }

    #[test]
    fn active_blinds_every_truncated_null_update_retains_only_raw_parent() {
        let identity = BLINDS;
        let bits = one_leaf(11, &unpack(&[0]));
        for length in 1..bits.len() {
            let truncated = &bits[..length];
            let (records, stats) = export_array(
                identity,
                &[(11, "CausingActor", 2_370_661_694)],
                truncated,
                Some(MEASURED_BUILD),
            );
            assert_eq!(stats.array.errors, 1, "cut at {length}");
            assert_eq!(records.fields.len(), 1, "cut at {length}");
            assert_eq!(records.fields[0].bit_count, length as u32);
            assert_eq!(
                records.fields[0].raw_bits.as_deref(),
                Some(pack(truncated).as_slice())
            );
        }
    }

    #[test]
    fn active_blinds_empty_delta_rejects_every_nonzero_trailer_byte() {
        for trailer in 1..=255u8 {
            let bits = unpack(&[2, 0, trailer]);
            let (records, stats) = export_array(BLINDS, &[], &bits, Some(MEASURED_BUILD));
            assert_eq!(stats.array.errors, 1, "trailer {trailer}");
            assert_eq!(stats.active_blinds_empty_trailers, 0, "trailer {trailer}");
            assert_eq!(records.fields.len(), 1);
        }
    }

    #[test]
    fn active_blinds_sparse_updates_keep_indices_and_packed_reference_boundaries() {
        let identity = BLINDS;
        for reference in [0, 1, 127, 128, 16_383, 16_384, 2_097_151] {
            let mut bits = Vec::new();
            bits.int_packed(3);
            for index in [0, 2] {
                bits.int_packed(index + 1);
                bits.int_packed(12);
                let mut payload = Vec::new();
                payload.int_packed(reference);
                bits.int_packed(payload.len() as u32);
                bits.extend(payload);
                bits.int_packed(0);
            }
            bits.int_packed(0);
            let (records, stats) = export_array(
                identity,
                &[(11, "CausingActor", 2_370_661_694)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(stats.array.errors + stats.array_leaf_decode_errors, 0);
            assert_eq!(records.fields.len(), 3);
            for (row, index) in records.fields[..2].iter().zip([0, 2]) {
                assert_eq!(
                    row.field_name.as_deref(),
                    Some(format!("ActiveBlinds[{index}].CausingActor").as_str())
                );
                assert_eq!(row.value_i64, Some(i64::from(reference)));
            }
            assert_eq!(
                records.fields[2].raw_bits.as_deref(),
                Some(pack(&bits).as_slice())
            );
        }
    }

    #[test]
    fn active_blinds_changed_member_declaration_retains_only_raw_parent() {
        let bits = blind_element(8);
        let (valid, clean) = export_array(BLINDS, &BLIND_MEMBERS, &bits, Some(MEASURED_BUILD));
        assert_eq!(valid.fields.len(), 10);
        assert_eq!(clean.array_leaf_decode_errors, 0);
        assert_eq!(valid.fields[0].value_i64, Some(7));
        assert_eq!(valid.fields[8].value_i64, Some(257));

        let mut changed = BLIND_MEMBERS;
        changed[0].2 += 1;
        let (refused, stats) = export_array(BLINDS, &changed, &bits, Some(MEASURED_BUILD));
        assert_eq!(refused.fields.len(), 1);
        assert_eq!(refused.fields[0].field_name.as_deref(), Some(BLINDS.1));
        assert_eq!(
            refused.fields[0].raw_bits.as_deref(),
            Some(pack(&bits).as_slice())
        );
        assert_eq!(stats.array_leaf_decode_errors, 1);
    }

    /// `EffectID` is an `int64` (see `LEAF_RULES`): bit 63 set is a
    /// negative ID, not an overflow a `UInt64` read would refuse.
    #[test]
    fn active_blinds_effect_id_is_signed() {
        let (valid, stats) = export_array(
            BLINDS,
            &BLIND_MEMBERS,
            &blind_element(-2),
            Some(MEASURED_BUILD),
        );
        assert_eq!(stats.array_leaf_decode_errors, 0);
        let effect_id = valid
            .fields
            .iter()
            .find(|f| f.field_name.as_deref() == Some("ActiveBlinds[0].EffectID"))
            .expect("the EffectID leaf is emitted");
        assert_eq!(effect_id.value_i64, Some(-2));
        assert_eq!(effect_id.bit_count, 64);
    }

    #[test]
    fn nested_array_identity_and_overlay_disagreements_are_refused() {
        let kill = MeasuredArrayRoute::KillData;
        let container = |name, checksum, resolved| typed(kill, 6, name, checksum, resolved);
        assert_eq!(
            container("AssistingPlayers", 1_689_463_717, None),
            Some(Leaf::Nested)
        );
        assert_eq!(container("Other", 1_689_463_717, None), None);
        assert_eq!(container("AssistingPlayers", 0, None), None);
        for blocked in [FieldType::ObjectNetGuid, FieldType::Raw, FieldType::Skip] {
            assert_eq!(
                container("AssistingPlayers", 1_689_463_717, Some(blocked)),
                None
            );
        }
        for blocked in [FieldType::Float, FieldType::Raw, FieldType::Skip] {
            let member = leaf_rule(
                NESTED_RULES,
                MeasuredArrayRoute::SelectedV2,
                14,
                0,
                Some("SocketAsset"),
                Some(3_666_994_016),
                Some(blocked),
            );
            assert_eq!(member, None, "{blocked:?}");
        }
    }

    #[test]
    fn malformed_nested_value_is_transactional_and_keeps_outer_raw() {
        let malformed = one_element(&[(7, unpack(&[2])), (7, unpack(&[1]))]);
        let (records, stats) = export_array(
            (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
            &[
                (6, "AssistingPlayers", 1_689_463_717),
                (7, "AssistingPlayers", 1_417_448_159),
            ],
            &one_leaf(6, &malformed),
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 2);
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some(pack(&malformed).as_slice())
        );
        assert_eq!(records.fields[1].field_name.as_deref(), Some(KILL_PARENT));
        assert_eq!(stats.array_leaf_decode_errors, 1);
        assert_eq!(
            stats.array.fields_emitted, 3,
            "walker count includes attempted leaves, while no row prefix leaks"
        );

        let valid = one_element(&[(14, unpack(&[2])), (15, unpack(&[4]))]);
        let (records, stats) = export_array(
            (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
            &[
                (13, "EquippableAttachments", 3_137_596_882),
                (14, "SocketAsset", 3_666_994_016),
                (15, "AttachmentAsset", 0),
            ],
            &one_leaf(13, &valid),
            Some(MEASURED_BUILD),
        );
        assert_eq!(
            records.fields.len(),
            2,
            "wrong nested checksum emits no prefix"
        );
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some(pack(&valid).as_slice())
        );
        assert_eq!(stats.array_leaf_decode_errors, 1);
    }

    /// Only on its measured group, parent, checksum and branch; anywhere else
    /// the literal is an ordinary raw field.
    #[test]
    fn tracked_rewards_literal_opaque_empty_variant_keeps_only_parent_raw() {
        let bits = unpack(&[0x02, 0x00, 0x00]);
        let (o, p, c) = (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM);
        let b = Some(MEASURED_BUILD);
        for (identity, branch) in [
            ((o, p, c + 1), b),
            (("/Script/ShooterGame.Other", p, c), b),
            ((o, "OtherRewards", c), b),
            ((o, p, c), None),
        ] {
            let (records, stats) = export_array(identity, &[(49, "Rewards", 0)], &bits, branch);
            let at = format!("{identity:?} {branch:?}");
            assert_eq!(records.fields.len(), 1, "{at}");
            assert_eq!(stats.tracked_rewards_opaque_empty_variants, 0, "{at}");
        }
        let (records, stats) = export_array((o, p, c), &[(49, "Rewards", 0)], &bits, b);
        assert_eq!(records.fields.len(), 1);
        assert_eq!(records.fields[0].field_name.as_deref(), Some(p));
        assert_eq!(
            records.fields[0].raw_bits.as_deref(),
            Some([2, 0, 0].as_slice())
        );
        assert_eq!(stats.tracked_rewards_opaque_empty_variants, 1);
        assert_eq!(stats.array.fields_emitted, 0);
    }

    /// A different trailing byte, a nonempty extension, or no zero index
    /// terminator: none becomes an accepted optional trailer, and each keeps
    /// the exact decoder's diagnostic.
    #[test]
    fn tracked_rewards_residual_variants_keep_exact_diagnostics() {
        for bits in [
            unpack(&[0x02, 0x00, 0x01]),
            unpack(&[0x02, 0x00, 0x00, 0x00]),
            unpack(&[0x02]),
        ] {
            let (records, stats) = export_array(
                (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM),
                &[(49, "Rewards", 0)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields.len(), 1);
            assert_eq!(stats.tracked_rewards_opaque_empty_variants, 0);
            assert_eq!(stats.array.fields_emitted, 0);
            assert!(
                stats.array.unconsumed_root_bits > 0
                    || stats.array.errors > 0
                    || stats.array.implicit_terminations > 0,
                "residual window lost its exact-decoder diagnostic: {stats:?}"
            );
        }
        // A complete nonempty array followed by a zero byte is not the measured
        // empty variant. Walking a child does not authorize emitting it when
        // the enclosing array retains unexplained bits.
        let mut bits = one_leaf(19, &[false; 32]);
        bits.extend(unpack(&[0]));
        let (records, stats) = export_array(
            (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM),
            &[(19, "Rewards", 0)],
            &bits,
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 1);
        assert_eq!(stats.tracked_rewards_opaque_empty_variants, 0);
        assert_eq!(stats.array.fields_emitted, 1);
        assert_eq!(stats.array.unconsumed_root_bits, 8);
    }

    #[test]
    fn measured_effect_and_ignore_routes_emit_expected_leaf_values() {
        let payload: Vec<bool> = (0..32)
            .map(|bit| (-0.0f32).to_bits() & (1 << bit) != 0)
            .collect();
        let bits = one_leaf(33, &payload);
        let (records, _) = export_array(
            (EFFECTS_GROUP, "ServerActiveEffects", 3_301_618_856),
            &[(33, "StartTimeStamp", 0)],
            &bits,
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 2);
        assert_eq!(
            records.fields[0].value_f64.unwrap().to_bits(),
            (-0.0f64).to_bits()
        );

        let mut payload = Vec::new();
        payload.int_packed(700);
        let bits = one_leaf(5, &payload);
        let (records, _) = export_array(
            (IGNORE_GROUP, "RequestedIgnoreActors", 1_063_739_204),
            &[(5, "RequestedIgnoreActors", 3_344_674_359)],
            &bits,
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 2);
        let child = &records.fields[0];
        assert_eq!(child.raw_bits.as_deref(), Some(pack(&payload).as_slice()));
        assert_eq!(values(child), (Some(700), None, None, None));
    }

    #[test]
    fn existing_ability_array_keeps_its_float_type_without_measured_route() {
        let payload: Vec<bool> = (0..32)
            .map(|bit| 12.5f32.to_bits() & (1 << bit) != 0)
            .collect();
        let bits = one_leaf(7, &payload);
        let (records, _) = export_array(
            (
                "/Game/Characters/_Core/Comp_AbilityStatisticsReplicator.Comp_AbilityStatisticsReplicator_C",
                "AbilityCastsThisRound",
                0,
            ),
            &[(7, "CastTime_4_5AE288704801A9B74D6D159DFC2BD147", 0)],
            &bits,
            None,
        );
        assert_eq!(records.fields.len(), 2);
        assert_eq!(records.fields[0].value_f64, Some(12.5));
        assert_eq!(
            records.fields[0].field_name.as_deref(),
            Some("AbilityCastsThisRound[0].CastTime_4_5AE288704801A9B74D6D159DFC2BD147")
        );
        // Elsewhere its handles mean something else: one raw row.
        let (records, _) = export_array(
            (
                "/Script/ShooterGame.SomeOtherComponent",
                "AbilityCastsThisRound",
                0,
            ),
            &[(7, "CastTime_4_5AE288704801A9B74D6D159DFC2BD147", 0)],
            &bits,
            None,
        );
        assert_eq!(records.fields.len(), 1);
    }

    /// A route's identity, child declaration and a one-leaf array it types.
    type Case = (
        (&'static str, &'static str, u32),
        (u32, &'static str, u32),
        Vec<bool>,
    );

    /// One typed case per flattened route. No wildcard: a new route does not
    /// compile until it has one.
    fn case_for(route: MeasuredArrayRoute) -> Option<Case> {
        let mut reference = Vec::new();
        reference.int_packed(5);
        let case = match route {
            MeasuredArrayRoute::KillData => (
                (KILL_GROUP, KILL_PARENT, KILL_CHECKSUM),
                (3, "Victim", 3_990_035_472),
                one_leaf(3, &reference),
            ),
            MeasuredArrayRoute::SelectedV2 => (
                (SELECTED_GROUP, SELECTED_PARENT, SELECTED_CHECKSUM),
                (3, "EquippableDataAsset", 1_793_937_854),
                one_leaf(3, &reference),
            ),
            MeasuredArrayRoute::TrackedRewards => (
                (OWNER, REWARDS_PARENT, REWARDS_CHECKSUM),
                (30, "InstancesOfReward", 2_922_243_316),
                one_leaf(30, &[false; 32]),
            ),
            MeasuredArrayRoute::ActiveBlinds => (
                BLINDS,
                (11, "CausingActor", 2_370_661_694),
                one_leaf(11, &unpack(&[0])),
            ),
            MeasuredArrayRoute::ServerActiveEffects => (
                (EFFECTS_GROUP, "ServerActiveEffects", 3_301_618_856),
                (33, "StartTimeStamp", 0),
                one_leaf(33, &unpack(&1.5f32.to_le_bytes())),
            ),
            MeasuredArrayRoute::RequestedIgnoreActors => (
                (IGNORE_GROUP, "RequestedIgnoreActors", 1_063_739_204),
                (5, "RequestedIgnoreActors", 3_344_674_359),
                one_leaf(5, &reference),
            ),
            MeasuredArrayRoute::AllPlayersObfuscatedPlayerInformation => (
                (OWNER, OWNER_PARENT, OWNER_CHECKSUM),
                (49, "bIsAfk", 0),
                one_leaf(49, &[true]),
            ),
            // An RPC parameter, not a flattened property; its gate is
            // `projectile_path_rpc_expands_only_on_admitting_branches`.
            MeasuredArrayRoute::NetworkedProjectilePath => return None,
        };
        Some(case)
    }

    /// The gate is per route, not per build: a typed child (a leaf the 13.05
    /// route types) appears exactly where the branch admits its route. Admission
    /// and the exact walker both take the route from `measured_array_route`, so
    /// this checks each parent reads its own route's bit: every flattened route
    /// has a case (no wildcard), every supported branch runs plus none, against
    /// `MeasuredArrayRoutes::for_branch`. Two pairs share their branches
    /// (PlayerInfo/TrackedRewards, KillData/RequestedIgnoreActors), so only the
    /// identity pin below sees a swap inside one.
    #[test]
    fn legacy_branches_expand_only_their_admitted_routes() {
        // The identity pin: each case must map to its own route.
        for route in MeasuredArrayRoute::ALL {
            if let Some(((group, parent, checksum), _, _)) = case_for(route) {
                assert_eq!(
                    measured_array_route(group, parent, Some(checksum)),
                    Some(route),
                    "{route:?}"
                );
            }
        }
        let branches = vrf_transform::ALL_VERSIONS
            .iter()
            .map(|version| Some(version.branch()))
            .chain([None]);
        let mut expanded = Vec::new();
        for branch in branches {
            let admitted =
                branch.map_or(MeasuredArrayRoutes::NONE, MeasuredArrayRoutes::for_branch);
            for route in MeasuredArrayRoute::ALL {
                let Some((identity, leaf, bits)) = case_for(route) else {
                    continue;
                };
                let (records, stats) = export_array(identity, &[leaf], &bits, branch);
                let at = format!("{branch:?} {route:?}");
                // One child, counted on its own route alone. The fields are read
                // directly, in `ALL` order: `route_children` would read back any
                // swap of its own arms as consistent.
                let counted = [
                    stats.route_children_player_information,
                    stats.route_children_tracked_rewards,
                    stats.route_children_selected_v2,
                    stats.route_children_kill_data,
                    stats.route_children_server_active_effects,
                    stats.route_children_requested_ignore_actors,
                    stats.route_children_active_blinds,
                    stats.route_children_projectile_path,
                ];
                let want = MeasuredArrayRoute::ALL
                    .map(|r| u64::from(r == route && admitted.admits(route)));
                assert_eq!(counted, want, "{at}");
                let parent = records.fields.last().unwrap();
                assert_eq!(parent.field_name.as_deref(), Some(identity.1), "{at}");
                assert_eq!(parent.raw_bits.as_deref(), Some(pack(&bits).as_slice()));
                assert_eq!(stats.array_leaf_decode_errors, 0, "{at}");
                if admitted.admits(route) {
                    if !expanded.contains(&route) {
                        expanded.push(route);
                    }
                    assert_eq!(records.fields.len(), 2, "{at}");
                    let child = &records.fields[0];
                    assert!(
                        child.value_i64.is_some()
                            || child.value_f64.is_some()
                            || child.value_bool.is_some(),
                        "{at}: the admitted child is typed"
                    );
                } else {
                    assert_eq!(records.fields.len(), 1, "{at}");
                    assert_eq!(stats.array.fields_emitted, 0, "{at}");
                }
            }
        }
        // Not vacuous: each of the seven flattened routes expanded on some
        // branch, and the run with no branch kept every one of them raw.
        assert_eq!(expanded.len(), 7, "{expanded:?}");
    }

    /// Every flattened route keeps only its raw parent when the group, parent
    /// or checksum differs, and when its exact window has 8 bits too many or
    /// too few, which must also move a walker diagnostic.
    #[test]
    fn measured_routes_refuse_changed_identity_and_inexact_windows() {
        for route in MeasuredArrayRoute::ALL {
            let Some(((group, parent, checksum), leaf, valid)) = case_for(route) else {
                continue;
            };
            let other_group = format!("{group}Other");
            let mut extra = valid.clone();
            extra.extend([false; 8]);
            let cut = valid[..valid.len() - 8].to_vec();
            for (identity, bits, inexact) in [
                ((other_group.as_str(), parent, checksum), &valid, false),
                ((group, "Other", checksum), &valid, false),
                ((group, parent, checksum + 1), &valid, false),
                ((group, parent, checksum), &extra, true),
                ((group, parent, checksum), &cut, true),
            ] {
                let (records, stats) = export_array(identity, &[leaf], bits, Some(MEASURED_BUILD));
                let at = format!("{route:?} {identity:?} {} bits", bits.len());
                assert_eq!(records.fields.len(), 1, "{at}");
                assert_eq!(
                    records.fields[0].raw_bits.as_deref(),
                    Some(pack(bits).as_slice()),
                    "{at}"
                );
                assert_eq!(stats.tracked_rewards_opaque_empty_variants, 0, "{at}");
                assert_eq!(stats.active_blinds_empty_trailers, 0, "{at}");
                if inexact {
                    assert!(
                        stats.array.unconsumed_root_bits > 0
                            || stats.array.errors > 0
                            || stats.array.implicit_terminations > 0,
                        "{at}: {stats:?}"
                    );
                } else {
                    assert_eq!(stats.array.fields_emitted, 0, "{at}");
                }
            }
        }
    }

    /// A leaf no rule types stays an exact raw child on every admitted route
    /// (ActiveBlinds refuses the whole array instead), beside its raw parent.
    #[test]
    fn an_untyped_leaf_on_an_admitted_route_stays_raw() {
        for route in MeasuredArrayRoute::ALL {
            let Some((identity, _, _)) = case_for(route) else {
                continue;
            };
            if route == MeasuredArrayRoute::ActiveBlinds {
                continue;
            }
            let bits = one_leaf(19, &[true, false, true]);
            let (records, stats) = export_array(
                identity,
                &[(19, "Unlisted", 0)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields.len(), 2, "{route:?}");
            let child = &records.fields[0];
            assert_eq!(child.raw_bits.as_deref(), Some([5].as_slice()), "{route:?}");
            assert_eq!(values(child), (None, None, None, None), "{route:?}");
            assert_eq!(
                records.fields[1].raw_bits.as_deref(),
                Some(pack(&bits).as_slice())
            );
            assert_eq!(stats.array.fields_emitted, 1, "{route:?}");
            assert_eq!(stats.tracked_rewards_opaque_empty_variants, 0);
        }
    }

    #[test]
    fn new_routes_type_only_the_verified_leaf_windows() {
        let effects = |handle, resolved| {
            leaf_rule(
                LEAF_RULES,
                MeasuredArrayRoute::ServerActiveEffects,
                handle,
                0,
                None,
                None,
                resolved,
            )
        };
        assert_eq!(
            effects(33, Some(FieldType::Float)),
            Some(Leaf::Field(FieldType::Float))
        );
        assert_eq!(effects(33, Some(FieldType::Double)), None);
    }

    #[test]
    fn requested_ignore_actor_requires_exact_child_identity_and_non_raw_resolution() {
        let ignore = MeasuredArrayRoute::RequestedIgnoreActors;
        assert_eq!(
            typed(ignore, 5, "RequestedIgnoreActors", 3_344_674_359, None),
            Some(Leaf::Field(FieldType::ObjectNetGuid))
        );
        for (handle, name, checksum, resolved) in [
            (
                5,
                "RequestedIgnoreActors",
                3_344_674_359,
                Some(FieldType::Raw),
            ),
            (
                5,
                "RequestedIgnoreActors",
                3_344_674_359,
                Some(FieldType::Skip),
            ),
            (
                5,
                "RequestedIgnoreActors",
                3_344_674_359,
                Some(FieldType::Int32),
            ),
            (5, "Other", 3_344_674_359, None),
            (5, "RequestedIgnoreActors", 0, None),
            (4, "RequestedIgnoreActors", 3_344_674_359, None),
        ] {
            assert_eq!(typed(ignore, handle, name, checksum, resolved), None);
        }
    }

    #[test]
    fn requested_ignore_actor_bad_packed_child_keeps_raw_rows_and_counts_error() {
        // 0xff is an unterminated IntPacked value: its continuation bit is
        // set, but the exact leaf window ends before another packed byte.
        let bits = one_leaf(5, &[true; 8]);
        let (records, stats) = export_array(
            (IGNORE_GROUP, "RequestedIgnoreActors", 1_063_739_204),
            &[(5, "RequestedIgnoreActors", 3_344_674_359)],
            &bits,
            Some(MEASURED_BUILD),
        );
        assert_eq!(records.fields.len(), 2);
        let child = &records.fields[0];
        assert_eq!(child.raw_bits.as_deref(), Some([0xff].as_slice()));
        assert_eq!(values(child), (None, None, None, None));
        let parent = &records.fields[1];
        assert_eq!(parent.raw_bits.as_deref(), Some(pack(&bits).as_slice()));
        assert_eq!(stats.array_leaf_decode_errors, 1);
    }

    /// `FloatValues` (9) and `ObjectValues` (17) are effect arrays: the effect
    /// decoder's JSON, only under the declared name and checksum, and a blob
    /// it refuses counts as a leaf error.
    #[test]
    fn measured_effect_value_arrays_render_as_effect_json() {
        let float = unpack(&[
            2, 2, 0x10, 0x20, 0x39, 4, 0x12, 0x40, 0, 0, 0x80, 0x3f, 0, 0,
        ]);
        let object = unpack(&[2, 2, 0x20, 0x20, 0x37, 4, 0x22, 0x20, 0x1d, 0x30, 0, 0]);
        let identity = (EFFECTS_GROUP, "ServerActiveEffects", 3_301_618_856);
        for (handle, name, checksum, payload, want, errors) in [
            (
                9,
                "FloatValues",
                3_597_032_544,
                &float,
                Some("[{\"tag\":284,\"value\":1}]"),
                0,
            ),
            (
                17,
                "ObjectValues",
                865_691_585,
                &object,
                Some("[{\"tag\":283,\"value\":3086}]"),
                0,
            ),
            (9, "FloatValues", 0, &float, None, 0),
            (17, "ObjectValues", 865_691_585, &float, None, 1),
        ] {
            let bits = one_leaf(handle, payload);
            let leaves = [(handle, name, checksum)];
            let (records, stats) = export_array(identity, &leaves, &bits, Some(MEASURED_BUILD));
            let child = &records.fields[0];
            assert_eq!(child.value_str.as_deref(), want, "{name} {checksum}");
            assert_eq!(child.raw_bits.as_deref(), Some(pack(payload).as_slice()));
            assert_eq!(stats.array_leaf_decode_errors, errors, "{name} {checksum}");
        }
    }

    #[test]
    fn measured_effect_vectors_are_typed_without_a_top_level_overlay() {
        let payload: Vec<bool> = [1.25f64, -0.0, -2.5]
            .iter()
            .flat_map(|value| (0..64).map(move |bit| value.to_bits() & (1 << bit) != 0))
            .collect();
        for (handle, name) in [(30, "Translation"), (31, "Scale3D")] {
            let bits = one_leaf(handle, &payload);
            let (records, _) = export_array(
                (EFFECTS_GROUP, "ServerActiveEffects", 3_301_618_856),
                &[(handle, name, 0)],
                &bits,
                Some(MEASURED_BUILD),
            );
            assert_eq!(records.fields.len(), 2);
            assert_eq!(
                records.fields[0].value_str.as_deref(),
                Some("(1.25,-0,-2.5)")
            );
        }
        let effects = MeasuredArrayRoute::ServerActiveEffects;
        let member = Some("DifferentMember");
        assert_eq!(
            leaf_rule(LEAF_RULES, effects, 30, 192, member, None, None),
            None
        );
    }
}
