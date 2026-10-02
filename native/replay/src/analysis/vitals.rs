//! Health and armour per player (docs/replay-format.md, "vitals").
//!
//! Health is the absolute `LifeResult` that the damage, heal and reset RPCs
//! carry per damage section (vrfkit docs/DATA.md, "Health is absolute, not a
//! subtraction"), read off each body's `HealthDamageSection`. Every round
//! opens at 100: the game resets every body with `MulticastSectionLifeChange`
//! a millisecond after `roundStarted`, except in the first round, whose bodies
//! spawn full and are never reset. A revive (Sage, Clove) is the same reset.
//!
//! Armour is an item with an `AttachedDamageSection` ("Armour is
//! `AttachedDamageSection`, not `ShieldDamageSection`"). Bought, it opens
//! owned by the buyer's body, at its class's full points: a full value is
//! never replicated, only later ones, through the damage RPCs and, while a
//! regen shield refills, `MulticastNotifySetLife`. A player wears the item
//! last assigned to one of their bodies until it closes (sold back, or gone
//! after a round they died in). An `Owner` of 0 changes nothing: survivors'
//! items are unowned for the moment between rounds and come back to their
//! next body, and a replaced item is superseded by its replacement.

use std::collections::{BTreeMap, HashMap, HashSet};

use super::Context;
use crate::document::{Round, VitalsRow};
use crate::fieldpath::FieldPath;

/// Health every body starts a round with.
const FULL_HEALTH: f64 = 100.0;

/// One thing that moves a player's vitals, at a time.
#[derive(Debug, Clone, PartialEq)]
enum Change {
    RoundStart,
    Health {
        subject: String,
        value: f64,
    },
    /// An armour item handed to one of the player's bodies.
    Assigned {
        subject: String,
        item: u32,
    },
    Reported {
        item: u32,
        value: f64,
    },
    Closed {
        item: u32,
    },
}

pub(super) fn vitals(cx: &mut Context<'_>, rounds: &[Round]) -> BTreeMap<String, Vec<VitalsRow>> {
    let mut changes: Vec<(u32, Change)> = rounds
        .iter()
        .filter_map(|r| Some((u32::try_from(r.start_ms).ok()?, Change::RoundStart)))
        .collect();

    // Armour items and their full points, by actor.
    let full: HashMap<u32, f64> = cx
        .actor_class
        .iter()
        .filter_map(|(&item, class)| Some((item, super::rounds::armor_points(class)? as f64)))
        .collect();
    for (&item, writes) in &cx.owner_writes {
        if !full.contains_key(&item) {
            continue;
        }
        for &(time, owner) in writes {
            if let Some(subject) = cx.body_subject.get(&owner) {
                let subject = subject.clone();
                changes.push((time, Change::Assigned { subject, item }));
            }
        }
    }
    for a in cx.actors {
        if a.event == "close" && full.contains_key(&a.actor_net_guid) {
            changes.push((
                a.time_ms,
                Change::Closed {
                    item: a.actor_net_guid,
                },
            ));
        }
    }

    // Every section result, in wire order: one life-change element's
    // `ChangedComponent` and `LifeResult` arrive as separate rows of one call.
    let mut results: Vec<(u32, u32, f64)> = Vec::new();
    let mut elements: HashMap<ElementKey<'_>, (Option<u32>, Option<f64>)> = HashMap::new();
    let mut order: Vec<(u32, ElementKey<'_>)> = Vec::new();
    for row in cx.rows {
        if &*row.name == "MulticastNotifySetLife.NewLife" {
            if let (Some(section), Some(value)) = (row.object, row.float) {
                results.push((row.time, section, value));
            }
            continue;
        }
        let path = FieldPath::parse(&row.name);
        if path.segments.len() != 3
            || !matches!(
                path.segments[1].base,
                "LifeChangeEvents" | "LifeChangeBySection"
            )
        {
            continue;
        }
        let key = (
            row.packet,
            row.actor,
            row.object,
            path.indices(),
            path.segments[0].base,
        );
        let slot = elements.entry(key.clone()).or_insert_with(|| {
            order.push((row.time, key));
            (None, None)
        });
        match path.leaf() {
            "ChangedComponent" => slot.0 = row.int.and_then(|v| u32::try_from(v).ok()),
            "LifeResult" => slot.1 = row.float,
            _ => {}
        }
    }
    for (time, key) in order {
        if let (Some(section), Some(value)) = elements[&key] {
            results.push((time, section, value));
        }
    }

    // A section is a body's health or an armour item's armour by its name
    // and outer in the GUID table; shield, overheal and ability sections are
    // neither.
    let mut health_results = 0;
    for (time, section, value) in results {
        let Some(outer) = cx.cache.get_outer_guid(section).map(|o| o.0) else {
            continue;
        };
        match cx.cache.get_path_by_guid(section) {
            Some("HealthDamageSection") => {
                if let Some(subject) = cx.body_subject.get(&outer) {
                    health_results += 1;
                    let subject = subject.clone();
                    changes.push((time, Change::Health { subject, value }));
                }
            }
            Some("AttachedDamageSection") if full.contains_key(&outer) => {
                changes.push((time, Change::Reported { item: outer, value }));
            }
            _ => {}
        }
    }
    if health_results == 0 {
        cx.warnings
            .push("no health results replicated: vitals hold only each round's start".to_owned());
    }

    // Stable: round starts lead their millisecond, the wire keeps its order.
    changes.sort_by_key(|c| c.0);
    let subjects: Vec<&str> = cx.players.iter().map(|p| p.subject.as_str()).collect();
    fold(&subjects, &full, changes)
}

/// One life-change element: (packet, actor, component, element indices,
/// function).
type ElementKey<'r> = (u32, u32, Option<u32>, Vec<Option<u32>>, &'r str);

