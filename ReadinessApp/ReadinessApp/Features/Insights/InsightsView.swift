import HRVCore
import SwiftData
import SwiftUI

/// What a month of mornings and check-ins says: routine, verdict vs feeling, what moves your HRV,
/// whether the illness warning caught sick days, and measurement quality. Port of the user-facing
/// sections of `hrmon analyze`; everything is recomputed from the stored mornings.
struct InsightsView: View {
    @Query(sort: \Morning.date) private var mornings: [Morning]
    @AppStorage(AppSettings.baselineResetsKey) private var baselineResets = ""

    var body: some View {
        let days = MorningStore.dayAssessments(mornings, resets: AppSettings.parseResets(baselineResets)).map {
            InsightDay(assessment: $0.assessment, feeling: $0.morning.feeling, tags: $0.morning.tags)
        }
        let report = Insights.report(days)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if report.mornings < 3 {
                        ContentUnavailableView {
                            Label("Insights need a few mornings", systemImage: "lightbulb")
                        } description: {
                            Text("Measure a few mornings and fill in how you feel afterwards. The cards appear as data comes in and sharpen over four weeks.")
                        }
                    } else {
                        if let routine = report.routine, routine.checkIns < Insights.targetCheckIns {
                            ProgressCard(checkIns: routine.checkIns)
                        }
                        FeelingCard(match: report.feeling)
                        TagsCard(effects: report.tags)
                        if let illness = report.illness { IllnessCard(check: illness) }
                        if let routine = report.routine { RoutineCard(routine: routine) }
                        if let signal = report.signal { SignalCard(signal: signal) }
                        Text("Insights compare your own mornings with each other. They are a training aid, not medical advice.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
            .navigationTitle("Insights")
        }
    }
}

// MARK: - Cards

private struct ProgressCard: View {
    let checkIns: Int

