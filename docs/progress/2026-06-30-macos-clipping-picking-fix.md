# Clipping-Aware Picking — Ray–Plane Intersection Fix

Date: 2026-06-30
Agent: ZCode (mimo-v2.5-pro)
Target: Fix pickNode to use ray–clipPlane intersection instead of
        crude AABB center check

---

## Problem

The previous `pickNode` checked if the mesh's AABB center was on the
negative side of the clip plane.  This was wrong because:

- A mesh whose center is clipped away might still have visible geometry
  (the center is on the wrong side but part of the AABB extends into
  the visible half-space)
- A mesh whose center is visible might have most of its geometry
  clipped away, making it a poor picking target

---

## Solution

### Ray–clipPlane intersection

Pre-compute the ray parameter `t_clip` where the ray crosses the
clip plane:

```
t_clip = -(dot(n, origin) + d) / dot(n, dir)
```

The visible half-space is `dot(n, P) + d >= 0`.  After computing
`t_clip`, the visible ray interval depends on the ray direction
relative to the plane normal:

- If `dot(n, dir) > 0`: ray crosses from clipped → visible at `t_clip`.
  Visible interval is `[max(t_clip, 0), ∞)`.
- If `dot(n, dir) < 0`: ray crosses from visible → clipped at `t_clip`.
  Visible interval is `[0, t_clip]`.
- If `dot(n, dir) ≈ 0`: ray is parallel.  Check origin side — if
  clipped, skip entirely.

### Ray–AABB intersection with clip

For each mesh:
1. Compute AABB intersection interval `[tmin, tmax]`
2. Intersect with clip half-space: visible interval is
   `[max(tmin, clipTMin), tmax]`
3. If `max(tmin, clipTMin) > tmax`, the mesh is fully clipped — skip
4. The first visible hit is at `max(tmin, clipTMin)`

This exactly matches the shader's clipping logic:
```metal
if (dot(clipPlane.xyz, worldPos) + clipPlane.w < 0) discard_fragment();
```

### Refactored `rayAABBIntersectRange`

Returns `(tmin, tmax)` tuple instead of a single `t` value.  This
enables the caller to intersect with the clip half-space interval.

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
| `macos/MMForge/Metal/MetalRenderer.swift` | `pickNode` with ray–plane intersection; `rayAABBIntersectRange` returns interval; `rayClipPlaneIntersect` helper |
