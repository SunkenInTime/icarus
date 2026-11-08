//! When a map's doors moved (docs/replay-format.md, "Doors").
//!
//! A rotating door or a dropping wall replicates its move as a burst of
//! writes on its own actor, then a last write when it stops. Their fields are
//! unnamed, so nothing here reads one: a move is told by when the actor is
//! written. A round's start writes every door too, putting it back.
//!
//! The A Link wall is simpler: its `OnDie` is a named call. So are an Ascent
//! door's moves: each `PlayDoorSounds` call carries the state it left and the
//! one it entered.

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::collect::{Collector, ShutterState, door_actor};
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

/// `EAresDoorState`, from the game's type mappings: Open 0, Opening 1,
/// Closing 2, Closed 3, Invalid 4.
const OPENING: u8 = 1;
const CLOSING: u8 = 2;

pub(super) fn doors(collector: &Collector, rounds: &[Round], duration_ms: i64) -> Vec<DoorMove> {
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
            moves_of(times, &starts, duration_ms)
                .into_iter()
                .map(move |(start_ms, end_ms)| DoorMove {
                    actor: actor.clone(),
                    start_ms,
                    end_ms,
                    to_rest: false,
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
                to_rest: false,
            }),
    );
    moves.extend(shutters(
        &collector.shutter_states,
        &collector.shutter_names,
        duration_ms,
    ));
    moves.sort_by_key(|door| (door.start_ms, door.actor.clone()));
    moves
}

