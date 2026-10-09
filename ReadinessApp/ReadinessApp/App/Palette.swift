import SwiftUI
import UIKit

/// Semantic colours. Muted and desaturated so the app stays calm at night; each token has a light and a
/// dark variant (dark ≈ 70–80 % lightness for contrast on dark cards, light ≈ 40–45 % on white).
/// Use these instead of the saturated system colours (.red, .green, …).
enum Palette {
    /// Tint for controls, selection and the week strip: calm ocean teal.
    static let accent = Color(light: 0x2F7F8E, dark: 0x6FB7C4)
    /// Good / inside the normal range: sage.
    static let good = Color(light: 0x3E8E5E, dark: 0x8CC7A1)
    /// Slightly off: soft amber.
    static let caution = Color(light: 0xA97A1C, dark: 0xE3C07A)
    /// Clearly off, illness warning: muted coral, never fire-engine red.
    static let alert = Color(light: 0xC0564B, dark: 0xE58F86)
    /// Building the baseline, settling: lavender.
    static let calm = Color(light: 0x6C63C7, dark: 0xA9A3E0)
    /// Live measurement progress and the beat-to-beat line: fresh mint, a "this is going well" colour.
    static let measure = Color(light: 0x2E9C7E, dark: 0x7FD1B9)

    // Identity colours of the three daily numbers: what each one measures, not whether it is good.
    // Good/bad stays with the level label (good / caution / alert) under each ring.
    /// Regeneration, your HRV against your normal (rest and recover): night blue.
    static let regeneration = Color(light: 0x3F63C0, dark: 0x8AA8F0)
    /// Readiness, energy for the day: fresh spring green.
    static let readiness = Color(light: 0x4F8A1F, dark: 0xA8D672)
    /// Stress, strain / load (mostly resting HR): warm rose, kept apart from the coral alert.
    static let stress = Color(light: 0xB54A82, dark: 0xE88AB8)

    /// Text on an accent-filled button: white on the deep light-mode teal, near-black on the pale dark-mode one.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0F2629)
}

extension View {
    /// The filled main action, with label contrast that holds in both modes.
    func prominentButton() -> some View {
        buttonStyle(.borderedProminent).foregroundStyle(Palette.onAccent)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// App-wide light/dark choice. Dark by default: the measurement usually happens in a dim room.
enum Appearance: String, CaseIterable, Identifiable {
    case dark, system, light
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .system: return "System"
        case .light: return "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .system: return nil
        case .light: return .light
        }
    }
}
