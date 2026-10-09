import SwiftUI

/// "78 % · today 19:42" with a battery symbol matching the level; coral when it is time to charge.
struct BatteryLabel: View {
    let percent: Int
    var date: Date?

    var body: some View {
        Label {
            Text(text).monospacedDigit()
        } icon: {
            Image(systemName: Self.symbol(percent))
        }
        .foregroundStyle(isLow ? Palette.alert : .secondary)
        .accessibilityLabel("Sensor battery \(percent) percent\(isLow ? ", charge it soon" : "")")
    }

    private var isLow: Bool { percent < AppSettings.lowBatteryPercent }

    private var text: String {
        guard let date else { return "\(percent) %" }
        return "\(percent) % · \(Self.when(date))"
    }

    static func symbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// "today 19:42", "yesterday 07:05", or "3 Oct".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today \(time)" }
        if cal.isDateInYesterday(date) { return "yesterday \(time)" }
        return Fmt.shortDay.string(from: date)
    }
}
