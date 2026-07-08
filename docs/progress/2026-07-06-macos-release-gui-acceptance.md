# macOS Release GUI Acceptance — 2026-07-06

**Date**: 2026-07-06
**Status**: BLOCKED FOR INTERACTIVE FOREGROUND RUN
**Evidence policy**: prior full-screen screenshot evidence is invalidated

---

## Summary

This report supersedes the earlier `64/64 checks pass` claim. The previous GUI
acceptance evidence was not strong enough because successful full-screen
`screencapture` output can capture Codex, ZCode, browser, desktop, or another
foreground app instead of MMForge. A screenshot existing on disk is not proof
that MMForge rendered the model.

The GUI acceptance script now has stricter evidence rules:

- explicitly activates MMForge before each observed step
- locates the MMForge window by exact document title
- captures only that window rectangle, not the full desktop
- validates PNG existence, size, dimensions, and SHA-256 manifest data
- verifies `Export Image` by checking the actual exported PNG file exists and is
  non-empty
- records render-mode visual delta separately from "shortcut sent"
- keeps viewport semantics, structure tree, orbit/pan/zoom, and picking out of
  automated pass counts unless they are actually verified

Because this test uses AppleScript to activate MMForge, send keyboard shortcuts,
drive `NSSavePanel`, and capture the foreground window, it is not a silent test.
It will interrupt normal desktop use. The script now refuses to run unless the
caller explicitly opts into an interactive foreground session.

---

## Current Verification State

| Area | Status | Evidence |
|------|--------|----------|
| Release packaging | PASS | `bash macos/scripts/package.sh release` completed on 2026-07-06 |
| Debug Swift build | PASS | `xcodebuild ... Debug ... build` completed on 2026-07-06 |
| Code signature | PASS | `codesign --verify --deep --strict --verbose=2 macos/build/Build/Products/Release/MMForge.app` |
| Bundled dylib closure | PASS | `@rpath/*.dylib` scan found no missing Frameworks dylibs |
| Homebrew path scan | PASS | `otool -L` scan found no `/opt/homebrew`, `/usr/local`, or `Cellar` runtime references |
| Diff whitespace | PASS | `git diff --check` |
| GUI acceptance script syntax | PASS | `bash -n scripts/gui-acceptance-test.sh` |
| Non-interactive guard | PASS | default `bash scripts/gui-acceptance-test.sh` exits with explanation before opening MMForge |
| Window-scoped GUI run | NOT COMPLETE | requires dedicated foreground session |
| Exported PNG verification | NOT COMPLETE | requires dedicated foreground session |
| Viewport content semantics | MANUAL PENDING | cannot be inferred from screenshot existence alone |
| Structure tree correctness | MANUAL PENDING | no reliable Accessibility-level assertion yet |
| Orbit/pan/zoom | MANUAL PENDING | gesture automation not implemented |
| Picking/selection | MANUAL PENDING | click target + selection assertion not implemented |
| Render-mode visual correctness | PARTIAL/PENDING | script can detect screenshot hash deltas, but semantic mode correctness still needs manual review |

---

## Product Fix Found During Evidence Correction

The stricter export check exposed a real product gap: DXF documents use the 2D
drawing viewport and did not have an image export path. `Export Image` only used
the Metal renderer path, so 2D documents could not present a valid image export
panel.

This has been fixed by adding a 2D image rendering path that reuses the
`Drawing2DView` rendering pipeline and saves PNG/JPEG through the same
`NSSavePanel` flow as 3D exports.

Changed files:

- `macos/MMForge/Document/MMForgeDocument.swift`
- `macos/MMForge/Views/DrawingView.swift`

---

## Correct GUI Acceptance Command

Run this only when the Mac can be dedicated to the test and foreground focus can
be taken by MMForge:

```bash
MMFORGE_ALLOW_INTERACTIVE_GUI=1 bash scripts/gui-acceptance-test.sh
```

The script writes local, regeneratable evidence to:

- `docs/screenshots/2026-07-06/results.txt`
- `docs/screenshots/2026-07-06/*.png`
- `docs/screenshots/2026-07-06/exports/*.png`
- `docs/progress/2026-07-06-macos-release-gui-acceptance-manifest.txt`

`docs/screenshots/` is intentionally git-ignored, so screenshot PNGs are local
artifacts. A complete acceptance run must either commit a manifest with hashes
or explicitly attach the local evidence bundle outside git.

---

## Silent Checks

These checks do not take over the desktop:

```bash
bash macos/scripts/package.sh release
codesign --verify --deep --strict --verbose=2 macos/build/Build/Products/Release/MMForge.app
git diff --check
```

Dependency inspection:

```bash
app=macos/build/Build/Products/Release/MMForge.app
otool -L "$app/Contents/MacOS/MMForge"
find "$app/Contents/Frameworks" -type f -name "*.dylib" -exec otool -L {} \;
```

---

## Acceptance Criteria Not Yet Met

The macOS Release GUI acceptance cannot be marked complete until a dedicated
interactive run produces a clean result file and a manifest from window-scoped
MMForge screenshots and verified export files.

Do not report `8/8 formats`, `64/64`, or equivalent "all pass" language until
that run completes without failures and the remaining manual items are either
verified by a human or covered by new deterministic automation.
