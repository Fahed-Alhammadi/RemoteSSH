import AppKit
import SwiftUI

/// "Ink & Teal" design tokens. Mirrors the CSS variables in desktop/src/renderer/styles.css.
enum Theme {
    /// Brand tint: teal-700 in light mode (white text 5.5:1), teal-400 in dark mode.
    static let accent = adaptive(light: 0x0F766E, dark: 0x2DD4BF)
    static let accentSoft = adaptive(light: 0x0D9488, dark: 0x2DD4BF, alpha: 0.13)
    static let folder = adaptive(light: 0x3B82F6, dark: 0x60A5FA)
    static let success = adaptive(light: 0x15803D, dark: 0x4ADE80)
    static let warning = adaptive(light: 0xEA580C, dark: 0xFB923C)
    static let danger = adaptive(light: 0xDC2626, dark: 0xF87171)
    static let upload = adaptive(light: 0x2563EB, dark: 0x60A5FA)
    static let download = success

    static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        })
    }
}

/// Rounded "Local" / "Remote" label at the start of each pane header.
struct PaneChip: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accentSoft, in: Capsule())
            .fixedSize()
    }
}

/// Connection state dot; always paired with a text label so state is not colour-only.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.25)).frame(width: 14, height: 14))
            .opacity(dim ? 0.35 : 1)
            .accessibilityHidden(true)
            .onAppear {
                guard pulsing, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) { dim = true }
            }
    }
}
