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
}
