//! View-frustum culling — plane extraction and AABB intersection tests.

use glam::Vec4;
use mmforge_core::math::BoundingBox;

/// Six-axis—aligned frustum planes in world space.
///
/// Each plane is stored as a 4D vector `(nx, ny, nz, d)` where the plane
/// equation is `nx*x + ny*y + nz*z + d = 0` and the normal points inward
/// (toward the frustum interior).  A point **inside** the frustum satisfies
/// `nx*x + ny*y + nz*z + d >= 0` for all six planes.
#[derive(Debug, Clone)]
pub struct Frustum {
    pub left: Vec4,
    pub right: Vec4,
    pub bottom: Vec4,
    pub top: Vec4,
    pub near: Vec4,
    pub far: Vec4,
}

impl Frustum {
    /// Extract frustum planes from the combined view-projection matrix.
    ///
    /// Uses Gribb/Hartmann plane extraction (Gribb & Hartmann, 2001),
    /// OpenGL NDC convention (z ∈ [-1, 1]).
    ///
    /// The input `vp` must be `projection * view` in column-major order
    /// (glam::Mat4's native storage).  `to_cols_array_2d()` returns
    /// `m[col][row_component]` where row-component 0..3 is x,y,z,w of the column.
    ///
    /// In column-major convention, Row R (0-indexed) is
    /// `(m[0][R], m[1][R], m[2][R], m[3][R])`.  For OpenGL:
    ///
    /// - Left:   Row3 + Row0
    /// - Right:  Row3 − Row0
    /// - Bottom: Row3 + Row1
    /// - Top:    Row3 − Row1
    /// - Near:   Row3 + Row2
    /// - Far:    Row3 − Row2
    pub fn from_view_projection(vp: &glam::Mat4) -> Self {
        let m = vp.to_cols_array_2d();

        Frustum {
            left: Vec4::new(
                m[0][3] + m[0][0],
                m[1][3] + m[1][0],
                m[2][3] + m[2][0],
                m[3][3] + m[3][0],
            ),
            right: Vec4::new(
                m[0][3] - m[0][0],
                m[1][3] - m[1][0],
                m[2][3] - m[2][0],
                m[3][3] - m[3][0],
            ),
            bottom: Vec4::new(
                m[0][3] + m[0][1],
                m[1][3] + m[1][1],
                m[2][3] + m[2][1],
                m[3][3] + m[3][1],
            ),
            top: Vec4::new(
                m[0][3] - m[0][1],
                m[1][3] - m[1][1],
                m[2][3] - m[2][1],
                m[3][3] - m[3][1],
            ),
            near: Vec4::new(
                m[0][3] + m[0][2],
                m[1][3] + m[1][2],
                m[2][3] + m[2][2],
                m[3][3] + m[3][2],
            ),
            far: Vec4::new(
                m[0][3] - m[0][2],
                m[1][3] - m[1][2],
                m[2][3] - m[2][2],
                m[3][3] - m[3][2],
            ),
        }
    }

    /// Normalise all six planes so that `(nx, ny, nz)` has unit length.
    pub fn normalise(&mut self) {
        self.left = normalise_plane(self.left);
        self.right = normalise_plane(self.right);
        self.bottom = normalise_plane(self.bottom);
        self.top = normalise_plane(self.top);
        self.near = normalise_plane(self.near);
        self.far = normalise_plane(self.far);
    }

    /// Test whether an axis-aligned bounding box intersects the frustum.
    pub fn intersects_aabb(&self, bb: &BoundingBox) -> bool {
        if !bb.is_valid() {
            return false;
        }
        let min = [bb.min.x, bb.min.y, bb.min.z];
        let max = [bb.max.x, bb.max.y, bb.max.z];
        let planes = [
            &self.left,
            &self.right,
            &self.bottom,
            &self.top,
            &self.near,
            &self.far,
        ];
        for plane in planes {
            let px = if plane.x >= 0.0 { max[0] } else { min[0] };
            let py = if plane.y >= 0.0 { max[1] } else { min[1] };
            let pz = if plane.z >= 0.0 { max[2] } else { min[2] };
            if plane.x * px + plane.y * py + plane.z * pz + plane.w < 0.0 {
                return false;
            }
        }
        true
    }

