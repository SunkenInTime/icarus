//! Corpus tests over real replays: set `ICARUS_REPLAY_CORPUS` to a directory
//! of `.vrf` files (skipped otherwise). Decoding needs Oodle: run with
//! `--features dev-vectors` and `ICARUS_OODLE_VECTORS` set.

use std::path::PathBuf;

use icarus_replay::container::{self, MOVEMENT_RECORD_BYTES, MovementSample};
use icarus_replay::decode::Control;
use icarus_replay::{ErrorCode, header, oodle};

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

fn decoder_available() -> bool {
    cfg!(feature = "dev-vectors") && std::env::var_os("ICARUS_OODLE_VECTORS").is_some()
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
    if !decoder_available() {
        eprintln!("no Oodle decoder: decode test skipped");
        return;
    }
    for path in corpus() {
        let started = std::time::Instant::now();
        let buffer = icarus_replay::decode_file(&path, Control::default()).expect("decode");
        let parts = container::read(&buffer).expect("container");
        assert_eq!(parts.format_version, 1);
        let doc: serde_json::Value = serde_json::from_str(parts.json).expect("JSON");
        let id = doc["match"]["id"].as_str().unwrap().to_owned();
        eprintln!("{id} decoded in {:?}", started.elapsed());

        assert_eq!(doc["decoder"]["version"], header::DECODER_VERSION);
        assert_eq!(doc["quality"]["transformVerified"], true);
        assert_eq!(doc["quality"]["decodeErrors"], 0);

        let players = doc["players"].as_array().unwrap();
        let red = players.iter().filter(|p| p["team"] == "Red").count();
        let blue = players.iter().filter(|p| p["team"] == "Blue").count();
        assert_eq!((red, blue), (5, 5), "{id}: teams");

        // Kills and rounds come one per Event-chunk death and round start.
        let rounds = doc["rounds"].as_array().unwrap();
        assert!(!rounds.is_empty());
        for (i, r) in rounds.iter().enumerate() {
            assert_eq!(r["index"], i);
            assert!(
                r["startMs"].as_i64() <= r["endMs"].as_i64(),
                "{id} round {i}"
            );
            assert!(r["attackingTeam"].is_string(), "{id} round {i}: attackers");
        }
        let kills = doc["kills"].as_array().unwrap();
        let subjects: Vec<&str> = players
            .iter()
            .map(|p| p["subject"].as_str().unwrap())
            .collect();
        for k in kills {
            assert!(subjects.contains(&k["victim"].as_str().unwrap()));
        }

        // Movement: every span in bounds, sorted, no parked record.
        for (subject, span) in doc["movement"].as_object().unwrap() {
            let offset = span["offset"].as_u64().unwrap() as usize;
            let count = span["count"].as_u64().unwrap() as usize;
            assert!(count > 0, "{id} {subject}: no movement");
            let bytes = &parts.blob[offset..offset + count * MOVEMENT_RECORD_BYTES];
            let mut last = i32::MIN;
            for record in bytes.chunks(MOVEMENT_RECORD_BYTES) {
                let s = MovementSample::read(record);
                assert!(s.time_ms >= last, "{id} {subject}: unsorted");
                assert!(
                    !(s.x < -40_000.0 && s.z < -40_000.0),
                    "{id} {subject}: parked at {s:?}"
                );
                assert!((-180.0..=180.0).contains(&s.pitch));
                last = s.time_ms;
            }
        }
    }
}

/// The guard's measure on every replay read with its own transform: far from
/// both thresholds, so neither a quiet match nor a busy one trips it.
#[test]
fn every_replay_passes_the_guard_with_margin() {
    if !decoder_available() {
        return;
    }
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
    if !decoder_available() {
        eprintln!("no Oodle decoder: guard test skipped");
        return;
    }
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
    if !decoder_available() {
        return;
    }
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
    if !decoder_available() {
        return;
    }
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
