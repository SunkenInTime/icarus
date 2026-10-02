//! Ability casts from `Comp_AbilityStatisticsReplicator.AbilityCastsThisRound`
//! (docs/DATA.md, "Abilities"): `Player`, `Slot`, `Round`, `CastTime`,
//! `CastLocation`. The array accumulates over a round and is re-sent, so a
//! cast is one identity (player, round, slot, cast time), counted once.
//! `CastTime` counts from the round's buy-phase end, so a cast happened at
//! `combatStartMs + CastTime` ("`CastTime` is not measured from roundStarted").
//!
//! The array names a slot, not an ability. A cast lands within a few
//! milliseconds of the charge (`AuthResourceAmount`) its ability item spends
//! (0-3 ms on 1fb53a2c), so each (player, slot) takes the item class those
//! decrements agree on.
//! Where they do not agree, or never fire (an ultimate spends no charge),
//! `classPath` stays absent.

use std::collections::{BTreeMap, HashMap, HashSet};

use super::{Context, parse_vector, value_at};
use crate::document::{Cast, Round};
use crate::fieldpath::FieldPath;

/// An array element: (component actor, component object, index).
type ElementKey = (u32, Option<u32>, u32);

/// An element's state after one packet's writes to it.
struct Snapshot {
    time: u32,
    packet: u32,
    key: ElementKey,
    state: Element,
}

#[derive(Default, Clone)]
struct Element {
    player: Option<String>,
    slot: Option<i64>,
    round: Option<i64>,
    cast_time: Option<f64>,
    location: Option<String>,
}

pub(super) fn casts(cx: &mut Context<'_>, rounds: &[Round]) -> Vec<Cast> {
    // Replicated state per array element, and its state after each packet
    // that wrote to it.
    let mut elements: HashMap<ElementKey, Element> = HashMap::new();
    let mut snapshots: Vec<Snapshot> = Vec::new();
    for row in cx.rows {
        if !row.name.starts_with("AbilityCastsThisRound[") {
            continue;
        }
        let path = FieldPath::parse(&row.name);
        let Some(index) = path.segments[0].index else {
            continue;
        };
        let key = (row.actor, row.object, index);
        let e = elements.entry(key).or_default();
        match path.leaf() {
            "Player" => e.player = row.text.as_ref().map(|s| s.to_ascii_lowercase()),
            "Slot" => e.slot = row.int,
            "Round" => e.round = row.int,
            "CastTime" => e.cast_time = row.float,
            "CastLocation" => e.location = row.text.clone(),
            _ => continue,
        }
        let state = e.clone();
        match snapshots.last_mut() {
            Some(last) if last.packet == row.packet && last.key == key => last.state = state,
            _ => snapshots.push(Snapshot {
                time: row.time,
                packet: row.packet,
                key,
                state,
            }),
        }
    }

    // Identities in first-send order.
    let mut seen: HashSet<(String, i64, i64, u64)> = HashSet::new();
    let mut found: Vec<(u32, Element)> = Vec::new();
    for Snapshot {
        time,
        state: element,
        ..
    } in snapshots
    {
        let (Some(player), Some(slot), Some(round), Some(cast_time)) = (
            element.player.clone(),
            element.slot,
            element.round,
            element.cast_time,
        ) else {
            continue;
        };
        if seen.insert((player, round, slot, cast_time.to_bits())) {
            found.push((time, element));
        }
    }

    // `Round` is the game's round number; rounds warn where it is not their index.
    let buy_end: HashMap<i64, i64> = rounds
        .iter()
        .filter_map(|r| Some((i64::from(r.index), r.combat_start_ms?)))
        .collect();
    let mut unplaced = 0;
    let timed: Vec<(i64, Element)> = found
        .into_iter()
        .map(|(first_send, e)| {
            let cast_ms = e
                .round
                .and_then(|r| buy_end.get(&r))
                .map(|&b| b + (e.cast_time.expect("identity has a time") * 1000.0).round() as i64);
            if cast_ms.is_none() {
                unplaced += 1;
            }
            (cast_ms.unwrap_or(i64::from(first_send)), e)
        })
        .collect();
    let classes = slot_classes(cx, &timed);
    let mut casts: Vec<Cast> = timed
        .into_iter()
        .map(|(time_ms, e)| {
            let player = e.player.expect("identity has a player");
            let slot = e.slot.expect("identity has a slot");
            Cast {
                time_ms,
                class_path: classes.get(&(player.clone(), slot)).cloned(),
                subject: player,
                slot,
                position: e.location.as_deref().and_then(parse_vector),
            }
        })
        .collect();
    casts.sort_by(|a, b| (a.time_ms, &a.subject).cmp(&(b.time_ms, &b.subject)));
    if unplaced > 0 {
        cx.warnings.push(format!(
            "{unplaced} cast(s) in a round with no buy-phase end; timed by first send"
        ));
    }
    let unnamed = casts.iter().filter(|c| c.class_path.is_none()).count();
    if unnamed > 0 {
        cx.warnings.push(format!(
            "{unnamed} of {} cast(s) without an ability class",
            casts.len()
        ));
    }
    casts
}