    /// Test whether a bounding sphere intersects the frustum.
    pub fn intersects_sphere(&self, center: glam::Vec3, radius: f32) -> bool {
        let planes = [
            &self.left,
            &self.right,
            &self.bottom,
            &self.top,
            &self.near,
            &self.far,
        ];
        for plane in planes {
            let dist = plane.x * center.x + plane.y * center.y + plane.z * center.z + plane.w;
            if dist < -radius {
                return false;
            }
        }
        true
    }

    /// All six planes as an array, for iteration or shader uniforms.
    pub fn planes(&self) -> [Vec4; 6] {
        [
            self.left,
            self.right,
            self.bottom,
            self.top,
            self.near,
            self.far,
        ]
    }

    /// Debug: compute signed distance of a point to each plane (normalised).
    #[doc(hidden)]
    pub fn signed_distances(&self, point: glam::Vec3) -> [f32; 6] {
        let planes = self.planes();
        let mut d = [0.0f32; 6];
        for (i, p) in planes.iter().enumerate() {
            d[i] = p.x * point.x + p.y * point.y + p.z * point.z + p.w;
        }
        d
    }
}

fn normalise_plane(plane: Vec4) -> Vec4 {
    let len = (plane.x * plane.x + plane.y * plane.y + plane.z * plane.z).sqrt();
    if len > 0.0 {
        Vec4::new(plane.x / len, plane.y / len, plane.z / len, plane.w / len)
    } else {
        plane
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::camera::OrbitCamera;

    fn make_frustum(cam: &OrbitCamera, aspect: f32) -> Frustum {
        let vp = cam.projection_matrix(aspect) * cam.view_matrix();
        let mut f = Frustum::from_view_projection(&vp);
        f.normalise();
        f
    }

    fn bounds(center: glam::Vec3, half: f32) -> BoundingBox {
        BoundingBox {
            min: center - glam::Vec3::splat(half),
            max: center + glam::Vec3::splat(half),
        }
    }

    fn frustum_center_target() -> OrbitCamera {
        OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 5.0),
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        }
    }

    // ----------------------------------------------------------------
    // General tests
    // ----------------------------------------------------------------

    #[test]
    fn frustum_contains_central_box() {
        let cam = frustum_center_target();
        let f = make_frustum(&cam, 1.0);
        let bb = bounds(glam::Vec3::new(0.0, 0.0, 5.0), 0.5);
        assert!(f.intersects_aabb(&bb));
    }

    #[test]
    fn sphere_inside_frustum() {
        let cam = frustum_center_target();
        let f = make_frustum(&cam, 1.0);
        assert!(f.intersects_sphere(glam::Vec3::new(0.0, 0.0, 5.0), 0.5));
    }

    #[test]
    fn all_planes_provided() {
        let cam = OrbitCamera::default();
        let f = make_frustum(&cam, 1.0);
        assert_eq!(f.planes().len(), 6);
    }

    #[test]
    fn empty_bounds_rejected() {
        let cam = OrbitCamera::default();
        let f = make_frustum(&cam, 1.0);
        assert!(!f.intersects_aabb(&BoundingBox::EMPTY));
    }

    // ----------------------------------------------------------------
    // Per-boundary culling tests
    // ----------------------------------------------------------------

    #[test]
    fn box_beyond_near_plane_is_culled() {
        // target=(0,0,5), distance=5 → eye at (0,0,10). near=0.1 → near plane
        // at z≈9.95.  A box whose entire z-range is between the eye and the
        // near plane (9.98±0.01 → [9.97, 9.99]) must be culled.
        let cam = OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 5.0),
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        let f = make_frustum(&cam, 1.0);
        let too_close = bounds(glam::Vec3::new(0.0, 0.0, 9.98), 0.01);
        assert!(!f.intersects_aabb(&too_close));
    }

    #[test]
    fn box_beyond_far_plane_is_culled() {
        let cam = OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 5.0),
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 10.0,
        };
        let f = make_frustum(&cam, 1.0);
        let far_box = bounds(glam::Vec3::new(0.0, 0.0, 100.0), 1.0);
        assert!(!f.intersects_aabb(&far_box));
    }

    #[test]
    fn box_to_left_of_frustum_is_culled() {
        let cam = frustum_center_target();
        let f = make_frustum(&cam, 1.0);
        let left_box = bounds(glam::Vec3::new(-100.0, 0.0, 5.0), 0.1);
        assert!(!f.intersects_aabb(&left_box));
    }

    #[test]
    fn box_to_right_of_frustum_is_culled() {
        let cam = frustum_center_target();
        let f = make_frustum(&cam, 1.0);
        let right_box = bounds(glam::Vec3::new(100.0, 0.0, 5.0), 0.1);
        assert!(!f.intersects_aabb(&right_box));
    }

    #[test]
    fn box_above_frustum_is_culled() {
        let cam = frustum_center_target();
        let f = make_frustum(&cam, 1.0);
        let top_box = bounds(glam::Vec3::new(0.0, 100.0, 5.0), 0.1);
        assert!(!f.intersects_aabb(&top_box));
    }

    #[test]
    fn box_below_frustum_is_culled() {
        let cam = frustum_center_target();
        let f = make_frustum(&cam, 1.0);
        let bottom_box = bounds(glam::Vec3::new(0.0, -100.0, 5.0), 0.1);
        assert!(!f.intersects_aabb(&bottom_box));
    }

    // ----------------------------------------------------------------
    // Sphere boundary tests
    // ----------------------------------------------------------------

    #[test]
    fn sphere_outside_near_plane_is_culled() {
        // eye at (0,0,10), near plane at z≈9.95.  Sphere at z=9.98, r=0.01
        // is entirely between the eye and the near plane.
        let cam = OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 5.0),
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        let f = make_frustum(&cam, 1.0);
        assert!(!f.intersects_sphere(glam::Vec3::new(0.0, 0.0, 9.98), 0.01));
    }

    #[test]
    fn sphere_outside_far_plane_is_culled() {
        let cam = OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 5.0),
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 10.0,
        };
        let f = make_frustum(&cam, 1.0);
        assert!(!f.intersects_sphere(glam::Vec3::new(0.0, 0.0, 100.0), 2.0));
    }

    // ----------------------------------------------------------------
    // Non-axial camera tests
    // ----------------------------------------------------------------

    #[test]
    fn rotated_camera_still_contains_target() {
        let cam = OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 5.0),
            distance: 5.0,
            yaw: 45.0_f32.to_radians(),
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        let f = make_frustum(&cam, 1.0);
        assert!(f.intersects_sphere(glam::Vec3::new(0.0, 0.0, 5.0), 0.1));
    }

    #[test]
    fn pitched_up_camera_still_contains_target() {
        let cam = OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 5.0),
            distance: 5.0,
            yaw: 0.0,
            pitch: 30.0_f32.to_radians(),
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        let f = make_frustum(&cam, 1.0);
        assert!(f.intersects_sphere(glam::Vec3::new(0.0, 0.0, 5.0), 0.1));
    }

    #[test]
    fn signed_distances_consistent() {
        let cam = frustum_center_target();
        let mut f = make_frustum(&cam, 1.0);
        let inside = glam::Vec3::new(0.0, 0.0, 5.0);
        let outside = glam::Vec3::new(100.0, 0.0, 5.0);
        f.normalise();
        let di = f.signed_distances(inside);
        let dl = f.signed_distances(outside);
        // Inside point: all distances >= 0
        for &d in &di {
            assert!(
                d >= -0.001,
                "inside point should have non-negative distances, got {d}"
            );
        }
        // Far-left point: at least one distance < 0
        assert!(
            dl.iter().any(|&d| d < -0.001),
            "far-left point should be outside, distances: {dl:?}"
        );
    }
}
