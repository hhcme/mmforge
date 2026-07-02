//! Memory budget tracking for GPU resource allocation.
//!
//! Provides a soft budget that limits how much data is packed into each
//! RenderPacket chunk, preventing GPU memory exhaustion on large models.

use std::sync::atomic::{AtomicUsize, Ordering};

/// A GPU memory budget in bytes.
///
/// Tracks both a hard limit (`capacity`) and a running `used` counter.
/// Allocations that would exceed the budget are rejected (return `false`),
/// allowing callers to split work across multiple chunks or reduce quality.
#[derive(Debug)]
pub struct MemoryBudget {
    capacity: usize,
    used: AtomicUsize,
}

impl MemoryBudget {
    /// Create a new budget with the given capacity in bytes.
    ///
    /// Common sizes:
    /// - 64 MB  for low-end / mobile
    /// - 256 MB for desktop
    /// - 1 GB   for workstation
    pub fn new(capacity: usize) -> Self {
        Self {
            capacity: capacity.min(isize::MAX as usize),
            used: AtomicUsize::new(0),
        }
    }

    /// The total capacity of this budget, in bytes.
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Current tracked usage, in bytes.
    pub fn used(&self) -> usize {
        self.used.load(Ordering::Relaxed)
    }

    /// Remaining available bytes.
    pub fn available(&self) -> usize {
        self.capacity.saturating_sub(self.used())
    }

    /// Fraction of budget used (0.0 – 1.0).
    pub fn usage_fraction(&self) -> f32 {
        if self.capacity == 0 {
            return 0.0;
        }
        self.used() as f32 / self.capacity as f32
    }

    /// Attempt to reserve `bytes` from the budget.
    ///
    /// Returns `true` if the reservation fits within capacity, `false` otherwise.
    /// The reservation is **not** automatically freed — call [`release`] when the
    /// data is no longer needed (e.g., after GPU upload completes).
    pub fn reserve(&self, bytes: usize) -> bool {
        let mut current = self.used.load(Ordering::Relaxed);
        loop {
            if current.saturating_add(bytes) > self.capacity {
                return false;
            }
            match self.used.compare_exchange_weak(
                current,
                current + bytes,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return true,
                Err(prev) => current = prev,
            }
        }
    }

    /// Release previously reserved bytes.
    pub fn release(&self, bytes: usize) {
        self.used
            .fetch_sub(bytes.min(self.used()), Ordering::Relaxed);
    }

    /// Reset the usage counter to zero.
    pub fn reset(&self) {
        self.used.store(0, Ordering::Relaxed);
    }
}

/// Approximate GPU memory cost for a mesh with the given buffer sizes.
///
/// Accounts for interleaved position+normal vertex buffer (6 × f32 = 24 bytes/vertex)
/// and a separate index buffer (4 bytes per index, u32).
pub fn gpu_mesh_memory_bytes(vertex_count: usize, index_count: usize) -> usize {
    vertex_count * 6 * std::mem::size_of::<f32>() + index_count * std::mem::size_of::<u32>()
}

/// Approximate GPU memory cost for a mesh with optional UVs.
pub fn gpu_mesh_memory_with_uvs(vertex_count: usize, index_count: usize) -> usize {
    let per_vertex = if vertex_count > 0 {
        // pos (3) + normal (3) + uv (2) = 8 floats per vertex
        8 * std::mem::size_of::<f32>()
    } else {
        0
    };
    vertex_count * per_vertex + index_count * std::mem::size_of::<u32>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_budget_zero_usage() {
        let b = MemoryBudget::new(1024 * 1024);
        assert_eq!(b.used(), 0);
        assert_eq!(b.available(), 1024 * 1024);
    }

    #[test]
    fn reserve_within_budget() {
        let b = MemoryBudget::new(1024);
        assert!(b.reserve(512));
        assert_eq!(b.used(), 512);
    }

    #[test]
    fn reserve_exceeds_budget() {
        let b = MemoryBudget::new(512);
        assert!(b.reserve(256));
        assert!(!b.reserve(512));
        assert_eq!(b.used(), 256);
    }

    #[test]
    fn release_frees_space() {
        let b = MemoryBudget::new(1024);
        assert!(b.reserve(800));
        b.release(800);
        assert_eq!(b.used(), 0);
        assert!(b.reserve(1000));
    }

    #[test]
    fn usage_fraction() {
        let b = MemoryBudget::new(1000);
        b.reserve(250);
        assert!((b.usage_fraction() - 0.25).abs() < 0.01);
        b.reset();
        assert_eq!(b.usage_fraction(), 0.0);
    }

    #[test]
    fn gpu_mesh_memory_cost() {
        let bytes = gpu_mesh_memory_bytes(1000, 3000);
        assert_eq!(bytes, 1000 * 6 * 4 + 3000 * 4);
    }

    #[test]
    fn gpu_mesh_memory_cost_with_uvs() {
        let bytes = super::gpu_mesh_memory_with_uvs(1000, 3000);
        assert_eq!(bytes, 1000 * 8 * 4 + 3000 * 4);
    }
}
