//! Orbit camera model — platform-neutral camera state and operations.

use glam::Vec3;

/// An orbit camera that rotates around a target point.
#[derive(Debug, Clone)]
pub struct OrbitCamera {
    pub target: Vec3,
    pub distance: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub fov_y: f32,
    pub near: f32,
    pub far: f32,
}

impl OrbitCamera {
    /// Create with sensible defaults.
    pub fn new() -> Self {
        Self {
            target: Vec3::ZERO,
            distance: 5.0,
            yaw: 0.0,
            pitch: 20.0_f32.to_radians(),
            fov_y: 45.0_f32.to_radians(),
            near: 0.01,
            far: 1000.0,
        }
    }

    /// Rotate the camera by a mouse delta (in radians per pixel).
    pub fn rotate(&mut self, dx: f32, dy: f32, sensitivity: f32) {
        self.yaw += dx * sensitivity;
        self.pitch =
            (self.pitch + dy * sensitivity).clamp(-89.0_f32.to_radians(), 89.0_f32.to_radians());
    }

    /// Zoom by a scroll delta.  Positive = zoom in.
    pub fn zoom(&mut self, delta: f32, speed: f32, min_dist: f32, max_dist: f32) {
        self.distance *= (-delta * speed).exp();
        self.distance = self.distance.clamp(min_dist, max_dist);
    }

    /// Pan the camera in the view plane.
    pub fn pan(&mut self, dx: f32, dy: f32, pan_scale: f32) {
        let (right, up) = self.right_up();
        let world_delta = (-dx * right + dy * up) * self.distance * pan_scale;
        self.target += world_delta;
    }

    /// Fit the camera to enclose a bounding sphere.
    pub fn fit(&mut self, center: Vec3, radius: f32, margin: f32) {
        self.target = center;
        self.distance = (radius / (self.fov_y * 0.5).tan()) * margin;
        self.near = (radius * 0.001).max(0.001);
        self.far = (radius * 100.0).max(100.0);
    }

    /// Eye position in world space.
    pub fn eye(&self) -> Vec3 {
        let (sy, cy) = self.yaw.sin_cos();
        let cp = self.pitch.cos();
        let sp = self.pitch.sin();
        self.target + Vec3::new(sy * cp, sp, cy * cp) * self.distance
    }

    /// View matrix (world → view).
    pub fn view_matrix(&self) -> glam::Mat4 {
        glam::Mat4::look_at_rh(self.eye(), self.target, Vec3::Y)
    }

    /// Projection matrix.
    pub fn projection_matrix(&self, aspect: f32) -> glam::Mat4 {
        glam::Mat4::perspective_rh(self.fov_y, aspect, self.near, self.far)
    }

    fn right_up(&self) -> (Vec3, Vec3) {
        let view = self.view_matrix();
        let right = Vec3::new(view.x_axis.x, view.y_axis.x, view.z_axis.x).normalize();
        let up = Vec3::new(view.x_axis.y, view.y_axis.y, view.z_axis.y).normalize();
        (right, up)
    }
}

impl Default for OrbitCamera {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_camera_sanity() {
        let cam = OrbitCamera::new();
        assert!(cam.distance > 0.0);
        assert!(cam.fov_y > 0.0);
        assert!(cam.near > 0.0);
        assert!(cam.far > cam.near);
    }

    #[test]
    fn fit_sets_reasonable_near_far() {
        let mut cam = OrbitCamera::new();
        cam.fit(Vec3::new(10.0, 0.0, 0.0), 50.0, 1.5);
        assert!(cam.near > 0.0);
        assert!(cam.far > cam.near);
    }

    #[test]
    fn pitch_clamped() {
        let mut cam = OrbitCamera::new();
        cam.rotate(0.0, 100.0, 1.0);
        assert!(cam.pitch <= 89.0_f32.to_radians());
        cam.rotate(0.0, -200.0, 1.0);
        assert!(cam.pitch >= -89.0_f32.to_radians());
    }
}