/// Play `changes` (in time order) into rows: one per player at every round
/// start, then one per change. Health is unknown until the first round
/// starts, so no row precedes it.
fn fold(
    subjects: &[&str],
    full: &HashMap<u32, f64>,
    changes: Vec<(u32, Change)>,
) -> BTreeMap<String, Vec<VitalsRow>> {
    let mut health: HashMap<String, f64> = HashMap::new();
    let mut worn: HashMap<String, u32> = HashMap::new();
    let mut wearer: HashMap<u32, String> = HashMap::new();
    let mut reported: HashMap<u32, f64> = HashMap::new();
    let mut closed: HashSet<u32> = HashSet::new();
    let mut out: BTreeMap<String, Vec<VitalsRow>> = BTreeMap::new();
    let mut started = false;

    for (time, change) in changes {
        let round_start = change == Change::RoundStart;
        started |= round_start;
        let touched: Vec<String> = match change {
            Change::RoundStart => {
                for &s in subjects {
                    health.insert(s.to_owned(), FULL_HEALTH);
                }
                subjects.iter().map(|&s| s.to_owned()).collect()
            }
            Change::Health { subject, value } => {
                health.insert(subject.clone(), round2(value));
                vec![subject]
            }
            Change::Assigned { subject, item } => {
                worn.insert(subject.clone(), item);
                wearer.insert(item, subject.clone());
                vec![subject]
            }
            Change::Reported { item, value } => {
                reported.insert(item, round2(value));
                wearer.get(&item).cloned().into_iter().collect()
            }
            Change::Closed { item } => {
                closed.insert(item);
                wearer.get(&item).cloned().into_iter().collect()
            }
        };
        if !started {
            continue;
        }
        for subject in touched {
            let Some(&h) = health.get(&subject) else {
                continue;
            };
            let armor = worn
                .get(&subject)
                .filter(|item| !closed.contains(item))
                .and_then(|item| reported.get(item).or(full.get(item)))
                .copied()
                .unwrap_or(0.0);
            let rows = out.entry(subject).or_default();
            push(rows, (i64::from(time), h, armor), round_start);
        }
    }
    out
}

/// Append `row` unless it repeats the last row's values and is not forced;
/// a row at the last row's millisecond replaces it.
fn push(rows: &mut Vec<VitalsRow>, row: VitalsRow, force: bool) {
    if let Some(last) = rows.last() {
        if !force && (last.1, last.2) == (row.1, row.2) {
            return;
        }
        if last.0 == row.0 {
            rows.pop();
        }
    }
    rows.push(row);
}

