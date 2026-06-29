//! Basic math types and bounding box — thin wrappers over `glam`.

use glam::Vec3;

/// Axis-aligned bounding box.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BoundingBox {
    pub min: Vec3,
    pub max: Vec3,
}

impl BoundingBox {
    /// An empty box with inverted extents; use [`extend`] to grow.
    pub const EMPTY: Self = Self {
        min: Vec3::splat(f32::MAX),
        max: Vec3::splat(f32::MIN),
    };

    /// Create from explicit min/max corners.
    pub fn new(min: Vec3, max: Vec3) -> Self {
        Self { min, max }
    }

    /// Create a box enclosing a single point.
    pub fn from_point(p: Vec3) -> Self {
        Self { min: p, max: p }
    }

    /// Grow to include `other`.
    pub fn extend(&mut self, other: BoundingBox) {
        self.min = self.min.min(other.min);
        self.max = self.max.max(other.max);
    }

    /// Grow to include a point.
    pub fn extend_point(&mut self, p: Vec3) {
        self.min = self.min.min(p);
        self.max = self.max.max(p);
    }

    /// Whether the box has been grown at least once.
    pub fn is_valid(&self) -> bool {
        self.min.x <= self.max.x && self.min.y <= self.max.y && self.min.z <= self.max.z
    }

    /// Centre of the box.
    pub fn center(&self) -> Vec3 {
        (self.min + self.max) * 0.5
    }

    /// Half-extents.
    pub fn half_extents(&self) -> Vec3 {
        (self.max - self.min) * 0.5
    }

    /// Length of the diagonal.
    pub fn diagonal(&self) -> f32 {
        (self.max - self.min).length()
    }

    /// Bounding sphere radius (half the diagonal).
    pub fn radius(&self) -> f32 {
        self.diagonal() * 0.5
    }
}

impl Default for BoundingBox {
    fn default() -> Self {
        Self::EMPTY
    }
}

/// SIMD-friendly 16-byte aligned Vec3, re-exported from glam.
pub type Vec3A = glam::Vec3A;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_box_is_invalid() {
        assert!(!BoundingBox::EMPTY.is_valid());
    }

    #[test]
    fn extend_builds_valid_box() {
        let mut bb = BoundingBox::EMPTY;
        bb.extend_point(Vec3::new(-1.0, -2.0, -3.0));
        bb.extend_point(Vec3::new(4.0, 5.0, 6.0));
        assert!(bb.is_valid());
        assert_eq!(bb.center(), Vec3::new(1.5, 1.5, 1.5));
    }

    #[test]
    fn diagonal_of_unit_box() {
        let bb = BoundingBox::new(Vec3::ZERO, Vec3::ONE);
        let expected = 3.0_f32.sqrt();
        assert!((bb.diagonal() - expected).abs() < 1e-6);
    }
}
