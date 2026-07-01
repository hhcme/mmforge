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
/// toggled per-layer.
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

    /// Viewport state: pan offset and zoom level.
    private var panOffset: CGPoint = .zero
    private var zoomLevel: CGFloat = 1.0

    /// World-space bounds of the drawing.
    private var worldBounds: CGRect {
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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Clear background.
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0))
        ctx.fill(bounds)

        // Compute transform: world → screen.
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let wb = worldBounds
        let worldCenter = CGPoint(x: wb.midX, y: wb.midY)

        // Scale to fit the drawing in the view with margin.
        let margin: CGFloat = 40
        let scaleX = (bounds.width - margin * 2) / max(wb.width, 0.001)
        let scaleY = (bounds.height - margin * 2) / max(wb.height, 0.001)
        let fitScale = min(scaleX, scaleY)

        ctx.saveGState()

        // Move to view center, apply zoom, apply pan, center world.
        ctx.translateBy(x: viewCenter.x, y: viewCenter.y)
        ctx.scaleBy(x: zoomLevel * fitScale, y: zoomLevel * fitScale)
        ctx.translateBy(x: panOffset.x / (zoomLevel * fitScale),
                        y: panOffset.y / (zoomLevel * fitScale))
        ctx.translateBy(x: -worldCenter.x, y: -worldCenter.y)

        // Flip Y axis (DXF Y-up → screen Y-down).
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: -wb.midY * 2)

        // Draw grid.
        drawGrid(ctx: ctx, worldBounds: wb, scale: zoomLevel * fitScale)

        // Draw all entities.
        let scale = zoomLevel * fitScale
        for cmd in drawCommands {
            drawCommand(ctx: ctx, cmd: cmd, scale: scale)
        }

        ctx.restoreGState()
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

    private func lineWidth(_ cmd: DrawCommandDTO, scale: CGFloat) -> CGFloat {
        let weight: Double
        switch cmd {
        case .line(_, _, _, _, _, _, _, _, _, let lw),
             .circle(_, _, _, _, _, _, _, _, let lw),
             .arc(_, _, _, _, _, _, _, _, _, _, _, let lw),
             .polyline(_, _, _, _, _, _, _, let lw):
            weight = lw
        case .text:
            weight = 0
        }
        // Line weight in mm → points.  Default 0 means 1px.
        if weight > 0 {
            return CGFloat(weight) * 2.835 / scale // 1mm ≈ 2.835pt
        }
        return 1.0
    }

    private func lineDashPattern(_ cmd: DrawCommandDTO) -> [CGFloat]? {
        let lineType: String?
        switch cmd {
        case .line(_, _, _, _, _, _, _, _, let lt, _),
             .circle(_, _, _, _, _, _, _, let lt, _),
             .arc(_, _, _, _, _, _, _, _, _, _, let lt, _),
             .polyline(_, _, _, _, _, _, let lt, _):
            lineType = lt
        case .text:
            lineType = nil
        }
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

    private func drawCommand(ctx: CGContext, cmd: DrawCommandDTO, scale: CGFloat) {
        // Extract layer name and visibility from command.
        let layerName: String
        let visible: Bool
        let colorIdx: Int
        switch cmd {
        case .line(_, _, _, _, _, let ln, let ci, let v, _, _),
             .circle(_, _, _, _, let ln, let ci, let v, _, _),
             .arc(_, _, _, _, _, _, _, let ln, let ci, let v, _, _),
             .polyline(_, _, _, let ln, let ci, let v, _, _),
             .text(_, _, _, _, _, _, let ln, let ci, let v):
            layerName = ln
            visible = v
            colorIdx = ci
        }

        guard isLayerVisible(layerName, default: visible) else { return }

        let lw = lineWidth(cmd, scale: scale)
        let dash = lineDashPattern(cmd)

        switch cmd {
        case .line(let x0, let y0, let x1, let y1, _, _, _, _, _, _):
            ctx.setStrokeColor(aciColor(colorIdx))
            ctx.setLineWidth(lw)
            if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
            else { ctx.setLineDash(phase: 0, lengths: []) }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x0, y: y0))
            ctx.addLine(to: CGPoint(x: x1, y: y1))
            ctx.strokePath()

        case .circle(let cx, let cy, let r, _, _, _, _, _, _):
            ctx.setStrokeColor(aciColor(colorIdx))
            ctx.setLineWidth(lw)
            if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
            else { ctx.setLineDash(phase: 0, lengths: []) }
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            ctx.strokeEllipse(in: rect)

        case .arc(let cx, let cy, let r, let startAngle, let endAngle, let ccw,
                  _, _, _, _, _, _):
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

        case .polyline(let points, let closed, _, _, _, _, _, _):
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

    func makeNSView(context: Context) -> Drawing2DView {
        let view = Drawing2DView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: Drawing2DView, context: Context) {
        nsView.drawCommands = drawCommands
        nsView.drawingInfo = drawingInfo
        nsView.layerVisibilityOverrides = layerVisibilityOverrides
    }
}
