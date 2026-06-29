# 解析层性能设计

> MMForge 解析层的性能优化策略和大文件处理方案。
>
> 最后更新：2026-06-29

---

## 1. 性能瓶颈分析

| 瓶颈 | 原因 | 影响格式 |
|------|------|---------|
| 文件 I/O | 大文件（几百 MB）需要大量磁盘读取 | 所有格式 |
| 文本解析 | STEP/DXF 的文本解析是 CPU 密集型 | STEP, DXF, IGES |
| Entity 引用解析 | STEP 有百万级 entity，引用关系复杂 | STEP |
| B-Rep 构建 | 拓扑关系验证（壳是否封闭） | STEP, IGES |
| Tessellation | 曲面三角化是 CPU 密集型 | STEP, IGES |
| 内存分配 | 大量小对象分配导致碎片化 | 所有格式 |

---

## 2. 性能目标

| 指标 | 目标 | 说明 |
|------|------|------|
| 小文件 (< 1MB) | < 100ms | 立即响应 |
| 中等文件 (1-10MB) | < 1s | 用户可接受 |
| 大文件 (10-100MB) | < 10s | 需要进度条 |
| 超大文件 (> 100MB) | < 60s | 需要流式加载 |
| 内存占用 | < 3× 文件大小 | 峰值内存 |

---

## 3. 优化策略

### 3.1 内存映射 (mmap)

大文件使用内存映射，避免完整的内存复制：

```rust
use memmap2::Mmap;

fn parse_file_mmap(path: &Path) -> Result<LsmModel> {
    let file = File::open(path)?;
    let mmap = unsafe { Mmap::map(&file)? };

    // 直接在映射内存上解析，无需复制
    let parser = detect_format(&mmap)?;
    parser.parse(&mmap)
}
```

优势：
- 零拷贝：操作系统管理页面加载
- 大文件友好：不需要一次性读入内存
- 延迟加载：只在访问时加载页面

### 3.2 流式解析

不一次性加载全部数据，按需解析：

```rust
/// 流式 STEP 解析器
pub struct StepStreamParser<R: Read> {
    reader: BufReader<R>,
    buffer: String,
    entity_cache: HashMap<u32, StepEntity>,
}

impl<R: Read> StepStreamParser<R> {
    /// 逐个解析 entity，不全部加载
    pub fn next_entity(&mut self) -> Option<Result<StepEntity>> {
        loop {
            self.buffer.clear();
            match self.reader.read_line(&mut self.buffer) {
                Ok(0) => return None, // EOF
                Ok(_) => {
                    if let Some(entity) = self.try_parse_entity(&self.buffer) {
                        return Some(Ok(entity));
                    }
                    // 跳过非 entity 行
                }
                Err(e) => return Some(Err(e.into())),
            }
        }
    }
}
```

### 3.3 零拷贝解析

尽可能避免数据复制，使用引用而非克隆：

```rust
// ❌ 低效：复制字符串
fn parse_entity(line: String) -> StepEntity {
    let name = line.to_string(); // 复制
    StepEntity { name }
}

// ✅ 高效：引用原始数据
fn parse_entity<'a>(line: &'a str) -> StepEntity<'a> {
    let name = &line[..10]; // 切片引用，零拷贝
    StepEntity { name }
}
```

### 3.4 并行解析

利用多核 CPU 并行处理：

```rust
use rayon::prelude::*;

/// 并行 tessellation
fn parallel_tessellate(
    faces: &[Face],
    options: &TessellationOptions,
) -> Vec<TessellationResult> {
    faces.par_iter()  // 并行迭代
        .map(|face| tessellate_face(face, options))
        .collect()
}

/// 并行解析多个文件
fn parallel_parse(files: &[PathBuf]) -> Vec<Result<LsmModel>> {
    files.par_iter()
        .map(|path| parse_file(path))
        .collect()
}
```

### 3.5 预分配内存

避免动态扩容导致的内存碎片：

```rust
// ❌ 低效：动态扩容
let mut positions = Vec::new();
for i in 0..num_vertices {
    positions.push([x, y, z]); // 可能触发多次扩容
}

// ✅ 高效：预分配
let mut positions = Vec::with_capacity(num_vertices);
for i in 0..num_vertices {
    positions.push([x, y, z]); // 无扩容
}
```

### 3.6 对象池

复用临时对象，减少分配/释放开销：

```rust
pub struct ParsePool {
    buffers: Vec<Vec<u8>>,
    strings: Vec<String>,
}

impl ParsePool {
    pub fn get_buffer(&mut self) -> Vec<u8> {
        self.buffers.pop().unwrap_or_else(|| Vec::with_capacity(4096))
    }

    pub fn return_buffer(&mut self, mut buf: Vec<u8>) {
        buf.clear();
        self.buffers.push(buf);
    }
}
```

---

## 4. 大文件处理策略

### 4.1 分块加载

```
大文件 (500MB)
  │
  ▼
分块读取 (每次 1MB)
  │
  ▼
逐块解析
  │
  ▼
增量构建 LSM
  │
  ▼
渲染层按需加载
```

### 4.2 进度报告

```rust
pub trait ProgressCallback: Send + Sync {
    fn on_progress(&self, current: u64, total: u64);
    fn on_stage(&self, stage: &str);
}

fn parse_with_progress(
    path: &Path,
    progress: &dyn ProgressCallback,
) -> Result<LsmModel> {
    let file_size = fs::metadata(path)?.len();
    progress.on_stage("Reading file");

    let data = fs::read(path)?;
    progress.on_progress(file_size, file_size);

    progress.on_stage("Parsing geometry");
    let model = parse_data(&data, &progress)?;

    Ok(model)
}
```

### 4.3 取消支持

大文件解析支持用户取消：

```rust
pub struct CancellationToken {
    cancelled: AtomicBool,
}

impl CancellationToken {
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }
}

fn parse_with_cancel(
    data: &[u8],
    cancel: &CancellationToken,
) -> Result<LsmModel> {
    for entity in parse_entities(data) {
        if cancel.is_cancelled() {
            return Err(ParseError::Cancelled);
        }
        process_entity(entity)?;
    }
    Ok(model)
}
```

---

## 5. 基准测试

```rust
use criterion::{criterion_group, criterion_main, Criterion};

fn bench_parse_step(c: &mut Criterion) {
    let data = std::fs::read("tests/fixtures/step/simple_box.step").unwrap();

    c.bench_function("parse_step_simple", |b| {
        b.iter(|| parse_step(&data))
    });
}

fn bench_parse_step_large(c: &mut Criterion) {
    let data = std::fs::read("tests/fixtures/step/assembly.step").unwrap();

    c.bench_function("parse_step_large", |b| {
        b.iter(|| parse_step(&data))
    });
}

fn bench_tessellation(c: &mut Criterion) {
    let shape = load_test_shape("complex_surface.step");

    c.bench_function("tessellation_standard", |b| {
        b.iter(|| tessellate(&shape, &TessellationOptions::standard()))
    });

    c.bench_function("tessellation_low", |b| {
        b.iter(|| tessellate(&shape, &TessellationOptions::low()))
    });
}

criterion_group!(benches, bench_parse_step, bench_parse_step_large, bench_tessellation);
criterion_main!(benches);
```
