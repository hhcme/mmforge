//! Background document open job with progress and cancellation.
//!
//! `OpenDocumentJob` orchestrates the detect → parse → tessellate → build
//! pipeline on a background thread, reporting progress and supporting
//! cooperative cancellation.
//!
//! # Thread safety
//!
//! All C callbacks (`progress_cb`, `completion_cb`) fire on the background
//! worker thread.  The `stage` pointer in the progress callback is valid
//! only for the duration of that single call — callers must copy it before
//! dispatching to another thread.
//!
//! # Error propagation
//!
//! The completion callback receives both the document pointer and an error
//! string.  On success `doc` is non-null and `error` is null; on failure
//! `doc` is null and `error` points to a UTF-8 error message.  The error
//! string is valid only for the duration of the completion callback.
//!
//! # Non-blocking free
//!
//! `mmf_open_job_free` cancels the token and detaches the background
//! thread.  The completion callback will still fire (if set), but the
//! caller must not use the document pointer after calling free.

use std::os::raw::c_char;
use std::sync::Arc;
use std::thread;

use mmforge_core::cancel::CancellationToken;
use mmforge_core::progress::{ParseProgress, ProgressCallback};

use crate::MmfDocument;

/// Wrapper for raw void pointer that is Send + Sync.
/// Uses usize to avoid the compiler seeing `*mut c_void` in closure captures.
/// SAFETY: The caller guarantees that the pointed-to data is valid and
/// thread-safe for the duration of the callbacks.
#[derive(Clone, Copy)]
struct UserdataPtr(usize);
unsafe impl Send for UserdataPtr {}
unsafe impl Sync for UserdataPtr {}

impl UserdataPtr {
    fn new(ptr: *mut std::ffi::c_void) -> Self {
        Self(ptr as usize)
    }
    fn as_ptr(self) -> *mut std::ffi::c_void {
        self.0 as *mut std::ffi::c_void
    }
}

/// Opaque job handle returned to Swift.
pub struct OpenDocumentJob {
    /// Shared cancellation token — the caller can cancel from any thread.
    cancel: Arc<CancellationToken>,
    /// Join handle for the background thread.
    handle: Option<thread::JoinHandle<Option<Box<MmfDocument>>>>,
}

/// C function pointer type for progress callbacks.
/// The `stage` pointer is valid only for the duration of the call —
/// callers must copy the string before dispatching to another thread.
pub type CProgressCallback = Option<
    unsafe extern "C" fn(
        stage: *const c_char,
        current: u32,
        total: u32,
        user_data: *mut std::ffi::c_void,
    ),
>;

/// C function pointer type for completion callbacks.
///
/// On success: `doc` is non-null, `error` is null.  Caller takes ownership
/// of `doc` via `mmf_document_free`.
///
/// On failure: `doc` is null, `error` points to a UTF-8 error message
/// valid for the duration of this call only.
pub type CCompletionCallback = Option<
    unsafe extern "C" fn(
        doc: *mut MmfDocument,
        error: *const c_char,
        user_data: *mut std::ffi::c_void,
    ),
>;

/// Create a new cancellation token.  Caller owns the returned pointer.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_cancel_token_new() -> *mut CancellationToken {
    Box::into_raw(Box::new(CancellationToken::new()))
}

/// Cancel the token.  Safe to call from any thread.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_cancel_token_cancel(token: *const CancellationToken) {
    if !token.is_null() {
        unsafe { &*token }.cancel();
    }
}

/// Free the cancellation token.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_cancel_token_free(token: *mut CancellationToken) {
    if !token.is_null() {
        unsafe { drop(Box::from_raw(token)) };
    }
}

/// Start an async document open operation.
///
/// Returns a job handle.  The caller must eventually call `mmf_open_job_free`.
/// The `progress_cb` and `completion_cb` are called from the background thread.
/// The `user_data` pointer is passed through to both callbacks.
///
/// On completion, `completion_cb` is called:
/// - `doc` non-null, `error` null: success.  Caller takes ownership via `mmf_document_free`.
/// - `doc` null, `error` non-null: failure.  Error string valid only for callback duration.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_open_async(
    path: *const c_char,
    cancel: *const CancellationToken,
    progress_cb: CProgressCallback,
    completion_cb: CCompletionCallback,
    user_data: *mut std::ffi::c_void,
) -> *mut OpenDocumentJob {
    // Immediately wrap raw pointers into Send-safe wrappers so the
    // `move` closures below never see the raw `*mut c_void`.
    let ud = UserdataPtr::new(user_data);
    mmf_open_async_inner(path, cancel, progress_cb, completion_cb, ud)
}

