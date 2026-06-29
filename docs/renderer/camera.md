# 相机控制算法

> 3D 轨道相机和 2D 平移相机的控制算法。
>
> 最后更新：2026-06-29

---

## 3D 轨道相机 (Orbit Camera)

### 数据结构

```rust
pub struct OrbitCamera {
    pub target: [f32; 3],    // 观察目标点
    pub distance: f32,        // 到目标的距离
    pub azimuth: f32,         // 水平角度（弧度）
    pub elevation: f32,       // 垂直角度（弧度）
    pub fov: f32,             // 视场角
    pub near: f32,            // 近裁剪面
    pub far: f32,             // 远裁剪面
}
```

### 旋转算法

```rust
impl OrbitCamera {
    pub fn rotate(&mut self, delta_azimuth: f32, delta_elevation: f32) {
        self.azimuth += delta_azimuth;
        self.elevation += delta_elevation;

        // 限制垂直角度，避免万向锁
        self.elevation = self.elevation.clamp(-FRAC_PI_2 + 0.01, FRAC_PI_2 - 0.01);
    }
}
```

### 缩放算法

```rust
pub fn zoom(&mut self, delta: f32) {
    self.distance *= 1.0 - delta * 0.1;
    self.distance = self.distance.clamp(0.01, 10000.0);
}
```

### 平移算法

```rust
pub fn pan(&mut self, delta_x: f32, delta_y: f32) {
    // 计算相机的右向量和上向量
    let forward = self.forward_vector();
    let right = forward.cross([0.0, 0.0, 1.0]).normalize();
    let up = right.cross(forward).normalize();

    let scale = self.distance * 0.001;
    self.target[0] += (right[0] * delta_x + up[0] * delta_y) * scale;
    self.target[1] += (right[1] * delta_x + up[1] * delta_y) * scale;
    self.target[2] += (right[2] * delta_x + up[2] * delta_y) * scale;
}
```

### 自动适配

```rust
pub fn fit_to_bounds(&mut self, bounds: &BoundingBox) {
    let center = [
        (bounds.min[0] + bounds.max[0]) / 2.0,
        (bounds.min[1] + bounds.max[1]) / 2.0,
        (bounds.min[2] + bounds.max[2]) / 2.0,
    ];
    let size = [
        bounds.max[0] - bounds.min[0],
        bounds.max[1] - bounds.min[1],
        bounds.max[2] - bounds.min[2],
    ];
    let max_size = size[0].max(size[1]).max(size[2]);

    self.target = center;
    self.distance = max_size / (self.fov / 2.0).tan() * 1.5;
}
```

### 坐标转换

```rust
/// 球坐标 → 笛卡尔坐标
pub fn eye_position(&self) -> [f32; 3] {
    [
        self.target[0] + self.distance * self.elevation.cos() * self.azimuth.cos(),
        self.target[1] + self.distance * self.elevation.cos() * self.azimuth.sin(),
        self.target[2] + self.distance * self.elevation.sin(),
    ]
}

/// 转换为 CameraState（传给渲染器）
pub fn to_camera_state(&self) -> CameraState {
    CameraState {
        eye: self.eye_position(),
        target: self.target,
        up: [0.0, 0.0, 1.0],
        fov: self.fov,
        near: self.near,
        far: self.far,
    }
}
```

---

## 2D 平移相机

```rust
pub struct Camera2D {
    pub offset: [f64; 2],
    pub zoom: f64,
    pub rotation: f64,
}

impl Camera2D {
    pub fn pan(&mut self, delta: [f64; 2]) {
        self.offset[0] += delta[0];
        self.offset[1] += delta[1];
    }

    pub fn zoom_at(&mut self, factor: f64, center: [f64; 2]) {
        let old_zoom = self.zoom;
        self.zoom *= factor;
        self.zoom = self.zoom.clamp(0.001, 1000.0);

        // 以 center 为中心缩放
        let zoom_ratio = self.zoom / old_zoom;
        self.offset[0] = center[0] - (center[0] - self.offset[0]) * zoom_ratio;
        self.offset[1] = center[1] - (center[1] - self.offset[1]) * zoom_ratio;
    }

    pub fn fit_to_bounds(&mut self, bounds: &[[f64; 2]; 2], screen_size: [f64; 2]) {
        let width = bounds[1][0] - bounds[0][0];
        let height = bounds[1][1] - bounds[0][1];
        let zoom_x = screen_size[0] / width;
        let zoom_y = screen_size[1] / height;
        self.zoom = zoom_x.min(zoom_y) * 0.9; // 留 10% 边距

        self.offset[0] = screen_size[0] / 2.0 - (bounds[0][0] + width / 2.0) * self.zoom;
        self.offset[1] = screen_size[1] / 2.0 - (bounds[0][1] + height / 2.0) * self.zoom;
    }

    pub fn screen_to_world(&self, screen: [f64; 2]) -> [f64; 2] {
        [
            (screen[0] - self.offset[0]) / self.zoom,
            (screen[1] - self.offset[1]) / self.zoom,
        ]
    }
}
```

