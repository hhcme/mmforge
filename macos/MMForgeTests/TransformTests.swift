import XCTest
@testable import MMForge

// MARK: - Drawing2DView Transform Tests
//
// Validates that worldToScreenTransform() and its inverse correctly map
// world coordinates ↔ screen coordinates under various pan/zoom/bounds
// configurations.  These tests exercise the exact same transform used
// by draw(_:) and spatiallyCulledCommands.

final class TransformTests: XCTestCase {

    // MARK: - Helpers

    /// Explicit screen bounds for all tests (avoids Auto Layout resizing).
    private let screenBounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// Create a Drawing2DView with the given world bounds.
    private func makeView(minX: Double, minY: Double, maxX: Double, maxY: Double)
        -> Drawing2DView
    {
        let view = Drawing2DView(frame: screenBounds)
        view.drawingInfo = Drawing2DInfo(
            entityCount: 0, layerCount: 0,
            boundsMinX: minX, boundsMinY: minY,
            boundsMaxX: maxX, boundsMaxY: maxY,
            layers: []
        )
        return view
    }

    /// Assert two CGPoints are approximately equal.
    private func assertPointEqual(
        _ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 0.01,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy,
                       "x mismatch: \(a.x) vs \(b.x)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy,
                       "y mismatch: \(a.y) vs \(b.y)", file: file, line: line)
    }

    // MARK: - No pan, no zoom — world center → screen center

    func testNoPanNoZoomWorldCenterMapsToViewCenter() {
        // World: (0,0)→(100,50), view: 800×600.
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let xform = view.worldToScreenTransform(viewBounds: screenBounds)
        let inv = xform.inverted()

        // World center (50, 25) → screen center (400, 300).
        let worldCenter = CGPoint(x: 50, y: 25)
        let screenCenter = worldCenter.applying(xform)
        assertPointEqual(screenCenter, CGPoint(x: 400, y: 300))

        // Screen center → world center.
        let backToWorld = screenCenter.applying(inv)
        assertPointEqual(backToWorld, worldCenter)
    }

    // MARK: - Round-trip: world → screen → world

    func testRoundTripNoPanNoZoom() {
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let xform = view.worldToScreenTransform(viewBounds: screenBounds)
        let inv = xform.inverted()

        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 50),
            CGPoint(x: 25, y: 12.5),
            CGPoint(x: 75, y: 37.5),
        ]
        for p in points {
            let screen = p.applying(xform)
            let back = screen.applying(inv)
            assertPointEqual(back, p, accuracy: 0.001)
        }
    }

    // MARK: - Pan shifts the mapping

    func testPanShiftsScreenMapping() {
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let viewBounds = screenBounds

        // No pan.
        let xform0 = view.worldToScreenTransform(viewBounds: viewBounds)
        let screen0 = CGPoint(x: 50, y: 25).applying(xform0)

        // Apply pan directly.
        view.panOffset = CGPoint(x: 50, y: -30)

        let xform1 = view.worldToScreenTransform(viewBounds: viewBounds)
        let screen1 = CGPoint(x: 50, y: 25).applying(xform1)

        // Screen position should shift by the pan offset (50, -30).
        XCTAssertEqual(screen1.x, screen0.x + 50, accuracy: 0.01)
        XCTAssertEqual(screen1.y, screen0.y - 30, accuracy: 0.01)

        // Round-trip should still work.
        let inv1 = xform1.inverted()
        let back = screen1.applying(inv1)
        assertPointEqual(back, CGPoint(x: 50, y: 25), accuracy: 0.001)
    }

    // MARK: - Zoom scales around center

    func testZoomScalesMapping() {
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let viewBounds = screenBounds

        let xform0 = view.worldToScreenTransform(viewBounds: viewBounds)

        // Apply zoom directly.
        view.zoomLevel = 2.0

        let xform1 = view.worldToScreenTransform(viewBounds: viewBounds)
        let inv1 = xform1.inverted()

        // World center should still map to screen center after zoom.
        let worldCenter = CGPoint(x: 50, y: 25)
        let screenCenter = worldCenter.applying(xform1)
        assertPointEqual(screenCenter, CGPoint(x: 400, y: 300))

        // Round-trip.
        let back = screenCenter.applying(inv1)
        assertPointEqual(back, worldCenter, accuracy: 0.001)

        // The scale factor should have changed.
        XCTAssertNotEqual(xform0.a, xform1.a, accuracy: 0.001)
    }

    // MARK: - Non-zero world midY

    func testNonZeroWorldMidY() {
        // World: (-200, 100) → (200, 300).  midY = 200, not zero.
        let view = makeView(minX: -200, minY: 100, maxX: 200, maxY: 300)
        let xform = view.worldToScreenTransform(viewBounds: screenBounds)
        let inv = xform.inverted()

        // World center (0, 200) → screen center (400, 300).
        let worldCenter = CGPoint(x: 0, y: 200)
        let screenCenter = worldCenter.applying(xform)
        assertPointEqual(screenCenter, CGPoint(x: 400, y: 300))

        // Round-trip for several points.
        let points: [CGPoint] = [
            CGPoint(x: -200, y: 100),
            CGPoint(x: 200, y: 300),
            CGPoint(x: 0, y: 200),
            CGPoint(x: -100, y: 150),
        ]
        for p in points {
            let screen = p.applying(xform)
            let back = screen.applying(inv)
            assertPointEqual(back, p, accuracy: 0.001)
        }
    }

    // MARK: - Empty / tiny world bounds (fallback)

    func testTinyWorldBounds() {
        // Nearly degenerate bounds — width ≈ 0.
        let view = makeView(minX: 5, minY: 5, maxX: 5.001, maxY: 10)
        let xform = view.worldToScreenTransform(viewBounds: screenBounds)
        let inv = xform.inverted()

        // Should not crash; round-trip should work.
        let p = CGPoint(x: 5, y: 7.5)
        let screen = p.applying(xform)
        let back = screen.applying(inv)
        assertPointEqual(back, p, accuracy: 0.1)
    }

    // MARK: - Screen corners map to correct world quadrants

    func testScreenCornersMapToWorldQuadrants() {
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let xform = view.worldToScreenTransform(viewBounds: screenBounds)
        let inv = xform.inverted()

        // Screen top-left (0, 0) → world top-left (near 0, 50).
        let wTL = CGPoint(x: 0, y: 0).applying(inv)
        XCTAssertLessThan(wTL.x, 10, "top-left world X should be near 0")
        XCTAssertGreaterThan(wTL.y, 40, "top-left world Y should be near 50 (Y-flipped)")

        // Screen bottom-right (800, 600) → world bottom-right (near 100, 0).
        let wBR = CGPoint(x: 800, y: 600).applying(inv)
        XCTAssertGreaterThan(wBR.x, 90, "bottom-right world X should be near 100")
        XCTAssertLessThan(wBR.y, 10, "bottom-right world Y should be near 0 (Y-flipped)")
    }

    // MARK: - Y-flip: screen Y increases downward, world Y increases upward

    func testYFlipDirection() {
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let xform = view.worldToScreenTransform(viewBounds: screenBounds)

        // World Y=0 (bottom) → screen Y near bottom (large screen Y).
        let wBottom = CGPoint(x: 50, y: 0).applying(xform)
        // World Y=50 (top) → screen Y near top (small screen Y).
        let wTop = CGPoint(x: 50, y: 50).applying(xform)

        XCTAssertGreaterThan(wBottom.y, wTop.y,
                             "World bottom should map to larger screen Y (Y-flip)")
    }

    // MARK: - Pan + zoom combined

    func testPanAndZoomRoundTrip() {
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let viewBounds = screenBounds

        // Apply zoom and pan directly.
        view.zoomLevel = 2.5
        view.panOffset = CGPoint(x: -100, y: 50)

        let xform = view.worldToScreenTransform(viewBounds: viewBounds)
        let inv = xform.inverted()

        // Round-trip several world points.
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 50, y: 25),
            CGPoint(x: 100, y: 50),
        ]
        for p in points {
            let screen = p.applying(xform)
            let back = screen.applying(inv)
            assertPointEqual(back, p, accuracy: 0.01)
        }
    }

    // MARK: - Verify matrix elements: worldCenter → screenCenter invariant

    func testMatrixElements() {
        // World: (0,0)→(100,50), no pan, zoom=1.
        // The transform must map worldCenter → screenCenter regardless of
        // the internal concatenation order.  We verify this invariant and
        // that the matrix has no shear and correct signs.
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)
        let xform = view.worldToScreenTransform(viewBounds: screenBounds)
        let inv = xform.inverted()

        // No shear: b and c must be zero.
        XCTAssertEqual(xform.b, 0, accuracy: 0.001)
        XCTAssertEqual(xform.c, 0, accuracy: 0.001)

        // Scale must be positive in X, negative in Y (Y-flip).
        XCTAssertGreaterThan(xform.a, 0)
        XCTAssertLessThan(xform.d, 0)

        // Equal magnitude: |a| == |d|.
        XCTAssertEqual(abs(xform.a), abs(xform.d), accuracy: 0.001)

        // The critical invariant: worldCenter maps to screenCenter.
        let wc = CGPoint(x: 50, y: 25)
        let sc = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
        assertPointEqual(wc.applying(xform), sc, accuracy: 0.001)

        // Round-trip.
        assertPointEqual(sc.applying(inv), wc, accuracy: 0.001)
    }

    // MARK: - Empty viewport (view outside world bounds)

    func testEmptyViewportRoundTrip() {
        let view = makeView(minX: 0, minY: 0, maxX: 100, maxY: 50)

        // Pan far away from the drawing.
        view.panOffset = CGPoint(x: 5000, y: 5000)

        let xform = view.worldToScreenTransform(viewBounds: screenBounds)
        let inv = xform.inverted()

        // Round-trip still works even when viewport doesn't overlap drawing.
        let p = CGPoint(x: 50, y: 25)
        let screen = p.applying(xform)
        let back = screen.applying(inv)
        assertPointEqual(back, p, accuracy: 0.01)
    }
}
