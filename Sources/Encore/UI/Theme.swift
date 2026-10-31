import AppKit
import SwiftUI

/// Encore's visual language: midnight surfaces, a coral → magenta → violet
/// signature gradient, soft glass, and rounded type.
enum Theme {
    enum Palette {
        static let coral = Color(red: 1.00, green: 0.33, blue: 0.40)
        static let magenta = Color(red: 0.93, green: 0.22, blue: 0.62)
        static let violet = Color(red: 0.55, green: 0.32, blue: 1.00)
        static let ember = Color(red: 1.00, green: 0.58, blue: 0.30)

        static let background = Color(red: 0.043, green: 0.039, blue: 0.063)
        static let backgroundNS = NSColor(red: 0.043, green: 0.039, blue: 0.063, alpha: 1)
        static let surface = Color.white.opacity(0.06)
        static let surfaceStrong = Color.white.opacity(0.10)
        static let stroke = Color.white.opacity(0.09)
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.38)
    }

    static let signature = LinearGradient(
        colors: [Palette.coral, Palette.magenta, Palette.violet],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static func gradient(_ palette: ArtworkPalette, colorsFromArtwork: Bool) -> [Color] {
        colorsFromArtwork ? palette.gradient : ArtworkPalette.brand.gradient
    }

    enum Fonts {
        static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
        static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
        static func body(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .rounded) }
        static func mono(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .rounded).monospacedDigit() }
    }
}

extension View {
    /// Frosted card used for floating controls.
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.Palette.stroke, lineWidth: 1)
                )
        )
    }
}

/// Time formatting for scrubbers.
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
