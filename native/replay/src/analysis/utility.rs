//! Utility: every world object an agent ability spawns, from actor open to
//! close. The class rule is tools/extract_ability_lifecycle.py's
//! `classify_candidate` (below `/Game/Characters/<agent>/` with an ability
//! path segment), minus the held ability items themselves (`Ability_*`,
//! `Equippable_*`), which live in inventories rather than the world.
//! Owners come from `Owner`/`Instigator` as that tool reads them, followed to
//! a player's body (`Context::subject_behind`).

use std::collections::HashMap;

use super::{Context, parse_vector};
use crate::document::{Utility, Vec3};

pub(super) fn utility(cx: &mut Context<'_>) -> Vec<Utility> {
    // ReplicatedMovement locations and wall points, per actor, in order.
    let mut moves: HashMap<u32, Vec<[f64; 4]>> = HashMap::new();
    let mut points: HashMap<u32, Vec<Vec3>> = HashMap::new();
    for row in cx.rows.iter().filter(|r| r.object.is_none()) {
        match &*row.name {
            "ReplicatedMovement" => {
                if let Some(loc) = row.text.as_deref().and_then(movement_location) {
                    moves.entry(row.actor).or_default().push([
                        f64::from(row.time),
                        loc[0],
                        loc[1],
                        loc[2],
                    ]);
                }
            }
            "MulticastAddSmokeScreenPoint.Translation" => {
                if let Some(p) = row.text.as_deref().and_then(parse_vector) {
                    points.entry(row.actor).or_default().push(p);
                }
            }
            _ => {}
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
                let first_move = moves.get(&a.actor_net_guid).and_then(|m| {
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
                if owner.is_none() {
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
                    yaw: a.spawn_yaw.map(f64::from),
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
    for u in &mut out {
        let within = |t: f64| t >= u.spawn_ms as f64 && u.end_ms.is_none_or(|e| t <= e as f64);
        if let Some(m) = moves.get(&u.id) {
            let mut path: Vec<[f64; 4]> = Vec::new();
            for p in m.iter().filter(|p| within(p[0])) {
                // Consecutive repeats of one location say nothing new.
                if path.last().is_none_or(|l| l[1..] != p[1..]) {
                    path.push(*p);
                }
            }
            if path.len() > 1 || path.first().is_some_and(|p| p[1..] != u.position[..]) {
                u.path = Some(path);
            }
        }
        if let Some(p) = points.get(&u.id) {
            u.points = Some(p.clone());
        }
    }
    for (n, what) in [
        (no_position, "utility actor(s) with no position (dropped)"),
        (reopened, "utility actor GUID(s) reopened while open"),
        (no_owner, "utility actor(s) with no player owner"),
    ] {
        if n > 0 {
            cx.warnings.push(format!("{n} {what}"));
        }
    }
    out
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
