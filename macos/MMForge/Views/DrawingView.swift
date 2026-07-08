import AppKit
import SwiftUI
import simd

/// DXF ACI (AutoCAD Color Index) toCGColor mapping.
private func aciColor(_ index: Int) -> CGColor {
    switch index {
    case 1: return CGColor(red: 1, green: 0, blue: 0, alpha: 1)     // red
    case 2: return CGColor(red: 1, green: 1, blue: 0, alpha: 1)     // yellow
    case 3: return CGColor(red: 0, green: 1, blue: 0, alpha: 1)     // green
    case 4: return CGColor(red: 0, green: 1, blue: 1, alpha: 1)     // cyan
    case 5: return CGColor(red: 0, green: 0, blue: 1, alpha: 1)     // blue
    case 6: return CGColor(red: 1, green: 0, blue: 1, alpha: 1)     // magenta
    default: return CGColor(red: 1, green: 1, blue: 1, alpha: 1)    // white
    }
}

/// A 2D drawing view using Core Graphics.
///
/// Renders DXF drawing entities (lines, circles, arcs, polylines, text)
/// with pan, zoom, and fit-to-view support.  Layer visibility can be
/// toggled per-layer.  Uses spatial index for viewport culling.
class Drawing2DView: NSView {
    /// Parsed draw commands from the Rust bridge.
    var drawCommands: [DrawCommandDTO] = [] {
        didSet { needsDisplay = true }
    }

    /// 2D drawing metadata.
    var drawingInfo: Drawing2DInfo? {
        didSet { needsDisplay = true }
    }

    /// Layer visibility overrides (layer name → visible).
    var layerVisibilityOverrides: [String: Bool] = [:] {
        didSet { needsDisplay = true }
    }

    /// Generation-guarded spatial query closure (from DocumentViewModel).
    ///
    /// `nil` means spatial index is unavailable — `spatiallyCulledCommands`
    /// falls back to drawing all commands.  The closure is safe to store
    /// because it validates `parseGeneration` before each query, preventing
    /// use-after-free when the underlying Rust document is freed.
    var spatialQueryFunc: ((Double, Double, Double, Double) -> [Int]?)?

    /// Annotations to render as overlay.
    var annotations: [Annotation] = [] {
        didSet { needsDisplay = true }
    }

    /// Whether measurement mode is active.
    var measurementMode: Bool = false

    /// The type of measurement being performed.
    var measurementType: MeasurementType = .distance

    /// Whether snap-to-entity is enabled.
    var snapEnabled: Bool = true

    /// Active independent annotation tool (text/arrow/dimension).
    var activeAnnotationTool: AnnotationTool?

    /// Text content for the text annotation tool.
    var annotationToolText: String = ""

    /// First-click point for 2D measurement (world coords).
    var pendingAnnotationPoint: CGPoint? {
        didSet { needsDisplay = true }
    }

    /// Accumulated polygon points for area measurement.
    var pendingPolygonPoints: [CGPoint] = [] {
        didSet { needsDisplay = true }
    }

    /// Delegate for annotation events.
    weak var annotationDelegate: Drawing2DAnnotationDelegate?

    /// Viewport state: pan offset and zoom level.
    /// Internal for testing — use gestures to modify in production.
    var panOffset: CGPoint = .zero
    var zoomLevel: CGFloat = 1.0

    /// World-space bounds of the drawing.
    var worldBounds: CGRect {
        guard let info = drawingInfo else {
            return CGRect(x: -100, y: -100, width: 200, height: 200)
        }
        return CGRect(
            x: info.boundsMinX,
            y: info.boundsMinY,
            width: info.boundsMaxX - info.boundsMinX,
            height: info.boundsMaxY - info.boundsMinY
        )
    }

    // MARK: - Transform

    /// Compute the fit-to-view scale given a screen rect and world bounds.
    func fitScale(screenBounds: CGRect, worldRect: CGRect) -> CGFloat {
        let margin: CGFloat = 40
        let scaleX = (screenBounds.width - margin * 2) / max(worldRect.width, 0.001)
        let scaleY = (screenBounds.height - margin * 2) / max(worldRect.height, 0.001)
        return min(scaleX, scaleY)
    }

    /// Build the world→screen affine transform.
    ///
    /// This is the **single source of truth** used by both `draw(_:)` and
    /// `spatiallyCulledCommands`.  The transform chain (applied left→right)
    /// matches the CGContext calls exactly:
    ///
    ///   T1: translate(viewCenter)
    ///   T2: scale(scale)
    ///   T3: translate(panOffset / scale)
    ///   T4: translate(-worldCenter)
    ///   T5: scale(1, -1)            // Y-flip
    ///   T6: translate(0, -wb.midY * 2)
    func worldToScreenTransform(viewBounds: CGRect) -> CGAffineTransform {
        let wb = worldBounds
        let s = zoomLevel * fitScale(screenBounds: viewBounds, worldRect: wb)
        let vc = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        let wc = CGPoint(x: wb.midX, y: wb.midY)

        // T1: translate(vc)
        let t1 = CGAffineTransform(translationX: vc.x, y: vc.y)
        // T2: scale(s)
        let t2 = CGAffineTransform(scaleX: s, y: s)
        // T3: translate(panOffset / s)
        let t3 = CGAffineTransform(translationX: panOffset.x / s, y: panOffset.y / s)
        // T4: translate(-wc)
        let t4 = CGAffineTransform(translationX: -wc.x, y: -wc.y)
        // T5: scale(1, -1)  — Y-flip
        let t5 = CGAffineTransform(scaleX: 1, y: -1)
        // T6: translate(0, -wb.midY * 2)
        let t6 = CGAffineTransform(translationX: 0, y: -wb.midY * 2)

        // CGAffineTransform.concatenating applies receiver first, but
        // CGContext.concat applies argument first.  To match the CGContext
        // call order (T1 first, T6 last), we must reverse the chain:
        //   t6.concatenating(t5)...concatenating(t1)
        // so that T1 is applied last (i.e., first in the CGContext order).
        return t6.concatenating(t5).concatenating(t4)
                  .concatenating(t3).concatenating(t2).concatenating(t1)
    }

