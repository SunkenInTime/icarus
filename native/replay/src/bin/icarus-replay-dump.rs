//! Dev tool: decode one replay and write what came out, for inspection.
//!
//!     icarus-replay-dump [--survey | --rows=A,B] <replay.vrf> [out-dir]
//!
//! Writes `<id>.icrp` and `<id>.json` (the document, movement summarized) to
//! `out-dir` (default: the current directory) and prints a one-line summary.
//! `--survey` instead writes `<id>.survey.tsv`: every (group, field) the
//! stream carried with its row and typed-value counts, for finding facts;
//! `--rows=A,B` writes `<id>.rows.tsv`, every field row whose name or group
//! contains A or B. Both also write `<id>.guids.tsv`, the GUID table.
//! Decompresses with the build's decoder (`oodle::default_decompressor`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use icarus_replay::decode::{Control, Observer};
use icarus_replay::{container, header, oodle};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let survey = args.iter().any(|a| a == "--survey");
    // `--rows=A,B`: every field row whose name or group contains A or B.
    let rows: Vec<String> = args
        .iter()
        .filter_map(|a| a.strip_prefix("--rows="))
        .flat_map(|a| a.split(',').map(str::to_owned))
        .collect();
    let paths: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    let Some(input) = paths.first() else {
        eprintln!("usage: icarus-replay-dump [--survey | --rows=A,B] <replay.vrf> [out-dir]");
        std::process::exit(2);
    };
    let out_dir = PathBuf::from(paths.get(1).map_or(".", |s| s.as_str()));
    let result = if survey || !rows.is_empty() {
        run_survey(Path::new(input), &out_dir, rows)
    } else {
        run_decode(Path::new(input), &out_dir)
    };
    if let Err(e) = result {
        eprintln!("{}", e.to_json());
        std::process::exit(1);
    }
}

fn run_decode(input: &Path, out_dir: &Path) -> Result<(), icarus_replay::ReplayError> {
    let started = Instant::now();
    let probe = header::probe(input)?;
    let probe_ms = started.elapsed().as_secs_f64() * 1000.0;
    let started = Instant::now();
    let buffer = icarus_replay::decode_file(input, Control::default())?;
    let decode_s = started.elapsed().as_secs_f64();
    let parts = container::read(&buffer).expect("our own buffer reads back");
    std::fs::create_dir_all(out_dir)?;
    std::fs::write(out_dir.join(format!("{}.icrp", probe.id)), &buffer)?;
    let mut doc: serde_json::Value = serde_json::from_str(parts.json).expect("our JSON parses");
    summarize_movement(&mut doc, parts.blob);
    let pretty = serde_json::to_string_pretty(&doc).expect("serializes");
    std::fs::write(out_dir.join(format!("{}.json", probe.id)), pretty)?;
    println!(
        "{} probe {probe_ms:.1} ms, decode {decode_s:.2} s, {} bytes ({} JSON, {} blob)",
        probe.id,
        buffer.len(),
        parts.json.len(),
        parts.blob.len()
    );
    Ok(())
}

/// Replace each player's movement entry with its count, time span and first
/// and last records.
fn summarize_movement(doc: &mut serde_json::Value, blob: &[u8]) {
    let Some(movement) = doc["movement"].as_object_mut() else {
        return;
    };
    for entry in movement.values_mut() {
        let offset = entry["offset"].as_u64().unwrap_or(0) as usize;
        let count = entry["count"].as_u64().unwrap_or(0) as usize;
        let record = |i: usize| {
            let at = offset + i * container::MOVEMENT_RECORD_BYTES;
            let s =
                container::MovementSample::read(&blob[at..at + container::MOVEMENT_RECORD_BYTES]);
            serde_json::json!([s.time_ms, s.x, s.y, s.z, s.yaw, s.pitch])
        };
        if count > 0 {
            entry["first"] = record(0);
            entry["last"] = record(count - 1);
        }
    }
}

#[derive(Default)]
struct Cell {
    rows: u64,
    i64s: u64,
    f64s: u64,
    bools: u64,
    strs: u64,
    samples: Vec<String>,
}

#[derive(Default)]
struct Survey {
    rows_filter: Vec<String>,
    rows: String,
    fields: BTreeMap<(String, String), Cell>,
    actors: BTreeMap<(String, &'static str), u64>,
    events: BTreeMap<String, u64>,
    movement_rows: u64,
}

impl Observer for Survey {
    fn on_event(&mut self, event: vrf_export::EventRecord) {
        *self.events.entry(event.group).or_default() += 1;
    }

