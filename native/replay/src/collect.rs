//! The [`Observer`] the decode runs: keeps the few thousand rows the analysis
//! reads out of the million a match replicates, plus actors, movement,
//! events and the transform guard's sample.

use std::sync::Arc;

use vrf_export::{ActorRecord, EventRecord, FieldRecord};
use vrf_schema::NetGuidCache;

use crate::decode::Observer;
use crate::error::ReplayError;
use crate::guard::GuardSample;
use crate::limits::{self, MAX_RETAINED_BYTES};
use crate::vendor::sink::RecordBuffers;

/// One field row the analysis reads. `name` is vrfkit's field name as
/// exported (array indices and Blueprint suffixes intact).
#[derive(Debug, Clone)]
pub struct Row {
    pub time: u32,
    pub packet: u32,
    pub actor: u32,
    pub object: Option<u32>,
    pub group: Arc<str>,
    pub name: Arc<str>,
    pub int: Option<i64>,
    pub float: Option<f64>,
    pub boolean: Option<bool>,
    pub text: Option<String>,
    /// The payload of a value vrfkit left untyped, whole bytes only.
    pub raw: Option<Vec<u8>>,
}

/// One movement sample, as compact as the analysis needs it.
#[derive(Debug, Clone, Copy)]
pub struct Move {
    pub time: u32,
    pub character: u32,
    pub pos: [f32; 3],
    pub yaw: f32,
    pub pitch: f32,
}

#[derive(Default)]
pub struct Collector {
    pub rows: Vec<Row>,
    pub actors: Vec<ActorRecord>,
    pub moves: Vec<Move>,
    pub events: Vec<EventRecord>,
    pub guard: GuardSample,
    /// Every write on a map door's actor, `(time, group)`. Their fields have
    /// no names, so they never reach `rows`.
    pub door_writes: Vec<(u32, Arc<str>)>,
    /// When the Lotus A Link wall reported `OnDie`.
    pub wall_breaks: Vec<u32>,
    /// Every door state an Ascent door's `PlayDoorSounds` call carried. Unlike
    /// the other doors' fields, these are named.
    pub shutter_states: Vec<ShutterState>,
    /// Each Ascent door's actor name by net GUID, since its calls carry only
    /// the GUID.
    pub shutter_names: std::collections::BTreeMap<u32, Arc<str>>,
    /// `wanted` per interned name; the `Arc` held here keeps its address unique.
    verdicts: std::collections::HashMap<usize, (Arc<str>, bool)>,
    /// Which door a group belongs to, if any, per interned group, the same way.
    door_groups: std::collections::HashMap<usize, (Arc<str>, DoorGroup)>,
    /// Bytes of the records above, against [`MAX_RETAINED_BYTES`].
    retained: usize,
}

impl Collector {
    fn retain(&mut self, bytes: usize) -> Result<(), ReplayError> {
        self.retained = self.retained.saturating_add(bytes);
        if self.retained > MAX_RETAINED_BYTES {
            return Err(limits::exceeded(
                "retained record bytes",
                MAX_RETAINED_BYTES,
            ));
        }
        Ok(())
    }
}

impl Observer for Collector {
    fn on_event(&mut self, event: EventRecord) -> Result<(), ReplayError> {
        self.retain(
            size_of::<EventRecord>()
                + event.raw_payload.len()
                + event.group.len()
                + event.metadata.len()
                + event.id.len(),
        )?;
        self.events.push(event);
        Ok(())
    }

