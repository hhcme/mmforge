# perf-baseline GEOMETRY_VERDICT Semantics Fix — 2026-07-09

**Date**: 2026-07-09
**Agent**: ZCode (deepseek-v4-pro)
**Status**: COMPLETE

---

## 1. Summary

This batch fixes non-interactive verification GEOMETRY_VERDICT output
issues discovered during review of the `perf-baseline.sh` script:

- **Bug**: `GEOMETRY_VERDICT` defaulted to `"PASS"` but was never updated
  to `"FAIL"` or `"PLACEHOLDER"` on ERROR/PLACEHOLDER paths. The script
  would exit 1 or 2 while still printing `GEOMETRY_VERDICT: PASS`.
- **Fix**: ERROR (non-advisory) → `GEOMETRY_VERDICT: FAIL`; PLACEHOLDER →
  `GEOMETRY_VERDICT: PLACEHOLDER`; only all-clean → `PASS`.
- **Gating test extension**: `test-preflight-geometry-gating.sh` now
  verifies both exit codes and GEOMETRY_VERDICT strings for all 10 scenarios.
- **Doc cleanup**: Removed outdated "v2 cumulative", "(0/1/2)",
  "v2 with review fixes" references from the 2026-07-08 progress report.

---

## 2. Contract (Corrected)

| State | Exit Code | GEOMETRY_VERDICT | When |
|-------|:---------:|------------------|------|
| All REAL-GEOMETRY or 2D-ONLY | 0 | `PASS` | No ERROR, no PLACEHOLDER |
| Hard ERROR (any format) | 1 | `FAIL` | Non-OCCT ERROR or advisory-off OCCT ERROR |
| PLACEHOLDER (empty model) | 2 | `PLACEHOLDER` | Any format with geoms==0 |
| STEP/IGES no-OCCT advisory | 3 | `ADVISORY` | Only when `MMFORGE_NO_OCCT_ADVISORY=1` AND errors are exclusively STEP/IGES |

Advisory rules (unchanged):
- Only STEP/IGES no-OCCT errors are downgradable
- STL, glTF, DXF ERROR always → exit 1 (FAIL)
- Any PLACEHOLDER always → exit 2 (PLACEHOLDER)
- Without `MMFORGE_NO_OCCT_ADVISORY=1`, any ERROR → exit 1 (FAIL)

---

## 3. Changes

### 3.1 `docs/scripts/perf-baseline.sh` (+7/−3 lines)

- `GEOMETRY_VERDICT="FAIL"` on non-advisory ERROR path (was missing)
- `GEOMETRY_VERDICT="PLACEHOLDER"` on PLACEHOLDER path (was missing)
- Exit code header updated: exit 2 labeled `PLACEHOLDER` (not `FAIL`)

### 3.2 `macos/scripts/test-preflight-geometry-gating.sh` (+28/−19 lines)

- `simulate_perf_verdict` now echoes GEOMETRY_VERDICT string to stdout
  before returning exit code
- `assert_verdict` accepts optional 5th argument (`expect_verdict`) and
  fails if the verdict string doesn't match
- All 10 test scenarios now assert both exit code and verdict:
  - Scenario 1: default STEP/IGES ERROR → rc=1, verdict=FAIL
  - Scenario 2: advisory STEP/IGES ERROR → rc=3, verdict=ADVISORY
  - Scenario 3: advisory IGES-only ERROR → rc=3, verdict=ADVISORY
  - Scenario 4: advisory + STL ERROR → rc=1, verdict=FAIL
  - Scenario 5: advisory + DXF ERROR → rc=1, verdict=FAIL
  - Scenario 6: advisory + PLACEHOLDER → rc=2, verdict=PLACEHOLDER
  - Scenario 7: PLACEHOLDER no advisory → rc=2, verdict=PLACEHOLDER
  - Scenario 8: all clean → rc=0, verdict=PASS
  - Scenario 9: advisory + glTF ERROR → rc=1, verdict=FAIL
  - Scenario 10: no advisory, all clean → rc=0, verdict=PASS

### 3.3 `docs/progress/2026-07-08-macos-noninteractive-verification-hardening.md` (+3/−3 lines)

- "Files Changed (v2 cumulative)" → "Files Changed"
- "Exit codes (0/1/2)" → "Exit codes (0/1/2/3)"
- "This report (v2 with review fixes)" → "This report"

---

## 4. Verification Results

| Check | Result |
|-------|--------|
| `bash -n docs/scripts/perf-baseline.sh` | syntax OK |
| `bash -n macos/scripts/test-preflight-geometry-gating.sh` | syntax OK |
| `bash macos/scripts/test-preflight-geometry-gating.sh` | **18/18 PASS** |
| `bash docs/scripts/perf-baseline.sh` (default) | `GEOMETRY_VERDICT: FAIL` / exit 1 ✓ |
| `MMFORGE_NO_OCCT_ADVISORY=1 bash docs/scripts/perf-baseline.sh` | `GEOMETRY_VERDICT: ADVISORY` / exit 3 ✓ |
| `MMFORGE_ALLOW_NO_OCCT=1 bash macos/scripts/preflight-check.sh` | Section 10: ADVISORY ✓ (DMG integrity pre-existing issue in Section 8) |
| `git diff --check` | clean |

---

## 5. Files Changed

| File | Δ | Change |
|------|---|--------|
| `docs/scripts/perf-baseline.sh` | +10/−6 | GEOMETRY_VERDICT=FAIL/PLACEHOLDER on non-pass; header update |
| `macos/scripts/test-preflight-geometry-gating.sh` | +28/−19 | Verdict string assertions in all 10 scenarios |
| `docs/progress/2026-07-08-macos-noninteractive-verification-hardening.md` | +3/−3 | Remove outdated v2/exit-code references |
