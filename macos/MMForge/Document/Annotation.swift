import AppKit
import simd

// MARK: - Annotation Data Model

/// The kind of annotation.
enum AnnotationKind: Equatable {
    /// 2D point-to-point distance measurement.
    case measurement(start: CGPoint, end: CGPoint)
    /// 2D angle measurement (three points: vertex, ray1, ray2).
    case angleMeasurement(vertex: CGPoint, p1: CGPoint, p2: CGPoint)
    /// 2D area measurement (polygon vertices).
    case areaMeasurement(points: [CGPoint])
    /// Dimension line with extension lines and text.
    case dimension(start: CGPoint, end: CGPoint, offset: CGFloat)
    /// Text annotation at a position.
    case textAnnotation(position: CGPoint, text: String, fontSize: CGFloat)
    /// Arrow annotation from tail to head with optional label.
    case arrowAnnotation(tail: CGPoint, head: CGPoint, text: String?)
}

/// A user-created annotation (measurement, dimension, text, arrow).
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var kind: AnnotationKind
    var color: NSColor

    init(kind: AnnotationKind, color: NSColor = .systemYellow) {
        self.id = UUID()
        self.kind = kind
        self.color = color
    }

    static func == (lhs: Annotation, rhs: Annotation) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}

// MARK: - Measurement Type Picker

/// The type of measurement the user is performing.
enum MeasurementType: String, CaseIterable {
    case distance = "Distance"
    case angle = "Angle"
    case area = "Area"

    var instruction: String {
        switch self {
        case .distance: return "Click two points to measure distance."
        case .angle:    return "Click vertex, then two ray points."
        case .area:     return "Click polygon vertices. Double-click to close."
        }
    }
}

// MARK: - 2D Geometry Utilities

/// Geometry helpers for 2D measurement and snap-to-entity.
enum Geometry2D {

