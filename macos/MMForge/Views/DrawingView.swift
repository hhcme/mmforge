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

    /// Document pointer for spatial queries (borrowed from DocumentViewModel).
    var documentPointer: OpaquePointer?

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

        ctx.restoreGState()
    }

    /// Compute the visible commands using spatial index, with fallback to all commands.
    ///
    /// Returns `nil` when the spatial index is unavailable (fallback to full draw).
    /// Returns `[]` when the viewport legitimately contains no visible commands.
    private func spatiallyCulledCommands(scale: CGFloat) -> [DrawCommandDTO]? {
        guard let doc = documentPointer, !drawCommands.isEmpty else {
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

        // Query spatial index.  nil = index unavailable, [] = nothing visible.
        guard let indices = RustBridge.shared.spatialQuery(
            doc, minX: vpMinX, minY: vpMinY, maxX: vpMaxX, maxY: vpMaxY) else {
            return nil // spatial index unavailable → fallback to full draw
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

    private func drawCommand(ctx: CGContext, cmd: DrawCommandDTO, scale: CGFloat) {
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
                .foregroundColor: aciColor(colorIdx),
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

// MARK: - NSViewRepresentable wrapper

struct Drawing2DViewRepresentable: NSViewRepresentable {
    let drawCommands: [DrawCommandDTO]
    let drawingInfo: Drawing2DInfo?
    let layerVisibilityOverrides: [String: Bool]
    let documentPointer: OpaquePointer?

    func makeNSView(context: Context) -> Drawing2DView {
        let view = Drawing2DView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: Drawing2DView, context: Context) {
        nsView.drawCommands = drawCommands
        nsView.drawingInfo = drawingInfo
        nsView.layerVisibilityOverrides = layerVisibilityOverrides
        nsView.documentPointer = documentPointer
    }
}
