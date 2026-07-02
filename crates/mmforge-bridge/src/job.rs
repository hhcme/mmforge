//! Background document open job with progress and cancellation.
//!
//! `OpenDocumentJob` orchestrates the detect → parse → tessellate → build
//! pipeline on a background thread, reporting progress and supporting
//! cooperative cancellation.

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
/// The `stage` pointer is valid only for the duration of the call.
pub type CProgressCallback = Option<
    unsafe extern "C" fn(
        stage: *const c_char,
        current: u32,
        total: u32,
        user_data: *mut std::ffi::c_void,
    ),
>;

/// C function pointer type for completion callbacks.
/// `doc` is non-null on success, null on error.  Call `mmf_last_error()` for details.
pub type CCompletionCallback =
    Option<unsafe extern "C" fn(doc: *mut MmfDocument, user_data: *mut std::ffi::c_void)>;

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
/// On completion, `completion_cb` is called with the result:
/// - `doc` non-null: success.  The caller takes ownership via `mmf_document_free`.
/// - `doc` null: error.  Call `mmf_last_error()` for the message.
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
            let stage = std::ffi::CString::new(p.stage).unwrap_or_default();
            unsafe { cb(stage.as_ptr(), p.current, p.total, ud.as_ptr()) };
        }) as ProgressCallback
    });

    let handle = thread::spawn(move || {
        let result = run_open_pipeline(&path, progress.as_ref(), &cancel_for_thread);

        if let Some(cb) = completion_cb {
            let doc_ptr = match result {
                Ok(doc) => Box::into_raw(doc),
                Err(_) => std::ptr::null_mut(),
            };
            unsafe { cb(doc_ptr, ud.as_ptr()) };
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

/// Free the job handle.  If the job is still running, it will be cancelled
/// and the caller must NOT use the document pointer from the completion callback.
#[unsafe(no_mangle)]
pub extern "C" fn mmf_open_job_free(job: *mut OpenDocumentJob) {
    if !job.is_null() {
        let mut job = unsafe { Box::from_raw(job) };
        job.cancel.cancel();
        if let Some(handle) = job.handle.take() {
            let _ = handle.join();
        }
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
