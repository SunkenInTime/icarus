//! When a map's doors moved (docs/replay-format.md, "Doors").
//!
//! A rotating door or a dropping wall replicates its move as a burst of
//! writes on its own actor, then a last write when it stops. Their fields are
//! unnamed, so nothing here reads one: a move is told by when the actor is
//! written. A round's start writes every door too, putting it back.
//!
//! The A Link wall is simpler: its `OnDie` is a named call.

use std::collections::BTreeMap;

use crate::collect::{Collector, door_actor};
use crate::document::{DoorMove, Round};

/// Writes this close together are one burst.
const BURST_GAP_MS: u32 = 50;

/// Writes this soon after a round's start put the door back.
const RESET_MS: i64 = 3000;

/// The longest a door takes: a Lotus door spins for 10 s, a Summit wall drops
/// in 1.75 s. A burst with no later write this close moved nothing.
const LONGEST_MOVE_MS: u32 = 12_000;

/// The name a wall's moves are filed under. Abyss has one too, and no door
/// here stands for it.
const WALL: &str = "RespawningWallPlate";

pub(super) fn doors(collector: &Collector, rounds: &[Round]) -> Vec<DoorMove> {
    let starts: Vec<i64> = rounds.iter().map(|round| round.start_ms).collect();
    let mut writes: BTreeMap<String, Vec<u32>> = BTreeMap::new();
    for (time, group) in &collector.door_writes {
        if let Some(actor) = door_actor(group) {
            writes.entry(actor.to_owned()).or_default().push(*time);
        }
    }
    let mut moves: Vec<DoorMove> = writes
        .into_iter()
        .flat_map(|(actor, times)| {
            moves_of(times, &starts)
                .into_iter()
                .map(move |(start_ms, end_ms)| DoorMove {
                    actor: actor.clone(),
                    start_ms,
                    end_ms,
                })
        })
        .collect();
    moves.extend(
        breaks(&collector.wall_breaks, &starts)
            .into_iter()
            .map(|time| DoorMove {
                actor: WALL.to_owned(),
                start_ms: time,
                end_ms: time,
            }),
    );
    moves.sort_by_key(|door| (door.start_ms, door.actor.clone()));
    moves
}

/// `(first write, writes)` of each burst of `times`.
fn bursts(mut times: Vec<u32>) -> Vec<(u32, usize)> {
    times.sort_unstable();
    let mut out: Vec<(u32, usize, u32)> = Vec::new();
    for time in times {
        match out.last_mut() {
            Some((_, count, last)) if time - *last <= BURST_GAP_MS => {
                *count += 1;
                *last = time;
            }
            _ => out.push((time, 1, time)),
        }
    }
    out.into_iter()
        .map(|(time, count, _)| (time, count))
        .collect()
}

/// The round a time falls in, as an index into `starts`.
fn round_of(time: i64, starts: &[i64]) -> Option<usize> {
    starts
        .partition_point(|&start| start <= time)
        .checked_sub(1)
}

/// Whether a burst at `time` is a round's start putting the door back, which
/// a burst before any round is too.
fn is_reset(time: u32, starts: &[i64]) -> bool {
    round_of(i64::from(time), starts)
        .map(|round| i64::from(time) - starts[round] < RESET_MS)
        .unwrap_or(true)
}

/// One actor's writes as `(start, end)` moves. A move is a burst of several
/// writes, away from a round's start, and it ends at the last lone write
/// within [`LONGEST_MOVE_MS`], before another burst. A door spun as a round
/// ends is cut short by the next round's reset, which ends the move instead.
/// A burst can touch a door without moving it: the barriers falling write
/// all of them, and nothing follows.
fn moves_of(times: Vec<u32>, starts: &[i64]) -> Vec<(i64, i64)> {
    let bursts = bursts(times);
    let mut moves = Vec::new();
    for (i, &(start, count)) in bursts.iter().enumerate() {
        if count < 2 || is_reset(start, starts) {
            continue;
        }
        let mut end = None;
        for &(time, writes) in &bursts[i + 1..] {
            if time - start > LONGEST_MOVE_MS {
                break;
            }
            if writes >= 2 {
                if end.is_none() && is_reset(time, starts) {
                    end = Some(time);
                }
                break;
            }
            end = Some(time);
        }
        if let Some(end) = end {
            moves.push((i64::from(start), i64::from(end)));
        }
    }
    moves
}

/// The first `OnDie` of each round: the wall only breaks once a round.
fn breaks(times: &[u32], starts: &[i64]) -> Vec<i64> {
    let mut sorted = times.to_vec();
    sorted.sort_unstable();
    let mut out = Vec::new();
    let mut seen = None;
    for time in sorted {
        let round = round_of(i64::from(time), starts);
        if round != seen {
            seen = round;
            out.push(i64::from(time));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // As 2dd2de86's first rounds on Lotus.
    const LOTUS: [i64; 4] = [56, 112_332, 205_060, 295_654];

    fn burst(time: u32, writes: usize) -> Vec<u32> {
        vec![time; writes]
    }

    #[test]
    fn a_spin_runs_from_its_burst_to_its_last_write() {
        let times = [
            burst(57, 4),
            burst(46_755, 4),
            burst(56_749, 1),
            burst(112_333, 4),
        ]
        .concat();

        assert_eq!(moves_of(times, &LOTUS), [(46_755, 56_749)]);
    }

    #[test]
    fn writes_in_the_middle_of_a_move_do_not_end_it() {
        // As Drawbridge6 in round 3: two lone writes while it turns.
        let times = [
            burst(334_326, 4),
            burst(335_812, 1),
            burst(337_812, 1),
            burst(344_332, 1),
        ]
        .concat();

        assert_eq!(moves_of(times, &LOTUS), [(334_326, 344_332)]);
    }

    #[test]
    fn a_rounds_start_puts_a_door_back_and_moves_nothing() {
        let times = [burst(205_061, 4), burst(206_000, 1)].concat();

        assert_eq!(moves_of(times, &LOTUS), []);
    }

    #[test]
    fn a_burst_with_nothing_after_it_is_not_a_move() {
        // As DescentBox_v5 at 121795, when the barriers fall.
        let times = [burst(121_795, 2), burst(228_986, 2), burst(230_738, 1)].concat();

        assert_eq!(moves_of(times, &LOTUS), [(228_986, 230_738)]);
    }

    #[test]
    fn the_next_rounds_reset_cuts_a_late_spin_short() {
        // As Drawbridge6 at 946001, after the round's end.
        let times = [burst(200_000, 4), burst(205_061, 4)].concat();

        assert_eq!(moves_of(times, &LOTUS), [(200_000, 205_061)]);
    }

    #[test]
    fn two_spins_back_to_back_stay_two() {
        // As Drawbridge5 at 1219231, in a match of 20 rounds.
        let times = [
            burst(219_231, 4),
            burst(229_231, 1),
            burst(230_512, 3),
            burst(240_509, 1),
        ]
        .concat();

        assert_eq!(
            moves_of(times, &LOTUS),
            [(219_231, 229_231), (230_512, 240_509)],
        );
    }

    #[test]
    fn a_wall_breaks_once_a_round() {
        assert_eq!(
            breaks(&[47_169, 47_170, 247_299, 247_299], &LOTUS),
            [47_169, 247_299],
        );
    }
}
