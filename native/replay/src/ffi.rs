//! The C ABI (include/icarus_replay.h). The only `unsafe` in the crate: it
//! reads the caller's path, hands back buffers it allocated, and lends out
//! the decode control it owns.

use std::ffi::{CStr, c_char};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

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

/// A decode's progress and cancel request, shared between the decoding
/// thread and the caller's. Opaque to C; every access is atomic.
#[derive(Default)]
pub struct IcarusReplayControl {
    progress: AtomicU32,
    cancel: AtomicU32,
}

impl IcarusReplayControl {
    fn view(&self) -> Control<'_> {
        Control {
            progress: Some(&self.progress),
            cancel: Some(&self.cancel),
        }
    }
}

/// A new control: progress 0, not cancelled. Free it with
/// `icarus_replay_control_free` once no decode is using it.
#[unsafe(no_mangle)]
pub extern "C" fn icarus_replay_control_new() -> *mut IcarusReplayControl {
    Box::into_raw(Box::default())
}

/// The decode's progress, 0..10000 (hundredths of a percent). 0 for null.
///
/// # Safety
/// `control` is null or a live control from `icarus_replay_control_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn icarus_replay_control_progress(
    control: *const IcarusReplayControl,
) -> u32 {
    // SAFETY: null or live, by the caller's contract.
    unsafe { control.as_ref() }.map_or(0, |c| c.progress.load(Ordering::Relaxed))
}

/// Ask the decode using `control` to stop with `cancelled`. Null is ignored.
///
/// # Safety
/// As for `icarus_replay_control_progress`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn icarus_replay_control_cancel(control: *const IcarusReplayControl) {
    // SAFETY: null or live, by the caller's contract.
    if let Some(c) = unsafe { control.as_ref() } {
        c.cancel.store(1, Ordering::Relaxed);
    }
}

/// Release a control. Null is ignored.
///
/// # Safety
/// `control` is null or came from `icarus_replay_control_new`, is freed once,
/// and no `icarus_replay_decode` call is still using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn icarus_replay_control_free(control: *mut IcarusReplayControl) {
    if !control.is_null() {
        // SAFETY: leaked by `icarus_replay_control_new`, freed once.
        drop(unsafe { Box::from_raw(control) });
    }
}

/// Full decode to an `.icrp` buffer, or an error object. `control`, when not
/// null, receives progress and is checked for a cancel request between
/// frames and packets.
///
/// # Safety
/// `path_utf8` as for `icarus_replay_probe`. `control` is null or a live
/// control that is not freed until this call returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn icarus_replay_decode(
    path_utf8: *const c_char,
    control: *const IcarusReplayControl,
) -> IcarusReplayBuffer {
    // SAFETY: forwarded caller contract.
    let path = unsafe { path_from(path_utf8) };
    // SAFETY: null or live for the whole call, by the caller's contract.
    let control =
        unsafe { control.as_ref() }.map_or_else(Control::default, IcarusReplayControl::view);
    guarded(|| crate::decode_file(&path?, control))
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
        // SAFETY: a valid C string; no control.
        let buffer = unsafe { icarus_replay_decode(path.as_ptr(), std::ptr::null()) };
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
    fn a_control_carries_cancel_in_and_progress_out() {
        let control = icarus_replay_control_new();
        // SAFETY: a live control, freed once at the end.
        unsafe {
            let view = (*control).view();
            assert_eq!(icarus_replay_control_progress(control), 0);
            view.report(0.5);
            assert_eq!(icarus_replay_control_progress(control), 5_000);
            assert!(!view.cancelled());
            icarus_replay_control_cancel(control);
            assert!(view.cancelled());

            let path = c"this/does/not/exist.vrf";
            let buffer = icarus_replay_decode(path.as_ptr(), control);
            assert_eq!(buffer.is_error, 1);
            icarus_replay_free(buffer);
            icarus_replay_control_free(control);
        }
        // SAFETY: null is allowed everywhere.
        unsafe {
            assert_eq!(icarus_replay_control_progress(std::ptr::null()), 0);
            icarus_replay_control_cancel(std::ptr::null());
            icarus_replay_control_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn an_empty_success_buffer_round_trips() {
        let buffer = IcarusReplayBuffer::from_result(Ok(Vec::new()));
        assert_eq!((buffer.len, buffer.is_error), (0, 0));
        // SAFETY: from this library, freed once.
        unsafe { icarus_replay_free(buffer) };
    }
}
