# macOS Alpha Trialability: HIG Polish, Test-Only Interface Cleanup, Smoke Checklist

**Date**: 2026-07-05
**Agent**: Opencode (deepseek-v4-pro)
**Scope**: Productionize macOS alpha for external trialability:
           clean test-only interfaces from production code, fix empty/error
           states per Apple HIG, add manual smoke-test checklist.

---

## 1. Changes

### 1.1 Test-Only Interface Cleanup (`MetalRenderer`)

Two interfaces were added solely for unit testing but leaked into all build configurations:

| Interface | Before | After |
|-----------|--------|-------|
| `getGPUMeshes() -> [GPUMesh]` | Public method on all builds | Wrapped in `#if DEBUG` |
| `frustumSkipCount: Int` | `private(set)` on all builds | `#if DEBUG` only; increment + reset also guarded |

Tests (`@testable import MMForge`) continue to pass under DEBUG configuration. Release builds exclude these symbols entirely.

### 1.2 Empty State HIG Fix (`EmptyStateView`)

**Before:** "Open a STEP file to begin." — only mentions STEP.

**After:**
- "Drag and drop or use ⌘O to open a file."
- "Supported: STEP, STL, glTF/GLB, IGES, DXF"
- Accessibility label lists all formats

This matches the macOS HIG requirement: "document-based workflow follows macOS file-open, drag-and-drop conventions."

### 1.3 Error State HIG Fix (`ErrorStateView`)

**Before:** Generic "Error" title with raw message.

**After:**
- Title: "Unable to Open File" (actionable, not just "Error")
- Body: Original error message
- Hint: "Try opening a different file or check the file format."
- Icon: `exclamationmark.triangle.fill` (filled, more visible)

### 1.4 Manual Smoke Test Checklist

Created `docs/progress/2026-07-05-macos-smoke-checklist.md` with 11 sections covering:
1. File Opening (STEP/STL/glTF/GLB/IGES/DXF + unsupported + empty)
2. Loading State (progress bar, cancel, format title, responsiveness)
3. Structure Tree (expand/collapse, selection, visibility, context menu, search, assembly, DFS order)
4. View Modes (solid, wireframe, solid+wire, transparent, persistence)
5. Selection & Visibility (click highlight, show all, hide, isolate)
6. Camera Controls (orbit, pan, zoom, fit, named views, ortho/persp)
7. Measurement (toggle, point-to-point, clear)
8. Clipping Plane (enable, axis, distance, section fill)
9. Export (image, PDF, 2D vector, 3D raster)
10. Error Handling (corrupt file, cancel, double-open, export error)
11. macOS HIG (Dark Mode, VoiceOver, keyboard nav, toolbar labels, drag-drop, shortcuts)

Total: **45 individual checks** across 11 categories.

---

## 2. Modified Files

| File | Change |
|------|--------|
| `macos/MMForge/Metal/MetalRenderer.swift` | Wrapped `getGPUMeshes()`, `frustumSkipCount`, skip increment, and reset in `#if DEBUG`. |
| `macos/MMForge/Views/ViewportContainer.swift` | `EmptyStateView`: shows all supported formats, drag-drop hint, accessibility. `ErrorStateView`: actionable title, "try another file" hint, filled icon. |
| `docs/progress/2026-07-05-macos-smoke-checklist.md` | **New**: 45-check manual smoke test for alpha trialability. |

---

## 3. Verified Results

| Command | Result |
|---------|--------|
| `xcodebuild -scheme MMForge -configuration Debug test` | **129 tests pass, 0 failures** |
| `cargo test --workspace` | **336 tests pass** |
| `cargo clippy --workspace -- -D warnings` | **0 warnings** |
| `cargo fmt --all --check` | **Clean** |
| `git diff --check` | **Clean** |

---

## 4. macOS HIG Compliance Summary

Based on development plan §1.4 and `docs/client/macos.md`:

| Requirement | Status | Notes |
|-------------|--------|-------|
| Document-based app (Cmd+O, recent files, drag-drop) | OK | `DocumentGroup` + `UTType` declarations for all formats |
| Toolbar with icon+label+tooltip | OK | Fit, Home, View, Render Mode, Measure, Clip, Export, Sidebar, Inspector |
| Sidebar for navigation | OK | Structure tree with search, expand/collapse, visibility |
| Inspector for properties | OK | Properties, Measure, Settings, Layers tabs with DisclosureGroup |
| Dark Mode | OK | Uses system colors, no hardcoded colors |
| VoiceOver accessibility | OK | All controls have `accessibilityLabel`/`accessibilityHint` |
| Long tasks: progress + cancel | OK | `LoadingStateView` with stage, percentage, cancel button + C token |
| Destructive ops: confirm/undo | Partial | Visibility hide allows show-all recovery; no native undo stack |
| Keyboard navigation | OK | Standard shortcuts + custom ⌘F/⌘K/⌘M/⌘⇧P |
| Empty state | OK | Shows supported formats + drag-drop hint |
| Error state | OK | Actionable title, file-format hint |

---

## 5. Next Steps

1. **Run the smoke checklist** (`docs/progress/2026-07-05-macos-smoke-checklist.md`) against real sample files and record results.
2. **Add native undo stack** for visibility/color operations (using SwiftUI `UndoManager`).
3. **Status bar** per `docs/client/macos.md` design: show fps, triangle count, coordinates, units.
4. **Performance profiling** with large STEP/STL files (>100MB) to tune streaming thresholds.
5. **Signing & notarization** for external distribution.
