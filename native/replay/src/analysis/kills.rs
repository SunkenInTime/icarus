//! Kills from Event-chunk `characterDeath` (word0 killer, word1 victim
//! character NetGUIDs), cross-checked against `MulticastNotifyKilledEnemy`
//! as tools/extract_kill_ledger.py and docs/DATA.md ("Kill log") pair them.
//!
//! On 13.00 vrfkit admits no `KillData` route, so assists and the damage
//! source come from elsewhere: an assist is an `AggregateAssists` increment
//! sent at the same millisecond as the death's `MulticastNotifyKilledEnemy`
//! (Event-chunk times run ~8 ms ahead of the packet clock, so the event's own
//! time does not line up), and the source is the `EquippableUsed` of the
//! victim's damage call that reports `bDamageKilledTarget`.

use std::collections::{BTreeMap, HashMap};

use super::Context;
use crate::document::Kill;

/// The RPCs travel with the event: matched lags in extract_kill_ledger.py
/// measure 5-41 ms against a 50 ms cap.
const LAG_MS: u32 = 50;

pub(super) fn kills(cx: &mut Context<'_>, teams: &BTreeMap<String, String>) -> Vec<Kill> {
    let notified: Vec<(u32, u32, u32)> = notify_pairs(cx);
    let assists = assist_increments(cx);
    let sources = kill_sources(cx);

    let deaths: Vec<_> = cx
        .events
        .iter()
        .filter(|e| e.group == "characterDeath")
        .collect();
    let mut notify_times: HashMap<u32, usize> = HashMap::new();
    for &(t, _, _) in &notified {
        *notify_times.entry(t).or_default() += 1;
    }

    let mut kills = Vec::new();
    let (mut unvalidated, mut unknown_victims, mut unknown_killers, mut corroborated) =
        (0, 0, 0, 0);
    let mut ambiguous_assists = 0;
    for death in deaths {
        let (Some(killer), Some(victim)) = (death.word0, death.word1) else {
            unvalidated += 1;
            continue;
        };
        let t = death.time1;
        let Some(victim_subject) = cx.body_subject.get(&victim).cloned() else {
            unknown_victims += 1;
            continue;
        };
        // A self-inflicted death has no killer, as the game's own kill count
        // agrees (`AggregateKills` skips it; Clove's ultimate running out).
        let killer_subject = cx
            .body_subject
            .get(&killer)
            .filter(|_| killer != victim)
            .cloned();
        if killer != 0 && killer != victim && killer_subject.is_none() {
            unknown_killers += 1;
        }
        let notify = notified
            .iter()
            .find(|&&(nt, k, v)| k == killer && v == victim && nt >= t && nt - t <= LAG_MS)
            .map(|&(nt, _, _)| nt);
        if notify.is_some() {
            corroborated += 1;
        }
        let mut credited = Vec::new();
        if let Some((nt, players)) = notify.and_then(|nt| Some((nt, assists.get(&nt)?))) {
            // Two kills in one millisecond share their assist increments.
            if notify_times[&nt] == 1 {
                for subject in players {
                    let teammate = |a: &str, b: &str| matches!((teams.get(a), teams.get(b)), (Some(x), Some(y)) if x == y);
                    // Assists come from the killer's side, never the victim's.
                    if Some(subject) != killer_subject.as_ref()
                        && !teammate(subject, &victim_subject)
                    {
                        credited.push(subject.clone());
                    }
                }
            } else {
                ambiguous_assists += 1;
            }
        }
        credited.sort();
        kills.push(Kill {
            time_ms: i64::from(t),
            victim: victim_subject,
            killer: killer_subject,
            assists: credited,
            damage_source: sources
                .iter()
                .filter(|s| s.victim == victim && s.time.abs_diff(t) <= LAG_MS)
                .min_by_key(|s| s.time.abs_diff(t))
                .and_then(|s| cx.class_of(s.equippable)),
        });
    }
    let total = kills.len() + unvalidated + unknown_victims;
    if corroborated < total {
        cx.warnings.push(format!(
            "{} of {total} death(s) without a matching MulticastNotifyKilledEnemy",
            total - corroborated
        ));
    }
    for (n, what) in [
        (
            unvalidated,
            "death event(s) off the measured payload layout (dropped)",
        ),
        (
            unknown_victims,
            "death(s) of a pawn no player owns (dropped)",
        ),
        (
            unknown_killers,
            "killer pawn(s) no player owns (killer left absent)",
        ),
        (
            ambiguous_assists,
            "simultaneous deaths whose assists cannot be told apart",
        ),
    ] {
        if n > 0 {
            cx.warnings.push(format!("{n} {what}"));
        }
    }
    kills
}

