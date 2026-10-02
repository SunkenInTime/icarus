//! Rounds, after tools/extract_rounds.py: one round per `MulticastSetPhase`
//! cycle on the game state (2 reset, 3 round start, 4 buy phase end, 5 post
//! round, 6 side switch), Event-chunk facts filed into a round by time, and
//! `RoundResults` joined by `RoundNumber`. Spike facts add the RPCs vrfkit's
//! docs/DATA.md ("Spike & objective") names; the economy is ours.

use std::collections::HashMap;

use super::{Context, parse_vector};
use crate::document::{Defuse, Economy, Plant, Round};
use crate::fieldpath::FieldPath;

/// One `RoundResults[i]` element: member -> (integer, text) as written last.
type ResultMembers = HashMap<String, (Option<i64>, Option<String>)>;

#[derive(Default, Clone)]
struct Phases {
    reset: Option<u32>,
    start: Option<u32>,
    buy_end: Option<u32>,
    post_round: Option<u32>,
    side_switch: Option<u32>,
}

impl Phases {
    fn slot(&mut self, phase: i64) -> Option<&mut Option<u32>> {
        Some(match phase {
            2 => &mut self.reset,
            3 => &mut self.start,
            4 => &mut self.buy_end,
            5 => &mut self.post_round,
            6 => &mut self.side_switch,
            _ => return None,
        })
    }

    fn open(&self) -> Option<u32> {
        [
            self.reset,
            self.start,
            self.buy_end,
            self.post_round,
            self.side_switch,
        ]
        .into_iter()
        .flatten()
        .min()
    }
}

/// One fact filed into a round by time; two of a kind in one round leave
/// the fact unset rather than pick one (extract_rounds.py "never pick one").
#[derive(Default)]
struct Placed {
    round_number: Vec<(u32, i64)>,
    plant: Vec<(u32, ())>,
    defuse: Vec<(u32, ())>,
    explode: Vec<(u32, ())>,
    site: Vec<(u32, i64)>,
}