/// (player, slot) -> ability item class, where the charge decrements in each
/// cast's first-send packet name one class without dissent, and no other
/// slot of that player names it too (Reyna's two abilities spend one pool).
/// Only ability items count: a gun's ammo is an `AuthResourceAmount` too.
fn slot_classes(cx: &Context<'_>, casts: &[(i64, Element)]) -> HashMap<(String, i64), String> {
    /// Spends within this of the cast belong to it.
    const WINDOW_MS: i64 = 10;
    // Charge decrements: (time, ability actor).
    let mut last: HashMap<(u32, Option<u32>), i64> = HashMap::new();
    let mut spends: Vec<(i64, u32)> = Vec::new();
    for row in cx.rows.iter().filter(|r| {
        &*r.name == "AuthResourceAmount"
            && (r.group.ends_with("EquipmentChargeComponent")
                || r.group.ends_with("SignatureAbilityResourceComponent"))
    }) {
        let Some(v) = row.int else { continue };
        if let Some(before) = last.insert((row.actor, row.object), v) {
            if v < before {
                spends.push((i64::from(row.time), row.actor));
            }
        }
    }
    let mut votes: BTreeMap<(String, i64), BTreeMap<String, u32>> = BTreeMap::new();
    for (time, e) in casts {
        let (Some(player), Some(slot)) = (&e.player, e.slot) else {
            continue;
        };
        let mut candidates: Vec<String> = spends
            .iter()
            .filter(|&&(t, _)| (t - time).abs() <= WINDOW_MS)
            .filter(|&&(t, item)| {
                cx.owner_writes
                    .get(&item)
                    .and_then(|w| value_at(w, u32::try_from(t).unwrap_or(0)))
                    .and_then(|owner| cx.body_subject.get(&owner))
                    == Some(player)
            })
            .filter_map(|&(_, item)| cx.actor_class.get(&item).cloned())
            .filter(|class| is_ability_item(class))
            .collect();
        candidates.dedup();
        if let [class] = candidates.as_slice() {
            *votes
                .entry((player.clone(), slot))
                .or_default()
                .entry(class.clone())
                .or_default() += 1;
        }
    }
    let agreed: Vec<((String, i64), String)> = votes
        .into_iter()
        .filter_map(|(key, classes)| {
            (classes.len() == 1).then(|| (key, classes.into_keys().next().expect("one")))
        })
        .collect();
    let mut claims: HashMap<(&str, &str), u32> = HashMap::new();
    for ((player, _), class) in &agreed {
        *claims.entry((player, class)).or_default() += 1;
    }
    agreed
        .iter()
        .filter(|((player, _), class)| claims[&(player.as_str(), class.as_str())] == 1)
        .cloned()
        .collect()
}

/// An agent's held ability item: `/Game/Characters/<agent>/…/Ability_*_C`.
fn is_ability_item(class: &str) -> bool {
    class.starts_with("/Game/Characters/")
        && class
            .rsplit('/')
            .next()
            .is_some_and(|leaf| leaf.starts_with("Ability_"))
}
