# Clipping-Aware Picking — Full Interval Intersection

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix pickNode to compute complete [clipTMin, clipTMax] visible
        interval, matching shader's discard_fragment() logic exactly

---

## Problem

The previous implementation only tracked `clipTMin` and didn't properly
handle `denom < 0` (ray crossing from visible → clipped).  When the
ray origin was on the clipped side with `denom < 0`, the code returned
nil even if part of the ray was visible.

---

## Solution

### Ray–clipPlane visible interval

The clip plane defines a half-space: `dot(n, P) + d >= 0` is visible.

For a ray `P = O + t*D`, the signed distance is linear in t:
```
dist(t) = (dot(n,O) + d) + t * dot(n,D)
```

The visible interval depends on `denom = dot(n, D)`:

| denom | Origin side | Visible interval |
|-------|-------------|-----------------|
| > 0 | clipped | `[tClip, ∞)` — ray enters visible at tClip |
| > 0 | visible | `[0, ∞)` — entire ray visible |
| < 0 | visible | `[0, tClip]` — ray exits visible at tClip |
| < 0 | clipped | empty — entire ray clipped, return nil |
| ≈ 0 | visible | `[0, ∞)` — parallel, visible |
| ≈ 0 | clipped | empty — parallel, clipped, return nil |

### Implementation

```swift
var clipTMin: Float = 0
var clipTMax: Float = .infinity

if abs(denom) < 1e-12 {
    // Parallel: check origin side
    if originDist < 0 { return nil }
} else {
    let tClip = -originDist / denom
    if denom > 0 {
        clipTMin = max(tClip, 0)  // enters visible at tClip
    } else {
        clipTMax = tClip           // exits visible at tClip
        if clipTMax < 0 { return nil }  // origin already clipped
    }
}
```

### AABB intersection with clip interval

For each mesh, compute AABB `[tmin, tmax]` then intersect:
```
visible = [max(tmin, clipTMin), min(tmax, clipTMax)]
```
If `visibleMin > visibleMax`, the mesh is fully clipped.

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
| `macos/MMForge/Metal/MetalRenderer.swift` | `pickNode` with full `[clipTMin, clipTMax]` interval; `denom < 0` exit-side handling |
