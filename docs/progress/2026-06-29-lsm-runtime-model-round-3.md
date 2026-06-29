# Phase 1 Goal 1 Round 3: LSM Runtime Model Cleanup

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: LSM model cleanup — duplicate child edges, remove_node semantics, has_validation_issues, MultipleRoots removal
Gate: ⛔ ARCHITECTURE GATE — LSM model round 3 — awaiting Codex review

---

## Summary

All four cleanup items from the review feedback are addressed:

1. **Duplicate child edge detection** — `validate_references()` now detects when a node's `children` list contains the same `NodeId` more than once, reporting `ValidationIssueKind::DuplicateChildEdge`.

2. **`remove_node` returns `Result<usize, RemoveError>`** — refuses to remove the sole root (returns `RemoveError::SoleRoot`) and rejects nonexistent ids (`RemoveError::NotFound`). Semantics are now explicit and tested.

3. **`has_validation_issues()` replaces `has_dangling_references()`** — the new method is the primary API. The old name is kept as a `#[deprecated]` alias for backward compatibility.

4. **`MultipleRoots` removed, `DuplicateChildEdge` added** — `MultipleRoots` was never implemented and its purpose is subsumed by `Orphan` detection. Replaced with `DuplicateChildEdge` which is actually used.

---

## Modified Files

| File | Change |
|------|--------|
| `crates/mmforge-core/src/model.rs` | Added `RemoveError` enum, changed `remove_node` to `Result`, added `DuplicateChildEdge` detection in `validate_references`, renamed `has_dangling_references` → `has_validation_issues` (old kept as deprecated), removed `MultipleRoots` from `ValidationIssueKind`, added 4 new tests |
| `crates/mmforge-core/src/lib.rs` | Added `RemoveError` to public exports |

---

## Architecture Decisions

1. **`remove_node` returns `Result<usize, RemoveError>`**: The sole-root case is a real programming error (emptying the tree), not a silent no-op. Returning `Err` forces callers to handle it explicitly. `RemoveError` uses `thiserror` for `Display`/`Error` impls.

2. **`has_dangling_references()` kept as deprecated alias**: Avoids breaking downstream code immediately. The `#[deprecated]` attribute produces a compiler warning at call sites.

3. **`DuplicateChildEdge` instead of `MultipleRoots`**: `MultipleRoots` was dead code — orphan detection already covers the case of nodes not reachable from root. `DuplicateChildEdge` catches a real structural bug that `validate_references` should detect.

4. **Duplicate child edge detection runs before dangling-child checks**: This ordering means a node with `[NodeId(1), NodeId(1)]` reports `DuplicateChildEdge` first, then only checks dangling/reciprocity once per unique child.

---

## Key Algorithms

### remove_node (updated)

```text
1. If id not in tree → Err(NotFound).
2. If tree has exactly 1 node and it's the root → Err(SoleRoot).
3. Collect descendants (HashSet-backed, cycle-safe).
4. Remove id from parent's children list.
5. Retain only nodes not in to_remove.
6. Update root if it was removed.
7. Ok(count_removed)
```

### Duplicate child edge detection

```text
For each node:
  seen = HashSet::new()
  for child_id in node.children:
    if !seen.insert(child_id):
      report DuplicateChildEdge
```

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 61 tests pass (55 core, 1 geometry, 5 render) |
| `cargo fmt` | ✅ Applied |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |

---

## New Tests

| Test | What it covers |
|------|---------------|
| `duplicate_child_edge_detected` | Node with `[NodeId(1), NodeId(1)]` in children |
| `has_validation_issues_reports_correctly` | New primary method works on valid and invalid models |
| `remove_sole_root_returns_err` | `remove_node` on the only node returns `Err(SoleRoot)` |
| `remove_nonexistent_returns_err` | `remove_node` on absent id returns `Err(NotFound)` |

---

## Deprecation Notice

```rust
#[deprecated(since = "0.1.0", note = "use `has_validation_issues()` instead")]
pub fn has_dangling_references(&self) -> bool
```

Callers should migrate to `has_validation_issues()`.

---

## ⛔ Architecture Gate — Pending Codex Review Round 3

| File | What to review |
|------|---------------|
| `crates/mmforge-core/src/model.rs` | `RemoveError` type, `remove_node` Result semantics, `DuplicateChildEdge` detection, deprecation strategy |

### Review questions:

1. Is `RemoveError::SoleRoot` the right error variant name and message?
2. Should `remove_node` allow removing the sole root if the caller explicitly wants an empty tree (e.g. `force: bool` parameter)?
3. Is the `#[deprecated]` approach for `has_dangling_references` appropriate, or should we just remove it?
4. Is `DuplicateChildEdge` the right variant name? Should it be `DuplicateChild` or `RepeatedChildEdge`?

---

## Next Target (after gate passes)

**Phase 1, Goal 2: OCCT Integration & STEP Parsing** — OCCT build/link, STEPControl_Reader wrapper, TopoDS_Shape safe handle.

---

## Sample Files / testfile Usage

None.

---

## New Dependencies And Licenses

None.
