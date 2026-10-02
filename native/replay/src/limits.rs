//! Caps on what one replay can make the decoder hold. A crafted file could
//! otherwise ask for more memory than the machine has, and a failed
//! allocation aborts the app: `catch_unwind` cannot turn it into an error.
//! Past a cap the decode stops with `corrupt` instead.
//!
//! Each cap sits several times above what our 7-replay corpus needs. Its
//! largest, 1fb53a2c (30 rounds, 50 minutes, 91 MB), sets the figure beside
//! each; the caps that grow with a match's length leave room for about four
//! times as long a one.

use vrf_bitio::BitReader;
use vrf_schema::NetGuidCache;

use crate::error::{ErrorCode, ReplayError};

/// The `.vrf` file, read whole. Real replays are 10-90 MB.
pub const MAX_FILE_BYTES: u64 = 512 << 20;
/// One ReplayData chunk, inflated. Corpus: 11.4 MB.
pub const MAX_CHUNK_BYTES: usize = 64 << 20;
/// Every ReplayData chunk together, inflated. Corpus: 221 MB.
pub const MAX_INFLATED_BYTES: u64 = 1 << 30;
/// Export groups in the schema. Corpus: 540.
pub const MAX_EXPORT_GROUPS: usize = 16_384;
/// Field slots across those groups, 32 bytes each however few are filled:
/// a group declares its slot count up front. Corpus: 10,788.
pub const MAX_EXPORT_SLOTS: usize = 1 << 20;
/// NetGUID paths registered or changed. Corpus: 28,422.
pub const MAX_GUID_CHANGES: u64 = 1 << 20;
/// Records the collector keeps for the analysis, by their size and the
/// strings and bytes they own (their vectors' spare capacity aside).
/// Corpus: 113 MB.
pub const MAX_RETAINED_BYTES: usize = 512 << 20;
/// The `.icrp` buffer handed back. Corpus: 74 MB.
pub const MAX_OUTPUT_BYTES: usize = 512 << 20;

/// The `corrupt` error for a replay past one of these caps.
pub fn exceeded(what: &str, cap: impl std::fmt::Display) -> ReplayError {
    ReplayError::new(
        ErrorCode::Corrupt,
        format!("{what} exceed the decoder's cap of {cap}"),
    )
}

/// ReplayData inflated so far.
#[derive(Default)]
pub struct Inflated(u64);

impl Inflated {
    /// Count one chunk inflated to `bytes`.
    pub fn add(&mut self, bytes: usize) -> Result<(), ReplayError> {
        self.0 += bytes as u64;
        if self.0 > MAX_INFLATED_BYTES {
            return Err(exceeded("inflated replay data bytes", MAX_INFLATED_BYTES));
        }
        Ok(())
    }
}

/// Before a frame's ExportData reaches `cache`: refuse a schema the caps
/// cannot hold. `exports` is a reader at the section's start; the commands
/// are read ahead on a copy, because `read_net_field_exports` allocates
/// every slot a group declares before the next command is read.
pub fn admit_exports(exports: &BitReader<'_>, cache: &NetGuidCache) -> Result<(), ReplayError> {
    // GUID paths are registered by the previous frames' ExportData, so this
    // catches them a frame late; one frame holds few.
    if cache.guid_generation() > MAX_GUID_CHANGES {
        return Err(exceeded("NetGUID path changes", MAX_GUID_CHANGES));
    }
    let declared = Declared::read(exports.clone());
    if declared.groups == 0 {
        return Ok(());
    }
    if cache.group_count() + declared.groups > MAX_EXPORT_GROUPS {
        return Err(exceeded("export groups", MAX_EXPORT_GROUPS));
    }
    let slots: usize = cache.groups().iter().map(|g| g.fields.len()).sum();
    if slots.saturating_add(declared.slots) > MAX_EXPORT_SLOTS {
        return Err(exceeded("export field slots", MAX_EXPORT_SLOTS));
    }
    Ok(())
}

