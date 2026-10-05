// Vendored from vrfkit v0.2.5 (c4d6cc0), crates/vrf-frame/src/lib.rs and
// sections.rs. Apache-2.0; see native/replay/NOTICE.md. Local edits:
// `walk_demo_frames` takes a `before_exports` hook that sees each frame's
// ExportData before the cache applies it, both callbacks return `false` to
// stop the walk, and `FrameWalk` is a copy (vrf-frame's is non-exhaustive, so
// it cannot be built here). The wire-layout notes live in vrf-frame.

//! DemoFrame iteration: decompressed replay-data chunk -> `(time_ms, packet)`
//! sequence.

use vrf_bitio::BitReader;
use vrf_frame::{
    DemoPacket, FLAG_GAME_SPECIFIC_FRAME_DATA, FLAG_HAS_STREAMING_FIXES, FrameError, FrameSkips,
};
use vrf_schema::NetGuidCache;

/// Unreal's `MaxPacketSizeInBits`, in bytes.
const MAX_PACKET_SIZE_BYTES: i32 = 16384 / 8;

/// Cap on a level name's FString.
const MAX_FSTRING_BYTES: i64 = 1024 * 1024;

/// What one [`walk_demo_frames`] call walked.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FrameWalk {
    /// Packets yielded to the callback.
    pub packets: u32,
    /// DemoFrames walked; not derivable from `packets`, since a frame carries
    /// any number of packets.
    pub frames: u32,
    /// Section bytes stepped over without being decoded.
    pub skipped: FrameSkips,
    /// Frames whose `timeSeconds` was NaN or infinite. Their packets carry
    /// 0 ms: a plausible wrong time, so it is counted.
    pub non_finite_times: u32,
}

