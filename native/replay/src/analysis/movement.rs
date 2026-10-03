//! Movement records (docs/replay-format.md, "Movement records"): every
//! decoded move of every body a player had, sorted by time.
//!
//! Positions are kept wherever they are. The only off-map ones in our corpus
//! (c8989335, 5,245 records around x -50000, z -49900) are the two players of
//! each Iso Kill Contract, which duels them in an arena built off the map;
//! vrfkit docs/DATA.md reads that spot as hidden actors parking, but every
//! such record falls in a Kill Contract window.

use std::collections::{BTreeMap, HashMap};

use super::Context;
use crate::collect::Move;
use crate::container::MovementSample;
use crate::document::MovementSpan;

/// The wire's pitch is 0..360 with looking down past 360; the contract's is
/// signed, positive up.
fn signed_pitch(pitch: f32) -> f32 {
    if pitch > 180.0 { pitch - 360.0 } else { pitch }
}

pub(super) fn movement(
    cx: &mut Context<'_>,
    moves: &[Move],
) -> (BTreeMap<String, MovementSpan>, Vec<u8>) {
    let mut by_body: HashMap<u32, Vec<&Move>> = HashMap::new();
    for m in moves {
        by_body.entry(m.character).or_default().push(m);
    }
    let mut blob = Vec::new();
    let mut spans = BTreeMap::new();
    for p in &cx.players {
        let mut mine: Vec<&Move> = p
            .bodies
            .iter()
            .filter(|b| cx.body_subject.get(b) == Some(&p.subject))
            .flat_map(|b| by_body.get(b).into_iter().flatten().copied())
            .collect();
        // Stable: moves sharing a millisecond keep wire order.
        mine.sort_by_key(|m| m.time);
        let offset = blob.len() as u64;
        for m in &mine {
            MovementSample {
                time_ms: i32::try_from(m.time).unwrap_or(i32::MAX),
                x: m.pos[0],
                y: m.pos[1],
                z: m.pos[2],
                yaw: m.yaw,
                pitch: signed_pitch(m.pitch),
            }
            .write_to(&mut blob);
        }
        spans.insert(
            p.subject.clone(),
            MovementSpan {
                offset,
                count: mine.len() as u64,
            },
        );
    }
    // An agent body no player claims is movement lost from the document.
    // Other pawns move too (drones, turrets, Clove's post-death form); they
    // are utility or no one's position, so they are not counted.
    let lost: usize = by_body
        .iter()
        .filter(|(guid, _)| !cx.body_subject.contains_key(guid))
        .filter(|(guid, _)| cx.actor_class.get(guid).is_some_and(|c| is_agent_body(c)))
        .map(|(_, list)| list.len())
        .sum();
    if lost > 0 {
        cx.warnings.push(format!(
            "{lost} movement record(s) of agent bodies no player claims (dropped)"
        ));
    }
    (spans, blob)
}

/// `/Game/Characters/<Agent>/<Agent>_PC.<Agent>_PC_C`: a player's body.
fn is_agent_body(class_path: &str) -> bool {
    let mut parts = class_path.split('/');
    let (Some(""), Some("Game"), Some("Characters"), Some(agent), Some(leaf), None) = (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) else {
        return false;
    };
    leaf == format!("{agent}_PC.{agent}_PC_C")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pitch_is_signed() {
        assert_eq!(signed_pitch(10.0), 10.0);
        assert_eq!(signed_pitch(350.0), -10.0);
    }

    #[test]
    fn agent_bodies_are_told_from_other_pawns() {
        assert!(is_agent_body("/Game/Characters/Wushu/Wushu_PC.Wushu_PC_C"));
        assert!(!is_agent_body(
            "/Game/Characters/Smonk/PostDeath/Smonk_PostDeath_PC.Smonk_PostDeath_PC_C"
        ));
        assert!(!is_agent_body(
            "/Game/Characters/Killjoy/S0/Ability_E/Pawn_Killjoy_E_Turret.Pawn_Killjoy_E_Turret_C"
        ));
        assert!(!is_agent_body("/Game/Characters/Wushu/Wushu_PC.Other_C"));
    }
}