    // MARK: - Coordinate Conversion

    /// Convert a screen point to world coordinates.
    func screenToWorld(_ screenPoint: CGPoint) -> CGPoint {
        let xform = worldToScreenTransform(viewBounds: bounds)
        return screenPoint.applying(xform.inverted())
    }

    /// Convert a world point to screen coordinates.
    func worldToScreen(_ worldPoint: CGPoint) -> CGPoint {
        worldPoint.applying(worldToScreenTransform(viewBounds: bounds))
    }

    // MARK: - Click Handling

    /// Whether the view should intercept clicks for measurement or annotation.
    private var isInteracting: Bool {
        measurementMode || activeAnnotationTool != nil
    }

    override func mouseDown(with event: NSEvent) {
        // Annotation tools and measurement mode both need click handling.
        // If neither is active, pass through to default behavior (e.g. pan).
        guard isInteracting else {
            super.mouseDown(with: event)
            return
        }

        let screenPt = convert(event.locationInWindow, from: nil)
        var worldPt = screenToWorld(screenPt)

        // Snap to nearest entity if enabled.
        if snapEnabled {
            let snapRadius = 8.0 / (zoomLevel * fitScale(screenBounds: bounds, worldRect: worldBounds))
            if let snapped = Geometry2D.findSnapTarget(
                worldPoint: worldPt, commands: drawCommands, snapRadius: snapRadius) {
                worldPt = snapped
            }
        }

        // Annotation tools take priority over measurement mode.
        if let tool = activeAnnotationTool {
            handleAnnotationToolClick(worldPt, tool: tool)
            return
        }

        // Measurement mode handling.
        switch measurementType {
        case .distance:
            handleDistanceClick(worldPt)
        case .angle:
            handleAngleClick(worldPt)
        case .area:
            handleAreaClick(worldPt)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInteracting else {
            super.rightMouseDown(with: event)
            return
        }
        // Cancel pending state for whichever mode is active.
        // If an annotation tool is active, cancel its pending point.
        // If measurement mode is active, cancel its pending state.
        if activeAnnotationTool != nil {
            annotationDelegate?.didCancelPending()
        } else if measurementMode {
            annotationDelegate?.didCancelPending()
        }
    }

    private func handleAnnotationToolClick(_ worldPt: CGPoint, tool: AnnotationTool) {
        switch tool {
        case .text:
            annotationDelegate?.didPlaceTextAnnotation(at: worldPt, text: annotationToolText)
        case .arrow:
            if let pending = pendingAnnotationPoint {
                annotationDelegate?.didCompleteArrowAnnotation(tail: pending, head: worldPt)
            } else {
                annotationDelegate?.didSetPendingPoint(worldPt)
            }
        case .dimension:
            if let pending = pendingAnnotationPoint {
                annotationDelegate?.didCompleteDimensionAnnotation(start: pending, end: worldPt)
            } else {
                annotationDelegate?.didSetPendingPoint(worldPt)
            }
        }
    }

    private func handleDistanceClick(_ worldPt: CGPoint) {
        if let pending = pendingAnnotationPoint {
            annotationDelegate?.didCompleteMeasurement(start: pending, end: worldPt)
        } else {
            annotationDelegate?.didSetPendingPoint(worldPt)
        }
    }

    private func handleAngleClick(_ worldPt: CGPoint) {
        if pendingPolygonPoints.isEmpty {
            annotationDelegate?.didSetPendingAngleVertex(worldPt)
        } else if pendingPolygonPoints.count == 1 {
            annotationDelegate?.didSetPendingAngleRay(worldPt)
        } else {
            let vertex = pendingPolygonPoints[0]
            let p1 = pendingPolygonPoints[1]
            annotationDelegate?.didCompleteAngleMeasurement(vertex: vertex, p1: p1, p2: worldPt)
        }
    }

    private func handleAreaClick(_ worldPt: CGPoint) {
        if pendingPolygonPoints.count >= 3 {
            let closeRadius = 8.0 / (zoomLevel * fitScale(screenBounds: bounds, worldRect: worldBounds))
            if Geometry2D.distance(worldPt, pendingPolygonPoints[0]) < closeRadius {
                annotationDelegate?.didCompleteAreaMeasurement(points: pendingPolygonPoints)
                return
            }
        }
        annotationDelegate?.didAddPolygonPoint(worldPt)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Clear background.
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0))
        ctx.fill(bounds)