/// What one frame's net-field export commands declare, in the layout
/// vrf-schema's `read_net_field_exports` reads. Every declaration counts as
/// a new group with all its slots: a re-declared group allocates them again
/// before merging.
#[derive(Debug, Default, PartialEq)]
struct Declared {
    groups: usize,
    slots: usize,
}

/// The cap vrf-schema holds an FString to.
const MAX_FSTRING_BYTES: i64 = 1024 * 1024;

impl Declared {
    /// Counts up to the first command that does not read; vrf-schema stops
    /// on the same bytes, so the commands it applies are all counted.
    fn read(mut reader: BitReader<'_>) -> Self {
        let mut declared = Self::default();
        let _ = declared.read_commands(&mut reader);
        declared
    }

    fn read_commands(&mut self, reader: &mut BitReader<'_>) -> Result<(), vrf_bitio::BitError> {
        let commands = reader.read_int_packed()?;
        for _ in 0..commands {
            let _path_name_index = reader.read_int_packed()?;
            match reader.read_int_packed()? {
                0 => {}
                1 => {
                    let _path = reader.read_fstring(MAX_FSTRING_BYTES)?;
                    let slots = reader.read_int_packed()?;
                    self.groups += 1;
                    self.slots = self.slots.saturating_add(slots as usize);
                }
                // vrf-schema refuses the frame here.
                _ => return Ok(()),
            }
            if reader.read_u8()? == 0 {
                continue;
            }
            let _handle = reader.read_int_packed()?;
            let _checksum = reader.read_u32()?;
            // FName: a u8 kind, then an index, or a string and a number.
            if reader.read_u8()? != 0 {
                let _index = reader.read_int_packed()?;
            } else {
                let _name = reader.read_fstring(MAX_FSTRING_BYTES)?;
                let _number = reader.read_i32()?;
            }
        }
        Ok(())
    }
}

