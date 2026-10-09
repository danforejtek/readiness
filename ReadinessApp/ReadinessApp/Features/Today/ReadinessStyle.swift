import HRVCore
import SwiftUI

extension ReadinessStatus {
    var color: Color {
        switch self {
        case .ready: return Palette.good
        case .moderate: return Palette.caution
        case .rest: return Palette.alert
        case .baseline: return Palette.calm
        }
    }

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .moderate: return "Moderate"
        case .rest: return "Rest"
        case .baseline: return "Building baseline"
        }
    }

    var subtitle: String {
        switch self {
        case .ready: return "Go for it"
        case .moderate: return "Easy to medium day"
        case .rest: return "Recovery day"
        case .baseline: return "Verdicts start after 7 mornings"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "bolt.fill"
        case .moderate: return "tortoise.fill"
        case .rest: return "bed.double.fill"
        case .baseline: return "hourglass"
        }
    }
}

enum Fmt {
    static func n(_ x: Double?, _ digits: Int = 0, unit: String = "") -> String {
        guard let x, x.isFinite else { return "–" }
        return String(format: "%.\(digits)f", x) + unit
    }

    static func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.up)))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f
    }()
}