/// Walk every DemoFrame in a decompressed ReplayData chunk (`data`), calling
/// `on_packet` for each packet. `flags` is `ReplayHeader.flags`.
///
/// Each frame's ExportData is applied to `cache` before its packets, after
/// `before_exports` has seen it: a reader at the section's start and the
/// cache it is about to change. `on_packet` gets the frame's time, the
/// packet's bytes (a slice of `data`) and the cache as of that packet's wire
/// position. Either returning `false` stops the walk there.
pub fn walk_demo_frames(
    data: &[u8],
    flags: u32,
    cache: &mut NetGuidCache,
    mut before_exports: impl FnMut(&BitReader<'_>, &NetGuidCache) -> bool,
    mut on_packet: impl FnMut(DemoPacket<'_>, &mut NetGuidCache) -> bool,
) -> Result<FrameWalk, FrameError> {
    let has_streaming_fixes = (flags & FLAG_HAS_STREAMING_FIXES) != 0;
    let has_game_specific = (flags & FLAG_GAME_SPECIFIC_FRAME_DATA) != 0;

    let mut reader = BitReader::new(data);
    let mut walk = FrameWalk::default();

    while !reader.at_end() {
        walk.frames += 1;
        let _current_level_index = reader.read_i32()?;
        let time_seconds = reader.read_f32()?;
        // The consumer bundle's rule: `seconds * 1000` in f64, rounded half away
        // from zero. Outside u32 ms after rounding is refused, not saturated
        // (-1.0 s would read as the first frame); non-finite is 0 ms, counted.
        let time_ms = if time_seconds.is_finite() {
            let ms = (f64::from(time_seconds) * 1000.0).round();
            if ms < 0.0 || ms > f64::from(u32::MAX) {
                return Err(FrameError::TimeOutOfRange {
                    seconds: time_seconds,
                });
            }
            ms as u32
        } else {
            walk.non_finite_times += 1;
            0
        };

        if !before_exports(&reader, cache) {
            return Ok(walk);
        }
        // ExportData into `cache`; its per-frame counts reach no counter.
        let _ = vrf_schema::read_net_field_exports(&mut reader, cache)?;
        let _ = vrf_schema::read_export_guids(&mut reader, cache)?;
        read_streaming_level_fixes(&mut reader, has_streaming_fixes)?;

        let (blobs, bytes) = read_external_data(&mut reader)?;
        walk.skipped.external_data_blobs += blobs;
        walk.skipped.external_data_bytes += bytes;

        walk.skipped.game_specific_bytes +=
            read_game_specific_frame_data(&mut reader, has_game_specific)?;

        loop {
            if has_streaming_fixes {
                let _seen_level_index = reader.read_int_packed()?;
            }

            let packet_size = reader.read_i32()?;
            if packet_size == 0 {
                break;
            }
            if packet_size < 0 {
                return Err(FrameError::NegativePacketSize { size: packet_size });
            }
            if packet_size > MAX_PACKET_SIZE_BYTES {
                return Err(FrameError::PacketTooLarge {
                    size: packet_size,
                    max: MAX_PACKET_SIZE_BYTES,
                });
            }

            let packet_size_usize = packet_size as usize;
            let bit_count = (packet_size_usize as u64) * 8;
            if reader.bits_remaining() < bit_count {
                return Err(FrameError::Truncated {
                    context: "packet data",
                    needed: packet_size_usize,
                    available: (reader.bits_remaining() / 8) as usize,
                });
            }

            // Every frame read, ExportData included, is whole bytes.
            debug_assert_eq!(reader.position() % 8, 0);
            let byte_offset = (reader.position() / 8) as usize;
            let packet_data = &data[byte_offset..byte_offset + packet_size_usize];
            reader.skip_bits(bit_count)?;

            let go_on = on_packet(
                DemoPacket {
                    time_ms,
                    packet_index: walk.packets,
                    data: packet_data,
                },
                cache,
            );
            walk.packets += 1;
            if !go_on {
                return Ok(walk);
            }
        }
    }

    Ok(walk)
}

/// StreamingLevelFixes: level names, compact or verbose.
fn read_streaming_level_fixes(
    reader: &mut BitReader<'_>,
    has_streaming_fixes: bool,
) -> Result<(), FrameError> {
    let num_levels = reader.read_int_packed()?;

    if has_streaming_fixes {
        // Compact form: FString names, then a u64 externalOffset.
        for _ in 0..num_levels {
            let _ = reader.read_fstring(MAX_FSTRING_BYTES)?;
        }
        let _ = reader.read_u64()?;
    } else {
        // Verbose form, which no measured replay takes: packageName,
        // packageNameToLoad and a 40-byte FTransform (10 f32) per entry.
        for _ in 0..num_levels {
            let _ = reader.read_fstring(MAX_FSTRING_BYTES)?;
            let _ = reader.read_fstring(MAX_FSTRING_BYTES)?;
            reader.skip_bits(40 * 8)?;
        }
    }

    Ok(())
}

/// ExternalData: numBits, netGuid and payload until numBits is 0. Returns the
/// `(blobs, bytes)` skipped.
fn read_external_data(reader: &mut BitReader<'_>) -> Result<(u64, u64), FrameError> {
    let mut blobs = 0u64;
    let mut bytes = 0u64;
    loop {
        let num_bits = reader.read_int_packed()?;
        if num_bits == 0 {
            return Ok((blobs, bytes));
        }
        let _net_guid = reader.read_int_packed()?;
        let byte_count = u64::from(num_bits.div_ceil(8));
        reader.skip_bits(byte_count * 8)?;
        blobs += 1;
        bytes += byte_count;
    }
}

/// GameSpecificFrameData: when the flag is set, a u64 byte count and that
/// many bytes. Returns the bytes skipped.
fn read_game_specific_frame_data(
    reader: &mut BitReader<'_>,
    has_game_specific: bool,
) -> Result<u64, FrameError> {
    if !has_game_specific {
        return Ok(0);
    }
    let skip_offset = reader.read_u64()?;
    // A raw wire u64: saturated, an overflow fails as Eof instead of wrapping.
    reader.skip_bits(skip_offset.saturating_mul(8))?;
    Ok(skip_offset)
}
