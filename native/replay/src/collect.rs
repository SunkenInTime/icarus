//! The [`Observer`] the decode runs: keeps the few thousand rows the analysis
//! reads out of the million a match replicates, plus actors, movement,
//! events and the transform guard's sample.

use std::sync::Arc;

use vrf_export::{ActorRecord, EventRecord, FieldRecord};
use vrf_schema::NetGuidCache;

use crate::decode::Observer;
use crate::guard::GuardSample;
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
    /// `wanted` per interned name; the `Arc` held here keeps its address unique.
    verdicts: std::collections::HashMap<usize, (Arc<str>, bool)>,
}

impl Observer for Collector {
    fn on_event(&mut self, event: EventRecord) {
        self.events.push(event);
    }

    fn on_packet(&mut self, records: &RecordBuffers, _cache: &NetGuidCache) {
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
            self.rows.push(Row {
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
            });
        }
    }
}

/// Field names whose rows the analysis reads (see each consumer for why).
const EXACT: &[&str] = &[
    "Money",
    "Owner",
    "Instigator",
    "AggregateAssists",
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