    var body: some View {
        let total = Insights.targetCheckIns
        InsightCard(title: "Insights sharpen over four weeks", symbol: "hourglass", tint: Palette.calm) {
            ProgressView(value: Double(min(checkIns, total)), total: Double(total))
                .tint(Palette.calm)
            Text("\(checkIns) of \(total) mornings with a check-in. After each measurement, tap how you feel and what applies: that is what these cards compare the numbers against.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct FeelingCard: View {
    let match: InsightsReport.FeelingMatch?

    var body: some View {
        InsightCard(title: "Does the verdict match how you feel?", symbol: "face.smiling") {
            if let match {
                if match.preliminary {
                    Badge(text: "First impression · \(match.pairs) check-ins", color: Palette.calm, symbol: "sparkles")
                }
                ForEach(match.byStatus, id: \.status) { row in
                    FeelingRow(row: row)
                }
                Label(summary(match), systemImage: symbol(match.agreement))
                    .font(.callout)
                    .foregroundStyle(color(match.agreement))
                    .padding(.top, 2)
            } else {
                Text("Appears after \(Insights.minPairs) scored mornings with a check-in. Scores start once the baseline is complete.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ m: InsightsReport.FeelingMatch) -> String {
        let r = Fmt.n(m.rho, 2)
        switch m.agreement {
        case .tracks: return "Yes. Your score follows how you feel (correlation \(r))."
        case .loose: return "Loosely. Score and feeling move together only a little (correlation \(r))."
        case .notYet: return "Not yet. So far the score does not follow how you feel (correlation \(r)). More check-ins will show whether that holds."
        }
    }

    private func symbol(_ a: InsightsReport.FeelingMatch.Agreement) -> String {
        switch a {
        case .tracks: return "checkmark.circle.fill"
        case .loose: return "circle.lefthalf.filled"
        case .notYet: return "questionmark.circle"
        }
    }

    private func color(_ a: InsightsReport.FeelingMatch.Agreement) -> Color {
        switch a {
        case .tracks: return Palette.good
        case .loose: return Palette.caution
        case .notYet: return .secondary
        }
    }
}

/// "Ready · 14 mornings · [bar] 4.1": mean feeling on mornings with this verdict, 1 awful … 5 great.
private struct FeelingRow: View {
    let row: InsightsReport.StatusFeeling

    var body: some View {
        HStack(spacing: 10) {
            Label(row.status.title, systemImage: row.status.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.status.color)
                .frame(width: 110, alignment: .leading)
            if let mean = row.meanFeeling {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(row.status.color.opacity(0.8))
                            .frame(width: max(8, geo.size.width * (mean - 1) / 4))
                    }
                }
                .frame(height: 8)
                Image(systemName: Self.feelingSymbol(mean)).foregroundStyle(.secondary).frame(width: 28)
                Text(Fmt.n(mean, 1)).font(.subheadline.weight(.semibold)).monospacedDigit()
            } else {
                Text("no mornings yet").font(.footnote).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(row.mornings) \(row.mornings == 1 ? "morning" : "mornings")")
                .font(.caption2).foregroundStyle(.secondary)
                .offset(x: 26, y: 14)
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.status.title): \(row.mornings) mornings, average feeling \(Fmt.n(row.meanFeeling, 1)) of 5")
    }

    static func feelingSymbol(_ mean: Double) -> String {
        let i = min(5, max(1, Int(mean.rounded())))
        return CheckIn.feelings.first { $0.id == i }?.symbol ?? "circle"
    }
}

private struct TagsCard: View {
    let effects: [InsightsReport.TagEffect]

    var body: some View {
        InsightCard(title: "What moves your mornings", symbol: "slider.horizontal.3") {
            if effects.isEmpty {
                Text("Tick what applies in the check-in (alcohol, poor sleep, hard training …). A tag shows up here once it is on \(Insights.minTagged) scored mornings, so you can see what it does to your HRV and resting heart rate.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(effects.sorted { $0.hrvPct < $1.hrvPct }, id: \.tag) { TagRow(effect: $0) }
                Text("Average on tagged mornings compared with your normal. HRV is RMSSD in %, heart rate is resting HR in bpm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TagRow: View {
    let effect: InsightsReport.TagEffect

    var body: some View {
        let tag = CheckIn.tags.first { $0.id == effect.tag }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(tag?.title ?? effect.tag, systemImage: tag?.symbol ?? "tag")
                    .font(.subheadline.weight(.semibold))
                Text("· \(effect.mornings)×").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("HRV \(Self.signed(effect.hrvPct)) %")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(hrvColor)
            }
            DivergingBar(value: effect.hrvPct, reference: effect.othersHrvPct, color: hrvColor)
            if let others = effect.othersHrvPct {
                Text("\(verdict) Resting HR \(Self.signed(effect.hrBpm, digits: 1)) bpm. Other mornings: HRV \(Self.signed(others)) %.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Thresholds in SD of your own HRV, the same scale the verdict uses.
    private var verdict: String {
        if effect.zHRV <= -1 { return "Clearly lowers your HRV." }
        if effect.zHRV <= -0.5 { return "Slightly lowers your HRV." }
        if effect.zHRV >= 0.5 { return "Your HRV tends to be higher." }
        return "No clear effect on your HRV."
    }

    private var hrvColor: Color {
        effect.zHRV <= -1 ? Palette.alert : effect.zHRV <= -0.5 ? Palette.caution : effect.zHRV >= 0.5 ? Palette.good : .secondary
    }

    static func signed(_ x: Double, digits: Int = 0) -> String {
        let s = Fmt.n(abs(x), digits)
        return s == Fmt.n(0, digits) ? s : (x < 0 ? "−" : "+") + s
    }
}

/// HRV change around zero (your normal), ±40 % full scale; a tick marks the other mornings.
private struct DivergingBar: View {
    let value: Double
    let reference: Double?
    let color: Color
    var span = 40.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, mid = w / 2
            let x = mid + CGFloat(max(-span, min(span, value)) / span) * mid
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1).offset(x: mid)
                Capsule().fill(color.opacity(0.8))
                    .frame(width: max(3, abs(x - mid)))
                    .offset(x: min(x, mid))
                if let reference {
                    let r = mid + CGFloat(max(-span, min(span, reference)) / span) * mid
                    Capsule().fill(Color.primary.opacity(0.45)).frame(width: 2, height: 12).offset(x: r - 1, y: 0)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

private struct IllnessCard: View {
    let check: InsightsReport.IllnessCheck

    var body: some View {
        InsightCard(title: "Illness warning", symbol: "thermometer.medium") {
            DatesRow(title: "Sick days it caught", dates: check.caught, symbol: "checkmark.circle.fill", color: Palette.good,
                     empty: "none yet")
            DatesRow(title: "Sick days it missed", dates: check.missed, symbol: "exclamationmark.circle", color: Palette.caution,
                     empty: "none")
            DatesRow(title: "Warnings without a sick tag", dates: check.unexplained, symbol: "questionmark.circle", color: .secondary,
                     empty: "none")
            Text("A warning counts if it came within two days of a morning tagged Feeling sick. Tag it whenever you are ill, even without a warning: that is how you learn whether to trust it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DatesRow: View {
    let title: String
    let dates: [Date]
    let symbol: String
    let color: Color
    let empty: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(dates.isEmpty ? empty : dates.map { Fmt.shortDay.string(from: $0) }.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RoutineCard: View {
    let routine: InsightsReport.Routine

    var body: some View {
        InsightCard(title: "Your routine", symbol: "clock") {
            Fact(title: "Measured", value: "\(routine.measuredDays) of \(routine.spanDays) days · \(Fmt.n(100 * routine.coverage)) %")
            Fact(title: "Typical time", value: "\(Self.clock(routine.typicalMinute)), half within \(Fmt.n(routine.spreadMinutes)) min")
            Fact(title: "Check-ins", value: "\(routine.checkIns) of \(routine.measuredDays) mornings")
            advice.font(.footnote).padding(.top, 2)
        }
    }

    @ViewBuilder private var advice: some View {
        if !routine.consistentTime {
            Label("Measurement times vary by more than an hour. HRV changes through the day, so a fixed time keeps mornings comparable.",
                  systemImage: "exclamationmark.triangle").foregroundStyle(Palette.caution)
        } else if !routine.enoughDays {
            Label("Fewer than 70 % of days measured. Gaps make the 7-day average and illness streaks less reliable.",
                  systemImage: "exclamationmark.triangle").foregroundStyle(Palette.caution)
        } else {
            Label("Steady routine: your mornings are comparable with each other.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.good)
        }
    }

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

private struct SignalCard: View {
    let signal: InsightsReport.Signal

    var body: some View {
        InsightCard(title: "Measurement quality", symbol: "waveform.path.ecg") {
            // Median and 90th percentile: a typical morning, and a bad one (one morning in ten is worse).
            Fact(title: "Rejected beats, typical / bad day", value: "\(Fmt.n(signal.medianArtefactPct, 1)) / \(Fmt.n(signal.p90ArtefactPct, 1)) %")
            Fact(title: "Noisy mornings", value: "\(signal.lowConfidence) of \(signal.mornings)")
            Fact(title: "Day-to-day HRV variation", value: "\(Fmt.n(signal.lnCV, 1)) %")
            Text(interpretation).font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
        }
    }

    private var interpretation: String {
        var parts: [String] = []
        if signal.p90ArtefactPct > Readiness.lowQualityArtefactPct {
            parts.append("More than one morning in ten is noisy: check how the sensor sits before reading too much into the verdicts.")
        }
        if let cv = signal.lnCV {
            if cv > 13 {
                parts.append("Your HRV varies more than usual from day to day (about 3–13 % is typical, most people 4–8 %). That often comes from an inconsistent protocol, such as time, posture or moving, rather than real changes.")
            } else if cv < 3 {
                parts.append("Your HRV is very steady from day to day (about 3–13 % is typical, most people 4–8 %).")
            } else {
                parts.append("Day-to-day variation is in the typical range of about 3–13 % (most people 4–8 %).")
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Building blocks

private struct InsightCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = Palette.accent
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .labelStyle(TintedIconLabelStyle(tint: tint))
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct Fact: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    InsightsView().modelContainer(PreviewData.container())
}