        let wb = worldBounds
        let scale = zoomLevel * fitScale(screenBounds: bounds, worldRect: wb)

        // Apply the exact same transform as worldToScreenTransform.
        let xform = worldToScreenTransform(viewBounds: bounds)
        ctx.saveGState()
        ctx.concatenate(xform)

        // Draw grid.
        drawGrid(ctx: ctx, worldBounds: wb, scale: scale)

        // Determine which commands to draw via spatial culling.
        // nil = index unavailable (draw all), [] = nothing visible, [...] = culled.
        let visibleCommands = spatiallyCulledCommands(scale: scale) ?? drawCommands

        // Draw visible entities.
        for cmd in visibleCommands {
            drawCommand(ctx: ctx, cmd: cmd, scale: scale)
        }

        // Draw annotation overlay.
        drawAnnotations(ctx: ctx, scale: scale)

        ctx.restoreGState()
    }

    /// Compute the visible commands using spatial index, with fallback to all commands.
    ///
    /// Returns `nil` when the spatial index is unavailable (fallback to full draw).
    /// Returns `[]` when the viewport legitimately contains no visible commands.
    private func spatiallyCulledCommands(scale: CGFloat) -> [DrawCommandDTO]? {
        guard let queryFn = spatialQueryFunc, !drawCommands.isEmpty else {
            return nil // fallback
        }

        // Build the world→screen transform and invert it.
        // This is guaranteed to be consistent with draw(_:) because both
        // use worldToScreenTransform().
        let w2s = worldToScreenTransform(viewBounds: bounds)
        let s2w = w2s.inverted()

        // Map screen corners through the inverse transform.
        // Screen origin is top-left; bottom-left = (0, height), top-right = (width, 0).
        let wBL = CGPoint(x: 0, y: bounds.height).applying(s2w)
        let wTR = CGPoint(x: bounds.width, y: 0).applying(s2w)

        let vpMinX = min(wBL.x, wTR.x)
        let vpMaxX = max(wBL.x, wTR.x)
        let vpMinY = min(wBL.y, wTR.y)
        let vpMaxY = max(wBL.y, wTR.y)

        // Query spatial index via generation-guarded closure.
        // nil = index unavailable (document freed or no spatial index),
        // [] = nothing visible in this viewport.
        guard let indices = queryFn(vpMinX, vpMinY, vpMaxX, vpMaxY) else {
            return nil
        }

        // Map indices to commands, filtering out-of-bounds.
        return indices.compactMap { idx in
            idx < drawCommands.count ? drawCommands[idx] : nil
        }
    }

    private func drawGrid(ctx: CGContext, worldBounds: CGRect, scale: CGFloat) {
        let gridColor = CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 0.5)
        ctx.setStrokeColor(gridColor)
        ctx.setLineWidth(0.5 / scale)

        let gridSize = computeGridSize(worldBounds: worldBounds)
        let minX = floor(worldBounds.minX / gridSize) * gridSize
        let maxX = ceil(worldBounds.maxX / gridSize) * gridSize
        let minY = floor(worldBounds.minY / gridSize) * gridSize
        let maxY = ceil(worldBounds.maxY / gridSize) * gridSize

        ctx.beginPath()
        var x = minX
        while x <= maxX {
            ctx.move(to: CGPoint(x: x, y: minY))
            ctx.addLine(to: CGPoint(x: x, y: maxY))
            x += gridSize
        }
        var y = minY
        while y <= maxY {
            ctx.move(to: CGPoint(x: minX, y: y))
            ctx.addLine(to: CGPoint(x: maxX, y: y))
            y += gridSize
        }
        ctx.strokePath()

        // Draw axes.
        ctx.setStrokeColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 0.8))
        ctx.setLineWidth(1.0 / scale)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: minX, y: 0))
        ctx.addLine(to: CGPoint(x: maxX, y: 0))
        ctx.move(to: CGPoint(x: 0, y: minY))
        ctx.addLine(to: CGPoint(x: 0, y: maxY))
        ctx.strokePath()
    }

    private func computeGridSize(worldBounds: CGRect) -> CGFloat {
        let extent = max(worldBounds.width, worldBounds.height)
        if extent <= 0 { return 1.0 }
        let raw = extent / 10.0
        let log10Val = log10(raw)
        let exp = floor(log10Val)
        let frac = pow(10.0, log10Val - exp)
        let mantissa: CGFloat
        if frac < 1.5 { mantissa = 1 }
        else if frac < 3.5 { mantissa = 2 }
        else if frac < 7.5 { mantissa = 5 }
        else { mantissa = 10 }
        return mantissa * pow(10.0, exp)
    }

    // MARK: - Entity rendering

    private func isLayerVisible(_ layerName: String, default visible: Bool) -> Bool {
        layerVisibilityOverrides[layerName] ?? visible
    }

    /// Compute line width in world-space units.
    ///
    /// - If `weight > 0`: converts mm → points, then divides by scale so the
    ///   rendered width is independent of zoom.
    /// - If `weight == 0` (default): returns `1.0 / scale` for a stable 1px
    ///   screen line regardless of zoom level.
    private func lineWidth(_ cmd: DrawCommandDTO, scale: CGFloat) -> CGFloat {
        let weight: Double
        switch cmd {
        case .line(_, _, _, _, _, _, _, _, _, let lw, _),
             .circle(_, _, _, _, _, _, _, _, let lw, _),
             .arc(_, _, _, _, _, _, _, _, _, _, _, let lw, _),
             .polyline(_, _, _, _, _, _, _, let lw, _):
            weight = lw
        case .text:
            weight = 0
        }
        // Line weight in mm → points.  Default 0 means 1px screen.
        if weight > 0 {
            return CGFloat(weight) * 2.835 / scale // 1mm ≈ 2.835pt
        }
        // Stable 1px line: divide by scale so it stays 1 screen pixel.
        return 1.0 / scale
    }

    /// Resolve the dash pattern for a command.
    ///
    /// Uses the command's LTYPE-derived dash pattern if available,
    /// otherwise falls back to a name-based lookup for standard patterns.
    private func lineDashPattern(_ cmd: DrawCommandDTO) -> [CGFloat]? {
        let (lineDash, lineType) = extractDashAndType(cmd)

        // Use LTYPE-derived dash pattern if available.
        // Convert zero-length dashes (DXF dots) to a visible small value.
        if !lineDash.isEmpty {
            let dotSize: CGFloat = 0.5  // visible dot length in drawing units
            return lineDash.map { val in
                let absVal = CGFloat(abs(val))
                return absVal < 1e-10 ? dotSize : absVal
            }
        }

        // Fallback: standard name-based patterns.
        guard let lt = lineType else { return nil }
        switch lt.lowercased() {
        case "dashed":       return [6, 3]
        case "dashdot":      return [6, 3, 1, 3]
        case "dashdotdot":   return [6, 3, 1, 3, 1, 3]
        case "dotted":       return [1, 3]
        case "center":       return [12, 3, 3, 3]
        case "hidden":       return [6, 3]
        case "phantom":      return [12, 3, 3, 3, 3, 3]
        case "border":       return [12, 3, 12, 3]
        case "border2":      return [6, 3, 6, 3]
        case "continuous":   return nil
        default:             return nil
        }
    }

    /// Extract dash pattern and line type name from a command.
    private func extractDashAndType(_ cmd: DrawCommandDTO) -> ([Double], String?) {
        switch cmd {
        case .line(_, _, _, _, _, _, _, _, let lt, _, let dash):
            return (dash, lt)
        case .circle(_, _, _, _, _, _, _, let lt, _, let dash):
            return (dash, lt)
        case .arc(_, _, _, _, _, _, _, _, _, _, let lt, _, let dash):
            return (dash, lt)
        case .polyline(_, _, _, _, _, _, let lt, _, let dash):
            return (dash, lt)
        case .text:
            return ([], nil)
        }
    }

    func drawCommand(ctx: CGContext, cmd: DrawCommandDTO, scale: CGFloat) {
        // Extract layer name and visibility from command.
        let layerName: String
        let visible: Bool
        let colorIdx: Int
        switch cmd {
        // line: x0, y0, x1, y1, layerIndex, layerName, colorIndex, visible, lineType, lineWeight, lineDash
        case .line(_, _, _, _, _, let ln, let ci, let v, _, _, _),
             // circle: cx, cy, r, layerIndex, layerName, colorIndex, visible, lineType, lineWeight, lineDash
             .circle(_, _, _, _, let ln, let ci, let v, _, _, _),
             // arc: cx, cy, r, start, end, ccw, layerIndex, layerName, colorIndex, visible, lineType, lineWeight, lineDash
             .arc(_, _, _, _, _, _, _, let ln, let ci, let v, _, _, _),
             // polyline: points, closed, layerIndex, layerName, colorIndex, visible, lineType, lineWeight, lineDash
             .polyline(_, _, _, let ln, let ci, let v, _, _, _):
            layerName = ln
            visible = v
            colorIdx = ci
        case .text(_, _, _, _, _, _, let ln, let ci, let v):
            layerName = ln
            visible = v
            colorIdx = ci
        }

        guard isLayerVisible(layerName, default: visible) else { return }

        let lw = lineWidth(cmd, scale: scale)
        let dash = lineDashPattern(cmd)

        switch cmd {
        case .line(let x0, let y0, let x1, let y1, _, _, _, _, _, _, _):
            ctx.setStrokeColor(aciColor(colorIdx))
            ctx.setLineWidth(lw)
            if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
            else { ctx.setLineDash(phase: 0, lengths: []) }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x0, y: y0))
            ctx.addLine(to: CGPoint(x: x1, y: y1))
            ctx.strokePath()

        case .circle(let cx, let cy, let r, _, _, _, _, _, _, _):
            ctx.setStrokeColor(aciColor(colorIdx))
            ctx.setLineWidth(lw)
            if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
            else { ctx.setLineDash(phase: 0, lengths: []) }
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            ctx.strokeEllipse(in: rect)

        case .arc(let cx, let cy, let r, let startAngle, let endAngle, let ccw,
                  _, _, _, _, _, _, _):
            ctx.setStrokeColor(aciColor(colorIdx))
            ctx.setLineWidth(lw)
            if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
            else { ctx.setLineDash(phase: 0, lengths: []) }
            ctx.beginPath()
            ctx.addArc(center: CGPoint(x: cx, y: cy),
                       radius: CGFloat(r),
                       startAngle: CGFloat(startAngle),
                       endAngle: CGFloat(endAngle),
                       clockwise: !ccw)
            ctx.strokePath()

        case .polyline(let points, let closed, _, _, _, _, _, _, _):
            guard !points.isEmpty else { return }
            ctx.setStrokeColor(aciColor(colorIdx))
            ctx.setLineWidth(lw)
            if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
            else { ctx.setLineDash(phase: 0, lengths: []) }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for i in 1..<points.count {
                ctx.addLine(to: CGPoint(x: points[i].0, y: points[i].1))
            }
            if closed && points.count > 1 {
                ctx.closePath()
            }
            ctx.strokePath()

        case .text(let x, let y, let content, let height, let rotation,
                   _, _, _, _):
            guard !content.isEmpty else { return }
            let fontSize = max(1.0, CGFloat(height))
            let font = NSFont.systemFont(ofSize: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(cgColor: aciColor(colorIdx))!,
            ]
            let nsString = content as NSString

            ctx.saveGState()
            ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
            ctx.rotate(by: CGFloat(rotation) * .pi / 180.0)
            ctx.scaleBy(x: 1.0, y: -1.0)
            nsString.draw(at: CGPoint(x: 0, y: 0), withAttributes: attrs)
            ctx.restoreGState()
        }

        // Reset line dash after each command.
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: - Annotation Overlay

    func drawAnnotations(ctx: CGContext, scale: CGFloat) {
        // Draw completed annotations.
        for ann in annotations {
            drawAnnotation(ctx: ctx, annotation: ann, scale: scale)
        }

        // Draw pending measurement preview.
        if measurementMode {
            drawPendingAnnotation(ctx: ctx, scale: scale)
        }
    }

    private func drawAnnotation(ctx: CGContext, annotation: Annotation, scale: CGFloat) {
        let color = annotation.color.cgColor

        switch annotation.kind {
        case .measurement(let start, let end):
            drawMeasurementLine(ctx: ctx, start: start, end: end,
                                color: color, scale: scale)

        case .angleMeasurement(let vertex, let p1, let p2):
            drawAngleAnnotation(ctx: ctx, vertex: vertex, p1: p1, p2: p2,
                                color: color, scale: scale)

        case .areaMeasurement(let points):
            drawAreaAnnotation(ctx: ctx, points: points,
                               color: color, scale: scale)

        case .dimension(let start, let end, let offset):
            drawDimension(ctx: ctx, start: start, end: end, offset: offset,
                          color: color, scale: scale)

        case .textAnnotation(let position, let text, let fontSize):
            drawTextAnnotation(ctx: ctx, position: position, text: text,
                               fontSize: fontSize, color: color, scale: scale)

        case .arrowAnnotation(let tail, let head, let text):
            drawArrowAnnotation(ctx: ctx, tail: tail, head: head, text: text,
                                color: color, scale: scale)
        }
    }

    private func drawPendingAnnotation(ctx: CGContext, scale: CGFloat) {
        let lineW = 1.5 / scale
        let markerR = 4.0 / scale

        // Draw pending point marker.
        if let pending = pendingAnnotationPoint {
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setFillColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(lineW)
            ctx.setLineDash(phase: 0, lengths: [])

            // Cross marker.
            ctx.beginPath()
            ctx.move(to: CGPoint(x: pending.x - markerR, y: pending.y))
            ctx.addLine(to: CGPoint(x: pending.x + markerR, y: pending.y))
            ctx.move(to: CGPoint(x: pending.x, y: pending.y - markerR))
            ctx.addLine(to: CGPoint(x: pending.x, y: pending.y + markerR))
            ctx.strokePath()
        }

        // Draw pending polygon preview for area measurement.
        if measurementType == .area && pendingPolygonPoints.count >= 2 {
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(lineW)
            ctx.setLineDash(phase: 0, lengths: [4 / scale, 4 / scale])
            ctx.beginPath()
            ctx.move(to: pendingPolygonPoints[0])
            for i in 1..<pendingPolygonPoints.count {
                ctx.addLine(to: pendingPolygonPoints[i])
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Draw pending angle preview.
        if measurementType == .angle && pendingPolygonPoints.count == 2 {
            let vertex = pendingPolygonPoints[0]
            let p1 = pendingPolygonPoints[1]
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(lineW)
            ctx.setLineDash(phase: 0, lengths: [4 / scale, 4 / scale])
            ctx.beginPath()
            ctx.move(to: vertex)
            ctx.addLine(to: p1)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    private func drawMeasurementLine(ctx: CGContext, start: CGPoint, end: CGPoint,
                                     color: CGColor, scale: CGFloat) {
        let lineW = 1.5 / scale
        let markerR = 4.0 / scale

        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineW)
        ctx.setLineDash(phase: 0, lengths: [6 / scale, 3 / scale])

        // Measurement line.
        ctx.beginPath()
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Endpoint markers.
        for pt in [start, end] {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: pt.x - markerR, y: pt.y - markerR))
            ctx.addLine(to: CGPoint(x: pt.x + markerR, y: pt.y + markerR))
            ctx.move(to: CGPoint(x: pt.x - markerR, y: pt.y + markerR))
            ctx.addLine(to: CGPoint(x: pt.x + markerR, y: pt.y - markerR))
            ctx.strokePath()
        }

        // Distance label at midpoint.
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dist = Geometry2D.distance(start, end)
        let label = String(format: "%.2f", dist)
        drawLabel(ctx: ctx, text: label, at: mid, color: color, scale: scale)
    }

    private func drawAngleAnnotation(ctx: CGContext, vertex: CGPoint,
                                     p1: CGPoint, p2: CGPoint,
                                     color: CGColor, scale: CGFloat) {
        let lineW = 1.5 / scale
        let markerR = 4.0 / scale

        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineW)
        ctx.setLineDash(phase: 0, lengths: [])

        // Draw rays.
        ctx.beginPath()
        ctx.move(to: vertex)
        ctx.addLine(to: p1)
        ctx.move(to: vertex)
        ctx.addLine(to: p2)
        ctx.strokePath()

        // Vertex marker.
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(
            x: vertex.x - markerR, y: vertex.y - markerR,
            width: markerR * 2, height: markerR * 2))

        // Angle arc.
        let v1 = CGVector(dx: p1.x - vertex.x, dy: p1.y - vertex.y)
        let v2 = CGVector(dx: p2.x - vertex.x, dy: p2.y - vertex.y)
        let a1 = atan2(v1.dy, v1.dx)
        let a2 = atan2(v2.dy, v2.dx)
        let arcR = min(Geometry2D.distance(vertex, p1), Geometry2D.distance(vertex, p2)) * 0.3

        ctx.beginPath()
        ctx.addArc(center: vertex, radius: arcR,
                   startAngle: a1, endAngle: a2, clockwise: false)
        ctx.strokePath()

        // Angle label.
        let angleDeg = Geometry2D.angleDegrees(vertex: vertex, p1: p1, p2: p2)
        let midAngle = (a1 + a2) / 2
        let labelPos = CGPoint(
            x: vertex.x + arcR * 1.3 * cos(midAngle),
            y: vertex.y + arcR * 1.3 * sin(midAngle))
        drawLabel(ctx: ctx, text: String(format: "%.1f°", angleDeg),
                  at: labelPos, color: color, scale: scale)
    }

    private func drawAreaAnnotation(ctx: CGContext, points: [CGPoint],
                                    color: CGColor, scale: CGFloat) {
        guard points.count >= 3 else { return }
        let lineW = 1.5 / scale

        // Semi-transparent fill.
        ctx.setFillColor(color.copy(alpha: 0.15) ?? color)
        ctx.beginPath()
        ctx.move(to: points[0])
        for i in 1..<points.count {
            ctx.addLine(to: points[i])
        }
        ctx.closePath()
        ctx.fillPath()

        // Outline.
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineW)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.beginPath()
        ctx.move(to: points[0])
        for i in 1..<points.count {
            ctx.addLine(to: points[i])
        }
        ctx.closePath()
        ctx.strokePath()

        // Area label at centroid.
        let area = Geometry2D.area(points)
        if let centroid = Geometry2D.centroid(points) {
            let label = String(format: "%.2f", area)
            drawLabel(ctx: ctx, text: label, at: centroid, color: color, scale: scale)
        }
    }

    private func drawDimension(ctx: CGContext, start: CGPoint, end: CGPoint,
                               offset: CGFloat, color: CGColor, scale: CGFloat) {
        let lineW = 1.5 / scale
        let dist = Geometry2D.distance(start, end)
        let label = String(format: "%.2f", dist)

        // Compute dimension line direction (perpendicular to measurement direction).
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1e-10 else { return }
        let nx = -dy / len * offset
        let ny = dx / len * offset

        let dStart = CGPoint(x: start.x + nx, y: start.y + ny)
        let dEnd = CGPoint(x: end.x + nx, y: end.y + ny)

        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineW)
        ctx.setLineDash(phase: 0, lengths: [])

        // Extension lines.
        ctx.beginPath()
        ctx.move(to: start); ctx.addLine(to: dStart)
        ctx.move(to: end); ctx.addLine(to: dEnd)
        ctx.strokePath()

        // Dimension line with arrowheads.
        ctx.beginPath()
        ctx.move(to: dStart)
        ctx.addLine(to: dEnd)
        ctx.strokePath()

        // Arrowheads.
        drawArrowhead(ctx: ctx, from: dStart, to: dEnd, size: 8 / scale, color: color)
        drawArrowhead(ctx: ctx, from: dEnd, to: dStart, size: 8 / scale, color: color)

        // Label at midpoint of dimension line.
        let mid = CGPoint(x: (dStart.x + dEnd.x) / 2, y: (dStart.y + dEnd.y) / 2)
        drawLabel(ctx: ctx, text: label, at: mid, color: color, scale: scale)
    }

    private func drawTextAnnotation(ctx: CGContext, position: CGPoint,
                                    text: String, fontSize: CGFloat,
                                    color: CGColor, scale: CGFloat) {
        let font = NSFont.systemFont(ofSize: max(8, fontSize) / scale)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let nsString = text as NSString
        let size = nsString.size(withAttributes: attrs)

        // Background rect.
        let pad: CGFloat = 2 / scale
        let bgRect = CGRect(
            x: position.x - pad, y: position.y - pad,
            width: size.width + pad * 2, height: size.height + pad * 2)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 0.8))
        ctx.fill(bgRect)

        nsString.draw(at: position, withAttributes: attrs)
    }

    private func drawArrowAnnotation(ctx: CGContext, tail: CGPoint, head: CGPoint,
                                     text: String?, color: CGColor, scale: CGFloat) {
        let lineW = 1.5 / scale

        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineW)
        ctx.setLineDash(phase: 0, lengths: [])

        // Arrow shaft.
        ctx.beginPath()
        ctx.move(to: tail)
        ctx.addLine(to: head)
        ctx.strokePath()

        // Arrowhead.
        drawArrowhead(ctx: ctx, from: tail, to: head, size: 10 / scale, color: color)

        // Optional label.
        if let text, !text.isEmpty {
            let labelPos = CGPoint(x: tail.x - 10 / scale, y: tail.y - 10 / scale)
            drawLabel(ctx: ctx, text: text, at: labelPos, color: color, scale: scale)
        }
    }

    private func drawArrowhead(ctx: CGContext, from: CGPoint, to: CGPoint,
                               size: CGFloat, color: CGColor) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1e-10 else { return }
        let ux = dx / len
        let uy = dy / len
        let px = -uy  // perpendicular
        let py = ux

        ctx.setFillColor(color)
        ctx.beginPath()
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - ux * size + px * size * 0.4,
                                y: to.y - uy * size + py * size * 0.4))
        ctx.addLine(to: CGPoint(x: to.x - ux * size - px * size * 0.4,
                                y: to.y - uy * size - py * size * 0.4))
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawLabel(ctx: CGContext, text: String, at point: CGPoint,
                           color: CGColor, scale: CGFloat) {
        let font = NSFont.systemFont(ofSize: max(8, 11.0) / scale)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let nsString = text as NSString
        let size = nsString.size(withAttributes: attrs)
        let pad: CGFloat = 2 / scale

        // Background.
        let bgRect = CGRect(
            x: point.x - pad, y: point.y - pad,
            width: size.width + pad * 2, height: size.height + pad * 2)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 0.85))
        ctx.fill(bgRect)

        nsString.draw(at: point, withAttributes: attrs)
    }

    // MARK: - Draw Command Filtering

    /// Filter draw commands by layer visibility.
    ///
    /// Returns only commands whose layer is visible according to the
    /// provided overrides.  This is the same logic used by `drawCommand`
    /// but extracted for testability.
    static func visibleCommands(
        _ commands: [DrawCommandDTO],
        layerVisibility: [String: Bool]
    ) -> [DrawCommandDTO] {
        commands.filter { cmd in
            let layerName: String
            let defaultVisible: Bool
            switch cmd {
            case .line(_, _, _, _, _, let ln, _, let v, _, _, _):
                layerName = ln; defaultVisible = v
            case .circle(_, _, _, _, let ln, _, let v, _, _, _):
                layerName = ln; defaultVisible = v
            case .arc(_, _, _, _, _, _, _, let ln, _, let v, _, _, _):
                layerName = ln; defaultVisible = v
            case .polyline(_, _, _, let ln, _, let v, _, _, _):
                layerName = ln; defaultVisible = v
            case .text(_, _, _, _, _, _, let ln, _, let v):
                layerName = ln; defaultVisible = v
            }
            return layerVisibility[layerName] ?? defaultVisible
        }
    }

    // MARK: - PDF Rendering (static, reused by DocumentViewModel)

    /// Coordinate contract for PDF rendering:
    ///
    /// `renderPDF` applies two transforms to the CGContext:
    ///
    ///   1. Page-level Y-flip: `translate(0, pageH); scale(1, -1)`
    ///      Converts native PDF coords (origin bottom-left, Y-up) into
    ///      screen-like coords (origin top-left, Y-down).
    ///
    ///   2. `pdfPageTransform` with `d = -s`:
    ///      Maps world coords into the centered drawing area.
    ///
    /// Composite (verified via CGBitmapContext pixel inspection):
    ///   Red (world top) renders at smaller image Y (visually above).
    ///   Blue (world bottom) renders at larger image Y (visually below).
    ///   World center → page center.
    ///   All four world corners inside page.
    ///   Text right-side up.

    /// The affine that maps world coords into the drawing area.
    ///
    /// Uses `d = -s` so that after the page-level Y-flip, world top
    /// (maxY) maps to smaller image Y (visually above).
    ///
    /// tx = originX - s * wb.minX
    /// ty = originY + s * wb.maxY
    /// where originX/Y center the drawing on the page.
    static func pdfPageTransform(
        worldBounds wb: CGRect,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat
    ) -> CGAffineTransform {
        let drawW = pageWidth - margin * 2
        let drawH = pageHeight - margin * 2
        let scaleX = drawW / max(wb.width, 0.001)
        let scaleY = drawH / max(wb.height, 0.001)
        let s = min(scaleX, scaleY)

        let originX = (pageWidth - wb.width * s) / 2
        let originY = (pageHeight - wb.height * s) / 2

        return CGAffineTransform(
            a: s, b: 0, c: 0, d: -s,
            tx: originX - s * wb.minX,
            ty: originY + s * wb.maxY
        )
    }

    static func renderPDF(
        ctx: CGContext,
        commands: [DrawCommandDTO],
        annotations: [Annotation],
        layerVisibility: [String: Bool],
        worldBounds wb: CGRect,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat
    ) {
        let drawW = pageWidth - margin * 2
        let drawH = pageHeight - margin * 2
        let scaleX = drawW / max(wb.width, 0.001)
        let scaleY = drawH / max(wb.height, 0.001)
        let pdfScale = min(scaleX, scaleY)

        let pdfFrame = pdfPageTransform(
            worldBounds: wb, pageWidth: pageWidth,
            pageHeight: pageHeight, margin: margin)

        let tmpView = Drawing2DView()
        tmpView.layerVisibilityOverrides = layerVisibility
        tmpView.annotations = annotations

        ctx.beginPDFPage(nil)
        ctx.saveGState()

        // Step 1: Page-level Y-flip.
        ctx.translateBy(x: 0, y: pageHeight)
        ctx.scaleBy(x: 1, y: -1)

        // Step 2: World→drawing-area (d=-s).
        ctx.concatenate(pdfFrame)

        for cmd in commands {
            tmpView.drawCommand(ctx: ctx, cmd: cmd, scale: pdfScale)
        }
        tmpView.drawAnnotations(ctx: ctx, scale: pdfScale)

        ctx.restoreGState()
        ctx.endPDFPage()
    }

    /// Render a 2D drawing into an image using the same view drawing pipeline as
    /// the on-screen DXF viewport.
    static func renderImage(
        commands: [DrawCommandDTO],
        drawingInfo: Drawing2DInfo,
        annotations: [Annotation],
        layerVisibility: [String: Bool],
        pixelWidth: Int,
        pixelHeight: Int
    ) -> NSImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelWidth,
                  pixelsHigh: pixelHeight,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bitmapFormat: [],
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else {
            return nil
        }

        let size = NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let view = Drawing2DView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        view.drawCommands = commands
        view.drawingInfo = drawingInfo
        view.layerVisibilityOverrides = layerVisibility
        view.annotations = annotations

        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Gestures

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        panOffset.x += event.deltaX
        panOffset.y -= event.deltaY
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let zoomFactor: CGFloat = 1.0 + event.scrollingDeltaY * 0.01
        zoomLevel = max(0.01, min(1000, zoomLevel * zoomFactor))
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let zoomFactor: CGFloat = 1.0 + event.magnification
        zoomLevel = max(0.01, min(1000, zoomLevel * zoomFactor))
        needsDisplay = true
    }

    /// Reset view to fit the entire drawing.
    func fitToView() {
        panOffset = .zero
        zoomLevel = 1.0
        needsDisplay = true
    }
}