    fn on_packet(
        &mut self,
        records: &RecordBuffers,
        _cache: &NetGuidCache,
    ) -> Result<(), ReplayError> {
        let text = |s: &Option<String>| s.as_ref().map_or(0, String::len);
        self.retain(
            records
                .actors
                .iter()
                .map(|a| size_of::<ActorRecord>() + text(&a.class_path) + text(&a.archetype_path))
                .sum::<usize>()
                + records.movement.len() * size_of::<Move>(),
        )?;
        self.actors.extend(records.actors.iter().cloned());
        self.moves.extend(records.movement.iter().map(|m| Move {
            time: m.time_ms,
            character: m.character_net_guid,
            pos: [m.pos_x, m.pos_y, m.pos_z],
            yaw: m.yaw,
            pitch: m.pitch,
        }));
        for field in &records.fields {
            if let Some(raw) = &field.raw_bits {
                self.guard.add(raw, field.bit_count);
            }
            let group_key = Arc::as_ptr(&field.group_path).cast::<u8>() as usize;
            let door = self
                .door_groups
                .entry(group_key)
                .or_insert_with(|| {
                    (
                        Arc::clone(&field.group_path),
                        door_group(&field.group_path),
                    )
                })
                .1;
            match door {
                DoorGroup::None => {}
                DoorGroup::Moves => {
                    self.door_writes
                        .push((field.time_ms, Arc::clone(&field.group_path)));
                    self.retain(size_of::<(u32, Arc<str>)>())?;
                }
                DoorGroup::Wall => {
                    if field.field_name.as_deref() == Some("OnDie") {
                        self.wall_breaks.push(field.time_ms);
                    }
                    self.retain(size_of::<(u32, Arc<str>)>())?;
                }
                DoorGroup::Shutter => {
                    if !self.shutter_names.contains_key(&field.actor_net_guid) {
                        let name = shutter_actor(&field.group_path).unwrap_or_default();
                        self.shutter_names
                            .insert(field.actor_net_guid, Arc::from(name));
                        self.retain(size_of::<(u32, Arc<str>)>() + name.len())?;
                    }
                }
                DoorGroup::ShutterCalls => {
                    let entered = match field.field_name.as_deref() {
                        Some("PlayDoorSounds.New State") => Some(true),
                        Some("PlayDoorSounds.Old State") => Some(false),
                        _ => None,
                    };
                    let state = field.raw_bits.as_deref().and_then(|raw| raw.first());
                    if let (Some(entered), Some(state)) = (entered, state) {
                        self.shutter_states.push(ShutterState {
                            time: field.time_ms,
                            actor: field.actor_net_guid,
                            entered,
                            state: state & 0b111,
                        });
                        self.retain(size_of::<ShutterState>())?;
                    }
                }
            }
            let Some(name) = &field.field_name else {
                continue;
            };
            let key = Arc::as_ptr(name).cast::<u8>() as usize;
            let keep = self
                .verdicts
                .entry(key)
                .or_insert_with(|| (Arc::clone(name), wanted(name)))
                .1;
            if !keep {
                continue;
            }
            let row = Row {
                time: field.time_ms,
                packet: field.packet_id,
                actor: field.actor_net_guid,
                object: field.object_net_guid,
                group: Arc::clone(&field.group_path),
                name: Arc::clone(name),
                int: field.value_i64,
                float: field.value_f64,
                boolean: field.value_bool,
                text: field.value_str.clone(),
                raw: untyped_bytes(field),
            };
            self.retain(size_of::<Row>() + text(&row.text) + row.raw.as_ref().map_or(0, Vec::len))?;
            self.rows.push(row);
        }
        Ok(())
    }
}

/// Field names whose rows the analysis reads (see each consumer for why).
const EXACT: &[&str] = &[
    "Money",
    "Owner",
    "Instigator",
    "AggregateAssists",
    "LongestActiveBlindDuration",
    "PlantedAtSite",
    "AuthResourceAmount",
    "ReplicatedMovement",
    "MulticastSetPhase.NewPhase",
    "BombPlantedRPC.BombPlanter",
    "BombPlantedRPC.PlantLocation",
    "BombPlantedRPC.PlantSite",
    "BombDefusedRPC.DefusingCharacter",
    "MulticastActivateBombSiteEffects.BombLocation",
    "MulticastNotifyKilledEnemy.KillerCharacter",
    "MulticastNotifyKilledEnemy.KilledCharacter",
    "MulticastAddSmokeScreenPoint.Translation",
    "MulticastAddAnchor.Translation",
    "MulticastAddTunnelPoint.Translation",
    "MulticastInitializeWall.WallStartLocation",
    "MulticastInitializeWall.WallEndLocation",
    "MulticastInitializeTrapAnchors.WallStartPoint",
    "MulticastInitializeTrapAnchors.WallEndPoint",
    "MulticastInitialize.Destination",
    "MulticastNotifySetLife.NewLife",
    "MulticastNotifyDamage_Point.bDamageKilledTarget",
    "MulticastNotifyDamage_Point.EquippableUsed",
    "MulticastNotifyDamage_Base.bDamageKilledTarget",
    "MulticastNotifyDamage_Base.EquippableUsed",
];

/// The whole bytes of a value vrfkit left untyped; the analysis types the
/// few it reads (`analysis::raw_vector`).
fn untyped_bytes(field: &FieldRecord) -> Option<Vec<u8>> {
    let typed = field.value_i64.is_some()
        || field.value_f64.is_some()
        || field.value_bool.is_some()
        || field.value_str.is_some();
    let raw = field.raw_bits.as_deref()?;
    (!typed && field.bit_count % 8 == 0)
        .then(|| {
            raw.get(..(field.bit_count / 8) as usize)
                .map(<[u8]>::to_vec)
        })
        .flatten()
}

/// The Lotus A Link wall's calls.
const WALL_NET_CACHE: &str = "RespawningWallPlate_C_ClassNetCache";

/// An Ascent door's calls, whichever door: the call names its actor by GUID.
const SHUTTER_NET_CACHE: &str = "WindowShield_C_ClassNetCache";

/// One door state an Ascent door's `PlayDoorSounds` call carried: the state
/// it `entered`, or the one it left. A state of 0 isn't sent, so a call
/// without one of the two left or entered 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ShutterState {
    pub time: u32,
    pub actor: u32,
    pub entered: bool,
    /// `EAresDoorState`, a 3-bit enum.
    pub state: u8,
}

