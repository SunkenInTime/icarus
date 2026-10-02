//! The C ABI (include/icarus_replay.h). The only `unsafe` in the crate: it
//! reads the caller's path and cells and hands back buffers it allocated.

use std::ffi::{CStr, c_char};
use std::path::PathBuf;
use std::sync::atomic::AtomicU32;

use crate::decode::Control;
use crate::error::{ErrorCode, ReplayError};

/// A byte buffer owned by this library until `icarus_replay_free`. When
/// `is_error` is nonzero, `ptr` holds the error object's JSON instead.
#[repr(C)]
pub struct IcarusReplayBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub is_error: u32,
}

impl IcarusReplayBuffer {
    fn from_result(result: Result<Vec<u8>, ReplayError>) -> Self {
        let (bytes, is_error) = match result {
            Ok(bytes) => (bytes, 0),
            Err(error) => (error.to_json().into_bytes(), 1),
        };
        // A boxed slice's capacity is its length, which `free` relies on.
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self {
            ptr: Box::into_raw(boxed).cast::<u8>(),
            len,
            is_error,
        }
    }
}

/// Run `f`, turning a panic into a `corrupt` error rather than unwinding
/// into the caller's frames.
fn guarded(f: impl FnOnce() -> Result<Vec<u8>, ReplayError>) -> IcarusReplayBuffer {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
        .unwrap_or_else(|_| Err(ReplayError::new(ErrorCode::Corrupt, "the decoder panicked")));
    IcarusReplayBuffer::from_result(result)
}

/// # Safety
/// `path` is null or a NUL-terminated string valid for the call.
unsafe fn path_from(path: *const c_char) -> Result<PathBuf, ReplayError> {
    if path.is_null() {
        return Err(ReplayError::new(ErrorCode::Io, "no path given"));
    }
    // SAFETY: non-null and NUL-terminated by the caller's contract.
    let bytes = unsafe { CStr::from_ptr(path) }.to_bytes();
    let text = std::str::from_utf8(bytes)
        .map_err(|_| ReplayError::new(ErrorCode::Io, "path is not UTF-8"))?;
    Ok(PathBuf::from(text))
}

/// Header-only probe: JSON, or an error object. Never decompresses.
///
/// # Safety
/// `path_utf8` is null or a NUL-terminated UTF-8 string valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn icarus_replay_probe(path_utf8: *const c_char) -> IcarusReplayBuffer {
    // SAFETY: forwarded caller contract.
    let path = unsafe { path_from(path_utf8) };
    guarded(|| {
        let probe = crate::header::probe(&path?)?;
        Ok(serde_json::to_vec(&probe).expect("a probe always serializes"))
    })
}

/// Full decode to an `.icrp` buffer, or an error object. `progress` receives
/// 0..10000 by relaxed stores; a nonzero `cancel` stops the decode with
/// `cancelled`. Either may be null.
///
/// # Safety
/// `path_utf8` as for `icarus_replay_probe`. `progress` and `cancel` are null
/// or 4-byte-aligned cells that stay valid until this call returns; other
/// threads may touch them only with atomic operations.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn icarus_replay_decode(
    path_utf8: *const c_char,
    progress: *mut u32,
    cancel: *const u32,
) -> IcarusReplayBuffer {
    // SAFETY: forwarded caller contract.
    let path = unsafe { path_from(path_utf8) };
    // SAFETY: aligned, live for the call, and only touched atomically; AtomicU32
    // has u32's size and alignment.
    let progress = unsafe { progress.cast::<AtomicU32>().as_ref() };
    // SAFETY: as above; only loaded.
    let cancel = unsafe { cancel.cast::<AtomicU32>().as_ref() };
    guarded(|| crate::decode_file(&path?, Control { progress, cancel }))
}

/// Release a buffer from `icarus_replay_probe` or `icarus_replay_decode`.
/// A null `ptr` is ignored.
///
/// # Safety
/// `buffer` came from this library and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn icarus_replay_free(buffer: IcarusReplayBuffer) {
    if buffer.ptr.is_null() {
        return;
    }
    // SAFETY: `ptr`/`len` are a boxed slice this library leaked in `from_result`.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len)) });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(buffer: &IcarusReplayBuffer) -> &[u8] {
        // SAFETY: a live buffer from this library.
        unsafe { std::slice::from_raw_parts(buffer.ptr, buffer.len) }
    }

    #[test]
    fn errors_cross_the_abi_as_json_and_free_cleanly() {
        let path = c"this/does/not/exist.vrf";
        // SAFETY: a valid C string; null cells.
        let buffer =
            unsafe { icarus_replay_decode(path.as_ptr(), std::ptr::null_mut(), std::ptr::null()) };
        assert_eq!(buffer.is_error, 1);
        let json: serde_json::Value = serde_json::from_slice(read(&buffer)).unwrap();
        assert_eq!(json["code"], "io");
        // SAFETY: from this library, freed once.
        unsafe { icarus_replay_free(buffer) };
    }

    #[test]
    fn a_null_path_is_an_error_not_a_crash() {
        // SAFETY: null is allowed.
        let buffer = unsafe { icarus_replay_probe(std::ptr::null()) };
        assert_eq!(buffer.is_error, 1);
        // SAFETY: from this library, freed once.
        unsafe { icarus_replay_free(buffer) };
        // SAFETY: a null buffer is ignored.
        unsafe {
            icarus_replay_free(IcarusReplayBuffer {
                ptr: std::ptr::null_mut(),
                len: 0,
                is_error: 0,
            })
        };
    }

    #[test]
    fn an_empty_success_buffer_round_trips() {
        let buffer = IcarusReplayBuffer::from_result(Ok(Vec::new()));
        assert_eq!((buffer.len, buffer.is_error), (0, 0));
        // SAFETY: from this library, freed once.
        unsafe { icarus_replay_free(buffer) };
    }
}
