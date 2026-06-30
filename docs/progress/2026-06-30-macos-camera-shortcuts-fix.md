# Camera Shortcuts Fix — Remove Global Key Monitor, Fix HIG Conflicts

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Remove global key monitor that swallowed F/H/I/P unconditionally;
        fix Cmd+H and Cmd+P shortcut conflicts with macOS system

---

## Problem

1. **Global key monitor** (`NSEvent.addLocalMonitorForEvents(matching: .keyDown)`)
   intercepted F/H/I/P keys unconditionally — even when typing in
   text fields, search bars, or other system controls.

2. **Cmd+H** assigned to "Home (Reset Camera)" — conflicts with
   macOS system "Hide Application" shortcut.

3. **Cmd+P** assigned to "Toggle Projection" — conflicts with
   macOS system "Print" shortcut.

---

## Solution

### 1. Removed global key monitor entirely

The `keyMonitor` in `ViewportContainer.Coordinator` was removed.
Keyboard shortcuts are now handled exclusively through SwiftUI's
`.keyboardShortcut()` on menu buttons, which respect focus state
and don't interfere with text input.

The **scroll wheel monitor** is retained — it's already scoped to
MTKView via `hitTest` and only fires when the pointer is over the
viewport.

### 2. Fixed shortcut conflicts

| Before | After | Reason |
|--------|-------|--------|
| Cmd+H = Reset Camera | (no shortcut) | Conflicts with macOS Hide Application |
| Cmd+P = Toggle Projection | Cmd+Shift+P | Conflicts with macOS Print |
| Cmd+F = Fit to View | Cmd+F (kept) | No conflict |

### 3. Camera menu shortcut policy (Apple HIG)

| Action | Shortcut | Notes |
|--------|----------|-------|
| Fit to View | Cmd+F | Consistent with toolbar button |
| Reset Camera | (none) | Avoids Cmd+H conflict |
| Front/Back/Left/Right/Top/Bottom/Isometric | (none) | Accessible via menu only |
| Toggle Perspective/Orthographic | Cmd+Shift+P | Avoids Cmd+P (Print) conflict |

Individual view presets have no shortcuts — they're in a dropdown
menu and rarely need keyboard access.

---

## Commands Run

| Command | Result |
|---------|--------|
| `cargo fmt --check` | ✅ Clean |
| `cargo clippy --workspace -- -D warnings` | ✅ No warnings |
| `cargo clippy --workspace --features occt -- -D warnings` | ✅ No warnings |
| `cargo test --workspace --features occt` (real OCCT) | ✅ 86 tests pass |
| `xcodebuild -scheme MMForge build` | ✅ BUILD SUCCEEDED |

---

## Files Modified

| File | Change |
|------|--------|
| `macos/MMForge/Views/ViewportContainer.swift` | Removed `keyMonitor`; kept scroll monitor only |
| `macos/MMForge/App/MMForgeApp.swift` | Removed Cmd+H; changed Cmd+P → Cmd+Shift+P; added HIG policy comment |
