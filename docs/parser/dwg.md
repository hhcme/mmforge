# DWG 解析器

> DWG (Drawing) 格式解析的详细设计。
>
> 最后更新：2026-06-29

---

## 概述

| 属性 | 值 |
|------|-----|
| 依赖 | LibreDWG (GPL v3) |
| 优先级 | P1 |
| 数据类型 | 2D 几何 |
| 特点 | Autodesk 私有格式，无官方规范，只能靠逆向工程 |

---

## DWG 格式挑战

DWG 是最大的坑：

- **没有官方文档** — 只能靠逆向工程
- **版本碎片化** — R14, 2000, 2004, 2007, 2010, 2013, 2018 内部结构各不同
- **二进制格式** — 不像 DXF 可以直接读文本
- **ODA 花了 20 年** — 才做到稳定支持

---

## 解析流程

```
DWG 文件
  │
  ▼
┌─────────────────────────────────────┐
│  LibreDWG 解析                      │
│  ├── 读取文件头，识别版本            │
│  ├── 解析对象表                     │
│  │   （图层、线型、样式等）           │
│  ├── 解析实体数据                   │
│  └── 输出 Dwg_Data 结构             │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  转换为 LSM                         │
│  ├── DWG_LINE → LSM::Line2D        │
│  ├── DWG_ARC → LSM::Arc2D          │
│  ├── DWG_CIRCLE → LSM::Circle2D    │
│  ├── DWG_TEXT → LSM::Text2D        │
│  └── ...                           │
└──────────────┬──────────────────────┘
               │
               ▼
          LSM Model (2D)
```

---

## LibreDWG FFI 绑定

```rust
extern "C" {
    fn dwg_read_file(filename: *const c_char, dwg: *mut Dwg_Data) -> c_int;
    fn dwg_free(dwg: *mut Dwg_Data);
}

pub fn parse_dwg(path: &Path) -> Result<LsmModel> {
    let c_path = CString::new(path.to_str().unwrap())?;
    let mut dwg = Dwg_Data::default();

    unsafe {
        let status = dwg_read_file(c_path.as_ptr(), &mut dwg);
        if status != 0 {
            return Err(Error::ParseFailed);
        }
    }

    let mut lsm = LsmModel::new();

    unsafe {
        for i in 0..dwg.num_object_refs {
            let obj = &*dwg.object_ref.add(i);
            match obj.type_ {
                DWG_TYPE_LINE => convert_line(obj, &mut lsm)?,
                DWG_TYPE_ARC => convert_arc(obj, &mut lsm)?,
                DWG_TYPE_CIRCLE => convert_circle(obj, &mut lsm)?,
                DWG_TYPE_TEXT => convert_text(obj, &mut lsm)?,
                _ => {} // 跳过不支持的实体
            }
        }
    }

    unsafe { dwg_free(&mut dwg); }
    Ok(lsm)
}
```

---

## 支持局限性

| 实体类型 | LibreDWG 支持 | 说明 |
|----------|--------------|------|
| LINE | ✅ | 完全支持 |
| ARC | ✅ | 完全支持 |
| CIRCLE | ✅ | 完全支持 |
| POLYLINE | ✅ | 基本支持 |
| TEXT | ✅ | 基本支持 |
| MTEXT | ⚠️ | 部分支持 |
| DIMENSION | ⚠️ | 部分支持 |
| HATCH | ⚠️ | 部分支持 |
| SPLINE | ⚠️ | 部分支持 |
| BLOCK | ⚠️ | 基本支持 |
| 动态块 | ❌ | 不支持 |
| OLE 对象 | ❌ | 不支持 |
| 自定义实体 | ❌ | 不支持 |

---

## DWG 版本差异

| 版本 | 标记 | 内部结构 | LibreDWG 支持 |
|------|------|---------|--------------|
| R14 | AC1014 | 老格式 | ✅ |
| 2000 | AC1015 | 对象字典 | ✅ |
| 2004 | AC1018 | 加密段 | ✅ |
| 2007 | AC1021 | 新文件头 | ✅ |
| 2010 | AC1024 | 扩展数据 | ✅ |
| 2013 | AC1027 | 对象关联 | ✅ |
| 2018 | AC1032 | 最新格式 | ⚠️ 部分 |

---

## 二进制解析算法

### 文件头解析

```
DWG 文件头 (前 128 字节):
  [0..6]    版本标记 "ACxxxx"
  [6..128]  填充数据 (XOR 加密)
```

