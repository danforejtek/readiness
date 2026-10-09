import Charts
import HRVCore
import SwiftData
import SwiftUI

struct TrendsView: View {
    @Query(sort: \Morning.date) private var mornings: [Morning]
    @AppStorage(AppSettings.baselineResetsKey) private var baselineResets = ""
    @State private var rangeDays = 30
    @State private var selectedDay: Date?

    /// Mornings within the chosen range. `body` assesses all mornings once per render (the expensive part) and
    /// hands the result to every chart.
    private func inRange(_ all: [DayAssessment]) -> [DayAssessment] {
        guard let last = all.last else { return [] }
        let cutoff = Readiness.calendar.date(byAdding: .day, value: -rangeDays, to: last.day)!
        return all.filter { $0.day >= cutoff }
    }

    private func selected(in days: [DayAssessment]) -> DayAssessment? {
        guard let selectedDay else { return nil }
        return days.min { abs($0.day.timeIntervalSince(selectedDay)) < abs($1.day.timeIntervalSince(selectedDay)) }
    }

    var body: some View {
        let days = inRange(MorningStore.dayAssessments(mornings, resets: AppSettings.parseResets(baselineResets)))
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Range", selection: $rangeDays) {
                        Text("2 wk").tag(14); Text("1 mo").tag(30); Text("3 mo").tag(90)
                        Text("6 mo").tag(182); Text("1 yr").tag(365)
                    }
                    .pickerStyle(.segmented)

