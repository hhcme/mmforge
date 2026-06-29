# Phase 1 Goal 1: LSM Runtime Model — Minimum Core

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Complete LSM runtime model with scene tree operations, reference validation, stats, and builder
Gate: ⛔ ARCHITECTURE GATE — LSM model — awaiting Codex review before proceeding

---

## Summary

The LSM runtime model is now complete for Phase 1 use. `mmforge-core` provides:

- **SceneTree** with `add_node`, `remove_node`, `find_node`, `find_node_mut`, `children_of`, `parent_of`, `depth`, `is_ancestor`, `descendants_of`, `ancestors_of`, `len`, `is_empty`
- **DescendantsIter / AncestorsIter** — lazy iterators for tree traversal
- **Geometry** helper methods: `id()`, `bounds()`, `triangle_count()`
- **LsmModel::validate_references()** — detects dangling `NodeId`, `GeometryId`, `MaterialId` references
- **LsmModel::stats()** — returns `ParseStats` from the model
- **ModelBuilder** — fluent builder for constructing test models
- **DanglingRef** — structured validation error type
- **38 unit tests** (23 new), all passing

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-core/src/model.rs` | Major rewrite: SceneTree operations, Geometry helpers, validate_references, stats, ModelBuilder, DanglingRef, 23 new tests |
| `crates/mmforge-core/src/lib.rs` | Added re-exports: `DanglingRef`, `LsmModel`, `ModelBuilder`, `ParseOutput`, `ParseStats`, `ParseWarning` |

---

## Architecture Decisions

1. **SceneTree uses flat Vec<Node> storage**: Nodes are stored in a contiguous vector. Each node carries `parent: Option<NodeId>` and `children: Vec<NodeId>`. This keeps iteration cache-friendly and avoids recursive Box<Node> structures.

2. **validate_references returns Vec<DanglingRef>, not Result**: Validation is a query, not an operation that fails. Callers decide whether to treat dangling refs as errors or warnings. `has_dangling_references()` provides a quick boolean check.

3. **DanglingRef is a structured type, not a String**: Each validation error carries `context` (which node/section) and `reference` (what's missing). This allows UI and CLI to format or filter errors programmatically.

4. **DescendantsIter uses a stack-based DFS**: Avoids recursion. Children are pushed in reverse order so depth-first traversal visits nodes in document order.

5. **ModelBuilder propagates geometry bounds to nodes**: When `add_child` is called with a `GeometryId`, the node's bounds are set from that geometry's bounds. This ensures `LsmModel::bounds()` works correctly for built models.

6. **remove_node collects descendants before removing**: The borrow checker requires collecting descendant IDs into a Vec before mutating `self.nodes`. This is a deliberate trade-off for safety.

7. **ParseStats derives PartialEq, Eq**: Enables test assertions like `assert_eq!(model.stats(), expected_stats)`.

---

## Key Algorithms

### validate_references

```text
1. Collect all known GeometryId, MaterialId, NodeId into HashSets.
2. If scene is non-empty and root not in known_nodes → error.
3. For each node:
   a. If parent not in known_nodes → error.
   b. For each child not in known_nodes → error.
   c. If geometry not in known_geometry → error.
   d. If material not in known_material → error.
4. Return Vec<DanglingRef>.
```

### descendants_of (DFS)

```text
1. Push start node onto stack.
2. Pop → push children in reverse → yield node.
3. Repeat until stack empty.
```

### depth

```text
1. Walk parent chain from node to root.
2. Count hops.
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 38 tests pass (15 old + 23 new) |
| `cargo fmt` | ✅ Applied |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |

---

## Checks Not Run

| Check | Reason |
|-------|--------|
| `xcodebuild` | No macOS changes this goal |
| `cargo audit` | Not installed |

---

## Known Issues

None. All tests pass, no clippy warnings.

---

## Test Coverage

| Area | Tests | Status |
|------|-------|--------|
| Empty model creation | 1 | ✅ |
| SceneTree find/add/remove | 4 | ✅ |
| Children/parent/depth | 5 | ✅ |
| Ancestors/descendants iterators | 3 | ✅ |
| is_ancestor | 2 | ✅ |
| Deep tree traversal | 1 | ✅ |
| Multi-child traversal | 1 | ✅ |
| Geometry helpers | 2 | ✅ |
| validate_references (valid) | 1 | ✅ |
| validate_references (dangling geometry) | 1 | ✅ |
| validate_references (dangling material) | 1 | ✅ |
| validate_references (dangling parent) | 1 | ✅ |
| validate_references (dangling child) | 1 | ✅ |
| validate_references (dangling root) | 1 | ✅ |
| ModelBuilder | 1 | ✅ |
| stats | 1 | ✅ |
| Triangle count / bounds | 2 | ✅ |

---

## ⛔ Architecture Gate — Pending Codex Review

This goal completes the LSM runtime model, which is a core architecture gate. The following should be reviewed before proceeding:

| File | What to review |
|------|---------------|
| `crates/mmforge-core/src/model.rs` | Full model contract: SceneTree ops, validate_references, ModelBuilder, iterators |
| `crates/mmforge-core/src/lib.rs` | Public API surface re-exports |

### Review questions for Codex:

1. Is `validate_references()` signature and return type appropriate? Should it return `Result` instead of `Vec<DanglingRef>`?
2. Is the flat `Vec<Node>` storage the right trade-off vs. arena/slotmap?
3. Should `remove_node` be the primary removal API, or should we also support `detach_node` (remove from parent but keep in tree)?
4. Is the `ModelBuilder` API surface sufficient for Phase 1 parser tests?
5. Are the iterator types (`DescendantsIter`, `AncestorsIter`) correctly borrowing?
6. Should `Geometry::Drawing2D` return `GeometryId::ZERO` from `id()` or should it carry its own id?

---

## Next Target Recommendation

**Phase 1, Goal 2: OCCT Integration & STEP Parsing** — but only after this LSM model gate passes review.

---

## Sample Files / testfile Usage

None.

---

## New Dependencies And Licenses

None.
