//! Who is flashed, per player (docs/replay-format.md, "Blinds").
//!
//! Each body's `BlindManagerComponent` replicates
//! `LongestActiveBlindDuration`: how many seconds the longest flash on that
//! player lasts, written as a flash lands and set to 0 when the last one
//! wears off. The component belongs to the body, so its actor is the pawn.
//! Killjoy's turret and alarm bot carry one too, and are left out: only
//! players' bodies are kept.
//!
//! A plain property, it needs none of vrfkit's `ActiveBlinds` array route,
//! which is off for 13.00 and earlier and for 13.08.

use std::collections::BTreeMap;

use super::Context;
use crate::document::BlindRow;

const FIELD: &str = "LongestActiveBlindDuration";

pub(super) fn blinds(cx: &Context<'_>) -> BTreeMap<String, Vec<BlindRow>> {
    let mut rows: BTreeMap<String, Vec<(u32, u32, f64)>> = BTreeMap::new();
    for row in cx.rows {
        if &*row.name != FIELD || !row.group.ends_with("BlindManagerComponent") {
            continue;
        }
        let Some(seconds) = row.float.filter(|s| s.is_finite() && *s >= 0.0) else {
            continue;
        };
        let Some(subject) = cx.body_subject.get(&row.actor) else {
            continue;
        };
        rows.entry(subject.clone())
            .or_default()
            .push((row.time, row.packet, seconds));
    }
    rows.into_iter()
        .map(|(subject, mut changes)| {
            changes.sort_by_key(|&(time, packet, _)| (time, packet));
            let mut out: Vec<BlindRow> = Vec::with_capacity(changes.len());
            for (time, _, seconds) in changes {
                let seconds = (seconds * 1000.0).round() / 1000.0;
                // A repeat of the value in force (0 before the first flash)
                // changes nothing.
                if out.last().map_or(0.0, |&(_, last)| last) == seconds {
                    continue;
                }
                out.push((i64::from(time), seconds));
            }
            (subject, out)
        })
        .collect()
}
