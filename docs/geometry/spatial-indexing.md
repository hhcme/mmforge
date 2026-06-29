# 空间索引

> BVH/AABB 空间索引的设计，用于射线拾取和视锥裁剪。
>
> 最后更新：2026-06-29

---

## 概述

空间索引用于加速空间查询：
- **射线拾取** — 用户点击屏幕，找到被点击的模型部件
- **视锥裁剪** — 只渲染相机能看到的部分
- **碰撞检测** — 模型间的距离查询

---

## AABB (Axis-Aligned Bounding Box)

轴对齐包围盒，最简单的空间包围体：

```rust
pub struct Aabb {
    pub min: [f32; 3],
    pub max: [f32; 3],
}

impl Aabb {
    pub fn union(&self, other: &Aabb) -> Aabb {
        Aabb {
            min: [
                self.min[0].min(other.min[0]),
                self.min[1].min(other.min[1]),
                self.min[2].min(other.min[2]),
            ],
            max: [
                self.max[0].max(other.max[0]),
                self.max[1].max(other.max[1]),
                self.max[2].max(other.max[2]),
            ],
        }
    }

    pub fn intersects(&self, other: &Aabb) -> bool {
        self.min[0] <= other.max[0] && self.max[0] >= other.min[0]
            && self.min[1] <= other.max[1] && self.max[1] >= other.min[1]
            && self.min[2] <= other.max[2] && self.max[2] >= other.min[2]
    }

    pub fn contains_point(&self, point: [f32; 3]) -> bool {
        point[0] >= self.min[0] && point[0] <= self.max[0]
            && point[1] >= self.min[1] && point[1] <= self.max[1]
            && point[2] >= self.min[2] && point[2] <= self.max[2]
    }
}
```

---

## BVH (Bounding Volume Hierarchy)

层次包围盒，用于加速射线查询：

```
        Root (AABB)
       /          \
   Left (AABB)   Right (AABB)
   /     \        /     \
 Leaf   Leaf    Leaf   Leaf
(Triangles)    (Triangles)
```

### 数据结构

```rust
pub struct Bvh {
    nodes: Vec<BvhNode>,
}

enum BvhNode {
    Leaf {
        mesh_id: u32,
        triangle_ids: Vec<u32>,
        aabb: Aabb,
    },
    Internal {
        left: usize,
        right: usize,
        aabb: Aabb,
    },
}
```

### 构建算法

```
输入: 三角形列表
输出: BVH 树

算法:
1. 计算所有三角形的 AABB
2. 选择分割轴（最长轴）
3. 按中位数分割为左右两组
4. 递归构建左右子树
5. 直到叶子节点三角形数量 < 阈值
```

```rust
impl Bvh {
    pub fn build(mesh: &MeshGeometry) -> Self {
        let triangles = collect_triangles(mesh);
        let root = build_recursive(&triangles, 0);
        Bvh { nodes: vec![root] }
    }
}
```

### 射线查询

```
输入: 射线 Ray { origin, direction }
输出: 最近的交点 HitResult

算法:
1. 从根节点开始
2. 检查射线是否与当前节点 AABB 相交
3. 如果不相交，剪枝
4. 如果是叶子节点，逐三角形检测
5. 如果是内部节点，递归左右子树
6. 返回最近的交点
```

```rust
impl Bvh {
    pub fn ray_query(&self, ray: &Ray) -> Option<HitResult> {
        self.ray_query_recursive(0, ray, f32::MAX)
    }

    fn ray_query_recursive(&self, node_idx: usize, ray: &Ray, max_t: f32) -> Option<HitResult> {
        let node = &self.nodes[node_idx];

        // AABB 快速剔除
        if !ray_intersects_aabb(ray, &node.aabb(), max_t) {
            return None;
        }

        match node {
            BvhNode::Leaf { triangle_ids, .. } => {
                // 逐三角形检测
                let mut closest = None;
                for &tri_id in triangle_ids {
                    if let Some(hit) = ray_intersects_triangle(ray, tri_id) {
                        if hit.t < max_t {
                            closest = Some(hit);
                        }
                    }
                }
                closest
            }
            BvhNode::Internal { left, right, .. } => {
                let left_hit = self.ray_query_recursive(*left, ray, max_t);
                let right_hit = self.ray_query_recursive(*right, ray, max_t);
                closer_hit(left_hit, right_hit)
            }
        }
    }
}
```

---

## 视锥裁剪

```rust
pub struct Frustum {
    pub planes: [Plane; 6], // 6 个裁剪面
}

impl Frustum {
    pub fn intersects_aabb(&self, aabb: &Aabb) -> bool {
        for plane in &self.planes {
            // 找到 AABB 在法线方向最远的点
            let p_vertex = [
                if plane.normal[0] >= 0.0 { aabb.max[0] } else { aabb.min[0] },
                if plane.normal[1] >= 0.0 { aabb.max[1] } else { aabb.min[1] },
                if plane.normal[2] >= 0.0 { aabb.max[2] } else { aabb.min[2] },
            ];
            // 如果最远的点都在平面外侧，则 AABB 在视锥外
            if plane.distance_to(p_vertex) < 0.0 {
                return false;
            }
        }
        true
    }
}
```
