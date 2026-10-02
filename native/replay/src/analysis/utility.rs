//! Utility: every world object an agent ability spawns, from actor open to
//! close. The class rule is tools/extract_ability_lifecycle.py's
//! `classify_candidate` (below `/Game/Characters/<agent>/` with an ability
//! path segment), minus the held ability items themselves (`Ability_*`,
//! `Equippable_*`), which live in inventories rather than the world.
//! Owners come from `Owner`/`Instigator` as that tool reads them, followed to
//! a player's body (`Context::subject_behind`). Actors the match places as
//! the first round starts (Iso's Kill Contract arenas, off the map) belong to
//! no one; anything later should have a thrower.
//!
//! A path is where the actor went: `ReplicatedMovement` for projectiles and
//! moving walls, and for pawns (Boom Bot, drones, cameras, Wingman) the
//! movement records vrfkit decodes for every pawn, thinned to about 10 Hz.
//! Shape points come from each family's own RPCs (docs/replay-format.md,
//! "Utility shape points").

use std::collections::HashMap;

use super::{Context, parse_vector, raw_vector, value_at};
use crate::collect::Move;
use crate::document::{Utility, Vec3};

/// Kept path points are at least this far apart in time, about 10 Hz; the
/// last point is always kept.
const PATH_STEP_MS: f64 = 100.0;

