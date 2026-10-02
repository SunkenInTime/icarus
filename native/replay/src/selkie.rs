//! Selkie: our Oodle decoder for the subset Valorant replays use (decoder
//! type 10, mode-1 LZ chunks with raw substreams, raw chunks, raw blocks).
//!
//! Written clean-room. Its only sources were the facts-only format notes in
//! `icarus-replay-work/oodle/`: `spec.md`, `corpus-variants.md`,
//! `examples.json` and `census.json`, plus the recorded archive pairs in
//! `vectors/` (`manifest.json`, `quick.json`, `*.in`/`*.out`). No existing
//! Oodle, Kraken, Mermaid or Selkie decoder source was read. Section names
//! below ("Block header", "Token meanings", ...) are the spec's.
//!
//! Anything outside the profile the corpus uses is refused rather than
//! guessed at: valid-but-unsupported forms report `unsupportedCompression`,
//! malformed bytes report `corrupt`, each naming the archive input position.

use std::fmt::Display;

use crate::error::{ErrorCode, ReplayError};
use crate::oodle::Decompressor;

/// Output span of a block; blocks start at its multiples.
const BLOCK: usize = 0x40000;
/// Most output one chunk carries.
const CHUNK: usize = 0x20000;
/// Output span of a token region; a chunk has one or two.
const REGION: usize = 0x10000;
/// Bytes copied verbatim at the start of the archive's first LZ chunk.
const INITIAL_BYTES: usize = 8;
/// Shortest match distance the profile allows; also each chunk's starting
/// remembered distance.
const MIN_DISTANCE: usize = 8;
/// Region starts from here on may use a far encoding the profile lacks.
const FAR_REGION_LIMIT: usize = 0xbf_ffff;
/// The quantum-size value that marks a special quantum, not a payload size.
const SPECIAL_QUANTUM: usize = 0x3_ffff;
/// Counts that announce a different encoding rather than a count.
const SPLIT_NEAR_COUNT: usize = 0xffff;
const EXTENDED_FAR_COUNT: usize = 0xfff;
/// Up-front output allocation per input byte. Real archives inflate about
/// 3x; a hostile size beyond this grows only as fast as blocks decode.
const PREALLOC_PER_INPUT_BYTE: usize = 16;
/// Scratch bytes past the current block's end, room for the widest copy to
/// overrun its logical end (see [`Output`]).
const SLACK: usize = 16;

/// The production [`Decompressor`].
pub struct Selkie;

impl Decompressor for Selkie {
    fn decompress(&self, input: &[u8], decompressed_size: usize) -> Result<Vec<u8>, ReplayError> {
        decode(input, decompressed_size)
    }
}

/// Inflate one archive body to exactly `size` bytes ("End conditions").
fn decode(input: &[u8], size: usize) -> Result<Vec<u8>, ReplayError> {
    if size == 0 {
        return Err(unsupported(0, "an empty archive"));
    }
    let mut archive = Stream::new(input, 0, "archive");
    let mut out = Output {
        buf: Vec::with_capacity(
            size.min(input.len().saturating_mul(PREALLOC_PER_INPUT_BYTE)) + SLACK,
        ),
        len: 0,
    };
    while out.len < size {
        let end = (out.len + BLOCK).min(size);
        out.buf.resize(end + SLACK, 0);
        if block_is_raw(&mut archive, out.len == 0)? {
            out.push(archive.take(end - out.len)?);
        } else {
            let quantum = quantum(&mut archive, end - out.len)?;
            decode_quantum(quantum, &mut out, end)?;
        }
    }
    archive.finish()?;
    out.buf.truncate(out.len);
    Ok(out.buf)
}

/// The archive's output: `buf[..len]` is decoded. The rest of `buf`, through
/// the current block's end plus [`SLACK`], is scratch. Short copies move
/// whole 8-byte words and may write scratch past their logical end; the
/// cursor rewrites every such byte before anything reads or returns it.
struct Output {
    buf: Vec<u8>,
    len: usize,
}

impl Output {
    /// Append `bytes`, which the caller has checked fit the current block.
    fn push(&mut self, bytes: &[u8]) {
        self.buf[self.len..self.len + bytes.len()].copy_from_slice(bytes);
        self.len += bytes.len();
    }
}

/// Read a two-byte block header; true for a raw block ("Block header").
fn block_is_raw(archive: &mut Stream<'_>, first: bool) -> Result<bool, ReplayError> {
    let at = archive.at;
    let &[flags, decoder] = archive.array::<2>()?;
    if flags & 0x0f != 0x0c || flags & 0x30 != 0 {
        return Err(corrupt(
            at,
            format_args!("invalid block header {flags:02x} {decoder:02x}"),
        ));
    }
    if decoder & 0x7f != 10 {
        return Err(unsupported(
            at,
            format_args!("decoder type {}", decoder & 0x7f),
        ));
    }
    if decoder & 0x80 != 0 {
        return Err(unsupported(at, "a block checksum"));
    }
    let (restart, raw) = (flags & 0x80 != 0, flags & 0x40 != 0);
    match (first, restart, raw) {
        (true, true, false) => Ok(false),
        (false, false, raw) => Ok(raw),
        _ => Err(unsupported(
            at,
            format_args!("block header {flags:02x} 0a at this position"),
        )),
    }
}

