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
        .map(|(subject, changes)| (subject, track(changes)))
        .collect()
}

/// One player's `(time, packet, seconds)` writes as rows: in wire order,
/// seconds to three decimals, and only those that change the value in force
/// (0 before the first flash).
fn track(mut changes: Vec<(u32, u32, f64)>) -> Vec<BlindRow> {
    changes.sort_by_key(|&(time, packet, _)| (time, packet));
    let mut out: Vec<BlindRow> = Vec::with_capacity(changes.len());
    for (time, _, seconds) in changes {
        let seconds = (seconds * 1000.0).round() / 1000.0;
        if out.last().map_or(0.0, |&(_, last)| last) == seconds {
            continue;
        }
        out.push((i64::from(time), seconds));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::track;

    #[test]
    fn rows_are_changes_in_wire_order() {
        // As 1fb53a2c's first flash, with a repeat, a stray leading 0 and
        // two writes arriving out of order.
        let rows = track(vec![
            (57102, 14364, 0.0),
            (55297, 13761, 1.799_260_735_511_779_8),
            (55000, 13700, 0.0),
            (55297, 13762, 1.799_260_7),
            (60000, 15000, 0.0),
        ]);
        assert_eq!(rows, [(55297, 1.799), (57102, 0.0)]);
    }
}
