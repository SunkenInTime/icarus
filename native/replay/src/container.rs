//! The `.icrp` buffer of docs/replay-format.md ("Container"): magic, format
//! version, the JSON document, zero padding to 8, then the movement blob.

pub const MAGIC: &[u8; 4] = b"ICRP";
pub const FORMAT_VERSION: u32 = 1;
const HEADER_BYTES: usize = 12;

/// Bytes per movement record: i32 timeMs, then f32 x, y, z, yaw, pitch.
pub const MOVEMENT_RECORD_BYTES: usize = 24;

/// One movement record, as the blob stores it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MovementSample {
    pub time_ms: i32,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub yaw: f32,
    pub pitch: f32,
}

impl MovementSample {
    pub fn write_to(&self, out: &mut Vec<u8>) {
        out.extend(self.time_ms.to_le_bytes());
        for v in [self.x, self.y, self.z, self.yaw, self.pitch] {
            out.extend(v.to_le_bytes());
        }
    }

    pub fn read(bytes: &[u8]) -> Self {
        let f = |i: usize| f32::from_le_bytes(bytes[i..i + 4].try_into().expect("4 bytes"));
        Self {
            time_ms: i32::from_le_bytes(bytes[0..4].try_into().expect("4 bytes")),
            x: f(4),
            y: f(8),
            z: f(12),
            yaw: f(16),
            pitch: f(20),
        }
    }
}

/// Assemble a buffer from the JSON document and the blob.
pub fn write(json: &str, blob: &[u8]) -> Vec<u8> {
    let json_len = u32::try_from(json.len()).expect("document under 4 GiB");
    let blob_start = (HEADER_BYTES + json.len()).next_multiple_of(8);
    let mut out = Vec::with_capacity(blob_start + blob.len());
    out.extend(MAGIC);
    out.extend(FORMAT_VERSION.to_le_bytes());
    out.extend(json_len.to_le_bytes());
    out.extend(json.as_bytes());
    out.resize(blob_start, 0);
    out.extend(blob);
    out
}

/// A buffer split into its parts; the dump tool and tests read it back.
#[derive(Debug, PartialEq)]
pub struct Parts<'a> {
    pub format_version: u32,
    pub json: &'a str,
    pub blob: &'a [u8],
}

#[derive(Debug, PartialEq, Eq)]
pub enum ReadError {
    BadMagic,
    Truncated,
    NonZeroPadding,
    NotUtf8,
}

pub fn read(buffer: &[u8]) -> Result<Parts<'_>, ReadError> {
    if buffer.len() < HEADER_BYTES {
        return Err(ReadError::Truncated);
    }
    if &buffer[..4] != MAGIC {
        return Err(ReadError::BadMagic);
    }
    let u32_at = |i: usize| u32::from_le_bytes(buffer[i..i + 4].try_into().expect("4 bytes"));
    let json_end = HEADER_BYTES + u32_at(8) as usize;
    let blob_start = json_end.next_multiple_of(8);
    if buffer.len() < blob_start {
        return Err(ReadError::Truncated);
    }
    if buffer[json_end..blob_start].iter().any(|&b| b != 0) {
        return Err(ReadError::NonZeroPadding);
    }
    Ok(Parts {
        format_version: u32_at(4),
        json: std::str::from_utf8(&buffer[HEADER_BYTES..json_end])
            .map_err(|_| ReadError::NotUtf8)?,
        blob: &buffer[blob_start..],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_matches_the_contract() {
        let buf = write("{}", &[0xAA; 3]);
        assert_eq!(&buf[..4], b"ICRP");
        assert_eq!(u32::from_le_bytes(buf[4..8].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[8..12].try_into().unwrap()), 2);
        assert_eq!(&buf[12..14], b"{}");
        // 14 bytes pad to 16; the blob starts there.
        assert_eq!(&buf[14..16], &[0, 0]);
        assert_eq!(&buf[16..], &[0xAA; 3]);
    }

    #[test]
    fn padding_is_zero_and_blob_is_8_aligned_for_every_json_length() {
        for len in 0..20 {
            let json = "x".repeat(len);
            let buf = write(&json, &[1]);
            let parts = read(&buf).unwrap();
            assert_eq!(parts.json, json);
            assert_eq!(parts.blob, &[1]);
            assert_eq!((buf.len() - 1) % 8, 0, "blob offset for json length {len}");
        }
    }

    #[test]
    fn movement_records_round_trip_in_24_bytes() {
        let sample = MovementSample {
            time_ms: -3,
            x: 1.5,
            y: -2.0,
            z: 3.25,
            yaw: 90.0,
            pitch: -10.5,
        };
        let mut blob = Vec::new();
        sample.write_to(&mut blob);
        assert_eq!(blob.len(), MOVEMENT_RECORD_BYTES);
        assert_eq!(MovementSample::read(&blob), sample);
    }

    #[test]
    fn reader_refuses_damaged_buffers() {
        assert_eq!(read(b"ICR"), Err(ReadError::Truncated));
        assert_eq!(read(b"XCRP\x01\0\0\0\0\0\0\0"), Err(ReadError::BadMagic));
        let mut buf = write("{}", &[]);
        buf[14] = 1;
        assert_eq!(read(&buf), Err(ReadError::NonZeroPadding));
        let mut short = write("{\"a\":1}", &[]);
        short.truncate(14);
        assert_eq!(read(&short), Err(ReadError::Truncated));
    }
}