/// Inner implementation that works entirely with Send-safe types.
fn mmf_open_async_inner(
    path: *const c_char,
    cancel: *const CancellationToken,
    progress_cb: CProgressCallback,
    completion_cb: CCompletionCallback,
    ud: UserdataPtr,
) -> *mut OpenDocumentJob {
    let path = match crate::c_path_to_owned(path) {
        Some(p) => p,
        None => return std::ptr::null_mut(),
    };

    let cancel = if cancel.is_null() {
        Arc::new(CancellationToken::new())
    } else {
        Arc::new(unsafe { &*cancel }.clone())
    };
    let cancel_for_thread = cancel.clone();

    let progress: Option<ProgressCallback> = progress_cb.map(|cb| {
        Box::new(move |p: &ParseProgress| {
            // Copy stage string into a CString before calling across the FFI
            // boundary — the &str is only valid for the duration of this call.
            let stage = std::ffi::CString::new(p.stage).unwrap_or_default();
            unsafe { cb(stage.as_ptr(), p.current, p.total, ud.as_ptr()) };
        }) as ProgressCallback
    });

    let handle = thread::spawn(move || {
        let result = run_open_pipeline(&path, progress.as_ref(), &cancel_for_thread);

        if let Some(cb) = completion_cb {
            match result {
                Ok(doc) => {
                    unsafe { cb(Box::into_raw(doc), std::ptr::null(), ud.as_ptr()) };
                }
                Err(e) => {
                    let msg = format!("{e}");
                    let c_msg = std::ffi::CString::new(msg).unwrap_or_default();
                    unsafe {
                        cb(std::ptr::null_mut(), c_msg.as_ptr(), ud.as_ptr());
                    }
                }
            }
            return None;
        }

        result.ok()
    });

    Box::into_raw(Box::new(OpenDocumentJob {
        cancel,
        handle: Some(handle),
    }))
}

/// Cancel the job.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_open_job_cancel(job: *const OpenDocumentJob) {
    if !job.is_null() {
        let job = unsafe { &*job };
        job.cancel.cancel();
    }
}

/// Free the job handle.  Cancels the token and drops the join handle,
/// which detaches the background thread (non-blocking).  The completion
/// callback will still fire if set, but the caller must NOT use the
/// document pointer after this call.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_open_job_free(job: *mut OpenDocumentJob) {
    if !job.is_null() {
        let mut job = unsafe { Box::from_raw(job) };
        job.cancel.cancel();
        // Drop the handle instead of join — this detaches the background
        // thread, avoiding blocking the caller (e.g. main thread).
        // The completion callback handles its own resource cleanup via the
        // generation counter and weak viewModel reference.
        drop(job.handle.take());
    }
}

