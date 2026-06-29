# 渲染优化

> LOD、视锥裁剪、实例化渲染等优化策略。
>
> 最后更新：2026-06-29

---

## 1. LOD (Level of Detail)

根据相机距离使用不同精度的网格：

```rust
pub struct LodManager {
    levels: Vec<LodLevel>,
}

pub struct LodLevel {
    pub distance_threshold: f32,
    pub tessellation_options: TessellationOptions,
}

impl LodManager {
    pub fn select_level(&self, distance: f32) -> &TessellationOptions {
        for level in &self.levels {
            if distance < level.distance_threshold {
                return &level.tessellation_options;
            }
        }
        &self.levels.last().unwrap().tessellation_options
    }
}
```

默认 LOD 配置：

| 距离 | 精度 | linear_deflection | angular_deflection |
|------|------|------------------|-------------------|
| < 10 | 高 | 0.01 | 0.1 |
| < 100 | 标准 | 0.1 | 0.5 |
| ≥ 100 | 低 | 0.5 | 1.0 |

---

## 2. 视锥裁剪

只渲染相机视锥内的实体：

```rust
pub struct Frustum {
    pub planes: [Plane; 6],
}

impl Frustum {
    pub fn from_camera(camera: &CameraState) -> Self {
        // 从 VP 矩阵提取 6 个裁剪面
        // left, right, bottom, top, near, far
    }

    pub fn intersects_aabb(&self, aabb: &Aabb) -> bool {
        for plane in &self.planes {
            let p_vertex = [
                if plane.normal[0] >= 0.0 { aabb.max[0] } else { aabb.min[0] },
                if plane.normal[1] >= 0.0 { aabb.max[1] } else { aabb.min[1] },
                if plane.normal[2] >= 0.0 { aabb.max[2] } else { aabb.min[2] },
            ];
            if plane.distance_to(p_vertex) < 0.0 {
                return false;
            }
        }
        true
    }
}
```

---

## 3. 实例化渲染

相同几何体的不同实例共享同一个 VBO，只传递不同的变换矩阵：

```rust
pub struct InstanceData {
    pub transforms: Vec<[f32; 16]>,
    pub colors: Vec<[f32; 4]>,
}

// 原生渲染后端的实例化渲染
fn add_instanced_mesh(
    backend: &mut NativeRenderBackend,
    scene: &mut RenderScene,
    mesh: &MeshGeometry,
    instances: &InstanceData,
) {
    let instance_buffer = backend.create_instance_buffer(instances);
    let mesh_handle = backend.upload_mesh_if_needed(mesh);
    scene.add_instanced_draw(mesh_handle, instance_buffer);
}
```

---

## 4. 遮挡剔除

基于 BVH 的层次剔除：

```rust
fn cull_recursive(&self, node_idx: usize, frustum: &Frustum) -> Vec<u32> {
    let node = &self.bvh.nodes[node_idx];

    // AABB 快速剔除
    if !frustum.intersects_aabb(&node.aabb()) {
        return vec![]; // 整个子树不可见
    }

    match node {
        BvhNode::Leaf { triangle_ids, .. } => {
            triangle_ids.clone() // 叶子节点的三角形都可见
        }
        BvhNode::Internal { left, right, .. } => {
            let mut visible = self.cull_recursive(*left, frustum);
            visible.extend(self.cull_recursive(*right, frustum));
            visible
        }
    }
}
```

---

## 5. 按需加载

大模型不一次性加载全部数据：

```rust
/// 流式加载：只加载可见部分
pub struct StreamingLoader {
    loaded_chunks: HashMap<ChunkId, MeshData>,
    pending_chunks: Vec<ChunkId>,
}

impl StreamingLoader {
    pub fn update(&mut self, camera: &CameraState) {
        // 1. 计算当前视锥
        let frustum = Frustum::from_camera(camera);

        // 2. 找出需要加载的 chunk
        let needed = self.query_visible_chunks(&frustum);

        // 3. 卸载远离的 chunk
        self.unload_distant(&frustum);

        // 4. 加载新的 chunk
        for chunk_id in needed {
            if !self.loaded_chunks.contains_key(&chunk_id) {
                self.pending_chunks.push(chunk_id);
            }
        }
    }
}
```