/// Whose door a group of fields is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DoorGroup {
    None,
    /// A Lotus or Summit door's own unnamed fields.
    Moves,
    /// A breakable wall's calls.
    Wall,
    /// An Ascent door's own fields, which name it.
    Shutter,
    /// Every Ascent door's calls.
    ShutterCalls,
}

fn door_group(group: &str) -> DoorGroup {
    if door_actor(group).is_some() {
        DoorGroup::Moves
    } else if group.ends_with(WALL_NET_CACHE) {
        DoorGroup::Wall
    } else if shutter_actor(group).is_some() {
        DoorGroup::Shutter
    } else if group.ends_with(SHUTTER_NET_CACHE) {
        DoorGroup::ShutterCalls
    } else {
        DoorGroup::None
    }
}

/// The Ascent door a group of fields belongs to, without the suffix a level
/// gives it: `WindowShieldA1`. Sunset has one too, `WindowShieldA3`.
pub fn shutter_actor(group: &str) -> Option<&str> {
    let actor = group.split("_UAID").next()?;
    (actor.len() > "WindowShield".len()
        && actor.starts_with("WindowShield")
        && !actor.contains('.'))
    .then_some(actor)
}

/// The door a group of fields belongs to, without the suffix a level gives it:
/// `Drawbridge5`, `DescentBox_v12`. None for anything else, such as
/// `Drawbridge_MinimapObject`.
pub fn door_actor(group: &str) -> Option<&str> {
    let actor = group.split("_UAID").next()?;
    let number = actor
        .strip_prefix("Drawbridge")
        .or_else(|| actor.strip_prefix("DescentBox_v"))?;
    (!number.is_empty() && number.bytes().all(|b| b.is_ascii_digit())).then_some(actor)
}

fn wanted(name: &str) -> bool {
    if EXACT.contains(&name) {
        return true;
    }
    let path = crate::fieldpath::FieldPath::parse(name);
    let first = path.segments.first().map_or("", |s| s.base);
    let last = path.leaf();
    match first {
        "RoundResults" => true,
        "AbilityCastsThisRound" => {
            path.segments.len() == 2
                && matches!(
                    last,
                    "Player" | "Slot" | "Round" | "CastTime" | "CastLocation"
                )
        }
        "Rounds" => matches!(last, "ParticipantSubject" | "ParticipantTeamName"),
        // `<Function>.LifeChangeEvents[i].<member>` (or `LifeChangeBySection`):
        // the damage, heal, decay and reset RPCs (docs/DATA.md, "Health is absolute").
        _ => {
            path.segments.len() == 3
                && matches!(
                    path.segments[1].base,
                    "LifeChangeEvents" | "LifeChangeBySection"
                )
                && matches!(last, "ChangedComponent" | "LifeResult")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ascent_door_is_named_by_its_own_group() {
        assert_eq!(shutter_actor("WindowShieldA1"), Some("WindowShieldA1"));
        assert_eq!(
            shutter_actor("WindowShieldB1_UAID_2C58B90EE7EFB17102_1686271982"),
            Some("WindowShieldB1"),
        );
        assert_eq!(shutter_actor("WindowShield.WindowShield_C_ClassNetCache"), None);
        assert_eq!(door_group("WindowShield.WindowShield_C_ClassNetCache"), DoorGroup::ShutterCalls);
        assert_eq!(door_group("WindowShieldA1"), DoorGroup::Shutter);
        assert_eq!(door_group("Drawbridge5"), DoorGroup::Moves);
    }

    #[test]
    fn only_a_door_is_a_door_actor() {
        assert_eq!(door_actor("Drawbridge5"), Some("Drawbridge5"));
        assert_eq!(
            door_actor("DescentBox_v12_UAID_2C58B90EE7EFB17102_1686271982"),
            Some("DescentBox_v12"),
        );
        assert_eq!(
            door_actor("Drawbridge_MinimapObject.Drawbridge_MinimapObject_C"),
            None
        );
        assert_eq!(
            door_actor("DescentBox_v5.DescentBox_v5_C_ClassNetCache"),
            None
        );
    }

    #[test]
    fn records_past_the_retained_cap_are_refused() {
        // vrfkit clones an actor's class path into every record of it, so a
        // long path opened often adds up without the wire growing.
        let opens = RecordBuffers {
            actors: vec![
                ActorRecord {
                    class_path: Some("/Game/X".repeat(1024)),
                    ..ActorRecord::default()
                };
                4
            ],
            ..RecordBuffers::default()
        };
        let cache = NetGuidCache::new();
        let mut collector = Collector::default();
        collector.on_packet(&opens, &cache).unwrap();
        assert_eq!(collector.actors.len(), 4);

        collector.retained = MAX_RETAINED_BYTES - 1024;
        let err = collector.on_packet(&opens, &cache).unwrap_err();
        assert_eq!(err.code, crate::error::ErrorCode::Corrupt);
        assert_eq!(collector.actors.len(), 4, "the refused packet is not kept");
    }
}
