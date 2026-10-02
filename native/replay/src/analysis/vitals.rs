//! Health and armour per player, from the absolute `LifeResult` the damage,
//! heal and reset RPCs carry per damage section (docs/DATA.md, "Health is
//! absolute, not a subtraction"; vrfkit's section tools keep the raw view).
//!
//! Health is the body's `HealthDamageSection`. Armour is the
//! `AttachedDamageSection` of the armour item the body owns ("Armour is
//! `AttachedDamageSection`, not `ShieldDamageSection`"), which also reports
//! through `MulticastNotifySetLife` while a regenerating shield refills.
//! A section's kind comes from its name in the GUID table. Armour reads
//! `null` until the wire states it: a bought item's full value is never
//! replicated, only later changes (the round's economy carries the tier).

use std::collections::{BTreeMap, HashMap};

use super::{Context, value_at};
use crate::fieldpath::FieldPath;

use crate::document::VitalsRow;

/// One element of one life-change call: (packet, actor, component, element
/// indices, function).
type ElementKey = (u32, u32, Option<u32>, Vec<Option<u32>>, String);

/// What a subject's vitals stand at, and which armour section the armour is.
#[derive(Default, Clone, Copy, PartialEq)]
struct Vital {
    health: Option<f64>,
    armor: Option<f64>,
    armor_section: Option<u32>,
}

#[derive(Clone, Copy, PartialEq)]
enum Section {
    Health,
    Armor,
}

pub(super) fn vitals(cx: &mut Context<'_>) -> BTreeMap<String, Vec<VitalsRow>> {
    // Every reported section result, in wire order: (time, body, section, kind, value).
    let mut changes: Vec<(u32, u32, u32, Section, f64)> = Vec::new();
    let mut pending: HashMap<ElementKey, (Option<u32>, Option<f64>)> = HashMap::new();
    let mut order = Vec::new();
    for row in cx.rows {
        let path = FieldPath::parse(&row.name);
        if path.segments.len() == 3
            && matches!(
                path.segments[1].base,
                "LifeChangeEvents" | "LifeChangeBySection"
            )
        {
            let key = (
                row.packet,
                row.actor,
                row.object,
                path.indices(),
                path.segments[0].base.to_owned(),
            );
            let slot = pending.entry(key.clone()).or_insert_with(|| {
                order.push((row.time, key));
                (None, None)
            });
            match path.leaf() {
                "ChangedComponent" => slot.0 = row.int.and_then(|v| u32::try_from(v).ok()),
                "LifeResult" => slot.1 = row.float,
                _ => {}
            }
        } else if &*row.name == "MulticastNotifySetLife.NewLife" {
            // On the armour item's section: the item, not a body, is the actor.
            let (Some(section), Some(value)) = (row.object, row.float) else {
                continue;
            };
            if section_kind(cx, section) != Some(Section::Armor) {
                continue;
            }
            let owner = cx
                .owner_writes
                .get(&row.actor)
                .and_then(|w| value_at(w, row.time));
            if let Some(body) = owner.filter(|b| cx.body_subject.contains_key(b)) {
                changes.push((row.time, body, section, Section::Armor, value));
            }
        }
    }
    for (time, key) in order {
        let body = key.1;
        let (Some(section), Some(value)) = pending[&key] else {
            continue;
        };
        if !cx.body_subject.contains_key(&body) {
            continue;
        }
        // Shield, overheal and agent sections are neither health nor armour.
        if let Some(kind) = section_kind(cx, section) {
            changes.push((time, body, section, kind, value));
        }
    }
    // An armour item changing hands: its new owner's armour is that item's,
    // unknown until it reports (NaN marks "unknown").
    for (item, section) in armor_sections(cx) {
        for &(time, owner) in cx.owner_writes.get(&item).into_iter().flatten() {
            if cx.body_subject.contains_key(&owner) {
                changes.push((time, owner, section, Section::Armor, f64::NAN));
            }
        }
    }
    changes.sort_by_key(|c| c.0);

    // Per subject: health, armour, and the armour section it belongs to.
    let mut state: HashMap<String, Vital> = HashMap::new();
    let mut out: BTreeMap<String, Vec<VitalsRow>> = BTreeMap::new();
    for (time, body, section, kind, value) in changes {
        let subject = cx.body_subject[&body].clone();
        let current = state.entry(subject.clone()).or_default();
        let next = match kind {
            Section::Health => Vital {
                health: Some(round2(value)),
                ..*current
            },
            // The same item handed back (a survivor at round start) keeps its value.
            Section::Armor if value.is_nan() && current.armor_section == Some(section) => *current,
            Section::Armor => Vital {
                armor: (!value.is_nan()).then(|| round2(value)),
                armor_section: Some(section),
                ..*current
            },
        };
        let changed = (next.health, next.armor) != (current.health, current.armor);
        *current = next;
        if !changed {
            continue;
        }
        let rows = out.entry(subject).or_default();
        let t = i64::from(time);
        // One row per change: a later change at the same millisecond replaces it.
        if rows.last().is_some_and(|r| r.0 == t) {
            rows.pop();
        }
        rows.push((t, next.health, next.armor));
    }
    if out.is_empty() {
        cx.warnings
            .push("no health or armour results replicated".to_owned());
    }
    out
}

/// Armour item actor -> its `AttachedDamageSection` subobject.
fn armor_sections(cx: &Context<'_>) -> Vec<(u32, u32)> {
    cx.cache
        .net_guid_entries()
        .into_iter()
        .filter(|e| e.path == "AttachedDamageSection")
        .filter_map(|e| {
            let item = e.outer_net_guid?;
            let class = cx.actor_class.get(&item)?;
            super::rounds::armor_points(class).map(|_| (item, e.net_guid))
        })
        .collect()
}

/// What a damage section is, by its object name in the GUID table.
fn section_kind(cx: &Context<'_>, section: u32) -> Option<Section> {
    match cx.cache.get_path_by_guid(section)? {
        "HealthDamageSection" => Some(Section::Health),
        "AttachedDamageSection" => {
            // Only an armour item's section: its outer is the item actor.
            let outer = cx.cache.get_outer_guid(section)?.0;
            let class = cx.actor_class.get(&outer)?;
            super::rounds::armor_points(class).map(|_| Section::Armor)
        }
        _ => None,
    }
}

/// The wire's f32 results to two decimals: 99.99999 and 100 are one value.
fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}