/// The wire's f32 results to two decimals: 99.99999 and 100 are one value.
fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn health(subject: &str, value: f64) -> Change {
        Change::Health {
            subject: subject.to_owned(),
            value,
        }
    }

    fn assigned(subject: &str, item: u32) -> Change {
        Change::Assigned {
            subject: subject.to_owned(),
            item,
        }
    }

    fn play(changes: Vec<(u32, Change)>) -> BTreeMap<String, Vec<VitalsRow>> {
        let full = HashMap::from([(7, 50.0), (8, 25.0)]);
        fold(&["a", "b"], &full, changes)
    }

    #[test]
    fn every_round_opens_at_full_health_for_every_player() {
        let rows = play(vec![
            (10, Change::RoundStart),
            (20, health("a", 40.0)),
            (30, health("a", 0.0)),
            (100, Change::RoundStart),
        ]);
        assert_eq!(
            rows["a"],
            vec![
                (10, 100.0, 0.0),
                (20, 40.0, 0.0),
                (30, 0.0, 0.0),
                (100, 100.0, 0.0)
            ]
        );
        // Unchanged, yet each round still opens with a row.
        assert_eq!(rows["b"], vec![(10, 100.0, 0.0), (100, 100.0, 0.0)]);
    }

    #[test]
    fn nothing_is_known_before_the_first_round() {
        let rows = play(vec![(5, health("a", 80.0)), (10, Change::RoundStart)]);
        assert_eq!(rows["a"], vec![(10, 100.0, 0.0)]);
    }

    #[test]
    fn a_revive_brings_health_back_after_death() {
        let rows = play(vec![
            (10, Change::RoundStart),
            (20, health("a", 0.0)),
            (25, health("a", 100.0)),
        ]);
        assert_eq!(rows["a"][1..], [(20, 0.0, 0.0), (25, 100.0, 0.0)]);
    }

    #[test]
    fn bought_armour_is_full_until_it_reports() {
        let rows = play(vec![
            (10, Change::RoundStart),
            (12, assigned("a", 7)),
            (
                20,
                Change::Reported {
                    item: 7,
                    value: 31.5,
                },
            ),
        ]);
        assert_eq!(
            rows["a"],
            vec![(10, 100.0, 0.0), (12, 100.0, 50.0), (20, 100.0, 31.5)]
        );
    }

    #[test]
    fn a_survivor_keeps_damaged_armour_into_the_next_round() {
        let rows = play(vec![
            (10, Change::RoundStart),
            (12, assigned("a", 7)),
            (
                20,
                Change::Reported {
                    item: 7,
                    value: 20.0,
                },
            ),
            // The item comes back to the next body after the round start.
            (100, Change::RoundStart),
            (101, assigned("a", 7)),
        ]);
        assert_eq!(rows["a"].last(), Some(&(100, 100.0, 20.0)));
    }

    #[test]
    fn a_replaced_or_sold_item_stops_counting() {
        let rows = play(vec![
            (10, Change::RoundStart),
            (12, assigned("a", 8)),
            (14, assigned("a", 7)),
            (15, Change::Closed { item: 8 }),
            (
                16,
                Change::Reported {
                    item: 8,
                    value: 1.0,
                },
            ),
            (18, Change::Closed { item: 7 }),
        ]);
        assert_eq!(
            rows["a"],
            vec![
                (10, 100.0, 0.0),
                (12, 100.0, 25.0),
                (14, 100.0, 50.0),
                (18, 100.0, 0.0)
            ]
        );
    }

    #[test]
    fn a_later_change_in_the_same_millisecond_replaces_the_row() {
        let rows = play(vec![
            (10, Change::RoundStart),
            (20, health("a", 60.0)),
            (20, health("a", 50.0)),
        ]);
        assert_eq!(rows["a"], vec![(10, 100.0, 0.0), (20, 50.0, 0.0)]);
    }
}
