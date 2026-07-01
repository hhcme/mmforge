import AppKit
import SwiftUI
import simd

/// A 2D drawing view using Core Graphics.
///
/// Renders DXF drawing entities (lines, circles, arcs, polylines, text)
/// with pan, zoom, and fit-to-view support.  Layer visibility can be
/// toggled per-layer.
class Drawing2DView: NSView {
    /// Parsed draw list data from the Rust bridge.
    var drawingInfo: Drawing2DInfo? {
        didSet { needsDisplay = true }
    }

    /// Layer visibility overrides (layer name → visible).
    var layerVisibility: [String: Bool] = [:] {
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

        guard let info = drawingInfo else { return }

        // Compute transform: world → screen.
        // 1. Translate to center of view.
        // 2. Apply zoom.
        // 3. Apply pan offset.
        // 4. Translate world origin to view center.
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let wb = worldBounds
        let worldCenter = CGPoint(x: wb.midX, y: wb.midY)

        // Scale to fit the drawing in the view with some margin.
        let margin: CGFloat = 40
        let scaleX = (bounds.width - margin * 2) / max(wb.width, 0.001)
        let scaleY = (bounds.height - margin * 2) / max(wb.height, 0.001)
        let fitScale = min(scaleX, scaleY)

        ctx.saveGState()

        // Move to view center.
        ctx.translateBy(x: viewCenter.x, y: viewCenter.y)
        // Apply zoom.
        ctx.scaleBy(x: zoomLevel * fitScale, y: zoomLevel * fitScale)
        // Apply pan.
        ctx.translateBy(x: panOffset.x / (zoomLevel * fitScale), y: panOffset.y / (zoomLevel * fitScale))
        // Center the world bounds.
        ctx.translateBy(x: -worldCenter.x, y: -worldCenter.y)

        // Flip Y axis (DXF Y-up → screen Y-down).
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.translateBy(x: 0, y: -wb.midY * 2)

        // Draw grid.
        drawGrid(ctx: ctx, worldBounds: wb, scale: zoomLevel * fitScale)

        // Draw entities grouped by layer.
        // For now, draw all entities directly since we don't have per-entity
        // layer data in the C ABI yet.  The layer visibility is handled by
        // the scene tree nodes.
        drawAllEntities(ctx: ctx, info: info)

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
        // Snap to 1, 2, 5, 10, 20, 50, ...
        let log10 = log10(raw)
        let exp = floor(log10)
        let frac = pow(10.0, log10 - exp)
        let mantissa: CGFloat
        if frac < 1.5 { mantissa = 1 }
        else if frac < 3.5 { mantissa = 2 }
        else if frac < 7.5 { mantissa = 5 }
        else { mantissa = 10 }
        return mantissa * pow(10.0, exp)
    }

    private func drawAllEntities(ctx: CGContext, info: Drawing2DInfo) {
        // We don't have per-entity data via C ABI yet.
        // For now, draw a placeholder bounding box to verify the view works.
        let wb = worldBounds
        ctx.setStrokeColor(CGColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0))
        ctx.setLineWidth(2.0)
        ctx.stroke(wb)
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
    let drawingInfo: Drawing2DInfo?
    @Binding var layerVisibility: [String: Bool]

    func makeNSView(context: Context) -> Drawing2DView {
        let view = Drawing2DView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: Drawing2DView, context: Context) {
        nsView.drawingInfo = drawingInfo
        nsView.layerVisibility = layerVisibility
    }
}