/// Each Ascent door's moves. A call that enters Closing or Opening starts
/// one, and the door's next call ends it: normally Closed or Open 5 s later,
/// or a round's start putting the door back, which cuts a move short. A
/// recording that ends first ends it there. Every other call, such as that
/// reset, moves nothing.
fn shutters(
    states: &[ShutterState],
    names: &BTreeMap<u32, Arc<str>>,
    duration_ms: i64,
) -> Vec<DoorMove> {
    // The state each call entered, by door and time: 0 unless it says.
    let mut calls: BTreeMap<(u32, u32), u8> = BTreeMap::new();
    for state in states {
        let entered = calls.entry((state.actor, state.time)).or_insert(0);
        if state.entered {
            *entered = state.state;
        }
    }
    let mut moves = Vec::new();
    let mut moving: Option<(u32, i64, bool)> = None;
    let mut end = |moving: &mut Option<(u32, i64, bool)>, end_ms: i64| {
        let Some((actor, start_ms, to_rest)) = moving.take() else {
            return;
        };
        if let Some(name) = names.get(&actor) {
            moves.push(DoorMove {
                actor: name.to_string(),
                start_ms,
                end_ms,
                to_rest,
            });
        }
    };
    for (&(actor, time), &entered) in &calls {
        if moving.is_some_and(|(door, ..)| door != actor) {
            end(&mut moving, duration_ms);
        }
        end(&mut moving, i64::from(time));
        if entered == CLOSING || entered == OPENING {
            moving = Some((actor, i64::from(time), entered == OPENING));
        }
    }
    end(&mut moving, duration_ms);
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
/// all of them, and nothing follows. A recording that ends within
/// [`LONGEST_MOVE_MS`] of a burst ends its move there instead, whatever came
/// in between: the door was still moving.
fn moves_of(times: Vec<u32>, starts: &[i64], duration_ms: i64) -> Vec<(i64, i64)> {
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
        let start = i64::from(start);
        let unfinished = duration_ms - start <= i64::from(LONGEST_MOVE_MS)
            && !bursts[i + 1..].iter().any(|&(_, writes)| writes >= 2);
        if unfinished && duration_ms > start {
            moves.push((start, duration_ms));
        } else if let Some(end) = end {
            moves.push((start, i64::from(end)));
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
    const MATCH_MS: i64 = 2_000_000;

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

        assert_eq!(moves_of(times, &LOTUS, MATCH_MS), [(46_755, 56_749)]);
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

        assert_eq!(moves_of(times, &LOTUS, MATCH_MS), [(334_326, 344_332)]);
    }

    #[test]
    fn a_rounds_start_puts_a_door_back_and_moves_nothing() {
        let times = [burst(205_061, 4), burst(206_000, 1)].concat();

        assert_eq!(moves_of(times, &LOTUS, MATCH_MS), []);
    }

    #[test]
    fn a_burst_with_nothing_after_it_is_not_a_move() {
        // As DescentBox_v5 at 121795, when the barriers fall.
        let times = [burst(121_795, 2), burst(228_986, 2), burst(230_738, 1)].concat();

        assert_eq!(moves_of(times, &LOTUS, MATCH_MS), [(228_986, 230_738)]);
    }

    #[test]
    fn the_next_rounds_reset_cuts_a_late_spin_short() {
        // As Drawbridge6 at 946001, after the round's end.
        let times = [burst(200_000, 4), burst(205_061, 4)].concat();

        assert_eq!(moves_of(times, &LOTUS, MATCH_MS), [(200_000, 205_061)]);
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
            moves_of(times, &LOTUS, MATCH_MS),
            [(219_231, 229_231), (230_512, 240_509)],
        );
    }

    #[test]
    fn a_recording_that_ends_mid_spin_ends_the_move() {
        // A lone write while it turns, then the recording stops.
        let times = [burst(390_000, 4), burst(391_500, 1)].concat();

        assert_eq!(moves_of(times, &LOTUS, 395_000), [(390_000, 395_000)]);
    }

    fn call(time: u32, old: u8, new: u8) -> Vec<ShutterState> {
        [(false, old), (true, new)]
            .into_iter()
            .filter(|&(_, state)| state != 0)
            .map(|(entered, state)| ShutterState {
                time,
                actor: 2401,
                entered,
                state,
            })
            .collect()
    }

    fn shutter_names() -> BTreeMap<u32, Arc<str>> {
        BTreeMap::from([(2401, Arc::from("WindowShieldA3"))])
    }

    fn shut(start_ms: i64, end_ms: i64, to_rest: bool) -> DoorMove {
        DoorMove {
            actor: "WindowShieldA3".to_owned(),
            start_ms,
            end_ms,
            to_rest,
        }
    }

    #[test]
    fn a_door_shuts_and_opens_again() {
        // As WindowShieldA3 in round 2 of c8313344, on Sunset.
        let states = [
            call(123_200, 0, CLOSING),
            call(128_203, CLOSING, 3),
            call(152_023, 3, OPENING),
            call(157_023, OPENING, 0),
        ]
        .concat();

        assert_eq!(
            shutters(&states, &shutter_names(), MATCH_MS),
            [shut(123_200, 128_203, false), shut(152_023, 157_023, true)],
        );
    }

    #[test]
    fn a_rounds_start_cuts_a_shutting_door_short() {
        // As WindowShieldA3 at 87171: the round ended as it shut.
        let states = [call(87_171, 0, CLOSING), call(91_755, CLOSING, 0)].concat();

        assert_eq!(
            shutters(&states, &shutter_names(), MATCH_MS),
            [shut(87_171, 91_755, false)],
        );
    }

    #[test]
    fn a_door_shut_as_the_recording_ends_ends_there() {
        let states = call(390_000, 0, CLOSING);

        assert_eq!(
            shutters(&states, &shutter_names(), 393_000),
            [shut(390_000, 393_000, false)],
        );
    }

    #[test]
    fn a_door_without_a_name_moves_nothing() {
        let states = call(123_200, 0, CLOSING);

        assert_eq!(shutters(&states, &BTreeMap::new(), MATCH_MS), []);
    }

    #[test]
    fn a_wall_breaks_once_a_round() {
        assert_eq!(
            breaks(&[47_169, 47_170, 247_299, 247_299], &LOTUS),
            [47_169, 247_299],
        );
    }
}
