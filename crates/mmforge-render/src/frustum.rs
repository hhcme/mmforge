//! View-frustum culling — plane extraction and AABB intersection tests.
//!
//! Extracts 6 clip planes from a view-projection matrix and provides fast
//! sphere/AABB intersection queries so renderers can discard invisible instances
//! before submitting draw calls.

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
    /// Uses Gribb/Hartmann plane extraction (Gribb & Hartmann, 2001).
    /// The input `vp` must be `projection * view`.
    pub fn from_view_projection(vp: &glam::Mat4) -> Self {
        let m = vp.to_cols_array_2d();
        // Left plane:   row3 + row0
        // Right plane:  row3 - row0
        // Bottom plane: row3 + row1
        // Top plane:    row3 - row1
        // Near plane:   row2
        // Far plane:    row3 - row2
        Frustum {
            left: Vec4::new(
                m[3][0] + m[0][0],
                m[3][1] + m[0][1],
                m[3][2] + m[0][2],
                m[3][3] + m[0][3],
            ),
            right: Vec4::new(
                m[3][0] - m[0][0],
                m[3][1] - m[0][1],
                m[3][2] - m[0][2],
                m[3][3] - m[0][3],
            ),
            bottom: Vec4::new(
                m[3][0] + m[1][0],
                m[3][1] + m[1][1],
                m[3][2] + m[1][2],
                m[3][3] + m[1][3],
            ),
            top: Vec4::new(
                m[3][0] - m[1][0],
                m[3][1] - m[1][1],
                m[3][2] - m[1][2],
                m[3][3] - m[1][3],
            ),
            near: Vec4::new(m[2][0], m[2][1], m[2][2], m[2][3]),
            far: Vec4::new(
                m[3][0] - m[2][0],
                m[3][1] - m[2][1],
                m[3][2] - m[2][2],
                m[3][3] - m[2][3],
            ),
        }
    }

    /// Normalise all six planes so that `(nx, ny, nz)` has unit length.
    ///
    /// This is necessary for correct distance-based testing.  Call this once
    /// after extraction before running intersection queries.
    pub fn normalise(&mut self) {
        self.left = normalise_plane(self.left);
        self.right = normalise_plane(self.right);
        self.bottom = normalise_plane(self.bottom);
        self.top = normalise_plane(self.top);
        self.near = normalise_plane(self.near);
        self.far = normalise_plane(self.far);
    }

    /// Test whether an axis-aligned bounding box intersects the frustum.
    ///
    /// Returns `true` if at least part of the box lies inside or intersects
    /// the frustum.  Uses the n-vertex / p-vertex optimisation (pick the
    /// corner farthest from the plane along the normal).
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
            // p-vertex: the corner that is farthest in the direction of the plane normal
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

    fn unit_cube_bounds() -> BoundingBox {
        BoundingBox {
            min: glam::Vec3::new(-1.0, -1.0, -1.0),
            max: glam::Vec3::new(1.0, 1.0, 1.0),
        }
    }

    #[test]
    fn frustum_contains_central_box() {
        let cam = OrbitCamera {
            target: glam::Vec3::ZERO,
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        let vp = cam.projection_matrix(1.0) * cam.view_matrix();
        let mut frustum = Frustum::from_view_projection(&vp);
        frustum.normalise();

        assert!(frustum.intersects_aabb(&unit_cube_bounds()));
    }

    #[test]
    fn box_behind_camera_is_culled() {
        let cam = OrbitCamera {
            target: glam::Vec3::new(0.0, 0.0, 20.0),
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        // Camera looks toward +Z from the origin, so objects behind it (near -Z) are out.
        let vp = cam.projection_matrix(1.0) * cam.view_matrix();
        let mut frustum = Frustum::from_view_projection(&vp);
        frustum.normalise();

        let behind = BoundingBox {
            min: glam::Vec3::new(-1.0, -1.0, -10.0),
            max: glam::Vec3::new(1.0, 1.0, -8.0),
        };
        assert!(!frustum.intersects_aabb(&behind));
    }

    #[test]
    fn box_far_away_is_culled() {
        let cam = OrbitCamera {
            target: glam::Vec3::ZERO,
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 10.0,
        };
        let vp = cam.projection_matrix(1.0) * cam.view_matrix();
        let mut frustum = Frustum::from_view_projection(&vp);
        frustum.normalise();

        let far = BoundingBox {
            min: glam::Vec3::new(-1.0, -1.0, 50.0),
            max: glam::Vec3::new(1.0, 1.0, 52.0),
        };
        assert!(!frustum.intersects_aabb(&far));
    }

    #[test]
    fn sphere_inside_frustum() {
        let cam = OrbitCamera {
            target: glam::Vec3::ZERO,
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        let vp = cam.projection_matrix(1.0) * cam.view_matrix();
        let mut frustum = Frustum::from_view_projection(&vp);
        frustum.normalise();

        assert!(frustum.intersects_sphere(glam::Vec3::ZERO, 2.0));
    }

    #[test]
    fn sphere_outside_frustum() {
        let cam = OrbitCamera {
            target: glam::Vec3::ZERO,
            distance: 5.0,
            yaw: 0.0,
            pitch: 0.0,
            fov_y: 45.0_f32.to_radians(),
            near: 0.1,
            far: 100.0,
        };
        let vp = cam.projection_matrix(1.0) * cam.view_matrix();
        let mut frustum = Frustum::from_view_projection(&vp);
        frustum.normalise();

        assert!(!frustum.intersects_sphere(glam::Vec3::new(0.0, 0.0, -50.0), 1.0));
    }

    #[test]
    fn all_planes_provided() {
        let cam = OrbitCamera::default();
        let vp = cam.projection_matrix(1.0) * cam.view_matrix();
        let frustum = Frustum::from_view_projection(&vp);
        let planes = frustum.planes();
        assert_eq!(planes.len(), 6);
    }

    #[test]
    fn empty_bounds_rejected() {
        let cam = OrbitCamera::default();
        let vp = cam.projection_matrix(1.0) * cam.view_matrix();
        let mut frustum = Frustum::from_view_projection(&vp);
        frustum.normalise();
        assert!(!frustum.intersects_aabb(&BoundingBox::EMPTY));
    }
}