    fn on_packet(&mut self, records: &icarus_replay::RecordBuffers, _: &vrf_schema::NetGuidCache) {
        self.movement_rows += records.movement.len() as u64;
        for a in &records.actors {
            let class = a.class_path.clone().unwrap_or_else(|| "?".into());
            *self.actors.entry((class, a.event)).or_default() += 1;
        }
        for f in &records.fields {
            if !self.rows_filter.is_empty() {
                let name = f.field_name.as_deref().unwrap_or("");
                if self
                    .rows_filter
                    .iter()
                    .any(|p| name.contains(p.as_str()) || f.group_path.contains(p.as_str()))
                {
                    let leaf = f.group_path.rsplit('/').next().unwrap_or("");
                    let value = f
                        .value_i64
                        .map(|v| v.to_string())
                        .or(f.value_f64.map(|v| v.to_string()))
                        .or(f.value_bool.map(|v| v.to_string()))
                        .or(f.value_str.clone())
                        .unwrap_or_else(|| format!("{}b", f.bit_count));
                    self.rows.push_str(&format!(
                        "{}\t{}\t{}\t{}\t{}\t{name}\t{value}\n",
                        f.time_ms,
                        f.packet_id,
                        f.actor_net_guid,
                        f.object_net_guid.map_or(String::new(), |o| o.to_string()),
                        leaf
                    ));
                }
                continue;
            }
            let name = f
                .field_name
                .as_deref()
                .map_or_else(|| format!("#{}", f.handle), normalize);
            let cell = self
                .fields
                .entry((f.group_path.to_string(), name))
                .or_default();
            cell.rows += 1;
            cell.i64s += u64::from(f.value_i64.is_some());
            cell.f64s += u64::from(f.value_f64.is_some());
            cell.bools += u64::from(f.value_bool.is_some());
            cell.strs += u64::from(f.value_str.is_some());
            if cell.samples.len() < 4 {
                let v = if let Some(v) = f.value_i64 {
                    v.to_string()
                } else if let Some(v) = f.value_f64 {
                    v.to_string()
                } else if let Some(v) = f.value_bool {
                    v.to_string()
                } else if let Some(v) = &f.value_str {
                    v.chars().take(120).collect()
                } else {
                    format!("{}b", f.bit_count)
                };
                cell.samples
                    .push(format!("{}@{}:{v}", f.actor_net_guid, f.time_ms));
            }
        }
    }
}

/// `A[3].B_12_0123…ABCD` -> `A[].B`: array indices and Blueprint GUID
/// suffixes dropped, so one row per member.
fn normalize(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut chars = name.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '[' {
            while let Some(&n) = chars.peek() {
                chars.next();
                if n == ']' {
                    break;
                }
            }
            out.push_str("[]");
        } else {
            out.push(c);
        }
    }
    // Blueprint member suffix: _<digits>_<32 hex>
    let mut parts: Vec<&str> = out.split('.').collect();
    let owned: Vec<String> = parts
        .iter_mut()
        .map(|p| {
            if let Some(cut) = p.rfind('_') {
                let hex = &p[cut + 1..];
                if hex.len() == 32 && hex.chars().all(|c| c.is_ascii_hexdigit()) {
                    let head = &p[..cut];
                    if let Some(cut2) = head.rfind('_') {
                        if head[cut2 + 1..].chars().all(|c| c.is_ascii_digit()) {
                            return head[..cut2].to_owned();
                        }
                    }
                }
            }
            (*p).to_owned()
        })
        .collect();
    owned.join(".")
}

fn run_survey(
    input: &Path,
    out_dir: &Path,
    rows_filter: Vec<String>,
) -> Result<(), icarus_replay::ReplayError> {
    let preamble = header::read_preamble(input)?;
    let data = std::fs::read(input)?;
    let mut survey = Survey {
        rows_filter,
        ..Survey::default()
    };
    let started = Instant::now();
    let decompressor = oodle::default_decompressor();
    let branch = preamble.header.replay_version.branch.clone();
    let walked = icarus_replay::decode::walk(
        &data,
        &preamble,
        &branch,
        decompressor.as_ref(),
        Control::default(),
        &mut survey,
    )?;
    let mut out = String::new();
    out.push_str(&format!(
        "# walk {:.2} s, packets {}, movement rows {}, stream failures {}\n",
        started.elapsed().as_secs_f64(),
        walked.packets,
        survey.movement_rows,
        walked.stream_failures.len()
    ));
    for (group, n) in &survey.events {
        out.push_str(&format!("event\t{group}\t{n}\n"));
    }
    for ((class, event), n) in &survey.actors {
        out.push_str(&format!("actor\t{class}\t{event}\t{n}\n"));
    }
    for ((group, field), c) in &survey.fields {
        out.push_str(&format!(
            "field\t{group}\t{field}\t{}\ti{} f{} b{} s{}\t{}\n",
            c.rows,
            c.i64s,
            c.f64s,
            c.bools,
            c.strs,
            c.samples.join(" | ")
        ));
    }
    std::fs::create_dir_all(out_dir)?;
    let mut guids = walked.cache.net_guid_entries();
    guids.sort_unstable_by_key(|e| e.net_guid);
    let guids: String = guids
        .iter()
        .map(|e| {
            let outer = e.outer_net_guid.map_or(String::new(), |o| o.to_string());
            format!("{}\t{outer}\t{}\n", e.net_guid, e.path)
        })
        .collect();
    std::fs::write(
        out_dir.join(format!("{}.guids.tsv", preamble.info.friendly_name)),
        guids,
    )?;
    if !survey.rows_filter.is_empty() {
        let name = format!("{}.rows.tsv", preamble.info.friendly_name);
        std::fs::write(out_dir.join(&name), &survey.rows)?;
        println!("wrote {name}");
        return Ok(());
    }
    let name = format!("{}.survey.tsv", preamble.info.friendly_name);
    std::fs::write(out_dir.join(&name), out)?;
    println!("wrote {name}");
    Ok(())
}
