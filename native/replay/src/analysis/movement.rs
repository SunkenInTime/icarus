//! Movement records (docs/replay-format.md, "Movement records"): every
//! decoded move of every body a player had, sorted by time, minus the
//! moves of a body parked off-map between lives.

use std::collections::BTreeMap;

use super::Context;
use crate::collect::Move;
use crate::container::MovementSample;
use crate::document::MovementSpan;

/// docs/DATA.md ("Minimap projection"): hidden actors park at x ≈ -50000,
/// z ≈ -49900; both are checked, since a fall passes through that z alone.
/// A parked body drifts: c8989335's 5,245 parked moves span x -51020..-49008
/// but z only -49919..-49900.
fn parked(m: &Move) -> bool {
    (m.pos[0] + 50_000.0).abs() < 5_000.0 && (m.pos[2] + 49_900.0).abs() < 100.0
}

/// The wire's pitch is 0..360 with looking down past 360; the contract's is
/// signed, positive up.
fn signed_pitch(pitch: f32) -> f32 {
    if pitch > 180.0 { pitch - 360.0 } else { pitch }
}

pub(super) fn movement(
    cx: &mut Context<'_>,
    moves: &[Move],
) -> (BTreeMap<String, MovementSpan>, Vec<u8>) {
    let mut by_body: std::collections::HashMap<u32, Vec<&Move>> = std::collections::HashMap::new();
    for m in moves {
        by_body.entry(m.character).or_default().push(m);
    }
    let mut blob = Vec::new();
    let mut spans = BTreeMap::new();
    let mut dropped = 0usize;
    for p in &cx.players {
        let mut mine: Vec<&Move> = p
            .bodies
            .iter()
            .filter(|b| cx.body_subject.get(b) == Some(&p.subject))
            .flat_map(|b| by_body.get(b).into_iter().flatten().copied())
            .collect();
        let before = mine.len();
        mine.retain(|m| !parked(m));
        dropped += before - mine.len();
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
    // Pawns that move but are no `SpawnedCharacter` body: possessed devices,
    // Clove's post-death form. Named by class so a lost body would show.
    let mut unclaimed: BTreeMap<String, usize> = BTreeMap::new();
    for (guid, list) in &by_body {
        if !cx.body_subject.contains_key(guid) {
            let class = cx
                .actor_class
                .get(guid)
                .map_or("?", |c| c.rsplit('.').next().unwrap_or(c));
            *unclaimed.entry(class.to_owned()).or_default() += list.len();
        }
    }
    if !unclaimed.is_empty() {
        let list: Vec<String> = unclaimed.iter().map(|(c, n)| format!("{c} {n}")).collect();
        cx.warnings.push(format!(
            "movement of pawns that are no player's body: {}",
            list.join(", ")
        ));
    }
    if dropped > 0 {
        cx.warnings
            .push(format!("{dropped} parked movement record(s) dropped"));
    }
    (spans, blob)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parking_needs_both_x_and_z() {
        let at = |x: f32, z: f32| Move {
            time: 0,
            character: 1,
            pos: [x, 0.0, z],
            yaw: 0.0,
            pitch: 0.0,
        };
        assert!(parked(&at(-50_000.0, -49_900.0)));
        assert!(parked(&at(-51_020.0, -49_919.0)), "a drifting parked body");
        assert!(!parked(&at(-50_000.0, 100.0)));
        assert!(
            !parked(&at(1_000.0, -49_900.0)),
            "a fall passes through that z"
        );
    }

    #[test]
    fn pitch_is_signed() {
        assert_eq!(signed_pitch(10.0), 10.0);
        assert_eq!(signed_pitch(350.0), -10.0);
    }
}