/// `(time, killer, victim)` of every `MulticastNotifyKilledEnemy` call.
fn notify_pairs(cx: &Context<'_>) -> Vec<(u32, u32, u32)> {
    let mut pairs = Vec::new();
    let mut killer: Option<(u32, u32, u32)> = None; // (packet, actor, value)
    for row in cx.rows {
        let Some(value) = row.int.and_then(|v| u32::try_from(v).ok()) else {
            continue;
        };
        match &*row.name {
            "MulticastNotifyKilledEnemy.KillerCharacter" => {
                killer = Some((row.packet, row.actor, value))
            }
            "MulticastNotifyKilledEnemy.KilledCharacter" => {
                if let Some((p, a, k)) = killer.take() {
                    if p == row.packet && a == row.actor {
                        pairs.push((row.time, k, value));
                    }
                }
            }
            _ => {}
        }
    }
    pairs
}

/// Packet time -> subjects whose `AggregateAssists` rose at that millisecond.
fn assist_increments(cx: &Context<'_>) -> HashMap<u32, Vec<String>> {
    let mut last: HashMap<u32, i64> = HashMap::new();
    let mut at: HashMap<u32, Vec<String>> = HashMap::new();
    for row in cx.rows.iter().filter(|r| &*r.name == "AggregateAssists") {
        let Some(value) = row.int else { continue };
        let before = last.insert(row.actor, value).unwrap_or(0);
        if value > before {
            if let Some(subject) = cx.state_subject.get(&row.actor) {
                at.entry(row.time).or_default().push(subject.clone());
            }
        }
    }
    at
}

struct KillSource {
    time: u32,
    victim: u32,
    equippable: u32,
}

/// The equippable of each damage call that killed its target, on the
/// victim's DamageableComponent. One call's parameters share a packet,
/// actor, component and function; a repeated parameter starts the next call.
fn kill_sources(cx: &Context<'_>) -> Vec<KillSource> {
    #[derive(Default)]
    struct Call {
        killed: Option<bool>,
        equippable: Option<u32>,
        time: u32,
    }
    /// (packet, actor, component, function).
    type CallKey<'r> = (u32, u32, Option<u32>, &'r str);
    let mut calls: Vec<(CallKey<'_>, Call)> = Vec::new();
    for row in cx.rows {
        let Some((function, member)) = row.name.split_once('.') else {
            continue;
        };
        if !function.starts_with("MulticastNotifyDamage_") {
            continue;
        }
        let key = (row.packet, row.actor, row.object, function);
        let fresh = match calls.last() {
            Some((k, call)) => {
                *k != key
                    || (member == "bDamageKilledTarget" && call.killed.is_some())
                    || (member == "EquippableUsed" && call.equippable.is_some())
            }
            None => true,
        };
        if fresh {
            calls.push((
                key,
                Call {
                    time: row.time,
                    ..Call::default()
                },
            ));
        }
        let call = &mut calls.last_mut().expect("pushed").1;
        match member {
            "bDamageKilledTarget" => call.killed = row.boolean,
            "EquippableUsed" => call.equippable = row.int.and_then(|v| u32::try_from(v).ok()),
            _ => {}
        }
    }
    calls
        .into_iter()
        .filter_map(|((_, actor, _, _), call)| {
            (call.killed == Some(true)).then_some(())?;
            Some(KillSource {
                time: call.time,
                victim: actor,
                equippable: call.equippable.filter(|&e| e != 0)?,
            })
        })
        .collect()
}
