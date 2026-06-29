# 解析层总览

> MMForge 解析层负责将各种工业格式文件转换为统一的 LSM 运行时模型。

---

## 职责

- 识别文件格式
- 解析各格式的内部结构
- 转换为 LSM 统一运行时模型
- B-Rep 曲面三角化（Tessellation）

## 数据流

```
源文件 → 格式识别 → 格式解析 → LSM 转换 → 输出
```

## 模块文档

| 文档 | 内容 |
|------|------|
| [architecture.md](architecture.md) | 解析器接口设计、格式识别算法、crate 结构 |
| [step.md](step.md) | STEP 解析器详细设计 |
| [iges.md](iges.md) | IGES 解析器详细设计 |
| [gltf.md](gltf.md) | glTF 解析器详细设计 |
| [stl.md](stl.md) | STL 解析器详细设计 |
| [dxf.md](dxf.md) | DXF 解析器详细设计 |
| [dwg.md](dwg.md) | DWG 解析器详细设计 |
| [tessellation.md](tessellation.md) | 三角化算法 |
| [error-handling.md](error-handling.md) | 错误处理与测试策略 |

## 依赖关系

```
mmforge-core (FormatParser trait, LSM 运行时模型)
    │
    ├── mmforge-format-step  → OCCT
    ├── mmforge-format-iges  → OCCT
    ├── mmforge-format-gltf  → gltf-rs
    ├── mmforge-format-stl   → 自研
    ├── mmforge-format-dxf   → 自研
    └── mmforge-format-dwg   → LibreDWG
```