pub(super) fn rounds(cx: &mut Context<'_>) -> Vec<Round> {
    let mut phases: Vec<Phases> = Vec::new();
    // (round ordinal, phase, kept time, repeat time).
    let mut repeated: Vec<(usize, i64, u32, u32)> = Vec::new();
    let mut results: HashMap<u32, ResultMembers> = HashMap::new();
    let mut sites = Vec::new();
    for row in cx.rows {
        if &*row.name == "MulticastSetPhase.NewPhase" {
            let Some(phase) = row.int else { continue };
            if !(2..=6).contains(&phase) {
                continue;
            }
            if phase == 2 || phases.is_empty() {
                phases.push(Phases::default());
            }
            let ordinal = phases.len() - 1;
            let slot = phases
                .last_mut()
                .expect("pushed")
                .slot(phase)
                .expect("2..=6");
            match *slot {
                None => *slot = Some(row.time),
                Some(kept) => repeated.push((ordinal, phase, kept, row.time)),
            }
        } else if &*row.name == "PlantedAtSite" {
            sites.push((row.time, row.int.unwrap_or(0)));
        } else if row.name.starts_with("RoundResults[") {
            let path = FieldPath::parse(&row.name);
            let (Some(index), 2) = (path.segments[0].index, path.segments.len()) else {
                continue;
            };
            results
                .entry(index)
                .or_default()
                .insert(path.leaf().to_owned(), (row.int, row.text.clone()));
        }
    }
    // Seen on 13.00: the buy phase ending twice, 0.4-0.9 s apart. The first
    // is kept, so `combatStartMs` and the cast times built on it could be
    // that much early.
    for (ordinal, phase, kept, again) in repeated {
        cx.warnings.push(format!(
            "round {ordinal}: game phase {phase} sent again at {again} ms; the first, at {kept} ms, is kept"
        ));
    }
    // The last side switch resets into a round that never starts.
    if phases.last().is_some_and(|p| p.start.is_none()) {
        phases.pop();
    }

    let opens: Vec<u32> = phases
        .iter()
        .map(|p| p.open().expect("a phase is set"))
        .collect();
    let place = |t: u32| opens.partition_point(|&o| o <= t).checked_sub(1);
    let mut placed: Vec<Placed> = phases.iter().map(|_| Placed::default()).collect();
    let mut before_first = 0;
    for event in cx.events {
        let Some(i) = place(event.time1) else {
            before_first += 1;
            continue;
        };
        let t = event.time1;
        match event.group.as_str() {
            "roundStarted" => {
                if let Some(word) = event.word0 {
                    placed[i].round_number.push((t, i64::from(word)));
                }
            }
            "spikePlanted" => placed[i].plant.push((t, ())),
            "spikeDefused" => placed[i].defuse.push((t, ())),
            "spikeExploded" => placed[i].explode.push((t, ())),
            _ => {}
        }
    }
    for &(t, site) in &sites {
        if let Some(i) = place(t) {
            placed[i].site.push((t, site));
        }
    }
    if before_first > 0 {
        cx.warnings.push(format!(
            "{before_first} round event(s) before the first round"
        ));
    }

    let by_number: HashMap<i64, &ResultMembers> = results
        .values()
        .filter_map(|r| Some((r.get("RoundNumber")?.0?, r)))
        .collect();
    let text = |r: &ResultMembers, k: &str| r.get(k).and_then(|(_, s)| s.clone());

    let plants = spike_rpcs(cx, "BombPlantedRPC.BombPlanter");
    let plant_locations = spike_text(cx, "BombPlantedRPC.PlantLocation");
    let defusers = spike_rpcs(cx, "BombDefusedRPC.DefusingCharacter");

    let mut rounds = Vec::new();
    let mut unknown_results = Vec::new();
    for (ordinal, (p, facts)) in phases.iter().zip(&placed).enumerate() {
        let single = |v: &[(u32, i64)]| (v.len() == 1).then(|| v[0]);
        let single_t = |v: &[(u32, ())]| (v.len() == 1).then(|| v[0].0);
        let round_number = single(&facts.round_number);
        if facts.round_number.len() > 1 {
            cx.warnings.push(format!(
                "round {ordinal}: {} roundStarted events",
                facts.round_number.len()
            ));
        }
        if let Some((_, n)) = round_number {
            if n != ordinal as i64 {
                cx.warnings.push(format!(
                    "round {ordinal} is numbered {n} by its roundStarted event"
                ));
            }
        }
        let start = round_number
            .map(|(t, _)| t)
            .or(p.start)
            .expect("rounds without a start are dropped");
        let result = round_number.and_then(|(_, n)| by_number.get(&n).copied());
        let winning_team = result.and_then(|r| text(r, "WinningTeam"));
        // A match surrendered mid-round ends with no end phase but a result;
        // only a round with neither was cut off.
        let end = match p.post_round.or_else(|| opens.get(ordinal + 1).copied()) {
            Some(end) => i64::from(end),
            None => {
                if winning_team.is_none() {
                    cx.warnings.push(format!(
                        "round {ordinal} never ended: the replay stops inside it"
                    ));
                }
                cx.duration_ms
            }
        };
        let role = result.and_then(|r| text(r, "WinningTeamRole"));
        let attacking_team = match (winning_team.as_deref(), role.as_deref()) {
            (Some(team), Some("attacker")) => Some(team.to_owned()),
            (Some(team), Some("defender")) => other_team(team).map(str::to_owned),
            _ => None,
        };
        let raw_result = result.and_then(|r| text(r, "RoundResult"));
        let end_reason = raw_result.as_deref().and_then(end_reason);
        if let (Some(raw), None) = (&raw_result, end_reason) {
            unknown_results.push(raw.clone());
        }

        let plant = single_t(&facts.plant).map(|t| {
            let rpc = nearest(&plants, t);
            Plant {
                time_ms: i64::from(t),
                site: single(&facts.site).map_or(
                    // PlantedAtSite is absent when it holds the default, site 0.
                    if facts.site.is_empty() {
                        Some("A")
                    } else {
                        None
                    },
                    |(_, s)| site_letter(s),
                ),
                subject: rpc.and_then(|(rt, g)| cx.subject_behind(g, rt).map(str::to_owned)),
                position: nearest(&plant_locations, t).and_then(|(_, s)| parse_vector(s)),
            }
        });
        let defuse = single_t(&facts.defuse).map(|t| Defuse {
            time_ms: i64::from(t),
            subject: nearest(&defusers, t)
                .and_then(|(rt, g)| cx.subject_behind(g, rt).map(str::to_owned)),
        });
        rounds.push(Round {
            index: ordinal as u32,
            start_ms: i64::from(start),
            combat_start_ms: p.buy_end.map(i64::from),
            end_ms: end,
            attacking_team,
            winning_team,
            end_reason,
            plant,
            defuse,
            detonate_ms: single_t(&facts.explode).map(i64::from),
            economy: economy(cx, p.buy_end),
        });
    }
    if !unknown_results.is_empty() {
        unknown_results.sort();
        unknown_results.dedup();
        cx.warnings.push(format!(
            "unknown RoundResult value(s): {}",
            unknown_results.join(", ")
        ));
    }
    fill_attackers(cx, &mut rounds, &phases);
    rounds
}