/// Read a quantum header and return its payload ("Quantum header").
fn quantum<'a>(archive: &mut Stream<'a>, block_size: usize) -> Result<Stream<'a>, ReplayError> {
    let at = archive.at;
    let header = archive.be24()?;
    if header >> 18 != 0 {
        return Err(unsupported(at, format_args!("quantum header {header:06x}")));
    }
    if header == SPECIAL_QUANTUM {
        return Err(unsupported(at, "a special quantum"));
    }
    let len = header + 1;
    if len == block_size {
        return Err(unsupported(at, "a raw quantum"));
    }
    if len > block_size {
        return Err(corrupt(
            at,
            format_args!("a {len}-byte quantum for {block_size} bytes of output"),
        ));
    }
    archive.sub(len, "quantum payload")
}

/// Decode a quantum's chunks into `out` up to `end`, consuming it exactly
/// ("Chunk header and raw chunks").
fn decode_quantum(
    mut quantum: Stream<'_>,
    out: &mut Output,
    end: usize,
) -> Result<(), ReplayError> {
    while out.len < end {
        let chunk_end = (out.len + CHUNK).min(end);
        let size = chunk_end - out.len;
        let at = quantum.at;
        let header = quantum.be24()?;
        if header & 0x80_0000 == 0 {
            return Err(unsupported(at, "a standalone byte-array chunk"));
        }
        let (mode, len) = ((header >> 19) & 0xf, header & 0x7_ffff);
        if len > size {
            return Err(corrupt(
                at,
                format_args!("a {len}-byte chunk for {size} bytes of output"),
            ));
        }
        match (mode, len == size) {
            (1, false) => lz_chunk(quantum.sub(len, "chunk payload")?, out, chunk_end)?,
            (0, true) => out.push(quantum.take(len)?),
            (0, false) => return Err(unsupported(at, "a mode-0 LZ chunk")),
            _ => {
                return Err(unsupported(
                    at,
                    format_args!("chunk mode {mode} with {len} of {size} bytes"),
                ));
            }
        }
    }
    quantum.finish()
}

/// Decode one mode-1 LZ chunk into `out` up to `end` ("Mode-1 LZ payload
/// layout").
fn lz_chunk(mut payload: Stream<'_>, out: &mut Output, end: usize) -> Result<(), ReplayError> {
    let start = out.len;
    let size = end - start;
    if start == 0 {
        if size < INITIAL_BYTES {
            return Err(corrupt(
                payload.at,
                format_args!("a {size}-byte first chunk"),
            ));
        }
        out.push(payload.take(INITIAL_BYTES)?);
    }
    let literals = byte_array(&mut payload, "literal", size)?;
    let commands = byte_array(&mut payload, "command", size)?;
    let two_regions = size > REGION;
    let split_at = payload.at;
    let split = if two_regions {
        payload.le16()?
    } else {
        commands.bytes.len()
    };
    if split > commands.bytes.len() {
        return Err(corrupt(
            split_at,
            format_args!("{split} first-region commands of {}", commands.bytes.len()),
        ));
    }
    let near_at = payload.at;
    let near_count = payload.le16()?;
    if near_count == SPLIT_NEAR_COUNT {
        return Err(unsupported(near_at, "a split near-offset stream"));
    }
    let near = payload.sub(2 * near_count, "near-entry")?;
    let far_at = payload.at;
    let far_counts = payload.le24()?;
    let (first_far, second_far) = (far_counts >> 12, far_counts & 0xfff);
    if first_far == EXTENDED_FAR_COUNT || second_far == EXTENDED_FAR_COUNT {
        return Err(unsupported(far_at, "an extended far count"));
    }
    if !two_regions && second_far != 0 {
        return Err(corrupt(
            far_at,
            "second-region far entries in a one-region chunk",
        ));
    }
    let last_region = if two_regions { start + REGION } else { start };
    if last_region >= FAR_REGION_LIMIT {
        return Err(unsupported(
            far_at,
            format_args!("a token region at output {last_region}"),
        ));
    }
    let first_far = payload.sub(3 * first_far, "first-region far-entry")?;
    let second_far = payload.sub(3 * second_far, "second-region far-entry")?;
    let lengths = payload.rest("length");

    let (first_commands, second_commands) = commands.split(split);
    let mut lz = Lz {
        out,
        literals,
        near,
        lengths,
        distance: MIN_DISTANCE,
    };
    lz.region(first_commands, first_far, start, end.min(start + REGION))?;
    if two_regions {
        lz.region(second_commands, second_far, start + REGION, end)?;
    }
    lz.literals.finish()?;
    lz.near.finish()?;
    lz.lengths.finish()
}

/// Read a raw byte-array header and its bytes ("Raw byte-array headers").
fn byte_array<'a>(
    payload: &mut Stream<'a>,
    name: &'static str,
    chunk_size: usize,
) -> Result<Stream<'a>, ReplayError> {
    let at = payload.at;
    let header = payload.be24()?;
    if header & 0x80_0000 != 0 {
        return Err(unsupported(
            at,
            format_args!("a short {name} byte-array header"),
        ));
    }
    if header & 0x70_0000 != 0 {
        return Err(unsupported(
            at,
            format_args!("{name} byte-array coding type {}", (header >> 20) & 7),
        ));
    }
    if header > chunk_size {
        return Err(corrupt(
            at,
            format_args!("{header} {name} bytes in a {chunk_size}-byte chunk"),
        ));
    }
    payload.sub(header, name)
}

/// The shared streams of one LZ chunk, consumed token by token.
struct Lz<'o, 'a> {
    out: &'o mut Output,
    literals: Stream<'a>,
    near: Stream<'a>,
    lengths: Stream<'a>,
    /// The remembered match distance.
    distance: usize,
}