pub(super) fn utility(
    cx: &mut Context<'_>,
    moves: &[Move],
    first_round_ms: Option<i64>,
) -> Vec<Utility> {
    // Where each actor was, `[time, x, y, z]`, and its shape points
    // `(time, point)`, in wire order.
    let mut tracks: HashMap<u32, Vec<[f64; 4]>> = HashMap::new();
    let mut points: HashMap<u32, Vec<(u32, Vec3)>> = HashMap::new();
    // Barrier Mesh arms: each deployer's destination, filed under the root
    // that owns it once the deployers' owners are known.
    let mut destinations: Vec<(u32, u32, Vec3)> = Vec::new();
    for row in cx.rows.iter().filter(|r| r.object.is_none()) {
        let mut point = |p: Option<Vec3>| {
            if let Some(p) = p {
                points.entry(row.actor).or_default().push((row.time, p));
            }
        };
        match &*row.name {
            "ReplicatedMovement" => {
                if let Some(loc) = row.text.as_deref().and_then(movement_location) {
                    tracks.entry(row.actor).or_default().push([
                        f64::from(row.time),
                        loc[0],
                        loc[1],
                        loc[2],
                    ]);
                }
            }
            // Phoenix's Blaze and Viper's Toxic Screen.
            "MulticastAddSmokeScreenPoint.Translation" => {
                point(row.text.as_deref().and_then(parse_vector));
            }
            // Neon's Fast Lane, then Vyse's Shear wall and its trap.
            "MulticastAddTunnelPoint.Translation"
            | "MulticastInitializeWall.WallStartLocation"
            | "MulticastInitializeWall.WallEndLocation"
            | "MulticastInitializeTrapAnchors.WallStartPoint"
            | "MulticastInitializeTrapAnchors.WallEndPoint" => {
                point(row.raw.as_deref().and_then(raw_vector));
            }
            "MulticastInitialize.Destination" => {
                if let Some(p) = row.raw.as_deref().and_then(raw_vector) {
                    destinations.push((row.time, row.actor, p));
                }
            }
            _ => {}
        }
    }
    for m in moves {
        if cx
            .actor_class
            .get(&m.character)
            .is_some_and(|c| is_utility(c))
        {
            let [x, y, z] = m.pos.map(f64::from);
            tracks
                .entry(m.character)
                .or_default()
                .push([f64::from(m.time), x, y, z]);
        }
    }
    for track in tracks.values_mut() {
        // Stable: rows sharing a millisecond keep wire order.
        track.sort_by(|a, b| a[0].total_cmp(&b[0]));
    }
    for (time, deployer, p) in destinations {
        let root = cx
            .owner_writes
            .get(&deployer)
            .and_then(|w| value_at(w, time));
        if let Some(root) = root {
            points.entry(root).or_default().push((time, p));
        }
    }

    let mut open: HashMap<u32, usize> = HashMap::new();
    let mut out: Vec<Utility> = Vec::new();
    let (mut no_position, mut reopened, mut no_owner) = (0, 0, 0);
    for a in cx.actors {
        match a.event {
            "open" => {
                let Some(class) = a.class_path.as_deref().filter(|c| is_utility(c)) else {
                    continue;
                };
                if open.contains_key(&a.actor_net_guid) {
                    reopened += 1;
                }
                let spawn = match (a.spawn_x, a.spawn_y, a.spawn_z) {
                    (Some(x), Some(y), Some(z)) => Some([f64::from(x), f64::from(y), f64::from(z)]),
                    _ => None,
                };
                let first_move = tracks.get(&a.actor_net_guid).and_then(|m| {
                    m.iter()
                        .find(|p| p[0] >= f64::from(a.time_ms))
                        .map(|p| [p[1], p[2], p[3]])
                });
                let Some(position) = spawn.or(first_move) else {
                    no_position += 1;
                    continue;
                };
                let owner = cx
                    .subject_behind(a.actor_net_guid, a.time_ms)
                    .map(str::to_owned);
                if owner.is_none() && first_round_ms.is_some_and(|t| i64::from(a.time_ms) > t) {
                    no_owner += 1;
                }
                open.insert(a.actor_net_guid, out.len());
                out.push(Utility {
                    id: a.actor_net_guid,
                    class_path: class.to_owned(),
                    owner,
                    spawn_ms: i64::from(a.time_ms),
                    end_ms: None,
                    position,
                    // A spawn block carries its rotation only when it is not
                    // zero (vrf-net's spawn.rs reads it behind a flag bit), so
                    // a spawned actor without one faces yaw 0.
                    yaw: a.spawn_yaw.map(f64::from).or(spawn.map(|_| 0.0)),
                    path: None,
                    points: None,
                });
            }
            // Dormancy is not destruction (vrfkit CLAUDE.md): only a close ends it.
            "close" => {
                if let Some(i) = open.remove(&a.actor_net_guid) {
                    out[i].end_ms = Some(i64::from(a.time_ms));
                }
            }
            _ => {}
        }
    }
    trapwire_far_ends(cx, &out, &mut points);
    for u in &mut out {
        let within = |t: f64| t >= u.spawn_ms as f64 && u.end_ms.is_none_or(|e| t <= e as f64);
        if let Some(track) = tracks.get(&u.id) {
            let path = thin(track.iter().copied().filter(|p| within(p[0])));
            if path.len() > 1 || path.first().is_some_and(|p| p[1..] != u.position[..]) {
                // Track times are whole milliseconds off the wire.
                u.path = Some(
                    path.iter()
                        .map(|p| (p[0] as i64, p[1], p[2], p[3]))
                        .collect(),
                );
            }
        }
        let mine: Vec<Vec3> = points
            .get(&u.id)
            .into_iter()
            .flatten()
            .filter(|(t, _)| within(f64::from(*t)))
            .map(|&(_, p)| p)
            .collect();
        if !mine.is_empty() {
            u.points = Some(mine);
        }
    }
    for (n, what) in [
        (no_position, "utility actor(s) with no position (dropped)"),
        (reopened, "utility actor GUID(s) reopened while open"),
        (
            no_owner,
            "utility actor(s) spawned in play with no player owner",
        ),
    ] {
        if n > 0 {
            cx.warnings.push(format!("{n} {what}"));
        }
    }
    out
}

/// Cypher's Trapwire opens with a `_SecondWire` actor at its far anchor, in
/// the same millisecond and under the same `Owner`; that anchor becomes the
/// wire's one shape point.
fn trapwire_far_ends(
    cx: &Context<'_>,
    out: &[Utility],
    points: &mut HashMap<u32, Vec<(u32, Vec3)>>,
) {
    let owner = |u: &Utility| {
        let time = u32::try_from(u.spawn_ms).ok()?;
        cx.owner_writes.get(&u.id).and_then(|w| value_at(w, time))
    };
    let is = |u: &Utility, asset: &str| u.class_path.rsplit('.').next() == Some(asset);
    for far in out
        .iter()
        .filter(|u| is(u, "GameObject_Gumshoe_E_TripWire_SecondWire_C"))
    {
        let wires: Vec<&Utility> = out
            .iter()
            .filter(|u| is(u, "GameObject_Gumshoe_E_TripWire_C"))
            .filter(|u| u.spawn_ms == far.spawn_ms && owner(u).is_some() && owner(u) == owner(far))
            .collect();
        if let [wire] = wires.as_slice() {
            let time = u32::try_from(far.spawn_ms).unwrap_or(u32::MAX);
            points
                .entry(wire.id)
                .or_default()
                .push((time, far.position));
        }
    }
}