/// Run the full open pipeline on the current thread.
fn run_open_pipeline(
    path: &std::path::Path,
    progress: Option<&ProgressCallback>,
    cancel: &CancellationToken,
) -> mmforge_core::Result<Box<MmfDocument>> {
    use mmforge_core::error::Error;

    // Stage 1: Detect format.
    if let Some(cb) = progress {
        cb(&ParseProgress::new("detecting", 0, 0));
    }
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }

    // Read header for detection.
    let header = std::fs::read(path).map_err(Error::Io)?;
    let header_slice = &header[..header.len().min(84)];

    // Stage 2: Parse.
    if let Some(cb) = progress {
        cb(&ParseProgress::new("parsing", 0, 0));
    }
    if cancel.is_cancelled() {
        return Err(Error::Cancelled);
    }

    // Run the same detection + parse logic as mmf_parse_file.
    let result = crate::parse_with_detection(path, header_slice, progress, cancel)?;

    if let Some(cb) = progress {
        cb(&ParseProgress::new("done", 1, 1));
    }

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Helper: create a temp file with the given extension and content.
    fn temp_file(ext: &str, content: &[u8]) -> tempfile::NamedTempFile {
        let f = tempfile::Builder::new()
            .suffix(&format!(".{ext}"))
            .tempfile()
            .unwrap();
        std::fs::write(f.path(), content).unwrap();
        f
    }

    #[test]
    fn cancel_token_new_and_cancel() {
        let token = CancellationToken::new();
        assert!(!token.is_cancelled());
        token.cancel();
        assert!(token.is_cancelled());
    }

    #[test]
    fn cancel_token_clone_shares_state() {
        let token = CancellationToken::new();
        let clone = token.clone();
        token.cancel();
        assert!(clone.is_cancelled());
    }

    #[test]
    fn open_async_null_path_returns_null() {
        let job = mmf_open_async(
            std::ptr::null(),
            std::ptr::null(),
            None,
            None,
            std::ptr::null_mut(),
        );
        assert!(job.is_null());
    }

    #[test]
    fn open_async_invalid_utf8_returns_null() {
        // Create a path with invalid UTF-8 (no interior null bytes).
        let bad_path = std::ffi::CString::new(vec![0xFF, 0xFE]).unwrap();
        let job = mmf_open_async(
            bad_path.as_ptr(),
            std::ptr::null(),
            None,
            None,
            std::ptr::null_mut(),
        );
        assert!(job.is_null());
    }

    #[test]
    fn open_async_nonexistent_file_returns_error_via_callback() {
        let path = std::ffi::CString::new("/tmp/mmforge_nonexistent_file.step").unwrap();

        extern "C" fn completion(
            doc: *mut MmfDocument,
            error: *const c_char,
            _ud: *mut std::ffi::c_void,
        ) {
            assert!(doc.is_null());
            assert!(!error.is_null());
            let msg = unsafe { std::ffi::CStr::from_ptr(error) }
                .to_str()
                .unwrap()
                .to_owned();
            // Store the error via the Arc<Mutex> passed as user_data is not
            // directly accessible here, so we just verify the pointer is valid.
            let _ = msg;
        }

        let job = mmf_open_async(
            path.as_ptr(),
            std::ptr::null(),
            None,
            Some(completion),
            std::ptr::null_mut(),
        );
        assert!(!job.is_null());

        // Free the job — this detaches the thread, but the completion
        // callback will fire before the thread exits.
        // Give the thread a moment to complete.
        std::thread::sleep(std::time::Duration::from_millis(100));
        mmf_open_job_free(job);
    }

    #[test]
    fn open_async_cancel_before_parse() {
        let f = temp_file("step", b"ISO-10303-21;\nEND-ISO-10303-21;\n");
        let path = std::ffi::CString::new(f.path().to_str().unwrap()).unwrap();
        let token = CancellationToken::new();
        token.cancel(); // Cancel immediately.

        let completed: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let completed_clone = completed.clone();

        extern "C" fn completion(
            doc: *mut MmfDocument,
            error: *const c_char,
            ud: *mut std::ffi::c_void,
        ) {
            assert!(doc.is_null());
            // Should be a cancellation error.
            if !error.is_null() {
                let msg = unsafe { std::ffi::CStr::from_ptr(error) }.to_str().unwrap();
                assert!(msg.contains("cancelled"), "expected cancelled, got: {msg}");
            }
            // Mark completed via user_data (passed as *mut AtomicBool).
            if !ud.is_null() {
                unsafe { &*(ud as *const AtomicBool) }.store(true, Ordering::Relaxed);
            }
        }

        let flag_ptr = Arc::into_raw(completed_clone) as *mut std::ffi::c_void;

        let job = mmf_open_async(
            path.as_ptr(),
            &token as *const CancellationToken,
            None,
            Some(completion),
            flag_ptr,
        );
        assert!(!job.is_null());

        // Wait for completion.
        for _ in 0..50 {
            if completed.load(Ordering::Relaxed) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(
            completed.load(Ordering::Relaxed),
            "completion callback not called"
        );

        mmf_open_job_free(job);

        // Reclaim the Arc so it gets dropped.
        unsafe { Arc::from_raw(flag_ptr as *const AtomicBool) };
    }

    #[test]
    fn open_async_progress_callback_fires() {
        let f = temp_file("step", b"ISO-10303-21;\nEND-ISO-10303-21;\n");
        let path = std::ffi::CString::new(f.path().to_str().unwrap()).unwrap();

        let progress_count: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let progress_clone = progress_count.clone();
        let progress_ptr = Arc::into_raw(progress_clone) as *mut std::ffi::c_void;

        extern "C" fn progress(
            _stage: *const c_char,
            _current: u32,
            _total: u32,
            ud: *mut std::ffi::c_void,
        ) {
            if !ud.is_null() {
                unsafe { &*(ud as *const AtomicBool) }.store(true, Ordering::Relaxed);
            }
        }

        extern "C" fn completion(
            _doc: *mut MmfDocument,
            _error: *const c_char,
            _ud: *mut std::ffi::c_void,
        ) {
            // no-op
        }

        let job = mmf_open_async(
            path.as_ptr(),
            std::ptr::null(),
            Some(progress),
            Some(completion),
            progress_ptr,
        );
        assert!(!job.is_null());

        // Wait for progress.
        for _ in 0..50 {
            if progress_count.load(Ordering::Relaxed) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(
            progress_count.load(Ordering::Relaxed),
            "progress callback not called"
        );

        mmf_open_job_free(job);
        unsafe { Arc::from_raw(progress_ptr as *const AtomicBool) };
    }

    #[test]
    fn job_free_is_non_blocking() {
        // Verify that mmf_open_job_free returns promptly even when the
        // background thread is still running.
        let f = temp_file("step", b"ISO-10303-21;\nEND-ISO-10303-21;\n");
        let path = std::ffi::CString::new(f.path().to_str().unwrap()).unwrap();

        let job = mmf_open_async(
            path.as_ptr(),
            std::ptr::null(),
            None,
            None,
            std::ptr::null_mut(),
        );
        assert!(!job.is_null());

        // Free immediately — should not block.
        let start = std::time::Instant::now();
        mmf_open_job_free(job);
        let elapsed = start.elapsed();
        assert!(
            elapsed < std::time::Duration::from_secs(2),
            "mmf_open_job_free blocked for {elapsed:?}"
        );
    }
}
