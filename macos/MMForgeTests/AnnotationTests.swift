import XCTest
@testable import MMForge

// MARK: - Geometry2D + Annotation Tests

final class AnnotationTests: XCTestCase {

    // MARK: - closestPointOnSegment

    func testClosestPointOnSegment_midpoint() {
        let p = CGPoint(x: 0.5, y: 0.5)
        let cp = Geometry2D.closestPointOnSegment(
            p: p, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 1, y: 0))
        XCTAssertEqual(cp.x, 0.5, accuracy: 1e-10)
        XCTAssertEqual(cp.y, 0.0, accuracy: 1e-10)
    }

    func testClosestPointOnSegment_clampToStart() {
        let p = CGPoint(x: -1, y: 0.5)
        let cp = Geometry2D.closestPointOnSegment(
            p: p, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 1, y: 0))
        XCTAssertEqual(cp.x, 0.0, accuracy: 1e-10)
        XCTAssertEqual(cp.y, 0.0, accuracy: 1e-10)
    }

    func testClosestPointOnSegment_clampToEnd() {
        let p = CGPoint(x: 2, y: 0.5)
        let cp = Geometry2D.closestPointOnSegment(
            p: p, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 1, y: 0))
        XCTAssertEqual(cp.x, 1.0, accuracy: 1e-10)
        XCTAssertEqual(cp.y, 0.0, accuracy: 1e-10)
    }

    func testClosestPointOnSegment_degenerateSegment() {
        let p = CGPoint(x: 5, y: 5)
        let cp = Geometry2D.closestPointOnSegment(
            p: p, a: CGPoint(x: 3, y: 3), b: CGPoint(x: 3, y: 3))
        XCTAssertEqual(cp.x, 3.0, accuracy: 1e-10)
        XCTAssertEqual(cp.y, 3.0, accuracy: 1e-10)
    }

    // MARK: - closestPointOnCircle

    func testClosestPointOnCircle_pointInside() {
        let cp = Geometry2D.closestPointOnCircle(
            p: CGPoint(x: 0.5, y: 0),
            center: CGPoint(x: 0, y: 0),
            radius: 1.0)
        XCTAssertEqual(cp.x, 1.0, accuracy: 1e-10)
        XCTAssertEqual(cp.y, 0.0, accuracy: 1e-10)
    }

    func testClosestPointOnCircle_pointOnCircle() {
        let cp = Geometry2D.closestPointOnCircle(
            p: CGPoint(x: 1, y: 0),
            center: CGPoint(x: 0, y: 0),
            radius: 1.0)
        XCTAssertEqual(cp.x, 1.0, accuracy: 1e-10)
        XCTAssertEqual(cp.y, 0.0, accuracy: 1e-10)
    }

    func testClosestPointOnCircle_pointFarAway() {
        let cp = Geometry2D.closestPointOnCircle(
            p: CGPoint(x: 100, y: 0),
            center: CGPoint(x: 0, y: 0),
            radius: 1.0)
        XCTAssertEqual(cp.x, 1.0, accuracy: 1e-10)
        XCTAssertEqual(cp.y, 0.0, accuracy: 1e-10)
    }

    // MARK: - closestPointOnArc

    func testClosestPointOnArc_pointOnArc() {
        // Arc from 0° to 90° (CCW).
        let cp = Geometry2D.closestPointOnArc(
            p: CGPoint(x: 0.7, y: 0.7),
            center: CGPoint(x: 0, y: 0),
            radius: 1.0,
            startAngle: 0,
            endAngle: CGFloat.pi / 2,
            ccw: true)
        // Should be on the arc near 45°.
        let dist = Geometry2D.distance(cp, CGPoint(x: cos(CGFloat.pi / 4), y: sin(CGFloat.pi / 4)))
        XCTAssertLessThan(dist, 0.1)
    }

    func testClosestPointOnArc_pointOutsideArc_returnsEndpoint() {
        // Arc from 0° to 90° (CCW). Point at 180° is outside the arc.
        let cp = Geometry2D.closestPointOnArc(
            p: CGPoint(x: -1, y: 0),
            center: CGPoint(x: 0, y: 0),
            radius: 1.0,
            startAngle: 0,
            endAngle: CGFloat.pi / 2,
            ccw: true)
        // Should return either start (0°) or end (90°).
        let dStart = Geometry2D.distance(cp, CGPoint(x: 1, y: 0))
        let dEnd = Geometry2D.distance(cp, CGPoint(x: 0, y: 1))
        XCTAssertTrue(min(dStart, dEnd) < 0.01)
    }

    // MARK: - closestPointOnPolyline

    func testClosestPointOnPolyline_singleSegment() {
        let cp = Geometry2D.closestPointOnPolyline(
            p: CGPoint(x: 0.5, y: 1),
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)])
        XCTAssertNotNil(cp)
        XCTAssertEqual(cp!.x, 0.5, accuracy: 1e-10)
        XCTAssertEqual(cp!.y, 0.0, accuracy: 1e-10)
    }

    func testClosestPointOnPolyline_multiSegment() {
        let cp = Geometry2D.closestPointOnPolyline(
            p: CGPoint(x: 1.5, y: 0.5),
            points: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1),
            ])
        XCTAssertNotNil(cp)
        // Closest should be on the vertical segment (1,0)→(1,1).
        XCTAssertEqual(cp!.x, 1.0, accuracy: 1e-10)
    }

    func testClosestPointOnPolyline_empty() {
        let cp = Geometry2D.closestPointOnPolyline(
            p: CGPoint(x: 0, y: 0), points: [])
        XCTAssertNil(cp)
    }

    // MARK: - Distance

    func testDistance_simple() {
        let d = Geometry2D.distance(CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4))
        XCTAssertEqual(d, 5.0, accuracy: 1e-10)
    }

    func testDistance_samePoint() {
        let d = Geometry2D.distance(CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5))
        XCTAssertEqual(d, 0.0, accuracy: 1e-10)
    }

    // MARK: - Area (shoelace)

    func testArea_unitSquare() {
        let area = Geometry2D.area([
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1),
        ])
        XCTAssertEqual(area, 1.0, accuracy: 1e-10)
    }

    func testArea_triangle() {
        let area = Geometry2D.area([
            CGPoint(x: 0, y: 0),
            CGPoint(x: 4, y: 0),
            CGPoint(x: 0, y: 3),
        ])
        XCTAssertEqual(area, 6.0, accuracy: 1e-10)
    }

    func testArea_emptyPolygon() {
        XCTAssertEqual(Geometry2D.area([]), 0.0)
        XCTAssertEqual(Geometry2D.area([CGPoint(x: 0, y: 0)]), 0.0)
        XCTAssertEqual(Geometry2D.area([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]), 0.0)
    }

    func testArea_cwVsCcw() {
        let ccw: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
        ]
        let cw = Array(ccw.reversed())
        XCTAssertEqual(Geometry2D.area(ccw), Geometry2D.area(cw), accuracy: 1e-10)
    }

    // MARK: - Centroid

    func testCentroid_unitSquare() {
        let c = Geometry2D.centroid([
            CGPoint(x: 0, y: 0),
            CGPoint(x: 2, y: 0),
            CGPoint(x: 2, y: 2),
            CGPoint(x: 0, y: 2),
        ])
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.x, 1.0, accuracy: 1e-10)
        XCTAssertEqual(c!.y, 1.0, accuracy: 1e-10)
    }

    func testCentroid_empty() {
        XCTAssertNil(Geometry2D.centroid([]))
    }

    // MARK: - Angle

    func testAngleDegrees_rightAngle() {
        let angle = Geometry2D.angleDegrees(
            vertex: CGPoint(x: 0, y: 0),
            p1: CGPoint(x: 1, y: 0),
            p2: CGPoint(x: 0, y: 1))
        XCTAssertEqual(angle, 90.0, accuracy: 0.01)
    }

    func testAngleDegrees_straightLine() {
        let angle = Geometry2D.angleDegrees(
            vertex: CGPoint(x: 0, y: 0),
            p1: CGPoint(x: 1, y: 0),
            p2: CGPoint(x: -1, y: 0))
        XCTAssertEqual(angle, 180.0, accuracy: 0.01)
    }

    func testAngleDegrees_45degrees() {
        let angle = Geometry2D.angleDegrees(
            vertex: CGPoint(x: 0, y: 0),
            p1: CGPoint(x: 1, y: 0),
            p2: CGPoint(x: 1, y: 1))
        XCTAssertEqual(angle, 45.0, accuracy: 0.01)
    }

    // MARK: - Annotation model

    func testAnnotationCreation() {
        let ann = Annotation(
            kind: .measurement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0)),
            color: .systemYellow)
        XCTAssertNotNil(ann.id)
        XCTAssertEqual(ann.color, .systemYellow)
    }

    func testAnnotationEquality() {
        let ann1 = Annotation(kind: .measurement(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0)))
        var ann2 = ann1
        ann2.color = .red
        // Same id and kind → equal (color not part of Equatable).
        XCTAssertEqual(ann1, ann2)
    }

    func testAnnotationInequality() {
        let ann1 = Annotation(kind: .measurement(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0)))
        let ann2 = Annotation(kind: .measurement(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 20, y: 0)))
        XCTAssertNotEqual(ann1, ann2)
    }

    // MARK: - MeasurementType

    func testMeasurementTypeInstructions() {
        for type in MeasurementType.allCases {
            XCTAssertFalse(type.instruction.isEmpty)
        }
    }

    // MARK: - PDF Smoke Tests

    func testPDFExport_doesNotCrash() {
        // Smoke test: creating a PDF context and rendering annotations
        // should not crash, even with empty command lists.
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            XCTFail("Failed to create CGDataConsumer")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create CGContext")
            return
        }

        let wb = CGRect(x: 0, y: 0, width: 100, height: 50)
        let annotations: [Annotation] = [
            Annotation(kind: .measurement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0))),
            Annotation(kind: .angleMeasurement(vertex: .zero, p1: CGPoint(x: 1, y: 0), p2: CGPoint(x: 0, y: 1))),
            Annotation(kind: .areaMeasurement(points: [
                CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])),
            Annotation(kind: .dimension(start: .zero, end: CGPoint(x: 50, y: 0), offset: 10)),
            Annotation(kind: .textAnnotation(position: CGPoint(x: 5, y: 5), text: "Test", fontSize: 12)),
            Annotation(kind: .arrowAnnotation(tail: .zero, head: CGPoint(x: 10, y: 5), text: "Arrow")),
        ]

        Drawing2DView.renderPDF(
            ctx: ctx,
            commands: [],
            annotations: annotations,
            layerVisibility: [:],
            worldBounds: wb,
            pageWidth: 842,
            pageHeight: 595,
            margin: 36)

        ctx.closePDF()

        // PDF data should be non-empty.
        XCTAssertGreaterThan(pdfData.length, 0, "PDF data should not be empty")
    }

    func testPDFExport_withDrawCommands() {
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            XCTFail("Failed to create CGDataConsumer")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("Failed to create CGContext")
            return
        }

        let wb = CGRect(x: 0, y: 0, width: 100, height: 50)

        // Create a minimal DrawCommandDTO.
        let cmd = DrawCommandDTO.line(
            x0: 0, y0: 0, x1: 100, y1: 0,
            layerIndex: 0, layerName: "0", colorIndex: 7, visible: true,
            lineType: nil, lineWeight: 0, lineDash: [])

        Drawing2DView.renderPDF(
            ctx: ctx,
            commands: [cmd],
            annotations: [],
            layerVisibility: ["0": true],
            worldBounds: wb,
            pageWidth: 842,
            pageHeight: 595,
            margin: 36)

        ctx.closePDF()

        XCTAssertGreaterThan(pdfData.length, 0, "PDF with draw commands should not be empty")
    }

    // MARK: - Annotation Creation Workflow Tests

    func testAllAnnotationKinds() {
        // Verify all annotation kinds can be created without crashing.
        let kinds: [AnnotationKind] = [
            .measurement(start: .zero, end: CGPoint(x: 10, y: 0)),
            .angleMeasurement(vertex: .zero, p1: CGPoint(x: 1, y: 0), p2: CGPoint(x: 0, y: 1)),
            .areaMeasurement(points: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]),
            .dimension(start: .zero, end: CGPoint(x: 10, y: 0), offset: 5),
            .textAnnotation(position: .zero, text: "Hello", fontSize: 14),
            .arrowAnnotation(tail: .zero, head: CGPoint(x: 10, y: 5), text: "Label"),
        ]
        for kind in kinds {
            let ann = Annotation(kind: kind)
            XCTAssertNotNil(ann.id)
        }
    }

    func testFindSnapTarget_noCommands() {
        let result = Geometry2D.findSnapTarget(
            worldPoint: CGPoint(x: 5, y: 5),
            commands: [],
            snapRadius: 10)
        XCTAssertNil(result)
    }

    // MARK: - PDF Coordinate Transform Tests

    /// Build the pdfFrame transform using the same method as renderPDF.
    private func buildPDFFrame(
        worldBounds wb: CGRect,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat
    ) -> CGAffineTransform {
        Drawing2DView.pdfPageTransform(
            worldBounds: wb, pageWidth: pageWidth,
            pageHeight: pageHeight, margin: margin)
    }

    func testPDFFrame_worldCenterMapsToPageCenter() {
        let wb = CGRect(x: 0, y: 0, width: 100, height: 50)
        let pageW: CGFloat = 842
        let pageH: CGFloat = 595
        let margin: CGFloat = 36
        let pdfFrame = buildPDFFrame(worldBounds: wb, pageWidth: pageW,
                                     pageHeight: pageH, margin: margin)

        let worldCenter = CGPoint(x: 50, y: 25)
        let pagePt = worldCenter.applying(pdfFrame)

        // World center must map to the page center.
        XCTAssertEqual(pagePt.x, pageW / 2, accuracy: 1.0,
                       "World center X should map to page center X")
        XCTAssertEqual(pagePt.y, pageH / 2, accuracy: 1.0,
                       "World center Y should map to page center Y")
    }

    func testPDFFrame_worldCornersInsidePage() {
        let wb = CGRect(x: 0, y: 0, width: 100, height: 50)
        let pageW: CGFloat = 842
        let pageH: CGFloat = 595
        let margin: CGFloat = 36
        let pdfFrame = buildPDFFrame(worldBounds: wb, pageWidth: pageW,
                                     pageHeight: pageH, margin: margin)

        let corners = [
            CGPoint(x: 0, y: 0),     // bottom-left
            CGPoint(x: 100, y: 0),   // bottom-right
            CGPoint(x: 0, y: 50),    // top-left
            CGPoint(x: 100, y: 50),  // top-right
        ]
        let pageRect = CGRect(x: 0, y: 0, width: pageW, height: pageH)

        for corner in corners {
            let pagePt = corner.applying(pdfFrame)
            XCTAssertTrue(pageRect.contains(pagePt),
                          "World corner \(corner) → page \(pagePt) should be inside page \(pageRect)")
        }
    }

    func testPDFFrame_yDirectionCorrect() {
        // World Y=0 (bottom) should map to LARGER page Y than world Y=50 (top).
        // In PDF coordinates, Y increases downward, so bottom of drawing is
        // at the bottom of the page (larger Y).
        let wb = CGRect(x: 0, y: 0, width: 100, height: 50)
        let pageW: CGFloat = 842
        let pageH: CGFloat = 595
        let margin: CGFloat = 36
        let pdfFrame = buildPDFFrame(worldBounds: wb, pageWidth: pageW,
                                     pageHeight: pageH, margin: margin)

        let worldBottom = CGPoint(x: 50, y: 0).applying(pdfFrame)
        let worldTop = CGPoint(x: 50, y: 50).applying(pdfFrame)

        XCTAssertGreaterThan(worldBottom.y, worldTop.y,
                             "World bottom (y=0) should have larger page Y than world top (y=50)")
    }

    func testPDFFrame_nonZeroOrigin() {
        // Drawing with non-zero origin (e.g. offset drawing).
        let wb = CGRect(x: -200, y: -100, width: 400, height: 200)
        let pageW: CGFloat = 842
        let pageH: CGFloat = 595
        let margin: CGFloat = 36
        let pdfFrame = buildPDFFrame(worldBounds: wb, pageWidth: pageW,
                                     pageHeight: pageH, margin: margin)

        let worldCenter = CGPoint(x: 0, y: 0)
        let pagePt = worldCenter.applying(pdfFrame)

        // Center of the drawing (0,0) should map to page center.
        XCTAssertEqual(pagePt.x, pageW / 2, accuracy: 1.0)
        XCTAssertEqual(pagePt.y, pageH / 2, accuracy: 1.0)

        // All four corners should be inside the page.
        let corners = [
            CGPoint(x: -200, y: -100),
            CGPoint(x: 200, y: -100),
            CGPoint(x: -200, y: 100),
            CGPoint(x: 200, y: 100),
        ]
        let pageRect = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        for corner in corners {
            let pagePt = corner.applying(pdfFrame)
            XCTAssertTrue(pageRect.contains(pagePt),
                          "Corner \(corner) → \(pagePt) should be inside page")
        }
    }

    // MARK: - Hidden Layer Filtering Tests

    func testVisibleCommands_filtersHiddenLayers() {
        let visible = DrawCommandDTO.line(
            x0: 0, y0: 0, x1: 10, y1: 0,
            layerIndex: 0, layerName: "visible", colorIndex: 7, visible: true,
            lineType: nil, lineWeight: 0, lineDash: [])
        let hidden = DrawCommandDTO.line(
            x0: 0, y0: 0, x1: 10, y1: 0,
            layerIndex: 1, layerName: "hidden", colorIndex: 7, visible: true,
            lineType: nil, lineWeight: 0, lineDash: [])

        let result = Drawing2DView.visibleCommands(
            [visible, hidden],
            layerVisibility: ["visible": true, "hidden": false])

        XCTAssertEqual(result.count, 1, "Hidden layer command should be filtered out")
        if case .line(_, _, _, _, _, let ln, _, _, _, _, _) = result[0] {
            XCTAssertEqual(ln, "visible")
        }
    }

    func testVisibleCommands_defaultVisible() {
        // When a layer is not in the overrides dict, use the command's default visible flag.
        let cmd = DrawCommandDTO.line(
            x0: 0, y0: 0, x1: 10, y1: 0,
            layerIndex: 0, layerName: "unknown", colorIndex: 7, visible: false,
            lineType: nil, lineWeight: 0, lineDash: [])

        let result = Drawing2DView.visibleCommands([cmd], layerVisibility: [:])
        XCTAssertTrue(result.isEmpty, "Command with visible=false and no override should be filtered")
    }

    func testVisibleCommands_overrideShow() {
        // Override a normally-hidden layer to be visible.
        let cmd = DrawCommandDTO.line(
            x0: 0, y0: 0, x1: 10, y1: 0,
            layerIndex: 0, layerName: "off", colorIndex: 7, visible: false,
            lineType: nil, lineWeight: 0, lineDash: [])

        let result = Drawing2DView.visibleCommands([cmd], layerVisibility: ["off": true])
        XCTAssertEqual(result.count, 1, "Override to visible should include the command")
    }

    func testVisibleCommands_emptyInput() {
        let result = Drawing2DView.visibleCommands([], layerVisibility: ["x": false])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Annotation Position Tests

    func testAnnotationPosition_measurement() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 30, y: 40)
        let ann = Annotation(kind: .measurement(start: start, end: end))

        if case .measurement(let s, let e) = ann.kind {
            XCTAssertEqual(s.x, 10)
            XCTAssertEqual(s.y, 20)
            XCTAssertEqual(e.x, 30)
            XCTAssertEqual(e.y, 40)
        } else {
            XCTFail("Expected measurement kind")
        }
    }

    func testAnnotationPosition_text() {
        let pos = CGPoint(x: 55.5, y: 33.3)
        let ann = Annotation(kind: .textAnnotation(position: pos, text: "Test", fontSize: 12))

        if case .textAnnotation(let p, let text, let fs) = ann.kind {
            XCTAssertEqual(p.x, 55.5, accuracy: 1e-10)
            XCTAssertEqual(p.y, 33.3, accuracy: 1e-10)
            XCTAssertEqual(text, "Test")
            XCTAssertEqual(fs, 12)
        } else {
            XCTFail("Expected textAnnotation kind")
        }
    }

    func testAnnotationPosition_arrow() {
        let tail = CGPoint(x: 0, y: 0)
        let head = CGPoint(x: 100, y: 50)
        let ann = Annotation(kind: .arrowAnnotation(tail: tail, head: head, text: "Arrow"))

        if case .arrowAnnotation(let t, let h, let text) = ann.kind {
            XCTAssertEqual(t.x, 0)
            XCTAssertEqual(h.x, 100)
            XCTAssertEqual(h.y, 50)
            XCTAssertEqual(text, "Arrow")
        } else {
            XCTFail("Expected arrowAnnotation kind")
        }
    }

    func testAnnotationPosition_dimension() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 60, y: 10)
        let ann = Annotation(kind: .dimension(start: start, end: end, offset: 15))

        if case .dimension(let s, let e, let offset) = ann.kind {
            XCTAssertEqual(s.x, 10)
            XCTAssertEqual(e.x, 60)
            XCTAssertEqual(offset, 15)
        } else {
            XCTFail("Expected dimension kind")
        }
    }

    // MARK: - AnnotationTool Tests

    func testAnnotationTool_properties() {
        for tool in AnnotationTool.allCases {
            XCTAssertFalse(tool.instruction.isEmpty)
            XCTAssertGreaterThan(tool.clickCount, 0)
            XCTAssertNotNil(tool.color)
        }
    }

    func testAnnotationTool_textSingleClick() {
        XCTAssertEqual(AnnotationTool.text.clickCount, 1)
    }

    func testAnnotationTool_arrowTwoClicks() {
        XCTAssertEqual(AnnotationTool.arrow.clickCount, 2)
    }

    func testAnnotationTool_dimensionTwoClicks() {
        XCTAssertEqual(AnnotationTool.dimension.clickCount, 2)
    }
}
