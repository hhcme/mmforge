# Phase 0 Cleanup

Date: 2026-06-29
Agent: ZCode (mimo-v2.5-pro)
Target: Phase 0 cleanup — repository metadata, READMEs, crate READMEs, macOS UTType documentation

---

## Summary

Phase 0 cleanup is complete. All repository metadata is corrected, READMEs reflect the actual Phase 0 status with build/test commands, each crate has a README explaining its role, and the macOS document type `public.data` usage is documented with explicit Phase 1 UTType replacement notes.

---

## Modified Files

| File | Change |
|------|--------|
| `Cargo.toml` | Repository URL changed from `https://github.com/user/mmforge` to `https://github.com/hhcme/mmforge` |
| `crates/mmforge-core/Cargo.toml` | Added `repository.workspace = true` |
| `crates/mmforge-geometry/Cargo.toml` | Added `repository.workspace = true` |
| `crates/mmforge-render/Cargo.toml` | Added `repository.workspace = true` |
| `crates/mmforge-cli/Cargo.toml` | Added `repository.workspace = true` |
| `README.md` | Updated status badge to "Phase 0 complete — Phase 1 in progress"; updated status text; updated project structure to reflect actual crates; added "Getting Started" section with Rust and macOS build/test commands |
| `README_zh.md` | Same updates as English README: status badge, status text, project structure, "快速开始" section |
| `crates/mmforge-core/README.md` | **New** — describes modules, role, usage example |
| `crates/mmforge-geometry/README.md` | **New** — describes current Phase 0 state and Phase 1+ plans |
| `crates/mmforge-render/README.md` | **New** — describes RenderPacket design and camera module |
| `crates/mmforge-cli/README.md` | **New** — lists current and planned commands |
| `macos/MMForge/Document/MMForgeDocument.swift` | Added detailed TODO comment explaining that `public.data` is a Phase 0 placeholder and listing the specific UTTypes to use in Phase 1 (STEP, glTF, STL, DXF) with Info.plist registration notes |

---

## Architecture Decisions

1. **`repository.workspace = true` on all crates**: Each crate now inherits the workspace repository URL. This ensures `cargo publish` and crates.io metadata point to the correct GitHub repo.

2. **UTType `public.data` kept with documentation**: The broad `public.data` type is retained for Phase 0 since format detection is not yet implemented. The TODO comment in `MMForgeDocument.swift` explicitly lists the Phase 1 target UTTypes (`com.mmforge.step`, `com.mmforge.gltf`, `com.mmforge.stl`, `com.mmforge.dxf`) and notes that `Info.plist` needs `UTImportedTypeDeclarations`.

3. **READMEs serve as onboarding docs**: Each crate README explains the crate's role, current modules, and design rationale. This helps new contributors understand the dependency graph without reading all source files.

---

## Key Algorithms

No algorithm changes in this cleanup. Purely documentation and metadata.

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo test --workspace` | ✅ 21 tests pass |
| `cargo fmt --check` | ✅ No diffs |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo run --bin mmforge -- version` | ✅ Outputs `mmforge 0.1.0` |
| `xcodebuild build ... MMForge` | ✅ BUILD SUCCEEDED |

---

## Checks Not Run

| Check | Reason |
|-------|--------|
| `cargo audit` | Not installed; planned for CI integration |
| `cargo package --list` | Not publishing to crates.io yet; deferred |

---

## Known Issues

None. All cleanup items completed without issues.

---

## Next Target Recommendation

**Phase 1, Goal 1: LSM Runtime Model — Minimum Core**

The foundation is solid. Next concrete step is implementing the full LSM model with:
- Complete scene tree traversal (`children`, `parent`, `find_node`)
- `validate_references()` — detect dangling `NodeId`/`GeometryId`/`MaterialId` references
- Model stats traversal (node count, geometry count, triangle count, bounds)
- `ModelBuilder` helper for tests and CLI
- Comprehensive unit tests covering the model contract

---

## Review Focus For Codex

| File | What to check |
|------|---------------|
| `Cargo.toml` | Correct `repository` URL |
| `crates/*/Cargo.toml` | `repository.workspace = true` present |
| `README.md` / `README_zh.md` | Build commands accurate, status text correct |
| `crates/*/README.md` | Role descriptions match actual code |
| `macos/MMForge/Document/MMForgeDocument.swift` | UTType TODO comment is actionable |

---

## Sample Files / testfile Usage

None.

---

## New Dependencies And Licenses

None. This cleanup introduced no new dependencies.
