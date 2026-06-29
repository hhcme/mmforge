# 几何层总览

> MMForge 几何处理层负责 OCCT 绑定、B-Rep 数据管理和几何运算。

---

## 职责

- OCCT FFI 绑定与安全封装
- B-Rep 数据结构管理
- Tessellation（三角化）
- 空间索引（BVH/AABB）
- 几何运算（v2.0+：求交、偏移、布尔运算）

## 模块文档

| 文档 | 内容 |
|------|------|
| [occt-binding.md](occt-binding.md) | OCCT FFI 绑定、编译选项、安全封装 |
| [brep.md](brep.md) | B-Rep 数据结构、拓扑遍历算法 |
| [curves-surfaces.md](curves-surfaces.md) | 曲线曲面类型、参数化表示、几何算法 |
| [spatial-indexing.md](spatial-indexing.md) | BVH/AABB 空间索引、射线拾取、视锥裁剪 |

## 依赖关系

```
mmforge-geometry
    └── OCCT (LGPL 2.1)
        ├── TKernel
        ├── TKMath
        ├── TKG3d
        ├── TKGeomBase
        ├── TKBRep
        ├── TKTopAlgo
        ├── TKMesh
        ├── TKXSBase
        ├── TKSTEP
        └── TKIGES
```
