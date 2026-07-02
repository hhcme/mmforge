//! Cooperative cancellation token for long-running operations.
//!
//! A `CancellationToken` is a cheap, thread-safe flag that parsers and
//! tessellation loops can poll to bail out early when the user cancels
//! an operation.  The flag uses `Relaxed` ordering — sufficient for a
//! best-effort cancellation that does not need to synchronize memory.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// A thread-safe cancellation token.
///
/// Clone returns a handle to the same underlying flag (via `Arc`).
#[derive(Debug, Clone)]
pub struct CancellationToken {
    cancelled: Arc<AtomicBool>,
}

impl CancellationToken {
    /// Create a new token in the "not cancelled" state.
    pub fn new() -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Request cancellation.  This is idempotent and safe to call from
    /// any thread, any number of times.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    /// Check whether cancellation has been requested.
    ///
    /// This is cheap (a single `Relaxed` load) and safe to call in
    /// tight loops.
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }
}

impl Default for CancellationToken {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_token_is_not_cancelled() {
        let token = CancellationToken::new();
        assert!(!token.is_cancelled());
    }

    #[test]
    fn cancel_sets_flag() {
        let token = CancellationToken::new();
        token.cancel();
        assert!(token.is_cancelled());
    }

    #[test]
    fn cancel_is_idempotent() {
        let token = CancellationToken::new();
        token.cancel();
        token.cancel();
        assert!(token.is_cancelled());
    }

    #[test]
    fn clone_shares_state() {
        let token = CancellationToken::new();
        let clone = token.clone();
        assert!(!clone.is_cancelled());
        token.cancel();
        assert!(clone.is_cancelled());
    }

    #[test]
    fn default_is_not_cancelled() {
        let token = CancellationToken::default();
        assert!(!token.is_cancelled());
    }
}