/// Consecutive repeats dropped, then one point per [`PATH_STEP_MS`], and the
/// last.
fn thin(track: impl Iterator<Item = [f64; 4]>) -> Vec<[f64; 4]> {
    let mut moved: Vec<[f64; 4]> = Vec::new();
    for p in track {
        if moved.last().is_none_or(|l| l[1..] != p[1..]) {
            moved.push(p);
        }
    }
    let last = moved.len().saturating_sub(1);
    let mut path: Vec<[f64; 4]> = Vec::new();
    for (i, p) in moved.into_iter().enumerate() {
        if i == last || path.last().is_none_or(|k| p[0] - k[0] >= PATH_STEP_MS) {
            path.push(p);
        }
    }
    path
}

/// `/Game/Characters/<agent>/…/Ability_*|Abilities/…/<Object>.<Object>_C`,
/// not the held `Ability_*` / `Equippable_*` item.
fn is_utility(class_path: &str) -> bool {
    let parts: Vec<&str> = class_path.split('/').collect();
    if parts.len() < 5 || parts[..3] != ["", "Game", "Characters"] || parts[3].starts_with('_') {
        return false;
    }
    let ability_segment = parts[4..parts.len() - 1].iter().any(|p| {
        let p = p.to_ascii_lowercase();
        p == "abilities" || p.starts_with("ability_")
    });
    let leaf = parts[parts.len() - 1];
    ability_segment && !leaf.starts_with("Ability_") && !leaf.starts_with("Equippable_")
}

/// `location` of a ReplicatedMovement JSON object, in world units.
fn movement_location(json: &str) -> Option<Vec3> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let l = &v["location"];
    Some([l["x"].as_f64()?, l["y"].as_f64()?, l["z"].as_f64()?])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_drop_repeats_and_keep_ten_points_a_second_and_the_last() {
        let at = |t: f64, x: f64| [t, x, 0.0, 0.0];
        let track = [
            at(0.0, 0.0),
            at(8.0, 0.0),
            at(16.0, 1.0),
            at(96.0, 2.0),
            at(120.0, 3.0),
            at(130.0, 4.0),
        ];
        assert_eq!(
            thin(track.into_iter()),
            vec![at(0.0, 0.0), at(120.0, 3.0), at(130.0, 4.0)]
        );
        assert_eq!(thin(std::iter::empty()), Vec::<[f64; 4]>::new());
    }

    #[test]
    fn world_objects_are_utility_and_held_items_are_not() {
        assert!(is_utility(
            "/Game/Characters/Killjoy/S0/Ability_Q/Pawn_Killjoy_Q_StealthAlarmbot.Pawn_Killjoy_Q_StealthAlarmbot_C"
        ));
        assert!(is_utility(
            "/Game/Characters/Sarge/S0/Ability_MapTargetSmoke/GameObject_Sarge_4_Smoke_ProductionNEW.GameObject_Sarge_4_Smoke_ProductionNEW_C"
        ));
        assert!(!is_utility(
            "/Game/Characters/Killjoy/S0/Ability_Q/Ability_Killjoy_Q_Alarmbot.Ability_Killjoy_Q_Alarmbot_C"
        ));
        assert!(!is_utility(
            "/Game/Characters/Killjoy/Killjoy_PC.Killjoy_PC_C"
        ));
        assert!(!is_utility(
            "/Game/Characters/_Core/Equippable_Unarmed.Equippable_Unarmed_C"
        ));
        assert!(!is_utility(
            "/Game/Characters/Wushu/S0/Glide/Ability_Wushu_Passive_Glide.Ability_Wushu_Passive_Glide_C"
        ));
    }

    #[test]
    fn movement_json_gives_its_location() {
        let json = r#"{"linear_velocity":{"x":0,"y":0,"z":0},"angular_velocity":null,"location":{"x":7979,"y":3932,"z":592}}"#;
        assert_eq!(movement_location(json), Some([7979.0, 3932.0, 592.0]));
        assert_eq!(movement_location("{}"), None);
    }
}