/// Rounds whose `RoundResults` entry is missing take their attackers from a
/// round of the same half: sides hold between side switches (phase 6, sent
/// on the round before the switch).
fn fill_attackers(cx: &mut Context<'_>, rounds: &mut [Round], phases: &[Phases]) {
    let mut half = 0;
    let halves: Vec<usize> = phases
        .iter()
        .map(|p| {
            let this = half;
            if p.side_switch.is_some() {
                half += 1;
            }
            this
        })
        .collect();
    let mut by_half: HashMap<usize, Vec<String>> = HashMap::new();
    for (r, &h) in rounds.iter().zip(&halves) {
        if let Some(team) = &r.attacking_team {
            by_half.entry(h).or_default().push(team.clone());
        }
    }
    for (h, teams) in &by_half {
        if teams.iter().any(|t| t != &teams[0]) {
            cx.warnings
                .push(format!("attackers change within side-switch segment {h}"));
        }
    }
    for (r, h) in rounds.iter_mut().zip(halves) {
        if r.attacking_team.is_none() {
            if let Some(teams) = by_half.get(&h).filter(|t| t.iter().all(|x| x == &t[0])) {
                r.attacking_team = Some(teams[0].clone());
            } else {
                cx.warnings
                    .push(format!("round {}: attacking team unknown", r.index));
            }
        }
    }
}

fn other_team(team: &str) -> Option<&'static str> {
    match team {
        "Red" => Some("Blue"),
        "Blue" => Some("Red"),
        _ => None,
    }
}

/// `RoundResults[].RoundResult` -> the contract's end reasons. The wire
/// strings seen on 13.00: "elimination", "defuse", "detonate", "timeout",
/// "surrendered" (the last from extract_rounds.py's `AWARDED`).
fn end_reason(raw: &str) -> Option<&'static str> {
    Some(match raw {
        "elimination" => "elimination",
        "detonate" | "bomb detonated" => "detonated",
        "defuse" | "bomb defused" => "defused",
        "timeout" | "round timer expired" => "time",
        "surrendered" => "surrender",
        _ => return None,
    })
}

/// `TimedBomb.PlantedAtSite` is an enum ordinal; vrfkit checked it against
/// the game's plant volumes (docs/DATA.md). Ordinals name sites in order.
fn site_letter(ordinal: i64) -> Option<&'static str> {
    ["A", "B", "C"].get(usize::try_from(ordinal).ok()?).copied()
}

/// `(time, value)` of every row named `name` holding a NetGUID.
fn spike_rpcs(cx: &Context<'_>, name: &str) -> Vec<(u32, u32)> {
    cx.rows
        .iter()
        .filter(|r| &*r.name == name)
        .filter_map(|r| Some((r.time, u32::try_from(r.int?).ok()?)))
        .collect()
}

fn spike_text<'r>(cx: &Context<'r>, name: &str) -> Vec<(u32, &'r str)> {
    cx.rows
        .iter()
        .filter(|r| &*r.name == name)
        .filter_map(|r| Some((r.time, r.text.as_deref()?)))
        .collect()
}

