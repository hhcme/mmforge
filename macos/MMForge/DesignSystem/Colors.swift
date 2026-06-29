import SwiftUI

/// Design system color tokens for MMForge.
/// Uses system colors where possible to support Dark Mode automatically.
extension Color {
    // Viewport
    static let viewportBackground = Color(nsColor: .controlBackgroundColor)
    static let gridLine = Color.primary.opacity(0.1)
    static let axisX = Color.red
    static let axisY = Color.green
    static let axisZ = Color.blue

    // Selection
    static let selectionHighlight = Color.accentColor
    static let hoverHighlight = Color.accentColor.opacity(0.3)

    // Status
    static let warning = Color.orange
    static let error = Color.red
    static let success = Color.green
}