/// The finished buffer: a JSON document and movement blob of these sizes.
pub fn check_output(json_bytes: usize, blob_bytes: usize) -> Result<(), ReplayError> {
    if json_bytes.saturating_add(blob_bytes) > MAX_OUTPUT_BYTES {
        return Err(exceeded("decoded replay bytes", MAX_OUTPUT_BYTES));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vendor::frame::walk_demo_frames;
    use vrf_testkit::{add_fstring, add_int_packed};

    /// The slot count vrf-schema allows one group.
    const GROUP_SLOTS: u32 = 65_536;

    /// An ExportData section declaring `groups` new groups of `slots` each,
    /// one field exported on the first, and no export GUIDs.
    fn exports(groups: u32, slots: u32) -> Vec<u8> {
        let mut data = Vec::new();
        add_int_packed(&mut data, groups);
        for index in 0..groups {
            add_int_packed(&mut data, index);
            add_int_packed(&mut data, 1);
            add_fstring(&mut data, &format!("/Game/G{index}.G{index}_C"));
            add_int_packed(&mut data, slots);
            if index == 0 {
                data.push(1);
                add_int_packed(&mut data, 0); // handle
                data.extend(0u32.to_le_bytes()); // checksum
                data.push(0); // FName kind: a string
                add_fstring(&mut data, "Health");
                data.extend(0i32.to_le_bytes());
            } else {
                data.push(0);
            }
        }
        add_int_packed(&mut data, 0); // export GUIDs
        data
    }

    fn admit(exports: &[u8], cache: &NetGuidCache) -> Result<(), ReplayError> {
        admit_exports(&BitReader::new(exports), cache)
    }

    #[test]
    fn a_real_sized_schema_is_admitted() {
        let data = exports(540, 20);
        assert_eq!(
            Declared::read(BitReader::new(&data)),
            Declared {
                groups: 540,
                slots: 10_800
            }
        );
        assert_eq!(admit(&data, &NetGuidCache::new()), Ok(()));
    }

    #[test]
    fn too_many_declared_slots_are_refused() {
        let groups = (MAX_EXPORT_SLOTS as u32).div_ceil(GROUP_SLOTS) + 1;
        let err = admit(&exports(groups, GROUP_SLOTS), &NetGuidCache::new()).unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
        assert!(err.message.contains("slots"), "{err}");
    }

    #[test]
    fn slots_already_in_the_cache_count() {
        let half = (MAX_EXPORT_SLOTS as u32 / GROUP_SLOTS).div_ceil(2) + 1;
        let mut cache = NetGuidCache::new();
        let first = exports(half, GROUP_SLOTS);
        assert_eq!(admit(&first, &cache), Ok(()));
        let _ =
            vrf_schema::read_net_field_exports(&mut BitReader::new(&first), &mut cache).unwrap();
        // The same paths again, so nothing about the second frame alone is
        // too much.
        let err = admit(&first, &cache).unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
    }

    #[test]
    fn too_many_groups_are_refused() {
        let err = admit(
            &exports(MAX_EXPORT_GROUPS as u32 + 1, 1),
            &NetGuidCache::new(),
        )
        .unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
        assert!(err.message.contains("groups"), "{err}");
    }

    #[test]
    fn too_many_guid_changes_are_refused() {
        let mut cache = NetGuidCache::new();
        for i in 0..=MAX_GUID_CHANGES {
            cache.set_net_guid_path(1, if i % 2 == 0 { "A" } else { "B" }, None);
        }
        let err = admit(&exports(0, 0), &cache).unwrap_err();
        assert!(err.message.contains("NetGUID"), "{err}");
    }

    /// One DemoFrame (no header flags) with `exports` and one 1-byte packet.
    fn frame(exports: &[u8]) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend(0i32.to_le_bytes()); // currentLevelIndex
        data.extend(1.0f32.to_le_bytes());
        data.extend(exports);
        add_int_packed(&mut data, 0); // streaming levels
        add_int_packed(&mut data, 0); // ExternalData ends
        data.extend(1i32.to_le_bytes());
        data.push(7);
        data.extend(0i32.to_le_bytes()); // packets end
        data
    }

    #[test]
    fn the_walk_stops_before_the_cache_allocates_a_refused_schema() {
        let groups = (MAX_EXPORT_SLOTS as u32).div_ceil(GROUP_SLOTS) + 1;
        let data = frame(&exports(groups, GROUP_SLOTS));
        let mut cache = NetGuidCache::new();
        let mut refused = None;
        let mut packets = 0;
        walk_demo_frames(
            &data,
            0,
            &mut cache,
            |exports, cache| {
                refused = admit_exports(exports, cache).err();
                refused.is_none()
            },
            |_, _| {
                packets += 1;
                true
            },
        )
        .unwrap();
        assert!(refused.is_some());
        assert_eq!((cache.group_count(), packets), (0, 0));

        // The same frame within the caps walks.
        let mut packets = 0;
        walk_demo_frames(
            &frame(&exports(3, 10)),
            0,
            &mut cache,
            |exports, cache| admit_exports(exports, cache).is_ok(),
            |_, _| {
                packets += 1;
                true
            },
        )
        .unwrap();
        assert_eq!((cache.group_count(), packets), (3, 1));
    }

    #[test]
    fn inflating_past_the_total_is_refused() {
        let mut inflated = Inflated::default();
        let chunks = MAX_INFLATED_BYTES / MAX_CHUNK_BYTES as u64;
        for _ in 0..chunks {
            inflated.add(MAX_CHUNK_BYTES).unwrap();
        }
        let err = inflated.add(1).unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
    }

    #[test]
    fn output_past_the_cap_is_refused() {
        assert_eq!(check_output(MAX_OUTPUT_BYTES - 10, 10), Ok(()));
        let err = check_output(MAX_OUTPUT_BYTES, 1).unwrap_err();
        assert_eq!(err.code, ErrorCode::Corrupt);
    }
}
