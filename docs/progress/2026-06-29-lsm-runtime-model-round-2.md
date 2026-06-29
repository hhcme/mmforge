# Phase 1 Goal 1 Round 2: LSM Runtime Model Hardening

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Harden LSM model — duplicate IDs, reciprocity, orphans, cycles, Drawing2D fix, bounds rule
Gate: ⛔ ARCHITECTURE GATE — LSM model round 2 — awaiting Codex review

---

## Summary

All issues raised in the architecture gate review are addressed:

1. **Duplicate ID detection** — `validate_references()` now checks for duplicate `NodeId`, `GeometryId`, and `MaterialId`.
2. **Parent/children reciprocity** — validates that if A.parent=B then B.children contains A, and vice-versa.
3. **Orphan nodes** — detects nodes not reachable from the scene root via BFS.
4. **Cycle detection** — parent-chain walk detects revisited nodes; reports `Cycle` issues.
5. **Cycle-safe traversal** — `depth`, `is_ancestor`, `ancestors_of`, `descendants_of` all use `HashSet` visitation tracking; stop on revisited node. `MAX_WALK_DEPTH = 10_000` hard cap.
6. **`Geometry::Drawing2D`** — now carries its own `id: GeometryId` and `bounds: BoundingBox`. No more `GeometryId::ZERO` sentinel.
7. **`bounds()` rule documented** — `LsmModel::bounds()` uses node-level bounds (not geometry-level). Parsers MUST propagate geometry bounds to nodes.
8. **`ValidationIssue` / `ValidationIssueKind`** — structured validation result with kind, context, and detail fields. `DanglingRef` is a backward-compatible alias.
9. **13 new tests** (51 total in mmforge-core, 57 workspace).

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-core/src/model.rs` | Major hardening: duplicate ID detection, parent/children reciprocity, orphan detection, cycle detection, `MAX_WALK_DEPTH`, `HashSet`-based visitation in all traversal functions, `Geometry::Drawing2D` carries own id+bounds, `ValidationIssue`/`ValidationIssueKind`, 13 new tests |
| `crates/mmforge-core/src/lib.rs` | Added exports: `ValidationIssue`, `ValidationIssueKind` |

---

## Architecture Decisions

1. **`ValidationIssue` replaces `DanglingRef`**: The old `DanglingRef` type only expressed "missing reference". The new `ValidationIssue` carries a `kind: ValidationIssueKind` discriminant (`DanglingRef`, `DuplicateId`, `ParentChildInconsistent`, `Orphan`, `Cycle`, `MultipleRoots`), `context` (which entity), and `detail` (what's wrong). `DanglingRef` is kept as a type alias for backward compatibility.

2. **`Geometry::Drawing2D` carries its own id**: Previously returned `GeometryId::ZERO` which violates the contract that every geometry has a real, unique id. Now `Drawing2D { id, bounds }` — no sentinels.

3. **`bounds()` uses node-level bounds**: The doc comment explicitly states: parsers MUST set `node.bounds` from geometry bounds (or union of children bounds for group nodes). `LsmModel::bounds()` iterates nodes, not geometries. This keeps the rendering path simple.

4. **`MAX_WALK_DEPTH = 10_000`**: Hard cap on parent-chain walks in `depth` and `is_ancestor`. Valid industrial models never exceed this. Prevents infinite loops even without cycle detection (belt-and-suspenders).

5. **`DescendantsIter` and `AncestorsIter` track visited nodes**: Both iterators maintain a `HashSet<NodeId>`. Already-visited nodes are skipped. This prevents yielding duplicates on trees with children-cycle bugs.

6. **Orphan detection via BFS from root**: `reachable_from_root()` does a BFS through child links starting from `self.scene.root`. Any node not in the reachable set is reported as `Orphan`.

---

## Key Algorithms

### validate_references (complete checklist)

```text
1. Check duplicate NodeId, GeometryId, MaterialId.
2. Check root exists in nodes list.
3. For each node:
   a. Dangling parent → DanglingRef.
   b. Parent reciprocity: parent must list this node as child → ParentChildInconsistent.
   c. Dangling children → DanglingRef.
   d. Child reciprocity: child's parent must be this node → ParentChildInconsistent.
   e. Dangling geometry → DanglingRef.
   f. Dangling material → DanglingRef.
   g. Cycle in parent chain (walk up, track visited) → Cycle.
4. BFS from root → unreachable nodes → Orphan.
```

### Cycle-safe depth

```text
visited = {start_id}
current = start_id
while current has parent:
    if parent in visited → break (cycle)
    visited.insert(parent)
    current = parent
    depth += 1
    if depth >= MAX_WALK_DEPTH → break
return depth
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 57 tests pass (51 core, 1 geometry, 5 render) |
| `cargo fmt` | ✅ Applied |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |

---

## Test Coverage (new tests in bold)

| Area | Tests |
|------|-------|
| **Duplicate NodeId detected** | **✅** |
| **Duplicate GeometryId detected** | **✅** |
| **Duplicate MaterialId detected** | **✅** |
| **Parent not listing child detected** | **✅** |
| **Child with wrong parent detected** | **✅** |
| **Orphan node detected** | **✅** |
| **Parent cycle detected** | **✅** |
| **depth on cyclic tree terminates** | **✅** |
| **is_ancestor on cyclic tree terminates** | **✅** |
| **ancestors_of on cyclic tree terminates** | **✅** |
| **descendants_of on cyclic children terminates** | **✅** |
| **Geometry::Drawing2D has own id** | **✅** |
| **bounds uses node bounds** | **✅** |

---

## ⛔ Architecture Gate — Pending Codex Review Round 2

| File | What to review |
|------|---------------|
| `crates/mmforge-core/src/model.rs` | All hardening: ValidationIssue, cycle safety, orphan detection, Drawing2D fix, bounds rule |

### Review questions:

1. Is `ValidationIssueKind::MultipleRoots` needed? Current impl reports `Orphan` for unreachable nodes, which subsumes the multi-root case.
2. Is `MAX_WALK_DEPTH = 10_000` the right constant?
3. Should `validate_references()` be called automatically by parsers, or left to callers?
4. Is `reachable_from_root()` the right orphan-detection strategy, or should we also walk parent links upward from each node?
5. Is the `bounds()` contract (node-level, not geometry-level) clearly enough documented?

---

## Next Target (after gate passes)

**Phase 1, Goal 2: OCCT Integration & STEP Parsing** — OCCT build/link, STEPControl_Reader wrapper, TopoDS_Shape safe handle, basic STEP AP203/AP214 parsing.

---

## Sample Files / testfile Usage

None.

---

## New Dependencies And Licenses

None.