    /// Closest point on a line segment [a, b] to point p.
    static func closestPointOnSegment(p: CGPoint, a: CGPoint, b: CGPoint) -> CGPoint {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let abLenSq = ab.x * ab.x + ab.y * ab.y
        guard abLenSq > 1e-20 else { return a }
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / abLenSq))
        return CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
    }

    /// Closest point on a circle (center, radius) to point p.
    static func closestPointOnCircle(p: CGPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        let dx = p.x - center.x
        let dy = p.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1e-10 else {
            return CGPoint(x: center.x + radius, y: center.y)
        }
        return CGPoint(
            x: center.x + dx / dist * radius,
            y: center.y + dy / dist * radius
        )
    }

    /// Closest point on an arc to point p.
    /// Angles in radians, CCW from startAngle to endAngle.
    static func closestPointOnArc(
        p: CGPoint, center: CGPoint, radius: CGFloat,
        startAngle: CGFloat, endAngle: CGFloat, ccw: Bool
    ) -> CGPoint {
        let dx = p.x - center.x
        let dy = p.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 1e-10 else {
            return CGPoint(
                x: center.x + radius * cos(startAngle),
                y: center.y + radius * sin(startAngle)
            )
        }
        // Angle from center to p.
        let angleP = atan2(dy, dx)

        // Normalize angles to [0, 2π).
        func normalize(_ a: CGFloat) -> CGFloat {
            var v = a.truncatingRemainder(dividingBy: 2 * .pi)
            if v < 0 { v += 2 * .pi }
            return v
        }

        let sa = normalize(startAngle)
        let ea = normalize(endAngle)
        let ap = normalize(angleP)

        // Check if ap is within the arc range.
        let onArc: Bool
        if ccw {
            // CCW: from sa to ea going counter-clockwise.
            if sa <= ea {
                onArc = ap >= sa && ap <= ea
            } else {
                onArc = ap >= sa || ap <= ea
            }
        } else {
            // CW: from sa to ea going clockwise.
            if sa >= ea {
                onArc = ap <= sa && ap >= ea
            } else {
                onArc = ap <= sa || ap >= ea
            }
        }

        if onArc {
            return CGPoint(
                x: center.x + radius * cos(angleP),
                y: center.y + radius * sin(angleP)
            )
        }

        // Not on arc — return closest endpoint.
        let pStart = CGPoint(
            x: center.x + radius * cos(sa),
            y: center.y + radius * sin(sa)
        )
        let pEnd = CGPoint(
            x: center.x + radius * cos(ea),
            y: center.y + radius * sin(ea)
        )
        let dStart = hypot(p.x - pStart.x, p.y - pStart.y)
        let dEnd = hypot(p.x - pEnd.x, p.y - pEnd.y)
        return dStart <= dEnd ? pStart : pEnd
    }

    /// Closest point on a polyline to point p.
    static func closestPointOnPolyline(p: CGPoint, points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        if points.count == 1 { return points[0] }

        var bestPoint = points[0]
        var bestDist = CGFloat.greatestFiniteMagnitude

        for i in 0..<(points.count - 1) {
            let cp = closestPointOnSegment(p: p, a: points[i], b: points[i + 1])
            let d = hypot(p.x - cp.x, p.y - cp.y)
            if d < bestDist {
                bestDist = d
                bestPoint = cp
            }
        }
        return bestPoint
    }

    /// Euclidean distance between two points.
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Signed area of a polygon (positive = CCW winding).
    /// Uses the shoelace formula.
    static func signedArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var area: CGFloat = 0
        for i in 0..<points.count {
            let j = (i + 1) % points.count
            area += points[i].x * points[j].y
            area -= points[j].x * points[i].y
        }
        return area / 2
    }

    /// Absolute area of a polygon.
    static func area(_ points: [CGPoint]) -> CGFloat {
        abs(signedArea(points))
    }

    /// Centroid of a polygon.
    static func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        var cx: CGFloat = 0, cy: CGFloat = 0
        for p in points {
            cx += p.x
            cy += p.y
        }
        return CGPoint(x: cx / CGFloat(points.count), y: cy / CGFloat(points.count))
    }

    /// Angle in degrees between three points (vertex, p1, p2).
    static func angleDegrees(vertex: CGPoint, p1: CGPoint, p2: CGPoint) -> CGFloat {
        let v1 = CGVector(dx: p1.x - vertex.x, dy: p1.y - vertex.y)
        let v2 = CGVector(dx: p2.x - vertex.x, dy: p2.y - vertex.y)
        let cross = v1.dx * v2.dy - v1.dy * v2.dx
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        let angle = atan2(abs(cross), dot)
        return angle * 180 / .pi
    }

    // MARK: - Snap-to-Entity

    /// Find the closest snap target from a list of draw commands.
    /// Returns the snapped world point and the distance, or nil if nothing
    /// within `snapRadius`.
    static func findSnapTarget(
        worldPoint: CGPoint,
        commands: [DrawCommandDTO],
        snapRadius: CGFloat
    ) -> CGPoint? {
        var bestPoint: CGPoint?
        var bestDist = snapRadius

        for cmd in commands {
            let candidate: CGPoint?
            switch cmd {
            case .line(let x0, let y0, let x1, let y1, _, _, _, _, _, _, _):
                candidate = closestPointOnSegment(
                    p: worldPoint,
                    a: CGPoint(x: x0, y: y0),
                    b: CGPoint(x: x1, y: y1))

            case .circle(let cx, let cy, let r, _, _, _, _, _, _, _):
                candidate = closestPointOnCircle(
                    p: worldPoint,
                    center: CGPoint(x: cx, y: cy),
                    radius: r)

            case .arc(let cx, let cy, let r, let startAngle, let endAngle, let ccw,
                      _, _, _, _, _, _, _):
                candidate = closestPointOnArc(
                    p: worldPoint,
                    center: CGPoint(x: cx, y: cy),
                    radius: r,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    ccw: ccw)

            case .polyline(let pts, _, _, _, _, _, _, _, _):
                let cgPoints = pts.map { CGPoint(x: $0.0, y: $0.1) }
                candidate = closestPointOnPolyline(p: worldPoint, points: cgPoints)

            case .text(let x, let y, _, _, _, _, _, _, _):
                candidate = CGPoint(x: x, y: y)
            }

            if let cp = candidate {
                let d = distance(worldPoint, cp)
                if d < bestDist {
                    bestDist = d
                    bestPoint = cp
                }
            }
        }

        return bestPoint
    }
}