---

## 手势映射

| 手势 | 3D 操作 | 2D 操作 |
|------|---------|---------|
| 单指拖动 | 旋转 (rotate) | 平移 (pan) |
| 双指缩放 | 缩放 (zoom) | 缩放 (zoom_at) |
| 双指拖动 | 平移 (pan) | — |
| 双击 | 适配 (fit_to_bounds) | 适配 (fit_to_bounds) |

---

## 数学原理

### 球坐标系

轨道相机使用球坐标系：

```
笛卡尔坐标 (x, y, z) ↔ 球坐标 (r, θ, φ)

r = distance (到原点的距离)
θ = azimuth (水平角度，从 X 轴逆时针)
φ = elevation (垂直角度，从 XY 平面向上)

转换公式:
  x = r × cos(φ) × cos(θ)
  y = r × cos(φ) × sin(θ)
  z = r × sin(φ)
```

### 视图矩阵

```rust
fn view_matrix(&self) -> Mat4 {
    let eye = self.eye_position();
    let target = self.target;
    let up = [0.0, 0.0, 1.0];

    // LookAt 矩阵
    let forward = (target - eye).normalize();
    let right = forward.cross(up).normalize();
    let new_up = right.cross(forward);

    Mat4::new(
        right[0],   right[1],   right[2],   -right.dot(eye),
        new_up[0],  new_up[1],  new_up[2],  -new_up.dot(eye),
        -forward[0],-forward[1],-forward[2], forward.dot(eye),
        0.0,        0.0,        0.0,        1.0,
    )
}
```

### 投影矩阵

```rust
/// 透视投影矩阵
fn perspective_matrix(fov: f32, aspect: f32, near: f32, far: f32) -> Mat4 {
    let tan_half_fov = (fov / 2.0).tan();

    Mat4::new(
        1.0 / (aspect * tan_half_fov), 0.0, 0.0, 0.0,
        0.0, 1.0 / tan_half_fov, 0.0, 0.0,
        0.0, 0.0, -(far + near) / (far - near), -1.0,
        0.0, 0.0, -(2.0 * far * near) / (far - near), 0.0,
    )
}
```

---

## 射线拾取算法

从屏幕坐标转换为 3D 射线：

```rust
fn screen_to_ray(&self, screen_pos: [f32; 2], screen_size: [f32; 2]) -> Ray {
    // 1. 屏幕坐标 → NDC (-1, 1)
    let ndc_x = (2.0 * screen_pos[0] / screen_size[0]) - 1.0;
    let ndc_y = 1.0 - (2.0 * screen_pos[1] / screen_size[1]);

    // 2. NDC → 裁剪空间
    let clip_coords = [ndc_x, ndc_y, -1.0, 1.0];

    // 3. 裁剪空间 → 相机空间
    let inv_proj = self.projection_matrix().inverse();
    let eye_coords = inv_proj * clip_coords;
    let eye_coords = [eye_coords[0], eye_coords[1], -1.0, 0.0];

    // 4. 相机空间 → 世界空间
    let inv_view = self.view_matrix().inverse();
    let world_ray = inv_view * eye_coords;
    let direction = [world_ray[0], world_ray[1], world_ray[2]].normalize();

    Ray {
        origin: self.eye_position(),
        direction,
    }
}
```

---

## 惯性滚动

```rust
pub struct InertialCamera {
    camera: OrbitCamera,
    velocity: [f32; 2],  // 旋转速度
    friction: f32,        // 摩擦系数
}

impl InertialCamera {
    pub fn update(&mut self, dt: f32) {
        // 应用摩擦力
        self.velocity[0] *= self.friction.powf(dt);
        self.velocity[1] *= self.friction.powf(dt);

        // 更新相机
        self.camera.rotate(self.velocity[0] * dt, self.velocity[1] * dt);

        // 速度足够小时停止
        if self.velocity[0].abs() < 0.001 && self.velocity[1].abs() < 0.001 {
            self.velocity = [0.0, 0.0];
        }
    }

    pub fn add_velocity(&mut self, delta: [f32; 2]) {
        self.velocity[0] += delta[0];
        self.velocity[1] += delta[1];
    }
}
```