impl Lz<'_, '_> {
    /// Decode one token region of output `[start, end)` ("Token meanings").
    fn region(
        &mut self,
        commands: Stream<'_>,
        mut far: Stream<'_>,
        start: usize,
        end: usize,
    ) -> Result<(), ReplayError> {
        for (i, &token) in commands.bytes.iter().enumerate() {
            let at = commands.at + i;
            let token_len = usize::from(token);
            match token {
                0x00 => {
                    let literals = self.length()? + 64;
                    self.literals(literals, end)?;
                }
                0x01 => {
                    let len = self.length()? + 91;
                    self.distance = self.near.le16()?;
                    self.copy(len, end, at)?;
                }
                0x02 => {
                    let len = self.length()? + 29;
                    self.far(&mut far, start)?;
                    self.copy(len, end, at)?;
                }
                0x09..=0x17 => {
                    self.far(&mut far, start)?;
                    self.copy(token_len + 5, end, at)?;
                }
                0x20..=0x7f => {
                    self.literals(token_len & 7, end)?;
                    self.distance = self.near.le16()?;
                    self.copy((token_len >> 3) & 15, end, at)?;
                }
                0x81..=0xff => {
                    self.literals(token_len & 7, end)?;
                    let len = (token_len >> 3) & 15;
                    if len > 0 {
                        self.copy(len, end, at)?;
                    }
                }
                _ => return Err(unsupported(at, format_args!("token {token:02x}"))),
            }
        }
        far.finish()?;
        self.literals(end - self.out.len, end)
    }

    /// One length value ("Length values").
    fn length(&mut self) -> Result<usize, ReplayError> {
        let first = usize::from(self.lengths.byte()?);
        if first < 252 {
            return Ok(first);
        }
        Ok(first + 4 * self.lengths.le16()?)
    }

    /// Take the region's next far entry as the remembered distance ("Far
    /// counts and entries"): it names absolute source `start - V`.
    fn far(&mut self, far: &mut Stream<'_>, start: usize) -> Result<(), ReplayError> {
        let at = far.at;
        let back = far.le24()?;
        if back > start {
            return Err(corrupt(
                at,
                format_args!("far entry {back} reaches before the archive from {start}"),
            ));
        }
        self.distance = self.out.len - (start - back);
        Ok(())
    }

    /// Append `len` literals, which must end by `end`.
    fn literals(&mut self, len: usize, end: usize) -> Result<(), ReplayError> {
        let pos = self.out.len;
        if len > end - pos {
            return Err(corrupt(
                self.literals.at,
                format_args!("{len} literals cross the region end at {end}"),
            ));
        }
        match self.literals.bytes.first_chunk::<8>() {
            Some(&word) if len <= 8 => {
                self.literals.take(len)?;
                self.out.buf[pos..pos + 8].copy_from_slice(&word);
                self.out.len += len;
            }
            _ => self.out.push(self.literals.take(len)?),
        }
        Ok(())
    }

    /// Append a `len`-byte match at the remembered distance, which must end
    /// by `end`. The token at input `at` asked for it.
    fn copy(&mut self, len: usize, end: usize, at: usize) -> Result<(), ReplayError> {
        let (pos, distance) = (self.out.len, self.distance);
        if len > end - pos {
            return Err(corrupt(
                at,
                format_args!("a {len}-byte match crosses the region end at {end}"),
            ));
        }
        if distance == 0 || distance > pos {
            return Err(corrupt(
                at,
                format_args!("match distance {distance} at output {pos}"),
            ));
        }
        if distance < MIN_DISTANCE {
            return Err(unsupported(at, format_args!("match distance {distance}")));
        }
        // With distance at least 8, each 8-byte word reads only bytes already
        // final, so copying word by word repeats a match's own output when it
        // is longer than its distance, as the format requires.
        let (buf, from) = (&mut self.out.buf, pos - distance);
        if len <= 16 {
            copy_word(buf, from, pos);
            copy_word(buf, from + 8, pos + 8);
        } else if len <= distance {
            buf.copy_within(from..from + len, pos);
        } else {
            for offset in (0..len).step_by(8) {
                copy_word(buf, from + offset, pos + offset);
            }
        }
        self.out.len += len;
        Ok(())
    }
}

fn copy_word(buf: &mut [u8], from: usize, to: usize) {
    let word: [u8; 8] = buf[from..from + 8].try_into().expect("8 bytes");
    buf[to..to + 8].copy_from_slice(&word);
}

/// One consecutive field of the archive, read front to back.
struct Stream<'a> {
    bytes: &'a [u8],
    /// Archive input position of `bytes[0]`.
    at: usize,
    name: &'static str,
}

impl<'a> Stream<'a> {
    fn new(bytes: &'a [u8], at: usize, name: &'static str) -> Self {
        Self { bytes, at, name }
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8], ReplayError> {
        let Some((head, rest)) = self.bytes.split_at_checked(len) else {
            return Err(corrupt(
                self.at,
                format_args!(
                    "the {} stream needs {len} bytes, {} remain",
                    self.name,
                    self.bytes.len()
                ),
            ));
        };
        self.bytes = rest;
        self.at += len;
        Ok(head)
    }