/// The RPC sent with an Event-chunk fact: same frame, within 50 ms (the
/// event clock and packet clock agree to the millisecond on 13.00).
fn nearest<T: Copy>(rows: &[(u32, T)], t: u32) -> Option<(u32, T)> {
    rows.iter()
        .copied()
        .filter(|&(rt, _)| rt.abs_diff(t) <= 50)
        .min_by_key(|&(rt, _)| rt.abs_diff(t))
}

/// Shield points of an armour item, by class: docs/DATA.md measured each
/// armour section's maximum as Heavy 50, Light 25, Plasma 25.
pub(super) fn armor_points(class: &str) -> Option<i64> {
    let leaf = class.rsplit('.').next()?;
    Some(match leaf {
        "HeavyArmorItem_C" => 50,
        "LightArmorItem_C" | "PlasmaArmorItem_C" => 25,
        _ => return None,
    })
}

/// Per player at the end of the buy phase: credits (`Money`, on the
/// PlayerState's MoneyManagementComponent), the gun they own (a primary
/// over a sidearm) and the armour they wear.
fn economy(cx: &Context<'_>, buy_end: Option<u32>) -> Vec<Economy> {
    let Some(t) = buy_end else {
        return Vec::new();
    };
    // Equippables open at `t`, by owner body.
    let mut open: HashMap<u32, bool> = HashMap::new();
    for a in cx.actors.iter().filter(|a| a.time_ms <= t) {
        match a.event {
            "open" => {
                open.insert(a.actor_net_guid, true);
            }
            "close" => {
                open.insert(a.actor_net_guid, false);
            }
            _ => {}
        }
    }
    let mut owned: HashMap<u32, Vec<&str>> = HashMap::new();
    for (&guid, &is_open) in &open {
        let Some(class) = cx.actor_class.get(&guid) else {
            continue;
        };
        if !is_open
            || !(class.starts_with("/Game/Equippables/Guns/") || armor_points(class).is_some())
        {
            continue;
        }
        let Some(writes) = cx.owner_writes.get(&guid) else {
            continue;
        };
        // Ownership needs a write at or before `t`, and its latest value.
        if let Some(&(_, owner)) = writes.iter().rev().find(|&&(wt, _)| wt <= t) {
            owned.entry(owner).or_default().push(class);
        }
    }
    let mut money: HashMap<u32, i64> = HashMap::new();
    for row in cx
        .rows
        .iter()
        .filter(|r| r.time <= t && &*r.name == "Money")
    {
        if row.group.ends_with("MoneyManagementComponent") {
            if let Some(v) = row.int {
                money.insert(row.actor, v);
            }
        }
    }
    cx.players
        .iter()
        .map(|p| {
            let items: Vec<&str> = p
                .bodies
                .iter()
                .flat_map(|b| owned.get(b).into_iter().flatten().copied())
                .collect();
            let gun = |sidearm: bool| {
                let mut guns: Vec<&str> = items
                    .iter()
                    .copied()
                    .filter(|c| {
                        c.starts_with("/Game/Equippables/Guns/")
                            && c.contains("/Sidearms/") == sidearm
                    })
                    .collect();
                guns.sort_unstable();
                guns.dedup();
                (guns.len() == 1).then(|| guns[0].to_owned())
            };
            Economy {
                subject: p.subject.clone(),
                credits: money.get(&p.state).copied(),
                weapon: gun(false).or_else(|| gun(true)),
                armor: items.iter().filter_map(|c| armor_points(c)).max(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sites_and_reasons_map_as_documented() {
        assert_eq!(site_letter(0), Some("A"));
        assert_eq!(site_letter(2), Some("C"));
        assert_eq!(site_letter(3), None);
        assert_eq!(end_reason("defuse"), Some("defused"));
        assert_eq!(end_reason("something new"), None);
        assert_eq!(
            armor_points("/Game/Gear/HeavyArmorItem.HeavyArmorItem_C"),
            Some(50)
        );
        assert_eq!(armor_points("/Game/Gear/Other.Other_C"), None);
    }
}
