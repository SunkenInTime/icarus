//! The walk over a whole replay: chunks -> decompressed DemoFrames -> packets
//! -> vrfkit's sink records, handed to an [`Observer`] packet by packet so no
//! caller holds the million field rows of a match at once.
//!
//! The per-packet pass is vrfkit's (`vendor::pass`); this module owns the
//! chunk loop that vrfkit's CLI keeps in `pass::for_each_chunk` and the
//! driver, because ours decompresses through the Oodle seam, reports
//! progress, can be cancelled and holds the walk to `crate::limits`.

use std::cell::Cell;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::sync_channel;
use std::thread;

use vrf_container::{
    ChunkIterator, ChunkType, Preamble, event_payload_seconds_matches_time, known_event_word_count,
    parse_event_chunk, parse_known_event_payload,
};
use vrf_export::EventRecord;
use vrf_net::pipeline::ReplicationReader;
use vrf_net::stats::NetStats;
use vrf_schema::{FxHashMap, NetGuidCache};

use crate::error::{ErrorCode, ReplayError};
use crate::limits;
use crate::oodle::{Decompressor, inflate_replay_data};
use crate::vendor::pass::Pass;
use crate::vendor::sink::{ExportStats, PlayerIdentity, RecordBuffers};

/// A decode's progress and cancel cells, borrowed (the C ABI lends its
/// `IcarusReplayControl`'s).
#[derive(Default, Clone, Copy)]
pub struct Control<'a> {
    /// 0..=10000, hundredths of a percent; relaxed stores.
    pub progress: Option<&'a AtomicU32>,
    /// Nonzero asks the decode to stop with `cancelled`.
    pub cancel: Option<&'a AtomicU32>,
}

/// Progress is in hundredths of a percent.
pub const PROGRESS_DONE: u32 = 10_000;
/// The walk's share of the progress bar; the analysis takes the rest.
pub const WALK_SHARE: f64 = 0.9;

impl Control<'_> {
    pub fn cancelled(&self) -> bool {
        self.cancel.is_some_and(|c| c.load(Ordering::Relaxed) != 0)
    }

    pub fn check(&self) -> Result<(), ReplayError> {
        if self.cancelled() {
            Err(ReplayError::cancelled())
        } else {
            Ok(())
        }
    }

    /// Report `fraction` (0..1) of the work done.
    pub fn report(&self, fraction: f64) {
        if let Some(p) = self.progress {
            let value = (fraction.clamp(0.0, 1.0) * f64::from(PROGRESS_DONE)).round() as u32;
            p.store(value, Ordering::Relaxed);
        }
    }
}

/// What the walk hands its consumer. An error stops the walk with it.
pub trait Observer {
    /// One Event chunk, parsed as vrfkit's driver parses it.
    fn on_event(&mut self, event: EventRecord) -> Result<(), ReplayError>;
    /// One packet's records; `cache` is the GUID table as of that packet.
    fn on_packet(
        &mut self,
        records: &RecordBuffers,
        cache: &NetGuidCache,
    ) -> Result<(), ReplayError>;
}

/// What the walk counted, and the state the analysis reads afterwards.
pub struct Walked {
    pub cache: NetGuidCache,
    pub players: FxHashMap<u32, PlayerIdentity>,
    pub stats: ExportStats,
    pub net: NetStats,
    pub unknown_chunks: u32,
    pub packets: u32,
    /// Event chunks whose payload did not fit the measured layout.
    pub event_layout_mismatches: u32,
    pub stream_failures: Vec<String>,
}