```rust
fn detect_dwg_version(data: &[u8]) -> Option<DwgVersion> {
    if data.len() < 6 {
        return None;
    }

    let version_str = std::str::from_utf8(&data[0..6]).ok()?;
    match version_str {
        "AC1014" => Some(DwgVersion::R14),
        "AC1015" => Some(DwgVersion::R2000),
        "AC1018" => Some(DwgVersion::R2004),
        "AC1021" => Some(DwgVersion::R2007),
        "AC1024" => Some(DwgVersion::R2010),
        "AC1027" => Some(DwgVersion::R2013),
        "AC1032" => Some(DwgVersion::R2018),
        _ => None,
    }
}
```

### 实体数据解析

DWG 实体使用变长编码：

```
实体记录:
  [类型码]    变长编码
  [大小]      变长编码
  [句柄]      变长编码
  [属性数据]  根据类型解析
```

```rust
/// 变长编码解析
fn read_bit_long(data: &[u8], offset: &mut usize) -> i32 {
    let first_byte = data[*offset];
    *offset += 1;

    match first_byte {
        0..=0x0F => first_byte as i32,
        0x10..=0x1F => {
            let second = data[*offset] as i32;
            *offset += 1;
            ((first_byte as i32 - 0x10) << 8) | second
        }
        0x20..=0x2F => {
            let b1 = data[*offset] as i32;
            let b2 = data[*offset + 1] as i32;
            *offset += 2;
            ((first_byte as i32 - 0x20) << 16) | (b1 << 8) | b2
        }
        _ => {
            let b1 = data[*offset] as i32;
            let b2 = data[*offset + 1] as i32;
            let b3 = data[*offset + 2] as i32;
            *offset += 3;
            (b1 << 24) | (b2 << 16) | (b3 << 8) | data[*offset] as i32
        }
    }
}
```

---

## 实体转换算法

### LINE 转换

```rust
fn convert_line(obj: &Dwg_Object, lsm: &mut LsmModel) -> Result<()> {
    unsafe {
        let line = &*(obj as *const _ as *const Dwg_Entity_LINE);

        let start = [line.start.x, line.start.y];
        let end = [line.end.x, line.end.y];

        lsm.add_entity(Entity2D::Line { start, end });
    }
    Ok(())
}
```

### ARC 转换

```rust
fn convert_arc(obj: &Dwg_Object, lsm: &mut LsmModel) -> Result<()> {
    unsafe {
        let arc = &*(obj as *const _ as *const Dwg_Entity_ARC);

        lsm.add_entity(Entity2D::Arc {
            center: [arc.center.x, arc.center.y],
            radius: arc.radius,
            start_angle: arc.start_angle,
            end_angle: arc.end_angle,
        });
    }
    Ok(())
}
```

---

## 性能优化

### 延迟解析

```rust
/// 只解析需要的实体类型
fn parse_dwg_selective(
    path: &Path,
    wanted_types: &[u32],
) -> Result<LsmModel> {
    let dwg = load_dwg(path)?;

    let mut lsm = LsmModel::new();

    unsafe {
        for i in 0..dwg.num_object_refs {
            let obj = &*dwg.object_ref.add(i);

            // 只处理需要的类型
            if wanted_types.contains(&obj.type_) {
                convert_entity(obj, &mut lsm)?;
            }
        }
    }

    Ok(lsm)
}
```

### 内存管理

```rust
/// 流式解析：逐个处理实体，不全部加载
fn parse_dwg_streaming(path: &Path) -> Result<LsmModel> {
    // LibreDWG 会一次性加载整个文件
    // 对于超大文件，考虑分段读取

    let dwg = load_dwg(path)?;
    let mut lsm = LsmModel::new();

    // 逐个处理，处理完立即释放
    unsafe {
        for i in 0..dwg.num_object_refs {
            let obj = &*dwg.object_ref.add(i);
            convert_entity(obj, &mut lsm)?;

            // 每处理 1000 个实体，检查内存
            if i % 1000 == 0 {
                shrink_if_needed(&mut lsm);
            }
        }
    }

    Ok(lsm)
}
```

---

## 务实策略

- **先做 DXF**（开放格式，可控）
- **DWG 用 LibreDWG 能支持多少算多少**
- **不追求完美**，复杂图纸可能丢实体
- **提示用户**：如果 DWG 解析不完整，建议另存为 DXF

---

## 性能基准

| 文件大小 | 实体数量 | 解析时间 | 内存峰值 |
|---------|---------|---------|---------|
| < 1MB | < 1K | < 50ms | < 5MB |
| 1-10MB | 1K - 10K | 50ms - 500ms | 5 - 50MB |
| 10-100MB | 10K - 100K | 500ms - 5s | 50 - 500MB |
