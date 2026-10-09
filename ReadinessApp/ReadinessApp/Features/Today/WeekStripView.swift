import HRVCore
import SwiftUI

/// Monday–Sunday of this week: a dot on measured mornings, today highlighted, and "5 of 7 mornings this week".
/// Tapping a measured day opens that morning.
struct WeekStripView: View {
    /// One morning per calendar day (`MorningStore.dailyMornings`).
    let daily: [Morning]
    var today = Date()

    var body: some View {
        let byDay = Dictionary(daily.map { (Readiness.calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
        let days = WeekStrip.days(containing: today, measuredDays: daily.map(\.date))
        let count = days.filter(\.measured).count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This week").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(count) of 7 mornings measured").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.date) { day in
                        if let morning = byDay[day.date] {
                            NavigationLink { MorningDetailView(morning: morning) } label: { DayCell(day: day) }
                                .buttonStyle(.plain)
                        } else {
                            DayCell(day: day)
                        }
                    }
                }
                RingGauge(fraction: Double(count) / 7, color: Palette.accent, size: 44, lineWidth: 5) {
                    Text("\(count)/7").font(.caption.weight(.bold)).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count) of 7 mornings measured this week")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DayCell: View {
    let day: WeekStrip.Day

    var body: some View {
        VStack(spacing: 4) {
            Text(Self.weekday.string(from: day.date))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(day.isToday ? Palette.accent : .secondary)
            Text(Self.dayNumber.string(from: day.date))
                .font(.subheadline.weight(day.isToday ? .bold : .regular))
                .monospacedDigit()
                .frame(width: 30, height: 30)
                .background(day.isToday ? Palette.accent.opacity(0.18) : .clear, in: Circle())
                .foregroundStyle(day.isFuture ? .tertiary : .primary)
            Circle()
                .fill(day.measured ? Palette.accent : Color.secondary.opacity(day.isFuture ? 0 : 0.25))
                .frame(width: 6, height: 6)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.day.string(from: day.date))\(day.measured ? ", measured" : "")\(day.isToday ? ", today" : "")")
    }

    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEE"); return f
    }()
    static let dayNumber: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d"); return f
    }()
}