---

## 6. 内存管理

| 策略 | 说明 |
|------|------|
| 纹理压缩 | 使用 BC/ETC/ASTC 压缩格式 |
| 顶点压缩 | 使用 half-float 存储法线/UV |
| 索引压缩 | 小模型用 u16 索引 |
| GPU 内存池 | 复用 VBO/IBO 缓冲区 |
| LRU 缓存 | 最近最少使用的数据优先卸载 |

---

## 7. 帧率控制

```rust
pub struct FrameRateController {
    target_fps: u32,
    frame_budget: Duration,
    last_frame: Instant,
}

impl FrameRateController {
    pub fn new(target_fps: u32) -> Self {
        Self {
            target_fps,
            frame_budget: Duration::from_secs_f64(1.0 / target_fps as f64),
            last_frame: Instant::now(),
        }
    }

    pub fn should_render(&self) -> bool {
        self.last_frame.elapsed() >= self.frame_budget
    }

    pub fn adaptive_quality(&self, current_fps: f32) -> QualityLevel {
        if current_fps >= 60.0 {
            QualityLevel::High
        } else if current_fps >= 30.0 {
            QualityLevel::Medium
        } else {
            QualityLevel::Low
        }
    }
}
```

---

## 8. Draw Call 优化

### 合批策略

```rust
/// 将相同材质的 Mesh 合并为一个 Draw Call
fn batch_by_material(meshes: &[Mesh]) -> Vec<Batch> {
    let mut batches: HashMap<MaterialId, Vec<&Mesh>> = HashMap::new();

    for mesh in meshes {
        batches.entry(mesh.material_id)
            .or_insert_with(Vec::new)
            .push(mesh);
    }

    batches.into_iter()
        .map(|(material_id, meshes)| {
            let merged = merge_meshes(&meshes);
            Batch { material_id, mesh: merged }
        })
        .collect()
}
```

### 排序策略

```rust
fn sort_for_rendering(entities: &mut [Entity]) {
    // 1. 不透明物体：前到后（减少 overdraw）
    // 2. 透明物体：后到前（正确的混合顺序）
    entities.sort_by(|a, b| {
        if a.is_transparent != b.is_transparent {
            return a.is_transparent.cmp(&b.is_transparent);
        }
        if a.is_transparent {
            // 透明：后到前
            b.distance_to_camera().partial_cmp(&a.distance_to_camera()).unwrap()
        } else {
            // 不透明：前到后
            a.distance_to_camera().partial_cmp(&b.distance_to_camera()).unwrap()
        }
    });
}
```

---

## 9. 渲染统计

```rust
pub struct RenderStats {
    pub draw_calls: u32,
    pub triangles: u32,
    pub vertices: u32,
    pub frame_time: Duration,
    pub gpu_time: Duration,
    pub fps: f32,
}

impl RenderStats {
    pub fn log(&self) {
        log::info!(
            "FPS: {:.1} | Draw Calls: {} | Triangles: {} | Frame: {:.1}ms | GPU: {:.1}ms",
            self.fps,
            self.draw_calls,
            self.triangles,
            self.frame_time.as_secs_f64() * 1000.0,
            self.gpu_time.as_secs_f64() * 1000.0,
        );
    }
}
```

---

## 性能目标

| 场景 | 目标帧率 | 三角形上限 | Draw Call 上限 |
|------|---------|-----------|---------------|
| 移动端 | 30 fps | 500K | 100 |
| 桌面端 | 60 fps | 5M | 500 |
| VR | 90 fps | 1M | 200 |
