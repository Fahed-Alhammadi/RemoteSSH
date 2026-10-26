import AppKit
import SwiftUI

/// "Ink & Teal" design tokens. Mirrors the CSS variables in electron/src/renderer/styles.css.
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

    /// The terminal is always ink (the icon's ">_" surface), in both appearances. Mirrors the --term-* CSS variables.
    enum Terminal {
        static let background = rgb(0x0A1019)
        static let foreground = rgb(0xE6EDF3)
        static let cursor = rgb(0x2DD4BF)
        static let selection = rgb(0x2DD4BF, alpha: 0.3)
        /// ANSI 0–15: black, red, green, yellow, blue, magenta, cyan, white, then the bright variants.
        static let ansi: [UInt32] = [
            0x484F58, 0xF87171, 0x4ADE80, 0xFACC15, 0x60A5FA, 0xA78BFA, 0x2DD4BF, 0xC9D1D9,
            0x8D9AA9, 0xF87171, 0x4ADE80, 0xFACC15, 0x60A5FA, 0xA78BFA, 0x2DD4BF, 0xF0F6FC,
        ]
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    static func adaptive(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: alpha)
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
