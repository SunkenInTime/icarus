// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrfkit/src/pass.rs. Apache-2.0;
// see native/replay/NOTICE.md. Local edits: `Replay`, `for_each_chunk` and the
// checkpoint block scope are dropped (crate::decode walks the chunks), the
// CLI error type is replaced by `vrf_frame::FrameError`, and `walk` runs our
// vendored frame walker (`super::frame`) with its `admit` hook, stopping the
// moment either callback says so.

//! The decode pass every subcommand runs: `validate`, `diag` and `export`, over
//! the ReplayData stream and over each Checkpoint snapshot.

use vrf_bitio::BitReader;
use vrf_frame::{FrameError, FrameSkips};
use vrf_net::pipeline::ReplicationReader;
use vrf_schema::NetGuidCache;

use super::frame::walk_demo_frames;
use super::sink::{ChannelState, ExportSink, ExportStats, RecordBuffers};

/// One replication stream -- the ReplayData stream, or one checkpoint
/// snapshot -- and what walking it counted.
pub(crate) struct Pass<'a> {
    branch: &'a str,
    flags: u32,
    pub cache: NetGuidCache,
    pub reader: ReplicationReader,
    pub channels: ChannelState,
    pub buffers: RecordBuffers,
    /// Packets walked, and so the next packet's id.
    pub packets: u32,
    pub frames: u32,
    pub frame_skips: FrameSkips,
    pub non_finite_frame_times: u64,
}

impl<'a> Pass<'a> {
    /// `reader` is built by the caller (`ReplicationReader::new(branch)`), so an
    /// unknown branch is the caller's error to name.
    pub fn new(branch: &'a str, flags: u32, reader: ReplicationReader) -> Self {
        Self {
            branch,
            flags,
            cache: NetGuidCache::new(),
            reader,
            channels: ChannelState::default(),
            buffers: RecordBuffers::default(),
            packets: 0,
            frames: 0,
            frame_skips: FrameSkips::default(),
            non_finite_frame_times: 0,
        }
    }

    /// Read every packet in `frames` through a fresh sink counting into
    /// `stats`, then hand its rows to `drain`. `admit` sees each frame's
    /// ExportData before the cache applies it. Once either returns `false`
    /// the walk stops.
    pub fn walk(
        &mut self,
        frames: &[u8],
        stats: &mut ExportStats,
        admit: impl FnMut(&BitReader<'_>, &NetGuidCache) -> bool,
        mut drain: impl FnMut(&mut RecordBuffers, &NetGuidCache) -> bool,
    ) -> Result<(), FrameError> {
        let branch = self.branch;
        let Self {
            cache,
            reader,
            channels,
            buffers,
            packets,
            ..
        } = self;
        let walk = walk_demo_frames(frames, self.flags, cache, admit, |pkt, cache| {
            let mut packet = ExportSink::new(cache, channels, buffers);
            packet.enable_measured_array_routes(branch);
            packet.time_ms = pkt.time_ms;
            packet.packet_id = *packets;
            // Lent, not folded: the totals ride in the sink and come back.
            std::mem::swap(&mut packet.stats, stats);
            reader.process_packet(pkt.data, *packets as i32, &mut packet);
            std::mem::swap(&mut packet.stats, stats);
            *packets += 1;
            drain(buffers, cache)
        })?;
        self.frames += walk.frames;
        self.frame_skips.absorb(walk.skipped);
        self.non_finite_frame_times += u64::from(walk.non_finite_times);
        Ok(())
    }

    /// End of stream: every bunch still in partial reassembly is counted and
    /// becomes a `buffers.partials` row. Until the stream stops, an
    /// unfinished partial cannot be told from one in flight.
    pub fn finish(&mut self) {
        let mut sink = ExportSink::new(&mut self.cache, &mut self.channels, &mut self.buffers);
        self.reader.finish_with_sink(&mut sink);
    }
}
