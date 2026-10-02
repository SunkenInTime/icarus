//! Corpus tests over real replays: set `ICARUS_REPLAY_CORPUS` to a directory
//! of `.vrf` files (skipped otherwise). Each decoded replay is checked
//! against its own Event chunks and against the rules of a match.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use icarus_replay::container::{self, MOVEMENT_RECORD_BYTES, MovementSample};
use icarus_replay::decode::Control;
use icarus_replay::{ErrorCode, header, oodle};
use serde_json::Value;
use vrf_container::{ChunkIterator, ChunkType, parse_event_chunk, parse_preamble};

fn corpus() -> Vec<PathBuf> {
    let Some(dir) = std::env::var_os("ICARUS_REPLAY_CORPUS") else {
        eprintln!("ICARUS_REPLAY_CORPUS unset: corpus test skipped");
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .expect("ICARUS_REPLAY_CORPUS is a directory")
        .map(|e| e.expect("readable").path())
        .filter(|p| p.extension().is_some_and(|e| e == "vrf"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "ICARUS_REPLAY_CORPUS holds no .vrf");
    files
}

/// Event chunks per group, read straight off the file.
fn event_counts(path: &Path) -> HashMap<String, usize> {
    let data = std::fs::read(path).unwrap();
    let preamble = parse_preamble(&data).unwrap();
    let mut chunks = ChunkIterator::new(&data, preamble.remaining_offset);
    let mut counts = HashMap::new();
    while let Some(c) = chunks.next_chunk().unwrap() {
        if c.chunk_type == ChunkType::Event {
            let payload = &data[c.data_offset..][..c.size_in_bytes as usize];
            *counts
                .entry(parse_event_chunk(payload).unwrap().group)
                .or_default() += 1;
        }
    }
    counts
}

#[test]
fn every_replay_probes_fast_without_decompressing() {
    for path in corpus() {
        let started = std::time::Instant::now();
        let probe = header::probe(&path).expect("probe");
        let elapsed = started.elapsed();
        eprintln!("{} probe {:?}", probe.id, elapsed);
        assert!(elapsed.as_millis() < 50, "{} took {elapsed:?}", probe.id);
        assert!(probe.supported, "{} build {}", probe.id, probe.build);
        assert_eq!(probe.decoder_version, header::DECODER_VERSION);
        assert_eq!(probe.players.len(), 10, "{}", probe.id);
        assert!(probe.players.iter().all(|p| p.agent_id.is_some()));
    }
}

#[test]
fn a_build_without_a_decoder_reports_unsupported_compression() {
    for path in corpus().into_iter().take(1) {
        let err = icarus_replay::decode_file_with(&path, &oodle::Unavailable, Control::default())
            .expect_err("no decoder");
        assert_eq!(err.code, ErrorCode::UnsupportedCompression, "{err}");
        assert!(err.build.is_some());
    }
}

#[test]
fn every_replay_decodes_to_the_contract() {
    for path in corpus() {
        let started = std::time::Instant::now();
        let buffer = icarus_replay::decode_file(&path, Control::default()).expect("decode");
        let parts = container::read(&buffer).expect("container");
        assert_eq!(parts.format_version, 1);
        let doc: Value = serde_json::from_str(parts.json).expect("JSON");
        let id = doc["match"]["id"].as_str().unwrap().to_owned();
        eprintln!("{id} decoded in {:?}", started.elapsed());

        assert_eq!(doc["decoder"]["version"], header::DECODER_VERSION);
        assert_eq!(doc["quality"]["transformVerified"], true);
        assert_eq!(doc["quality"]["decodeErrors"], 0);

        let players = doc["players"].as_array().unwrap();
        let team: HashMap<&str, &str> = players
            .iter()
            .map(|p| (p["subject"].as_str().unwrap(), p["team"].as_str().unwrap()))
            .collect();
        let red = team.values().filter(|&&t| t == "Red").count();
        assert_eq!((red, team.len() - red), (5, 5), "{id}: teams");

        let rounds = doc["rounds"].as_array().unwrap();
        let kills = doc["kills"].as_array().unwrap();
        check_event_counts(&id, &event_counts(&path), rounds, kills);
        check_score(&id, rounds);
        check_sides(&id, rounds, kills, &team);
        check_vitals(&id, &doc, rounds, kills, &team);
        check_movement(&id, &doc, parts.blob, &team);
        check_utility(&id, doc["utility"].as_array().unwrap());
        for c in doc["casts"].as_array().unwrap() {
            assert!(
                [3, 4, 5, 9].contains(&c["slot"].as_i64().unwrap()),
                "{id}: cast {c}"
            );
        }
    }
}

/// One round per `roundStarted`, one kill per `characterDeath`, and every
/// plant, defuse and detonation the Event chunks record.
fn check_event_counts(
    id: &str,
    events: &HashMap<String, usize>,
    rounds: &[Value],
    kills: &[Value],
) {
    let count = |group: &str| events.get(group).copied().unwrap_or(0);
    let with = |key: &str| rounds.iter().filter(|r| !r[key].is_null()).count();
    assert_eq!(rounds.len(), count("roundStarted"), "{id}: rounds");
    assert_eq!(kills.len(), count("characterDeath"), "{id}: kills");
    assert_eq!(with("plant"), count("spikePlanted"), "{id}: plants");
    assert_eq!(with("defuse"), count("spikeDefused"), "{id}: defuses");
    assert_eq!(
        with("detonateMs"),
        count("spikeExploded"),
        "{id}: detonations"
    );
}

/// Winners follow the score: no round is played once a team has 13 with a
/// two-round lead, and the last round decides the match unless it was
/// surrendered or the replay stops inside it.
fn check_score(id: &str, rounds: &[Value]) {
    let mut score: HashMap<&str, u32> = HashMap::from([("Red", 0), ("Blue", 0)]);
    let decided = |s: &HashMap<&str, u32>| {
        let (r, b) = (s["Red"], s["Blue"]);
        r.max(b) >= 13 && r.abs_diff(b) >= 2
    };
    for (i, r) in rounds.iter().enumerate() {
        assert_eq!(r["index"], i);
        assert!(
            r["startMs"].as_i64() <= r["endMs"].as_i64(),
            "{id} round {i}"
        );
        assert!(
            !decided(&score),
            "{id}: round {i} played after the match was won"
        );
        match r["winningTeam"].as_str() {
            Some(team) => *score.get_mut(team).expect("Red or Blue") += 1,
            None => assert_eq!(i, rounds.len() - 1, "{id}: round {i} has no winner"),
        }
    }
    let last = rounds.last().expect("a round");
    assert!(
        decided(&score) || last["endReason"] == "surrender" || last["winningTeam"].is_null(),
        "{id}: the match ends undecided at {score:?}"
    );
}

/// Sides switch after 12 rounds and every overtime round; the teams' own
/// acts agree: attackers plant, defenders defuse, no one kills a teammate.
fn check_sides(id: &str, rounds: &[Value], kills: &[Value], team: &HashMap<&str, &str>) {
    let first = rounds[0]["attackingTeam"].as_str().unwrap();
    for (i, r) in rounds.iter().enumerate() {
        let swapped = match i {
            0..12 => false,
            12..24 => true,
            _ => (i - 24) % 2 == 1,
        };
        let attackers = r["attackingTeam"].as_str().unwrap();
        assert_eq!(attackers != first, swapped, "{id}: round {i} attackers");
        let of = |v: &Value| team[v["subject"].as_str().expect("named")];
        if !r["plant"].is_null() {
            assert_eq!(of(&r["plant"]), attackers, "{id}: round {i} planter");
        }
        if !r["defuse"].is_null() {
            assert_ne!(of(&r["defuse"]), attackers, "{id}: round {i} defuser");
        }
    }
    for k in kills {
        let victim = team[k["victim"].as_str().unwrap()];
        if let Some(killer) = k["killer"].as_str() {
            assert_ne!(team[killer], victim, "{id}: team kill {k}");
        }
    }
}

/// Every player opens every round at 100 health and lies at 0 after each
/// death; nothing is negative or unknown.
fn check_vitals(
    id: &str,
    doc: &Value,
    rounds: &[Value],
    kills: &[Value],
    team: &HashMap<&str, &str>,
) {
    let rows = |subject: &str| -> Vec<(i64, f64, f64)> {
        doc["vitals"][subject]
            .as_array()
            .unwrap_or_else(|| panic!("{id}: no vitals for {subject}"))
            .iter()
            .map(|r| {
                (
                    r[0].as_i64().unwrap(),
                    r[1].as_f64().unwrap(),
                    r[2].as_f64().unwrap(),
                )
            })
            .collect()
    };
    let at = |rows: &[(i64, f64, f64)], t: i64| rows.iter().rev().find(|r| r.0 <= t).copied();
    for &subject in team.keys() {
        let rows = rows(subject);
        assert!(
            rows.iter().all(|r| r.1 >= 0.0 && r.2 >= 0.0),
            "{id} {subject}"
        );
        for r in rounds {
            let start = r["startMs"].as_i64().unwrap();
            assert!(
                rows.iter().any(|&(t, h, _)| t == start && h == 100.0),
                "{id} {subject}: round {} opens without a full-health row",
                r["index"]
            );
        }
    }
    for k in kills {
        let victim = k["victim"].as_str().unwrap();
        // The death's damage call follows its event by a few milliseconds.
        let t = k["timeMs"].as_i64().unwrap() + 100;
        assert_eq!(at(&rows(victim), t).map(|r| r.1), Some(0.0), "{id}: {k}");
    }
}

/// Every player moves; each span is in bounds, sorted, and signed in pitch.
fn check_movement(id: &str, doc: &Value, blob: &[u8], team: &HashMap<&str, &str>) {
    let movement = doc["movement"].as_object().unwrap();
    assert_eq!(movement.len(), team.len(), "{id}: movement per player");
    for (subject, span) in movement {
        let offset = span["offset"].as_u64().unwrap() as usize;
        let count = span["count"].as_u64().unwrap() as usize;
        assert!(count > 0, "{id} {subject}: no movement");
        let bytes = &blob[offset..offset + count * MOVEMENT_RECORD_BYTES];
        let mut last = i32::MIN;
        for record in bytes.chunks(MOVEMENT_RECORD_BYTES) {
            let s = MovementSample::read(record);
            assert!(s.time_ms >= last, "{id} {subject}: unsorted");
            assert!((-180.0..=180.0).contains(&s.pitch), "{id} {subject}: {s:?}");
            last = s.time_ms;
        }
    }
}

/// Paths run inside the actor's life at no more than 10 Hz; shapes start
/// where their actor is, and a Trapwire reaches its far anchor along its yaw.
fn check_utility(id: &str, utility: &[Value]) {
    let asset = |u: &Value| {
        let path = u["classPath"].as_str().unwrap();
        path.rsplit('/')
            .next()
            .unwrap()
            .split('.')
            .next()
            .unwrap()
            .to_owned()
    };
    let xy = |v: &Value| (v[0].as_f64().unwrap(), v[1].as_f64().unwrap());
    let far = |a: (f64, f64), b: (f64, f64)| (a.0 - b.0).hypot(a.1 - b.1);
    for u in utility {
        let (spawn, end) = (u["spawnMs"].as_f64().unwrap(), u["endMs"].as_f64());
        let path = u["path"].as_array().map_or(&[][..], Vec::as_slice);
        assert!(
            path.iter().all(|p| p[0].is_i64()),
            "{id}: path time not an integer {u}"
        );
        let times: Vec<f64> = path.iter().map(|p| p[0].as_f64().unwrap()).collect();
        assert!(
            times
                .iter()
                .all(|&t| t >= spawn && end.is_none_or(|e| t <= e)),
            "{id}: path outside its life {u}"
        );
        assert!(
            times.windows(2).rev().skip(1).all(|w| w[1] - w[0] >= 100.0),
            "{id}: path above 10 Hz {u}"
        );
        let points = u["points"].as_array().map_or(&[][..], Vec::as_slice);
        let at = xy(&u["position"]);
        match asset(u).as_str() {
            "GameObject_Gumshoe_E_TripWire" => {
                assert_eq!(points.len(), 1, "{id}: Trapwire far end {u}");
                let (x, y) = xy(&points[0]);
                let toward = (y - at.1).atan2(x - at.0).to_degrees();
                let off = (toward - u["yaw"].as_f64().unwrap()).rem_euclid(360.0);
                assert!(off.min(360.0 - off) < 1.0, "{id}: Trapwire yaw {u}");
            }
            "GameObject_Nox_Wall" | "GameObject_Sprinter_4_Tunnel" => {
                assert!(points.len() >= 2, "{id}: wall points {u}");
                assert!(far(xy(&points[0]), at) < 1.0, "{id}: wall start {u}");
            }
            "GameObject_CableJamRoot" => {
                assert!((1..=4).contains(&points.len()), "{id}: mesh arms {u}");
            }
            _ => {}
        }
    }
}

/// The guard's measure on every replay read with its own transform: far from
/// both thresholds, so neither a quiet match nor a busy one trips it.
#[test]
fn every_replay_passes_the_guard_with_margin() {
    let decompressor = oodle::default_decompressor();
    for path in corpus() {
        let data = std::fs::read(&path).unwrap();
        let build = header::probe(&path).unwrap().build;
        let (verdict, sample) =
            icarus_replay::measure_guard(&data, &build, decompressor.as_ref()).unwrap();
        eprintln!(
            "{}: {:.1}% zero bytes, {:.1}% bits set over {} bytes of {} payloads",
            path.file_name().unwrap().to_string_lossy(),
            verdict.zero_share * 100.0,
            verdict.bit_density * 100.0,
            sample.bytes,
            sample.payloads
        );
        assert!(verdict.verified);
        assert!(
            verdict.zero_share > 2.0 * icarus_replay::guard::MIN_ZERO_SHARE,
            "{verdict:?}"
        );
        assert!(
            verdict.bit_density < icarus_replay::guard::MAX_BIT_DENSITY - 0.05,
            "{verdict:?}"
        );
    }
}

/// A transform that is registered but wrong for the file decodes into noise;
/// the guard must refuse it rather than return an empty replay.
#[test]
fn a_wrong_transform_fails_the_guard() {
    let decompressor = oodle::default_decompressor();
    for path in corpus().into_iter().take(2) {
        let data = std::fs::read(&path).unwrap();
        let build = header::probe(&path).unwrap().build;
        let wrong = if build == "++Ares-Core+release-13.01" {
            "++Ares-Core+release-13.02"
        } else {
            "++Ares-Core+release-13.01"
        };
        let err =
            icarus_replay::decode_bytes(&data, wrong, decompressor.as_ref(), Control::default())
                .expect_err("a wrong transform must not decode");
        eprintln!("{}: {}", path.display(), err.message);
        assert_eq!(err.code, ErrorCode::TransformCheckFailed, "{err}");
    }
}

#[test]
fn cancel_stops_a_decode() {
    for path in corpus().into_iter().take(1) {
        let cancel = std::sync::atomic::AtomicU32::new(1);
        let err = icarus_replay::decode_file(
            &path,
            Control {
                progress: None,
                cancel: Some(&cancel),
            },
        )
        .expect_err("cancelled");
        assert_eq!(err.code, ErrorCode::Cancelled);
        assert!(err.build.is_some(), "the header was read");
    }
}

#[test]
fn progress_reaches_done() {
    for path in corpus().into_iter().take(1) {
        let progress = std::sync::atomic::AtomicU32::new(0);
        icarus_replay::decode_file(
            &path,
            Control {
                progress: Some(&progress),
                cancel: None,
            },
        )
        .unwrap();
        assert_eq!(progress.load(std::sync::atomic::Ordering::Relaxed), 10_000);
    }
}