// MARK: - Annotation Delegate

protocol Drawing2DAnnotationDelegate: AnyObject {
    func didCompleteMeasurement(start: CGPoint, end: CGPoint)
    func didCompleteAngleMeasurement(vertex: CGPoint, p1: CGPoint, p2: CGPoint)
    func didCompleteAreaMeasurement(points: [CGPoint])
    func didSetPendingPoint(_ point: CGPoint)
    func didSetPendingAngleVertex(_ point: CGPoint)
    func didSetPendingAngleRay(_ point: CGPoint)
    func didAddPolygonPoint(_ point: CGPoint)
    func didCancelPending()
    func didPlaceTextAnnotation(at position: CGPoint, text: String)
    func didCompleteArrowAnnotation(tail: CGPoint, head: CGPoint)
    func didCompleteDimensionAnnotation(start: CGPoint, end: CGPoint)
}

// MARK: - NSViewRepresentable wrapper

struct Drawing2DViewRepresentable: NSViewRepresentable {
    let drawCommands: [DrawCommandDTO]
    let drawingInfo: Drawing2DInfo?
    let layerVisibilityOverrides: [String: Bool]
    let spatialQueryFunc: ((Double, Double, Double, Double) -> [Int]?)?
    let annotations: [Annotation]
    let measurementMode: Bool
    let measurementType: MeasurementType
    let snapEnabled: Bool
    let activeAnnotationTool: AnnotationTool?
    let annotationToolText: String
    let pendingAnnotationPoint: CGPoint?
    let pendingPolygonPoints: [CGPoint]
    let annotationDelegate: Drawing2DAnnotationDelegate?

    func makeNSView(context: Context) -> Drawing2DView {
        let view = Drawing2DView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: Drawing2DView, context: Context) {
        nsView.drawCommands = drawCommands
        nsView.drawingInfo = drawingInfo
        nsView.layerVisibilityOverrides = layerVisibilityOverrides
        nsView.spatialQueryFunc = spatialQueryFunc
        nsView.annotations = annotations
        nsView.measurementMode = measurementMode
        nsView.measurementType = measurementType
        nsView.snapEnabled = snapEnabled
        nsView.activeAnnotationTool = activeAnnotationTool
        nsView.annotationToolText = annotationToolText
        nsView.pendingAnnotationPoint = pendingAnnotationPoint
        nsView.pendingPolygonPoints = pendingPolygonPoints
        nsView.annotationDelegate = annotationDelegate
    }
}