    fn array<const N: usize>(&mut self) -> Result<&'a [u8; N], ReplayError> {
        Ok(self.take(N)?.try_into().expect("took N bytes"))
    }

    /// The next `len` bytes as their own stream.
    fn sub(&mut self, len: usize, name: &'static str) -> Result<Stream<'a>, ReplayError> {
        let at = self.at;
        Ok(Stream::new(self.take(len)?, at, name))
    }

    /// Everything left, as its own stream.
    fn rest(&mut self, name: &'static str) -> Stream<'a> {
        let rest = Stream::new(self.bytes, self.at, name);
        self.at += self.bytes.len();
        self.bytes = &[];
        rest
    }

    /// The first `len` bytes and the rest, as two streams.
    fn split(self, len: usize) -> (Stream<'a>, Stream<'a>) {
        let (head, tail) = self.bytes.split_at(len);
        (
            Stream::new(head, self.at, self.name),
            Stream::new(tail, self.at + len, self.name),
        )
    }

    fn byte(&mut self) -> Result<u8, ReplayError> {
        Ok(self.array::<1>()?[0])
    }

    fn le16(&mut self) -> Result<usize, ReplayError> {
        Ok(usize::from(u16::from_le_bytes(*self.array()?)))
    }

    fn le24(&mut self) -> Result<usize, ReplayError> {
        let &[a, b, c] = self.array()?;
        Ok(usize::from(a) | usize::from(b) << 8 | usize::from(c) << 16)
    }

    fn be24(&mut self) -> Result<usize, ReplayError> {
        let &[a, b, c] = self.array()?;
        Ok(usize::from(a) << 16 | usize::from(b) << 8 | usize::from(c))
    }

    /// Every byte must have been consumed.
    fn finish(&self) -> Result<(), ReplayError> {
        if self.bytes.is_empty() {
            return Ok(());
        }
        Err(corrupt(
            self.at,
            format_args!("{} unused {} bytes", self.bytes.len(), self.name),
        ))
    }
}

#[cold]
fn corrupt(at: usize, what: impl Display) -> ReplayError {
    ReplayError::new(
        ErrorCode::Corrupt,
        format!("Oodle archive byte {at}: {what}"),
    )
}

#[cold]
fn unsupported(at: usize, what: impl Display) -> ReplayError {
    ReplayError::new(
        ErrorCode::UnsupportedCompression,
        format!("Oodle archive byte {at}: {what} is not supported"),
    )
}

#[cfg(test)]
mod tests {
    //! Archives built field by field from the spec's layout, carrying the
    //! token, offset, length and literal bytes of its worked examples.

    use super::*;

    fn hex(text: &str) -> Vec<u8> {
        let digits: Vec<u8> = text.bytes().filter(u8::is_ascii_hexdigit).collect();
        digits
            .chunks(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect()
    }

    fn be24(value: usize) -> [u8; 3] {
        let [_, a, b, c] = u32::try_from(value).unwrap().to_be_bytes();
        [a, b, c]
    }

    fn le24(value: usize) -> [u8; 3] {
        let [a, b, c, _] = u32::try_from(value).unwrap().to_le_bytes();
        [a, b, c]
    }

    /// A length value in its one- or three-byte form.
    fn length(value: usize) -> Vec<u8> {
        if value < 252 {
            return vec![value as u8];
        }
        let first = 252 + (value - 252) % 4;
        let mut bytes = vec![first as u8];
        bytes.extend(u16::try_from((value - first) / 4).unwrap().to_le_bytes());
        bytes
    }

    /// Bytes that differ position to position, so a copy from the wrong
    /// place shows.
    fn pattern(len: usize, seed: u32) -> Vec<u8> {
        (0..len as u32)
            .map(|i| (i.wrapping_add(seed << 20).wrapping_mul(2_654_435_761) >> 24) as u8)
            .collect()
    }

    /// The fields of one mode-1 LZ chunk, in the spec's order.
    #[derive(Clone, Default)]
    struct LzChunk {
        initial: Vec<u8>,
        literals: Vec<u8>,
        commands: Vec<u8>,
        /// First-region command count, written for chunks over 64 KiB.
        split: Option<u16>,
        near: Vec<u16>,
        far: [Vec<usize>; 2],
        lengths: Vec<u8>,
    }

    impl LzChunk {
        fn encode(&self) -> Vec<u8> {
            let mut bytes = self.initial.clone();
            for array in [&self.literals, &self.commands] {
                bytes.extend(be24(array.len()));
                bytes.extend(array);
            }
            if let Some(split) = self.split {
                bytes.extend(split.to_le_bytes());
            }
            bytes.extend(u16::try_from(self.near.len()).unwrap().to_le_bytes());
            for distance in &self.near {
                bytes.extend(distance.to_le_bytes());
            }
            bytes.extend(le24(self.far[0].len() << 12 | self.far[1].len()));
            for &back in self.far.iter().flatten() {
                bytes.extend(le24(back));
            }
            bytes.extend(&self.lengths);
            bytes
        }

        /// A long-near token at distance 8, `len` bytes long.
        fn fill(&mut self, len: usize) {
            self.commands.push(0x01);
            self.near.push(8);
            self.lengths.extend(length(len - 91));
        }

        /// The whole archive when this is its only chunk.
        fn archive(&self) -> Vec<u8> {
            block(0x8c, &[chunk(1, &self.encode())])
        }

        /// Archive position of the literal header in [`Self::archive`].
        fn literal_header_at(&self) -> usize {
            2 + 3 + 3 + self.initial.len()
        }

        /// Archive position of the near-entry count in [`Self::archive`],
        /// for a one-region chunk.
        fn near_count_at(&self) -> usize {
            self.literal_header_at() + 3 + self.literals.len() + 3 + self.commands.len()
        }
    }

    fn chunk(mode: usize, payload: &[u8]) -> Vec<u8> {
        let mut bytes = be24(0x80_0000 | mode << 19 | payload.len()).to_vec();
        bytes.extend(payload);
        bytes
    }

    fn block(header: u8, chunks: &[Vec<u8>]) -> Vec<u8> {
        let body = chunks.concat();
        let mut bytes = vec![header, 0x0a];
        bytes.extend(be24(body.len() - 1));
        bytes.extend(body);
        bytes
    }

    /// `out[at..end]` repeats the bytes `distance` before it.
    fn repeats(out: &[u8], at: usize, end: usize, distance: usize) -> bool {
        (at..end).all(|i| out[i] == out[i - distance])
    }

    // Worked examples ("Worked examples from the corpus").

    /// Initial bytes, `8e` (compact reuse) and `87` (literal only), from
    /// 1fb53a2c_1_1.
    fn compact_reuse() -> (LzChunk, usize) {
        let mut lz = LzChunk {
            initial: hex("00 00 00 00 82 32 00 3c"),
            literals: hex("47 04 02 02 43 00  00 2f 47 61 6d 65 2f"),
            commands: vec![0x8e, 0x87],
            ..Default::default()
        };
        lz.fill(300);
        (lz, 8 + 7 + 7 + 300)
    }

    #[test]
    fn initial_bytes_then_compact_reuse_and_literal_only_tokens() {
        let (lz, size) = compact_reuse();
        let out = decode(&lz.archive(), size).unwrap();
        assert_eq!(out[..8], hex("00 00 00 00 82 32 00 3c"));
        // 8e: six literals, then one byte from output[6] at distance 8.
        assert_eq!(out[8..15], hex("47 04 02 02 43 00 00"));
        // 87: seven literals, no match, nothing else consumed.
        assert_eq!(out[15..22], hex("00 2f 47 61 6d 65 2f"));
        assert!(repeats(&out, 22, size, 8));
    }

    /// `7d` (compact new distance) from 1fb53a2c_1_1 at output 55, then `87`
    /// and `90`, which reuses the distance `7d` set.
    fn compact_new() -> (LzChunk, usize) {
        let mut literals = vec![0; 31]; // output [8, 39)
        literals.extend(hex("42 61 73 65 52 65 70 6c 61 79 43 6f 6e 74 72")); // [39, 54)
        literals.push(0x99); // 54
        literals.extend(hex("6c 6c 65 72 2e"));
        literals.extend(pattern(7, 1));
        let mut lz = LzChunk {
            initial: pattern(8, 0),
            literals,
            commands: vec![0x87, 0x87, 0x87, 0x87, 0x87, 0x87, 0x85, 0x7d, 0x87, 0x90],
            near: vec![u16::from_le_bytes([0x15, 0x00])],
            ..Default::default()
        };
        lz.fill(100);
        (lz, 55 + 20 + 7 + 2 + 100)
    }

    #[test]
    fn compact_new_distance_token() {
        let (lz, size) = compact_new();
        let out = decode(&lz.archive(), size).unwrap();
        assert_eq!(
            out[55..75],
            hex("6c 6c 65 72 2e 42 61 73 65 52 65 70 6c 61 79 43 6f 6e 74 72")
        );
        // 87 keeps D = 21; 90 copies two bytes at it.
        assert_eq!(out[82..84], out[61..63]);
    }

    #[test]
    fn a_match_longer_than_its_distance_repeats_its_own_output() {
        // `48` with near `08 00`: nine bytes at distance 8 (1fb53a2c_1_1).
        let mut lz = LzChunk {
            initial: (1..=8).collect(),
            commands: vec![0x48],
            near: vec![8],
            ..Default::default()
        };
        lz.fill(100);
        let out = decode(&lz.archive(), 117).unwrap();
        assert_eq!(out[8..17], [1, 2, 3, 4, 5, 6, 7, 8, 1]);
    }

    const LONG_LITERAL: &str = "7b0a9728fbba85210984c7e3ac4412981cdb44598090b58127fedb3c8bd07b13\
        c7eda7209983eba89273c1958ebabd52efde9834a71b294df19f99d16c469cef\
        eebc011a26f6e16e9247596f1e4122ca11985321aa6c0244000000d30a32c707\
        b5029f2806b0d7adb1b16890a66c8312b7ea362871ab708312b72a372871ab74\
        8312b76a372871ab788312b7aa372871ab7c8312b7ea372871ab008412b702";
    const LONG_NEAR: &[u8; 95] =
        b"\0\0\0/Game/Environment/Plummet/Blueprints/RespawningPlummetShootable.RespawningPlummetShootable_C";

    /// `00` with length `5f` (159 literals), a second `00` with a three-byte
    /// length, `01` with length `04` and near `a5 0f` (95 bytes at 4005), and
    /// `01` with length `fd d6 00` and near `1b 00` (1200 bytes at 27), from
    /// 1fb53a2c_1_1 and 1fb53a2c_1_12.
    fn long_literal_and_near() -> (LzChunk, usize) {
        let source = 4300 - 4005 - 167; // within the second literal run
        let mut run = pattern(4300 - 167, 2);
        run[source..source + 95].copy_from_slice(LONG_NEAR);
        let mut literals = hex(LONG_LITERAL);
        literals.extend(run);
        let mut lengths = hex("5f");
        lengths.extend(length(4300 - 167 - 64));
        lengths.extend(hex("04  fd d6 00"));
        let lz = LzChunk {
            initial: pattern(8, 3),
            literals,
            commands: vec![0x00, 0x00, 0x01, 0x01],
            near: vec![
                u16::from_le_bytes([0xa5, 0x0f]),
                u16::from_le_bytes([0x1b, 0x00]),
            ],
            lengths,
            ..Default::default()
        };
        (lz, 4300 + 95 + 1200)
    }

    #[test]
    fn long_literal_and_long_near_tokens_with_both_length_forms() {
        let (lz, size) = long_literal_and_near();
        let out = decode(&lz.archive(), size).unwrap();
        assert_eq!(out[8..167], hex(LONG_LITERAL));
        assert_eq!(out[4300..4395], LONG_NEAR[..]);
        // fd d6 00 = 253 + 4 * 214: a 1200-byte match at distance 27.
        assert!(repeats(&out, 4395, size, 27));
    }

    const SHORT_FAR: &str = "2f41737361756c745269666c655f";
    const LONG_FAR: &str = "4d6f6465732f436f6d6d6f6e2f426173655265706c6179506c617965725374617465";
    const LONG_LITERAL_PREFIX: &str =
        "530032a70c041206477117e099c35d00807f08168d2d7b8c636ccd7145832de3";

    /// Far tokens in a second region at 65536 (1fb53a2c_1_1, 1fb53a2c_2_13):
    /// `00` with `fe 25 02` (2514 literals), `09` with far `fe c8 00`, `02`
    /// with length `05` and far `ac f4 00`, `88` reusing that distance, and
    /// `02` with length `ff 01 00` and far `e0 e8 00`. The first region is
    /// all trailing literals.
    fn far_tokens() -> (LzChunk, usize) {
        let mut literals = pattern(REGION - 8, 4);
        literals[14082 - 8..14082 - 8 + 14].copy_from_slice(&hex(SHORT_FAR));
        literals[2900 - 8..2900 - 8 + 34].copy_from_slice(&hex(LONG_FAR));
        literals.extend(hex(LONG_LITERAL_PREFIX));
        literals.extend(pattern(2514 - 32, 5));
        literals.extend(pattern(92037 - 68050 + 100, 6)); // second run, then the tail
        let mut lengths = hex("fe 25 02");
        lengths.extend(length(92037 - 68050 - 64));
        lengths.extend(hex("05  ff 01 00"));
        let far = |bytes: &str| {
            let b = hex(bytes);
            usize::from(b[0]) | usize::from(b[1]) << 8 | usize::from(b[2]) << 16
        };
        let lz = LzChunk {
            initial: pattern(8, 7),
            literals,
            commands: vec![0x00, 0x00, 0x09, 0x02, 0x88, 0x02],
            split: Some(0),
            far: [
                vec![],
                vec![far("fe c8 00"), far("ac f4 00"), far("e0 e8 00")],
            ],
            lengths,
            ..Default::default()
        };
        (lz, 92474)
    }

    #[test]
    fn far_tokens_name_sources_from_their_region_start() {
        let (lz, size) = far_tokens();
        let out = decode(&lz.archive(), size).unwrap();
        assert_eq!(out[65536..65568], hex(LONG_LITERAL_PREFIX));
        // 09: 14 bytes from 65536 - 51454 = 14082, not from P - 51454.
        assert_eq!(out[92037..92051], hex(SHORT_FAR));
        // 02 + 05: 34 bytes from 65536 - 62636 = 2900.
        assert_eq!(out[92051..92085], hex(LONG_FAR));
        // 88 reuses D = 92051 - 2900.
        assert_eq!(out[92085], out[92085 - (92051 - 2900)]);
        // 02 + ff 01 00: 288 bytes from 65536 - 59616.
        assert_eq!(out[92086..92374], out[5920..6208]);
    }

    /// Two LZ chunks, a raw chunk, a raw block, then a compressed block whose
    /// far matches reach back into both raw spans. Also returns where that
    /// last block starts.
    fn raw_storage() -> (Vec<u8>, usize, usize) {
        let mut lz = LzChunk {
            initial: pattern(8, 8),
            split: Some(1),
            ..Default::default()
        };
        lz.fill(REGION - 8);
        lz.fill(REGION);
        let mut archive = block(
            0x8c,
            &[chunk(1, &lz.encode()), chunk(0, &pattern(CHUNK, 9))],
        );
        archive.extend([0x4c, 0x0a]);
        archive.extend(pattern(BLOCK, 10));
        let last_block = archive.len();
        let mut last = LzChunk {
            commands: vec![0x09, 0x02],
            far: [vec![2 * BLOCK - 300_000, 2 * BLOCK - 140_000], vec![]],
            lengths: vec![0],
            ..Default::default()
        };
        last.fill(1000 - 14 - 29);
        archive.extend(block(0x0c, &[chunk(1, &last.encode())]));
        (archive, 2 * BLOCK + 1000, last_block)
    }

    #[test]
    fn raw_chunks_and_raw_blocks_join_the_history() {
        let (archive, size, _) = raw_storage();
        let out = decode(&archive, size).unwrap();
        assert!(repeats(&out, 8, CHUNK, 8));
        assert_eq!(out[CHUNK..BLOCK], pattern(CHUNK, 9));
        assert_eq!(out[BLOCK..2 * BLOCK], pattern(BLOCK, 10));
        assert_eq!(out[2 * BLOCK..2 * BLOCK + 14], out[300_000..300_014]);
        assert_eq!(out[2 * BLOCK + 14..2 * BLOCK + 43], out[140_000..140_029]);
        assert!(repeats(&out, 2 * BLOCK + 43, size, 8));
    }

    #[test]
    fn selkie_is_this_decoder() {
        let (lz, size) = compact_reuse();
        assert_eq!(
            Selkie.decompress(&lz.archive(), size),
            decode(&lz.archive(), size)
        );
    }

    // Rejections ("Reject table", "End conditions and consistency checks").

    const CORRUPT: ErrorCode = ErrorCode::Corrupt;
    const UNSUPPORTED: ErrorCode = ErrorCode::UnsupportedCompression;

    fn code(archive: &[u8], size: usize) -> ErrorCode {
        decode(archive, size).expect_err("an error").code
    }

    /// The error from [`compact_reuse`]'s archive with `edit` applied.
    fn edited(edit: impl FnOnce(&mut Vec<u8>)) -> ErrorCode {
        let (lz, size) = compact_reuse();
        let mut archive = lz.archive();
        edit(&mut archive);
        code(&archive, size)
    }

    /// The error from [`compact_reuse`]'s fields with `edit` applied.
    fn rebuilt(edit: impl FnOnce(&mut LzChunk)) -> ErrorCode {
        let (mut lz, size) = compact_reuse();
        edit(&mut lz);
        code(&lz.archive(), size)
    }

    #[test]
    fn every_truncation_is_corrupt() {
        let (lz, size) = compact_reuse();
        let archive = lz.archive();
        for len in 0..archive.len() {
            assert_eq!(code(&archive[..len], size), CORRUPT, "{len} bytes");
        }
    }

    #[test]
    fn trailing_input_and_wrong_sizes_are_corrupt() {
        let (lz, size) = compact_reuse();
        let archive = lz.archive();
        assert_eq!(code(&archive, size - 1), CORRUPT);
        assert_eq!(code(&archive, size + 1), CORRUPT);
        assert_eq!(code(&archive, 0), UNSUPPORTED, "an empty archive");
        assert_eq!(edited(|a| a.push(0)), CORRUPT);
    }

    #[test]
    fn block_headers_outside_the_profile_are_refused() {
        assert_eq!(edited(|a| a[1] = 0x0b), UNSUPPORTED, "decoder 11");
        assert_eq!(edited(|a| a[1] = 0x08), UNSUPPORTED, "decoder 8");
        assert_eq!(edited(|a| a[1] = 0x8a), UNSUPPORTED, "checksum");
        assert_eq!(edited(|a| a[0] = 0x8d), CORRUPT, "signature");
        assert_eq!(edited(|a| a[0] = 0x9c), CORRUPT, "reserved bits");
        assert_eq!(
            edited(|a| a[0] = 0x0c),
            UNSUPPORTED,
            "first block without restart"
        );
        assert_eq!(edited(|a| a[0] = 0xcc), UNSUPPORTED, "raw first block");
        let (mut archive, size, last_block) = raw_storage();
        archive[last_block] = 0x8c;
        assert_eq!(code(&archive, size), UNSUPPORTED, "restart past output 0");
    }

    #[test]
    fn quantum_headers_outside_the_profile_are_refused() {
        let (_, size) = compact_reuse();
        let quantum = |header: usize| edited(|a| a[2..5].copy_from_slice(&be24(header)));
        assert_eq!(
            quantum(size - 1),
            UNSUPPORTED,
            "payload as large as the block"
        );
        assert_eq!(quantum(size), CORRUPT, "payload larger than the block");
        assert_eq!(quantum(0x07_ffff), UNSUPPORTED, "fill quantum");
        assert_eq!(quantum(0x03_ffff), UNSUPPORTED, "special quantum");
        assert_eq!(quantum(0x04_0000 | 50), UNSUPPORTED, "upper bits");
    }

    #[test]
    fn chunk_headers_outside_the_profile_are_refused() {
        let chunk_header = |set: u8, clear: u8| {
            edited(|a| {
                a[5] |= set;
                a[5] &= !clear;
            })
        };
        assert_eq!(chunk_header(0, 0x80), UNSUPPORTED, "standalone byte array");
        assert_eq!(chunk_header(0, 0x08), UNSUPPORTED, "mode 0, short");
        assert_eq!(chunk_header(0x10, 0x08), UNSUPPORTED, "mode 2");
        assert_eq!(chunk_header(0x04, 0), CORRUPT, "larger than its output");
        // One raw chunk makes the quantum as large as its output: a raw
        // quantum, which this profile does not carry.
        let raw = block(0x8c, &[chunk(0, &[7; 100])]);
        assert_eq!(code(&raw, 103), UNSUPPORTED);
    }

    #[test]
    fn byte_array_headers_outside_the_profile_are_refused() {
        let at = compact_reuse().0.literal_header_at();
        let header = |byte: u8| edited(|a| a[at] = byte);
        assert_eq!(header(0x80), UNSUPPORTED, "short header");
        assert_eq!(header(0x10), UNSUPPORTED, "entropy-coded");
        assert_eq!(header(0x50), UNSUPPORTED, "entropy-coded");
        assert_eq!(header(0x03), CORRUPT, "more literals than output");
    }

    #[test]
    fn stream_counts_outside_the_profile_are_refused() {
        let lz = compact_reuse().0;
        let near = lz.near_count_at();
        assert_eq!(
            edited(|a| a[near..near + 2].fill(0xff)),
            UNSUPPORTED,
            "split near stream"
        );
        let far = near + 2 + 2 * lz.near.len();
        assert_eq!(
            edited(|a| a[far..far + 3].copy_from_slice(&le24(0xfff << 12))),
            UNSUPPORTED
        );
        assert_eq!(
            edited(|a| a[far..far + 3].copy_from_slice(&le24(0xfff))),
            UNSUPPORTED
        );
        assert_eq!(
            rebuilt(|lz| lz.far[1].push(0)),
            CORRUPT,
            "second-region far list in one region"
        );
        // A first-region command count beyond the commands.
        let (mut lz, size) = far_tokens();
        lz.split = Some(7);
        assert_eq!(code(&lz.archive(), size), CORRUPT);
    }

    #[test]
    fn unobserved_tokens_are_refused() {
        for token in [0x80, 0x03, 0x08, 0x18, 0x1f] {
            assert_eq!(
                rebuilt(|lz| lz.commands.insert(0, token)),
                UNSUPPORTED,
                "{token:02x}"
            );
        }
    }

    #[test]
    fn leftover_or_missing_stream_bytes_are_corrupt() {
        assert_eq!(rebuilt(|lz| lz.literals.push(0)), CORRUPT, "spare literal");
        assert_eq!(
            rebuilt(|lz| {
                lz.literals.pop();
            }),
            CORRUPT,
            "missing literal"
        );
        assert_eq!(rebuilt(|lz| lz.near.push(8)), CORRUPT, "spare near entry");
        assert_eq!(
            rebuilt(|lz| {
                lz.near.pop();
            }),
            CORRUPT,
            "missing near entry"
        );
        assert_eq!(rebuilt(|lz| lz.lengths.push(0)), CORRUPT, "spare length");
        assert_eq!(rebuilt(|lz| lz.far[0].push(0)), CORRUPT, "spare far entry");
        assert_eq!(
            rebuilt(|lz| lz.commands.push(0x87)),
            CORRUPT,
            "past the region end"
        );
    }

    #[test]
    fn matches_out_of_range_are_refused() {
        let near = |distance: u16| rebuilt(|lz| *lz.near.last_mut().unwrap() = distance);
        assert_eq!(near(23), CORRUPT, "before output 0");
        assert_eq!(near(4), UNSUPPORTED, "distance below 8");
        assert_eq!(near(0), CORRUPT, "distance 0");
        let (mut lz, size) = compact_reuse();
        *lz.near.last_mut().unwrap() = 22;
        assert!(
            decode(&lz.archive(), size).is_ok(),
            "distance reaching exactly output 0"
        );
        // Far entries are relative to the region start, here 0.
        let far = |back: usize| {
            rebuilt(|lz| {
                lz.commands.insert(2, 0x09);
                lz.far[0].push(back);
            })
        };
        assert_eq!(far(1), CORRUPT, "far entry before output 0");
        // The match crossing the region end.
        assert_eq!(rebuilt(|lz| lz.lengths[0] += 1), CORRUPT);
    }

    #[test]
    fn regions_from_0xbfffff_on_are_refused() {
        // One compressed block, then raw blocks up to output 48 * 256 KiB =
        // 0xc00000, then a compressed block there.
        let mut lz = LzChunk {
            initial: vec![0; 8],
            split: Some(1),
            ..Default::default()
        };
        lz.fill(REGION - 8);
        lz.fill(REGION);
        let mut archive = block(0x8c, &[chunk(1, &lz.encode()), chunk(0, &vec![0; CHUNK])]);
        for _ in 1..48 {
            archive.extend([0x4c, 0x0a]);
            archive.extend(vec![0; BLOCK]);
        }
        let mut last = LzChunk::default();
        last.fill(1000);
        archive.extend(block(0x0c, &[chunk(1, &last.encode())]));
        assert_eq!(48 * BLOCK, 0xc0_0000);
        assert_eq!(code(&archive, 48 * BLOCK + 1000), UNSUPPORTED);
    }

    // Hostile input must come back as an error, never a panic or a hang.

    /// xorshift64*: deterministic, no dependency.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
        }

        fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }
    }

    /// Valid archives to mutate: the worked examples, plus the quick set when
    /// `ICARUS_OODLE_VECTORS` names the vectors directory.
    fn seeds() -> Vec<(Vec<u8>, usize)> {
        let mut seeds = vec![];
        for (lz, size) in [
            compact_reuse(),
            compact_new(),
            long_literal_and_near(),
            far_tokens(),
        ] {
            seeds.push((lz.archive(), size));
        }
        let (archive, size, _) = raw_storage();
        seeds.push((archive, size));
        if let Some(dir) = std::env::var_os("ICARUS_OODLE_VECTORS") {
            let dir = std::path::Path::new(&dir);
            for id in ["2dd2de86_1_1", "b63bb117_1_1", "1fb53a2c_2_2"] {
                let input = std::fs::read(dir.join(format!("{id}.in"))).unwrap();
                let size = std::fs::metadata(dir.join(format!("{id}.out")))
                    .unwrap()
                    .len();
                seeds.push((input, size as usize));
            }
        }
        seeds
    }

    #[test]
    fn mutated_archives_never_panic() {
        let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
        for (seed, size) in seeds() {
            assert_eq!(decode(&seed, size).map(|out| out.len()), Ok(size));
            for _ in 0..400 {
                let mut archive = seed.clone();
                // Damage the headers often: they steer everything after them.
                for _ in 0..1 + rng.below(4) {
                    let at = if rng.below(2) == 0 {
                        rng.below(64.min(archive.len()))
                    } else {
                        rng.below(archive.len())
                    };
                    archive[at] = rng.next() as u8;
                }
                if rng.below(4) == 0 {
                    archive.truncate(rng.below(archive.len()));
                }
                let size = match rng.below(4) {
                    0 => rng.below(2 * size + 1),
                    _ => size,
                };
                if let Ok(out) = decode(&archive, size) {
                    assert_eq!(out.len(), size);
                }
            }
        }
    }

    #[test]
    fn random_bytes_never_panic() {
        let mut rng = Rng(42);
        for _ in 0..20_000 {
            let mut archive: Vec<u8> = (0..rng.below(300)).map(|_| rng.next() as u8).collect();
            if archive.len() >= 2 && rng.below(2) == 0 {
                archive[..2].copy_from_slice(&[0x8c, 0x0a]);
            }
            let _ = decode(&archive, 1 + rng.below(1 << 20));
        }
    }
}
