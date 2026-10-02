// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/sink/paths.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: listed in src/vendor/mod.rs.

//! Content-block group-path resolution.
//!
//! Every content block is attributed to a declared export group before any
//! field in it can be named (`resolve_actor_group_path`,
//! `resolve_subobject_group_path`, `NetGuidCache::unique_leaf_match`).
//!
//! # The memo
//!
//! [`BlockPathMemo`] caches the resolution, a pure function of the [`BlockKey`]
//! and of three inputs with independent stamps: the declared group paths
//! (`NetGuidCache::schema_generation`); the GUID -> path and GUID -> outer maps
//! (`NetGuidCache::guid_generation`, which also sees the frame-level
//! `vrf_frame::read_export_data` writes that bypass `register_path`); and the
//! channel -> (actor, archetype) map (`ChannelState::resolution_generation`,
//! moved only by `on_actor_open`/`on_actor_close`). Any stamp moving discards
//! the whole memo, so a hit is indistinguishable from a recomputation; some
//! stamp moves every ~92 blocks, so the unbounded table never grows far. The
//! value carries the function count because `resolve_function_count` can
//! replace the path. Hit rate: docs/PERFORMANCE_NOTES.md#group-path-resolution-memo.

use std::sync::Arc;

use vrf_net::content::ContentBlockHeader;
use vrf_net::types::NetworkGuid;
use vrf_schema::{FxHashMap, NetFieldExportGroup, find_class_net_cache_key, find_replay_path_key};

use super::{ChannelState, ExportSink};