                    if days.isEmpty {
                        ContentUnavailableView("No data yet", systemImage: "chart.xyaxis.line",
                                               description: Text("Trends appear after your first measurements."))
                    } else {
                        if let s = selected(in: days) { SelectedDayCard(day: s) }
                        ChartCard(title: "HRV (lnRMSSD)", subtitle: "green band = your normal range · dashed = 7-day average") {
                            HRVChart(days: days, selection: $selectedDay)
                        }
                        ChartCard(title: "Resting heart rate", subtitle: "bpm · green band = your normal range") {
                            HRChart(days: days, selection: $selectedDay)
                        }
                        ChartCard(title: "Regeneration", subtitle: "0–10 · 5 = your normal · green band = normal range 4–6") {
                            IndexChart(days: days, value: \.regeneration, direction: .higherIsBetter, tint: Palette.regeneration, selection: $selectedDay)
                        }
                        ChartCard(title: "Stress", subtitle: "0–10 · 5 = your normal · higher = more strain") {
                            IndexChart(days: days, value: \.stress, direction: .lowerIsBetter, tint: Palette.stress, selection: $selectedDay)
                        }
                        ChartCard(title: "Readiness score", subtitle: "75 = your normal morning") {
                            ScoreChart(days: days, selection: $selectedDay)
                        }
                        ChartCard(title: "Breathing rate", subtitle: "breaths per minute, from the spectrum's peak · mornings without a clear peak are left out") {
                            BreathingChart(days: days, selection: $selectedDay)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Trends")
        }
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            content().frame(height: 200)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SelectedDayCard: View {
    let day: DayAssessment

    var body: some View {
        let a = day.assessment
        NavigationLink { MorningDetailView(morning: day.morning) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.day.string(from: day.morning.date)).font(.subheadline.weight(.semibold))
                    Text("lnRMSSD \(Fmt.n(a.record.lnRMSSD, 2)) · HR \(Fmt.n(a.record.meanHR)) bpm · RMSSD \(Fmt.n(a.record.rmssd)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                    if a.regeneration != nil || a.stress != nil {
                        Text("Regeneration \(Fmt.n(a.regeneration, 1)) · Stress \(Fmt.n(a.stress, 1))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(a.status.title, systemImage: a.status.symbol).font(.caption.weight(.semibold)).foregroundStyle(a.status.color)
                if let s = a.score { Text("\(s)").font(.title3.weight(.bold)).monospacedDigit() }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(a.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct HRVChart: View {
    let days: [DayAssessment]
    @Binding var selection: Date?

    var body: some View {
        Chart {
            ForEach(days) { d in
                if let r = d.assessment.lnRange {
                    AreaMark(x: .value("Day", d.day), yStart: .value("Low", r.lowerBound), yEnd: .value("High", r.upperBound))
                        .foregroundStyle(Palette.good.opacity(0.18))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(days) { d in
                if let w = d.assessment.lnWeek {
                    LineMark(x: .value("Day", d.day), y: .value("7-day", w), series: .value("Series", "7-day"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(days) { d in
                LineMark(x: .value("Day", d.day), y: .value("lnRMSSD", d.assessment.record.lnRMSSD), series: .value("Series", "lnRMSSD"))
                    .foregroundStyle(.primary.opacity(0.6))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Day", d.day), y: .value("lnRMSSD", d.assessment.record.lnRMSSD))
                    .foregroundStyle(d.assessment.status.color)
                    .symbolSize(d.assessment.illness ? 90 : days.pointSize)
            }
            if let selection {
                RuleMark(x: .value("Selected", selection)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selection)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
    }
}

struct HRChart: View {
    let days: [DayAssessment]
    @Binding var selection: Date?

    var body: some View {
        Chart {
            ForEach(days) { d in
                if let r = d.assessment.hrRange {
                    AreaMark(x: .value("Day", d.day), yStart: .value("Low", r.lowerBound), yEnd: .value("High", r.upperBound))
                        .foregroundStyle(Palette.good.opacity(0.18))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(days) { d in
                LineMark(x: .value("Day", d.day), y: .value("HR", d.assessment.record.meanHR))
                    .foregroundStyle(.primary.opacity(0.6))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Day", d.day), y: .value("HR", d.assessment.record.meanHR))
                    .foregroundStyle(d.assessment.illness ? Palette.alert : d.assessment.status.color)
                    .symbolSize(d.assessment.illness ? 90 : days.pointSize)
            }
            if let selection {
                RuleMark(x: .value("Selected", selection)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selection)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
    }
}

/// Regeneration or Stress on 0–10 with the normal band 4–6, points coloured like the verdicts.
struct IndexChart: View {
    let days: [DayAssessment]
    let value: KeyPath<Assessment, Double?>
    let direction: MetricDirection
    /// Line colour, the same identity colour as the ring on Today.
    let tint: Color
    @Binding var selection: Date?

    var body: some View {
        let band = IndexLevel.normalRange
        Chart {
            RectangleMark(yStart: .value("Low", band.lowerBound), yEnd: .value("High", band.upperBound))
                .foregroundStyle(Palette.good.opacity(0.15))
            RuleMark(y: .value("Normal", Readiness.indexCenter)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 3]))
            ForEach(days) { d in
                if let v = d.assessment[keyPath: value] {
                    LineMark(x: .value("Day", d.day), y: .value("Value", v))
                        .foregroundStyle(tint.opacity(0.8))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", d.day), y: .value("Value", v))
                        .foregroundStyle(IndexLevel(value: v, direction: direction).color)
                        .symbolSize(days.pointSize)
                }
            }
            if let selection {
                RuleMark(x: .value("Selected", selection)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: 0...10)
        .chartYAxis { AxisMarks(values: [0, 2, 4, 6, 8, 10]) }
        .chartXSelection(value: $selection)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
    }
}

extension [DayAssessment] {
    /// Smaller points when months of mornings share one chart.
    var pointSize: CGFloat { count > 120 ? 12 : count > 45 ? 22 : 40 }
}

struct ScoreChart: View {
    let days: [DayAssessment]
    @Binding var selection: Date?

    var body: some View {
        Chart {
            RuleMark(y: .value("Normal", 75)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(dash: [3, 3]))
            ForEach(days) { d in
                if let s = d.assessment.score {
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Score", s))
                        .foregroundStyle(d.assessment.status.color.opacity(0.8))
                }
            }
            if let selection {
                RuleMark(x: .value("Selected", selection)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $selection)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
    }
}

struct BreathingChart: View {
    let days: [DayAssessment]
    @Binding var selection: Date?

    var body: some View {
        Chart {
            ForEach(days) { d in
                if let b = d.assessment.record.breathingRate {
                    LineMark(x: .value("Day", d.day), y: .value("Breaths", b)).foregroundStyle(Palette.accent).interpolationMethod(.monotone)
                    PointMark(x: .value("Day", d.day), y: .value("Breaths", b)).foregroundStyle(Palette.accent).symbolSize(30)
                }
            }
            if let selection {
                RuleMark(x: .value("Selected", selection)).foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selection)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
    }
}

#Preview {
    TrendsView().modelContainer(PreviewData.container())
}