/// Walk `data` (the whole file). `transform_branch` picks the payload
/// transform: the header's own branch, except in the guard's tests.
pub fn walk(
    data: &[u8],
    preamble: &Preamble,
    transform_branch: &str,
    decompressor: &dyn Decompressor,
    control: Control<'_>,
    observer: &mut dyn Observer,
) -> Result<Walked, ReplayError> {
    let build = preamble.header.replay_version.branch.as_str();
    let reader = ReplicationReader::new(transform_branch).map_err(|e| {
        ReplayError::new(ErrorCode::UnsupportedBuild, e.to_string()).with_build(build)
    })?;
    if preamble.info.encrypted {
        return Err(
            ReplayError::new(ErrorCode::UnsupportedBuild, "encrypted replay").with_build(build),
        );
    }
    let mut pass = Pass::new(transform_branch, preamble.header.flags, reader);
    let mut stats = ExportStats::default();
    let compressed = preamble.info.compressed;
    let first_chunk = preamble.remaining_offset;
    let total = data.len().max(1) as f64;

    let chunks = move || {
        let mut iter = ChunkIterator::new(data, first_chunk);
        std::iter::from_fn(move || match iter.next_chunk() {
            Ok(Some(c)) => {
                let end = c.data_offset + c.size_in_bytes as usize;
                Some(Ok((c.chunk_type, &data[c.data_offset..end], end)))
            }
            Ok(None) => None,
            Err(e) => {
                iter = ChunkIterator::new(&[], 0);
                Some(Err(e))
            }
        })
    };

    let mut walked = Walked {
        cache: NetGuidCache::new(),
        players: FxHashMap::default(),
        stats: ExportStats::default(),
        net: NetStats::default(),
        unknown_chunks: 0,
        packets: 0,
        event_layout_mismatches: 0,
        stream_failures: Vec::new(),
    };

    let mut inflated = limits::Inflated::default();
    thread::scope(|scope| -> Result<(), ReplayError> {
        // Rendezvous: the helper holds at most one decompressed chunk ahead
        // (Oodle is order-free and a fifth of the work in vrfkit's measure).
        let (tx, rx) = sync_channel(0);
        scope.spawn(move || {
            for (_, payload, _) in chunks()
                .map_while(Result::ok)
                .filter(|(kind, _, _)| *kind == ChunkType::ReplayData)
            {
                if control.cancelled() {
                    return;
                }
                if tx
                    .send(inflate_replay_data(payload, compressed, decompressor))
                    .is_err()
                {
                    return;
                }
            }
        });
        for chunk in chunks() {
            control.check()?;
            let (kind, payload, end) = chunk.map_err(|e| crate::header::container_error(&e))?;
            match kind {
                ChunkType::ReplayData => {
                    let Ok(inflated_chunk) = rx.recv() else {
                        // The helper stops early only when cancelled.
                        control.check()?;
                        return Err(ReplayError::new(
                            ErrorCode::Corrupt,
                            "decompression stopped",
                        ));
                    };
                    let frames = inflated_chunk?;
                    inflated.add(frames.len())?;
                    // Why a callback stopped the walk, between frames or packets.
                    let stop = Cell::new(None);
                    let go_on = |result: Result<(), ReplayError>| match result
                        .and_then(|()| control.check())
                    {
                        Ok(()) => true,
                        Err(e) => {
                            stop.set(Some(e));
                            false
                        }
                    };
                    pass.walk(
                        &frames,
                        &mut stats,
                        |exports, cache| go_on(limits::admit_exports(exports, cache)),
                        |records, cache| go_on(observer.on_packet(records, cache)),
                    )
                    .map_err(|e| ReplayError::new(ErrorCode::Corrupt, e.to_string()))?;
                    if let Some(e) = stop.take() {
                        return Err(e);
                    }
                }
                ChunkType::Event => {
                    let event = parse_event(payload, &mut walked.event_layout_mismatches)?;
                    observer.on_event(event)?;
                }
                // Checkpoints repeat state the stream already carried.
                ChunkType::Checkpoint | ChunkType::Header => {}
                ChunkType::Unknown(_) => walked.unknown_chunks += 1,
            }
            control.report(WALK_SHARE * end as f64 / total);
        }
        Ok(())
    })
    .map_err(|e| match e.build {
        Some(_) => e,
        None => e.with_build(build),
    })?;

    pass.finish();
    observer
        .on_packet(&pass.buffers, &pass.cache)
        .map_err(|e| e.with_build(build))?;
    walked.packets = pass.packets;
    walked.net = pass.reader.stats().clone();
    walked.stream_failures = pass.channels.stream_failures().to_vec();
    walked.players = pass.channels.players().clone();
    walked.cache = pass.cache;
    walked.stats = stats;
    Ok(walked)
}

/// One Event chunk as vrfkit's driver (`write_event`) reads it: the words
/// only when the payload fits the measured layout exactly.
fn parse_event(payload: &[u8], mismatches: &mut u32) -> Result<EventRecord, ReplayError> {
    let event = parse_event_chunk(payload)
        .map_err(|e| ReplayError::new(ErrorCode::Corrupt, format!("event chunk: {e}")))?;
    let parsed = known_event_word_count(&event.group).and_then(|_| {
        let parsed = parse_known_event_payload(&event.group, event.payload)
            .filter(|p| event_payload_seconds_matches_time(event.time1, p.seconds));
        if parsed.is_none() {
            *mismatches += 1;
        }
        parsed
    });
    Ok(EventRecord {
        id: event.id,
        group: event.group,
        metadata: event.metadata,
        time1: event.time1,
        time2: event.time2,
        payload_size: event.size_in_bytes,
        raw_payload: event.payload.to_vec(),
        word0: parsed.as_ref().and_then(|p| p.words.first().copied()),
        word1: parsed.as_ref().and_then(|p| p.words.get(1).copied()),
        payload_tag: parsed.as_ref().map(|p| p.tag),
        payload_name: parsed.as_ref().map(|p| p.name.clone()),
        payload_seconds: parsed.as_ref().map(|p| p.seconds),
    })
}