/// Stably named subobject leaves -> the class path they resolve to, tagged with
/// the block kind each applies to: the fallback when no `class_net_guid` names
/// the class.
///
/// The first four pairs are the ClassNetCache effect entries. The rest are
/// RepLayout-only: VALORANT replicates components under bare instance names but
/// declares their layouts under the class (native, or the `/Game/` Blueprint
/// class the replay declares), and the AbilitySystem `_ClassNetCache` group is
/// declared with an incomplete function table, so its RPC stream stays
/// unresolved and is brute-forced at fc=34; every remapped component's RPC rows
/// stay bare.
///
/// The pairs are read from the shipped game by `tools/extract_component_classes`
/// (docs/DATA.md, "Reading component classes out of the game", has the
/// procedure, numbers and rejects); `tools/check_component_remaps.py` watches
/// for the symptoms of a rename, which nothing here can detect.
#[rustfmt::skip]
const KNOWN_SUBOBJECT_CLASS_PATHS: &[(&str, &str, GroupKind)] = &[
    ("ReplayEffect", "/Script/ShooterGame.ReplayEffectComponent", GroupKind::ClassNetCache),
    ("EffectManager", "/Script/ShooterGame.EffectManagerComponent", GroupKind::ClassNetCache),
    ("LocationalEffectManager", "/Script/ShooterGame.LocationalEffectManagerComponent", GroupKind::ClassNetCache),
    ("DamageHandlerComponent", "/Script/ShooterGame.DamageableComponent", GroupKind::ClassNetCache),
    ("InventoryComponent", "/Script/ShooterGame.AresInventory", GroupKind::RepLayout),
    ("AbilitiesAndBuffsComponent", "/Script/ShooterGame.AresAbilitySystemComponent", GroupKind::RepLayout),
    ("ZoomStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("SelectBounceStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("StateMachine_Priming", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("TargetingToggle_StateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("SuppressionRoundsStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("BoostStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("Gun_StateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("RewindStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("UseAbilityStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("Resume_StateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("Sprint_StateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("Slide_StateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("ProjectileStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("EquipStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("PrimaryTriggerActionStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("EquippableStateMachine_Activate", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("LaserStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("SelfResStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("Ability State Machine (EquippableStateMachine)", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("TimerStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("CloakStateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("SpontaneousEquip_StateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("EquippableStateMachine_Dart", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("EquippableStateMachine_Attack", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("EquippableStateMachine_PickUpOnCooldown", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    ("SwapCameras_StateMachine", "/Script/ShooterGame.EquippableStateMachineComponent", GroupKind::RepLayout),
    // One native class, two instances; handle 2 is `AuthResourceAmount`
    // (magazine 0..100, reserve 0..200).
    ("MagazineAmmo", "/Script/ShooterGame.AmmoComponent", GroupKind::RepLayout),
    ("ReserveAmmo", "/Script/ShooterGame.AmmoComponent", GroupKind::RepLayout),
    ("CalloutRegionTracker", "/Script/ShooterGame.CalloutRegionTrackingComponent", GroupKind::RepLayout),
    ("VisionComponent", "/Script/ShooterGame.ShooterCharacterVisionComponent", GroupKind::RepLayout),
    ("HealthDamageSection", "/Script/ShooterGame.ChildDamageSectionComponent", GroupKind::RepLayout),
    ("ShieldDamageSection", "/Script/ShooterGame.ChildDamageSectionComponent", GroupKind::RepLayout),
    ("OverhealDamageSection", "/Script/ShooterGame.ChildDamageSectionComponent", GroupKind::RepLayout),
    ("PreventDeathDamageSection", "/Script/ShooterGame.AttachedDamageSectionComponent", GroupKind::RepLayout),
    ("UsableComponent_EquippableGroundPickup", "/Script/ShooterGame.UsableComponent_EquippableGroundPickups", GroupKind::RepLayout),
    ("Usable_PickUp", "/Script/ShooterGame.UsableComponent", GroupKind::RepLayout),
    ("StealthComp", "/Script/ShooterGame.SimpleVisualTimelineStealthComp", GroupKind::RepLayout),
    ("StealthV1AddedForAISight", "/Script/ShooterGame.StealthComponent", GroupKind::RepLayout),
    ("Collision Static Mesh", "/Script/Engine.StaticMeshComponent", GroupKind::RepLayout),
    ("PMAimToolingPointsTarget", "/Script/InputTooling.AimToolingPointsTargetComponent", GroupKind::RepLayout),
    // Handle 2 `AttachParent` is a packed reference: 16 bits vs the target's 24
    // is the NetGUID's size, not a type disagreement.
    ("PMAimToolingTarget", "/Script/InputTooling.AimToolingSkeletalTargetComponent", GroupKind::RepLayout),
    ("Comp_Ability_CooldownComponent1", "/Game/Characters/Components/Comp_Ability_CooldownComponent.Comp_Ability_CooldownComponent_C", GroupKind::RepLayout),
    ("DamageSection_Vampire_Q_BloodArmor", "/Game/Characters/Vampire/S0/Ability_Q/DamageSection_Vampire_Q_Heal_BloodArmor.DamageSection_Vampire_Q_Heal_BloodArmor_C", GroupKind::RepLayout),
    ("ChooseTeleportSpot_StateComponent", "/Game/Characters/States/ChooseMapLocationOnNavMesh_StateComponent.ChooseMapLocationOnNavMesh_StateComponent_C", GroupKind::RepLayout),
    // The 13.06 armour section. Beside Phoenix's native `PreventDeathDamageSection`,
    // `unique_leaf_match` binds that native parent first (only `bAlive`), so
    // handles 3 and 5 stay unnamed there.
    ("AttachedDamageSection", "/Game/Gear/BasicArmorAttachedDamageSection.BasicArmorAttachedDamageSection_C", GroupKind::RepLayout),
    // GAS attribute sets, runtime subobjects in no cooked asset: wire evidence
    // only (every handle declared by the native group, all at 32 bits).
    ("AresAttributeSet_1", "/Script/ShooterGame.AresAttributeSet", GroupKind::RepLayout),
    ("AresAttributeSet_2", "/Script/ShooterGame.AresAttributeSet", GroupKind::RepLayout),
];

/// Everything a block's resolution reads that is not cache state. All six stay
/// in the key though each branch ignores some: dropping a field the resolution
/// does read is silent byte movement, while an over-precise key costs entries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct BlockKey {
    channel_index: u32,
    actor_net_guid: u32,
    class_net_guid: u32,
    object_net_guid: u32,
    is_actor: bool,
    has_rep_layout: bool,
}

/// One block's resolution, as [`ExportSink::resolve_block`] memoises it.
#[derive(Debug, Clone)]
struct Resolution {
    path: Arc<str>,
    function_count: u32,
    group_source: &'static str,
    count_source: &'static str,
}

/// Memo for [`ExportSink::resolve_block`]; see the module docs.
#[derive(Debug, Clone, Default)]
pub(super) struct BlockPathMemo {
    /// The (schema, resolution, GUID) generations `entries` is valid for.
    stamps: (u64, u64, u64),
    entries: FxHashMap<BlockKey, Resolution>,
}

impl BlockPathMemo {
    /// Drop everything if any stamp has moved, then report the entry for `key`.
    fn get(&mut self, key: &BlockKey, stamps: (u64, u64, u64)) -> Option<Resolution> {
        if self.stamps != stamps {
            self.entries.clear();
            self.stamps = stamps;
            return None;
        }
        self.entries.get(key).cloned()
    }
}

impl ExportSink<'_> {
    /// Resolve one content block, memoised: set `current_group_path` and return
    /// the function count its RPC handles are read against (0 for a RepLayout
    /// block or an unresolved group).
    pub(super) fn resolve_block(
        &mut self,
        channel_index: u32,
        actor_net_guid: NetworkGuid,
        header: &ContentBlockHeader,
    ) -> u32 {
        let key = BlockKey {
            channel_index,
            actor_net_guid: actor_net_guid.0,
            class_net_guid: header.class_net_guid.0,
            object_net_guid: header.object_net_guid.0,
            is_actor: header.is_actor,
            has_rep_layout: header.has_rep_layout,
        };
        let stamps = (
            self.cache.schema_generation(),
            self.channel_state.resolution_generation,
            self.cache.guid_generation(),
        );
        if let Some(hit) = self.channel_state.block_paths.get(&key, stamps) {
            self.set_current_group_path(hit.path);
            self.current_group_resolution_source = hit.group_source;
            self.current_function_count_source = hit.count_source;
            self.current_resolution_memo_hit = true;
            return hit.function_count;
        }

        let (path, group_source) = if header.is_actor {
            self.resolve_actor_group_path(channel_index, actor_net_guid.0, header)
        } else {
            self.resolve_subobject_group_path(header)
        };
        let interned = self.channel_state.names.intern(&path);
        self.set_current_group_path(interned);
        // May replace `current_group_path`, hence before the path is stored.
        let (function_count, count_source) = if header.has_rep_layout {
            (0, "rep_layout_not_applicable")
        } else {
            self.resolve_function_count()
        };
        let group_source = if count_source == "class_net_cache_instance_name" {
            count_source
        } else {
            group_source
        };
        self.current_group_resolution_source = group_source;
        self.current_function_count_source = count_source;
        self.current_resolution_memo_hit = false;
        let resolution = Resolution {
            path: Arc::clone(&self.current_group_path),
            function_count,
            group_source,
            count_source,
        };
        self.channel_state
            .block_paths
            .entries
            .insert(key, resolution);
        function_count
    }

    /// Actor blocks: the first group of the wanted kind matched by the combined
    /// archetype candidate, the archetype's outer (package) path, the archetype
    /// path unless it is a CDO, then the actor GUID's own path.
    fn resolve_actor_group_path(
        &self,
        channel_index: u32,
        actor_guid: u32,
        header: &ContentBlockHeader,
    ) -> (String, &'static str) {
        let archetype =
            channel_archetype(self.channel_state, channel_index, NetworkGuid(actor_guid));
        let (package_path, archetype_path) = self.archetype_paths(archetype);
        let combined = combined_candidate(package_path.as_deref(), archetype_path.as_deref());

        // A ClassNetCache block accepts only a `_ClassNetCache` group: the key
        // `AggroBot_PC.AggroBot_PC_C` would otherwise bind the 14-field
        // RepLayout group, not the 4-field ClassNetCache one, and
        // ReadSerializedInt would consume the wrong number of bits.
        let want = GroupKind::for_block(header);

        if let Some(hit) = self.match_group(combined.as_deref(), want) {
            return (hit, "actor_archetype_combined");
        }
        if let Some(hit) = self.match_group(package_path.as_deref(), want) {
            return (hit, "actor_archetype_outer");
        }
        if let Some(arch) = archetype_path.as_deref() {
            if !leaf(arch).starts_with("Default__") {
                if let Some(hit) = self.match_group(Some(arch), want) {
                    return (hit, "actor_archetype_path");
                }
            }
        }
        if let Some(actor_path) = self.cache.get_path_by_guid(actor_guid) {
            // A static actor arrives as a bare instance name (`AresWorldSettings`).
            return self.resolve_named_path(
                actor_path,
                want,
                [
                    "actor_guid_path",
                    "actor_guid_unique_leaf",
                    "actor_guid_known_remap",
                    "actor_guid_unresolved_fallback",
                ],
            );
        }

        // The best candidate even unmatched: the export needs a path, and the
        // raw bits still ship.
        if let Some(combined) = combined {
            (combined, "actor_archetype_combined_unresolved_fallback")
        } else if let Some(package_path) = package_path {
            (package_path, "actor_archetype_outer_unresolved_fallback")
        } else {
            (format!("<unknown:{actor_guid}>"), "actor_unknown")
        }
    }

    /// Subobject blocks: the `class_net_guid` path, else the object's outer path
    /// as a group, then its own path.
    fn resolve_subobject_group_path(&self, header: &ContentBlockHeader) -> (String, &'static str) {
        let want = GroupKind::for_block(header);
        let (class_guid, object_guid) = (header.class_net_guid.0, header.object_net_guid.0);

        if class_guid != 0 {
            if let Some(class_path) = self.cache.get_path_by_guid(class_guid) {
                return self.resolve_named_path(
                    class_path,
                    want,
                    [
                        "subobject_class_guid_path",
                        "subobject_class_guid_unique_leaf",
                        "subobject_class_guid_known_remap",
                        "subobject_class_guid_unresolved_fallback",
                    ],
                );
            }
        }
        if object_guid != 0 {
            if let Some(obj_path) = self.cache.get_path_by_guid(object_guid) {
                let outer = self.cache.get_outer_path(object_guid);
                if let Some(hit) = self.match_group(outer, want) {
                    return (hit, "subobject_object_outer_path");
                }
                return self.resolve_named_path(
                    obj_path,
                    want,
                    [
                        "subobject_object_guid_path",
                        "subobject_object_guid_unique_leaf",
                        "subobject_object_guid_known_remap",
                        "subobject_object_guid_unresolved_fallback",
                    ],
                );
            }
        }
        let fallback_guid = if class_guid != 0 {
            class_guid
        } else {
            object_guid
        };
        (format!("<unknown:{fallback_guid}>"), "subobject_unknown")
    }

    /// `path` as a declared group of kind `want`, then as a unique leaf (an
    /// ambiguous leaf binds nothing), then through the remap table (bare
    /// `InventoryComponent` never leaf-matches `AresInventory`), else `path`
    /// itself; `labels` name the four outcomes in that order. The kind guard on
    /// the leaf match keeps a RepLayout group from a ClassNetCache block.
    fn resolve_named_path(
        &self,
        path: &str,
        want: GroupKind,
        labels: [&'static str; 4],
    ) -> (String, &'static str) {
        if let Some(hit) = self.match_group(Some(path), want) {
            return (hit, labels[0]);
        }
        if let Some(group) = self.cache.unique_leaf_match(path) {
            if want.accepts(group) {
                return (group.path.clone(), labels[1]);
            }
        }
        let known = resolve_known_subobject_class_path(path, want);
        if let Some(hit) = self.match_group(known, want) {
            return (hit, labels[2]);
        }
        (path.to_owned(), labels[3])
    }

    /// The canonical path of the first declared group of kind `want` that a
    /// lookup key of `candidate` finds. One function, so no caller can pick the
    /// wrong key generator or skip the `_ClassNetCache` guard.
    fn match_group(&self, candidate: Option<&str>, want: GroupKind) -> Option<String> {
        let candidate = candidate?;
        want.find(candidate, |key| {
            let group = self.cache.get_group_by_path(key)?;
            want.accepts(group).then(|| group.path.clone())
        })
    }

    /// `(outer path, path)` of a valid archetype GUID; either is `None` while
    /// the cache lacks it. Owned: borrowing them measured no gain.
    pub(super) fn archetype_paths(
        &self,
        archetype: Option<NetworkGuid>,
    ) -> (Option<String>, Option<String>) {
        let Some(guid) = archetype.filter(|guid| guid.is_valid()) else {
            return (None, None);
        };
        (
            self.cache.get_outer_path(guid.0).map(str::to_owned),
            self.cache.get_path_by_guid(guid.0).map(str::to_owned),
        )
    }

    /// A ClassNetCache block's function count: its group's declared slot count,
    /// the bound its handle is read as a SerializedInt against. 0 when no group
    /// resolves: the payload is then preserved raw and counted as a stream
    /// failure, never dropped. The group resolution already probed every
    /// class and archetype key for a `_ClassNetCache` group, so only the
    /// current path and a bare instance name are left to try.
    fn resolve_function_count(&mut self) -> (u32, &'static str) {
        if let Some(group) = self.cache.get_group_by_path(&self.current_group_path) {
            if is_class_net_cache(group) {
                return (group.len(), "current_resolved_group");
            }
        }
        // A bare instance name -- static actors (`BombDestination_A`), stably
        // named subobjects (`ForceModuleManager`) -- has no archetype or class
        // GUID on the wire: match it against the replay's own `_ClassNetCache`
        // groups by Unreal naming conventions and rebind the block to that
        // group, or its RPCs are named by handle.
        if is_bare_instance_name(&self.current_group_path) {
            if let Some(group) = self
                .cache
                .resolve_cnc_for_instance_name(&self.current_group_path)
            {
                let len = group.len();
                let resolved = self.channel_state.names.intern(&group.path);
                self.set_current_group_path(resolved);
                return (len, "class_net_cache_instance_name");
            }
        }
        (0, "unresolved_class_net_cache")
    }
}

/// Which family of export group a block may bind to. It selects both the
/// lookup-key generator and the acceptance test, which must move together: a
/// ClassNetCache block bound to a RepLayout group reads the wrong handle width,
/// a decode failure, not a naming one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GroupKind {
    RepLayout,
    ClassNetCache,
}

impl GroupKind {
    fn for_block(header: &ContentBlockHeader) -> Self {
        if header.has_rep_layout {
            Self::RepLayout
        } else {
            Self::ClassNetCache
        }
    }

    /// Probe this kind's lookup keys in order until one is accepted. The
    /// generators are visitors, so a path with no alias allocates nothing.
    fn find<T>(self, path: &str, probe: impl FnMut(&str) -> Option<T>) -> Option<T> {
        match self {
            Self::RepLayout => find_replay_path_key(path, probe),
            Self::ClassNetCache => find_class_net_cache_key(path, probe),
        }
    }

    fn accepts(self, group: &NetFieldExportGroup) -> bool {
        match self {
            Self::RepLayout => true,
            Self::ClassNetCache => is_class_net_cache(group),
        }
    }
}

fn is_class_net_cache(group: &NetFieldExportGroup) -> bool {
    group.path.ends_with(vrf_schema::CLASS_NET_CACHE_SUFFIX)
}

/// A path with no separators and no `<unknown:` marker -- the shape the
/// instance-name resolver is allowed to see.
fn is_bare_instance_name(path: &str) -> bool {
    !vrf_schema::has_path_separator(path) && !path.starts_with('<')
}

/// The path's last component, after its final `/`, `.` or `:`.
fn leaf(path: &str) -> &str {
    path.rfind(['/', '.', ':']).map_or(path, |i| &path[i + 1..])
}

/// `package_path` joined with the class name of the archetype's leaf
/// (`Default__` stripped), unless the package path already ends with it:
/// `/Game/Characters/AggroBot/AggroBot_PC` + `Default__AggroBot_PC_C`.
pub(super) fn combined_candidate(
    package_path: Option<&str>,
    archetype_path: Option<&str>,
) -> Option<String> {
    let pkg = package_path?;
    let class_leaf = leaf(archetype_path?);
    if class_leaf.is_empty() {
        return None;
    }
    let class_name = class_leaf.strip_prefix("Default__").unwrap_or(class_leaf);
    if pkg
        .strip_suffix(class_name)
        .is_some_and(|prefix| prefix.ends_with(['.', ':']))
    {
        return Some(pkg.to_owned());
    }
    Some(format!("{pkg}.{class_name}"))
}

/// The [`KNOWN_SUBOBJECT_CLASS_PATHS`] target for `object_path`'s leaf and kind.
fn resolve_known_subobject_class_path(object_path: &str, want: GroupKind) -> Option<&'static str> {
    let leaf = leaf(object_path);
    KNOWN_SUBOBJECT_CLASS_PATHS
        .iter()
        .find(|(name, _, kind)| *name == leaf && *kind == want)
        .map(|(_, class_path, _)| *class_path)
}

/// An archetype GUID together with the actor it was read for.
///
/// Channel indices are recycled and a *static* actor carries no archetype to
/// displace its predecessor's, so a channel-keyed archetype decodes the new
/// actor under the old class -- and nothing fails: fields get names, values get
/// types, and rows ship under a class the actor never had. Destruction retires
/// the entry; dormancy keeps it (a wake-up need not repeat the archetype), and
/// the actor stamp keeps a surviving dormant entry safe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct ChannelArchetype {
    actor: NetworkGuid,
    archetype: NetworkGuid,
}

/// Register an archetype for a channel and, if that changed anything, tell the
/// memo. Called from `on_actor_open`.
pub(super) fn set_channel_archetype(
    state: &mut ChannelState,
    channel_index: u32,
    actor: NetworkGuid,
    archetype: NetworkGuid,
) {
    let entry = ChannelArchetype { actor, archetype };
    if state.archetypes.get(&channel_index) == Some(&entry) {
        return;
    }
    state.archetypes.insert(channel_index, entry);
    state.note_resolution_input_changed();
}

/// The archetype GUID recorded for `channel_index`, but only if it was read for
/// `actor`. See [`ChannelArchetype`].
pub(super) fn channel_archetype(
    state: &ChannelState,
    channel_index: u32,
    actor: NetworkGuid,
) -> Option<NetworkGuid> {
    state
        .archetypes
        .get(&channel_index)
        .filter(|entry| entry.actor == actor)
        .map(|entry| entry.archetype)
}

/// Retire the archetype state owned by a destroyed channel index.
pub(super) fn retire_channel_archetype(state: &mut ChannelState, channel_index: u32) {
    if state.archetypes.remove(&channel_index).is_some() {
        state.note_resolution_input_changed();
    }
}

#[cfg(test)]
mod tests {
    #![allow(unused_must_use)]

    use super::*;
    use crate::vendor::sink::test_fixtures::{Rig, actor_block, channel_open};
    use vrf_net::pipeline::ReplicationSink;

    /// Build a cache holding `groups` as declared export groups and mapping
    /// `guid` to `guid_path`, then run one actor content block through a sink
    /// and report the group path it resolved to.
    fn actor_group_path_for(
        groups: &[&str],
        guid: u32,
        guid_path: &str,
        has_rep_layout: bool,
    ) -> String {
        let mut rig = Rig::default();
        for (i, path) in groups.iter().enumerate() {
            rig.cache
                .add_export_group(vrf_schema::NetFieldExportGroup::new(
                    (*path).to_owned(),
                    i as u32 + 1,
                    4,
                ));
        }
        rig.cache.set_net_guid_path(guid, guid_path, None);
        let mut sink = rig.sink();

        // No archetype is registered, so only the actor-GUID path is left.
        sink.on_content_block(3, NetworkGuid(guid), &actor_block(has_rep_layout));
        sink.current_group_path.to_string()
    }

    /// An actor whose own NetGUID path is a unique leaf of a declared group
    /// reaches that group, as the class and subobject paths do.
    #[test]
    fn an_actor_path_that_is_a_unique_leaf_reaches_its_declared_group() {
        assert_eq!(
            actor_group_path_for(
                &["/Script/ShooterGame.AresWorldSettings"],
                42,
                "AresWorldSettings",
                true,
            ),
            "/Script/ShooterGame.AresWorldSettings",
        );
    }

    /// Every RepLayout pair reaches its target from a RepLayout block and stays
    /// bare on a ClassNetCache block (fails if the remap stops asking the block
    /// kind). Only the four effect entries remap a ClassNetCache block: another
    /// would bind that leaf's RPC stream to `<target>_ClassNetCache`, the
    /// AbilitySystem mis-parse. The row count pins deletions, which
    /// `tools/check_component_remaps.py` only reports.
    #[test]
    fn every_rep_layout_remap_reaches_its_group_and_only_from_rep_layout() {
        let mut rep_layout = 0;
        for (leaf, target, kind) in KNOWN_SUBOBJECT_CLASS_PATHS {
            if *kind != GroupKind::RepLayout {
                continue;
            }
            rep_layout += 1;
            assert_eq!(actor_group_path_for(&[target], 100, leaf, true), *target);
            assert_eq!(
                actor_group_path_for(&[target], 100, leaf, false),
                *leaf,
                "{leaf}: a ClassNetCache block is not handed the RepLayout group",
            );
            assert_eq!(
                resolve_known_subobject_class_path(leaf, GroupKind::ClassNetCache),
                None,
                "{leaf} is RepLayout-only",
            );
        }
        assert_eq!(rep_layout, 49);
        let class_net_cache: Vec<&str> = KNOWN_SUBOBJECT_CLASS_PATHS
            .iter()
            .filter(|(_, _, kind)| *kind == GroupKind::ClassNetCache)
            .map(|(leaf, _, _)| *leaf)
            .collect();
        assert_eq!(
            class_net_cache,
            [
                "ReplayEffect",
                "EffectManager",
                "LocationalEffectManager",
                "DamageHandlerComponent",
            ],
        );
    }

    /// A component the table does not list keeps its bare path rather than
    /// joining whichever native group looks close.
    #[test]
    fn an_unlisted_component_name_is_not_remapped() {
        assert_eq!(
            actor_group_path_for(
                &["/Script/ShooterGame.AmmoComponent"],
                100,
                "SomeUnlistedComponent",
                true,
            ),
            "SomeUnlistedComponent",
        );
    }

    /// Two declared groups sharing a leaf mark it `AMBIGUOUS_LEAF`: the actor
    /// keeps its raw path rather than binding to whichever came first.
    #[test]
    fn an_ambiguous_actor_leaf_binds_to_nothing() {
        assert_eq!(
            actor_group_path_for(
                &[
                    "/Script/ShooterGame.AresWorldSettings",
                    "/Game/Maps/Ascent.AresWorldSettings",
                ],
                42,
                "AresWorldSettings",
                true,
            ),
            "AresWorldSettings",
        );
    }

    /// A ClassNetCache actor block is not captured by a RepLayout leaf; see the
    /// `_ClassNetCache` guard in `resolve_actor_group_path`.
    #[test]
    fn a_class_net_cache_actor_block_is_not_captured_by_a_rep_layout_leaf() {
        assert_eq!(
            actor_group_path_for(
                &["/Script/ShooterGame.AresWorldSettings"],
                42,
                "AresWorldSettings",
                false,
            ),
            "AresWorldSettings",
        );
    }

    /// A cache declaring `Smoke_C`, whose archetype (GUID 8) names its class
    /// through its outer (GUID 9).
    fn smoke_rig() -> Rig {
        let mut rig = Rig::default();
        rig.cache
            .add_export_group(vrf_schema::NetFieldExportGroup::new(
                "/Game/Effects/Smoke.Smoke_C".to_owned(),
                1,
                4,
            ));
        rig.cache
            .set_net_guid_path(8, "Default__Smoke_C", Some(NetworkGuid(9)));
        rig.cache.set_net_guid_path(9, "/Game/Effects/Smoke", None);
        rig
    }

    /// A static actor on a recycled channel is not decoded under the previous
    /// actor's archetype; see [`ChannelArchetype`].
    #[test]
    fn a_reused_channel_does_not_inherit_the_previous_actors_archetype() {
        let mut rig = smoke_rig();
        // GUID 77 is a static actor that opens later on the same channel and
        // brings no archetype with it.
        rig.cache.set_net_guid_path(77, "SomeStaticProp", None);

        let mut sink = rig.sink();
        let header = actor_block(true);

        // The dynamic actor opens on channel 5 and resolves to its class.
        sink.on_actor_open(&channel_open(5, 42, 8));
        sink.on_content_block(5, NetworkGuid(42), &header);
        assert_eq!(
            &*sink.current_group_path, "/Game/Effects/Smoke.Smoke_C",
            "the dynamic actor must reach its own class",
        );

        // It closes, and the channel number is handed to a static actor.
        sink.on_actor_close(5, NetworkGuid(42), false);
        sink.on_actor_open(&channel_open(5, 77, 0));
        sink.on_content_block(5, NetworkGuid(77), &header);
        assert_eq!(
            &*sink.current_group_path, "SomeStaticProp",
            "the static actor must not be decoded under the previous actor's class",
        );
    }

    /// ...while the *same* actor waking from dormancy without re-sending its
    /// archetype keeps its class.
    #[test]
    fn the_same_actor_reopening_without_an_archetype_keeps_its_class() {
        let mut rig = smoke_rig();

        let mut sink = rig.sink();
        let header = actor_block(true);

        sink.on_actor_open(&channel_open(5, 42, 8));
        sink.on_actor_close(5, NetworkGuid(42), true);
        // Woken: same actor, same channel, no archetype on the wire.
        sink.on_actor_open(&channel_open(5, 42, 0));
        sink.on_content_block(5, NetworkGuid(42), &header);
        assert_eq!(
            &*sink.current_group_path, "/Game/Effects/Smoke.Smoke_C",
            "a dormancy wake must not lose the actor's class",
        );
    }

    /// The memo never answers for a block whose inputs moved: a GUID path
    /// declared through `register_path`, or written by frame-level ExportData
    /// straight into the cache between two sinks, moves only
    /// `NetGuidCache::guid_generation`.
    #[test]
    fn a_guid_path_registration_invalidates_the_memo() {
        use vrf_net::net_guid::GuidPathSink;

        for through_sink in [true, false] {
            let mut rig = Rig::default();
            rig.cache
                .add_export_group(vrf_schema::NetFieldExportGroup::new(
                    "/Script/ShooterGame.AresWorldSettings".to_owned(),
                    1,
                    4,
                ));
            let header = actor_block(true);
            let mut sink = rig.sink();
            sink.on_content_block(3, NetworkGuid(42), &header);
            assert_eq!(&*sink.current_group_path, "<unknown:42>");
            if through_sink {
                sink.register_path(42, "AresWorldSettings", NetworkGuid(0));
            } else {
                rig.cache.set_net_guid_path(42, "AresWorldSettings", None);
            }
            let mut sink = rig.sink();
            sink.on_content_block(3, NetworkGuid(42), &header);
            assert_eq!(
                &*sink.current_group_path, "/Script/ShooterGame.AresWorldSettings",
                "through the sink: {through_sink}"
            );
        }
    }

    /// A repeat registration that changes nothing leaves the memo standing (if
    /// every re-declaration moved a stamp, the hit rate would collapse). The
    /// asserts read the memo's hit flag, so they hold whichever stamp moves.
    #[test]
    fn a_redundant_registration_leaves_the_memo_alone() {
        use vrf_net::net_guid::GuidPathSink;

        let mut rig = Rig::default();
        let mut sink = rig.sink();
        let header = actor_block(true);

        sink.register_path(42, "AresWorldSettings", NetworkGuid(7));
        sink.on_content_block(3, NetworkGuid(42), &header);
        assert!(!sink.current_resolution_memo_hit, "a first resolution hit");
        sink.register_path(42, "AresWorldSettings", NetworkGuid(7));
        sink.on_content_block(3, NetworkGuid(42), &header);
        assert!(
            sink.current_resolution_memo_hit,
            "an unchanged re-declaration invalidated the memo"
        );

        // A different outer is a real change (the `outer_net_guid` column and a
        // resolution input): an invalid outer removes the one the cache held.
        sink.register_path(42, "AresWorldSettings", NetworkGuid(0));
        sink.on_content_block(3, NetworkGuid(42), &header);
        assert!(
            !sink.current_resolution_memo_hit,
            "a changed outer left the memo standing"
        );
        assert_eq!(sink.cache.get_outer_guid(42), None);
    }
}
