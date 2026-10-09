import Charts
import HRVCore
import SwiftData
import SwiftUI

struct MorningDetailView: View {
    let morning: Morning
    @Query(sort: \Morning.date) private var mornings: [Morning]
    @AppStorage(AppSettings.baselineResetsKey) private var baselineResets = ""
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        // A deleted morning must not be read again while the view animates away.
        if morning.isDeleted || morning.modelContext == nil {
            ContentUnavailableView("Measurement deleted", systemImage: "trash")
        } else {
            content
        }
    }

    private var content: some View {
        let assessment = MorningStore.assessment(for: morning, in: mornings, resets: AppSettings.parseResets(baselineResets))
        let analysis = MorningAnalysis(morning)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VerdictCard(assessment: assessment)
                CheckInCard(morning: morning)
                WhySection(assessment: assessment)
                if morning.hasBeats {
                    TachogramCard(analysis: analysis)
                    PoincareCard(analysis: analysis)
                    if !analysis.spectrum.isEmpty { SpectrumCard(analysis: analysis, morning: morning) }
                } else {
                    Label("Imported row without beat data, so only the summary numbers are available.", systemImage: "square.and.arrow.down")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                MetricsTable(morning: morning, assessment: assessment, poincare: analysis.poincare)
            }
            .padding()
        }
        .navigationTitle(Fmt.day.string(from: morning.date))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete measurement")
            }
        }
        .confirmationDialog("Delete this measurement?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let target = morning
                Task {
                    await HealthKitService.shared.delete([target])
                    context.delete(target)
                    try? context.save()
                }
                dismiss()
            }
        } message: {
            Text(morning.healthSaved
                 ? "Your baseline and later verdicts are recalculated without it. Its entries in Apple Health are removed too."
                 : "Your baseline and later verdicts are recalculated without it.")
        }
    }
}

/// Everything derived from the stored beats, computed once per render.
private struct MorningAnalysis {
    struct Beat: Identifiable { let id: Int; let t: Double; let rr: Double; let accepted: Bool }
    struct SpecPoint: Identifiable { let id: Int; let f: Double; let p: Double }

    let beats: [Beat]
    let rejected: Int
    /// Consecutive accepted beats (RRₙ, RRₙ₊₁), without the pairs that span a rejected beat.
    let pairs: [(x: Double, y: Double)]
    let meanRR: Double
    let poincare: Poincare?
    let spectrum: [SpecPoint]

    init(_ m: Morning) {
        // Re-run the artefact filter over every received interval so rejected beats can be drawn. Intervals from
        // before the end of the settle phase (only replayed mornings store them) were never measured: drawn, not filtered.
        var breaks = m.breakIndices
        if m.allRR.isEmpty {
            beats = zip(m.beatTimes, m.rrMs).enumerated().map { Beat(id: $0, t: $1.0 - m.settleS, rr: $1.1, accepted: true) }
        } else {
            let buffer = RRBuffer()
            beats = zip(m.allElapsed, m.allRR).enumerated().map { i, pair in
                Beat(id: i, t: pair.0 - m.settleS, rr: pair.1, accepted: pair.0 < m.settleS || buffer.add(pair.1, at: pair.0))
            }
            // the re-run's breaks line up with the stored beats only when it reproduces them
            if buffer.values == m.rrMs { breaks = buffer.breaks }
        }
        rejected = beats.filter { !$0.accepted }.count
        let skip = Set(breaks)
        pairs = m.rrMs.indices.dropFirst().filter { !skip.contains($0) }.map { (x: m.rrMs[$0 - 1], y: m.rrMs[$0]) }
        meanRR = m.rrMs.isEmpty ? 0 : m.rrMs.reduce(0, +) / Double(m.rrMs.count)
        poincare = HRVCore.poincare(rr: m.rrMs, breaks: breaks)
        if m.rrMs.count >= 30 {
            let freqs = stride(from: 0.02, through: 0.5, by: 0.002).map { $0 }
            let psd = lombScarglePSD(t: m.beatTimes, y: m.rrMs, freqs: freqs)
            spectrum = zip(freqs, psd).enumerated().map { SpecPoint(id: $0, f: $1.0, p: $1.1) }
        } else {
            spectrum = []
        }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let info: Metric?
    let subtitle: String
    var height: CGFloat = 180
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(title).font(.headline)
                if let info { InfoButton(metric: info) }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content().frame(height: height)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct TachogramCard: View {
    let analysis: MorningAnalysis

    var body: some View {
        let rejectedText = analysis.rejected == 0 ? "no beats rejected"
            : analysis.rejected == 1 ? "1 rejected beat in amber" : "\(analysis.rejected) rejected beats in amber"
        Card(title: "Beat-to-beat intervals", info: .quality,
             subtitle: "Time between heartbeats over the measurement, \(rejectedText). The line rises when you breathe out and falls when you breathe in; bigger waves mean more variability.") {
            Chart(analysis.beats) { b in
                LineMark(x: .value("Seconds", b.t), y: .value("RR", b.rr))
                    .foregroundStyle(Palette.measure.opacity(0.9)).interpolationMethod(.monotone)
                if !b.accepted {
                    PointMark(x: .value("Seconds", b.t), y: .value("RR", b.rr)).foregroundStyle(Palette.caution)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxisLabel("seconds")
            .chartYAxisLabel("ms")
        }
    }
}

private struct PoincareCard: View {
    let analysis: MorningAnalysis

    private struct P: Identifiable { let id: Int; let x: Double; let y: Double }

    var body: some View {
        let pts = analysis.pairs.enumerated().map { P(id: $0, x: $1.x, y: $1.y) }
        let lo = (analysis.pairs.map { min($0.x, $0.y) }.min() ?? 600) - 20
        let hi = (analysis.pairs.map { max($0.x, $0.y) }.max() ?? 1200) + 20
        let pc = analysis.poincare
        let subtitle = pc.map {
            "Each beat against the next. A wide cloud means high variability. The ellipse shows SD1 \(Fmt.n($0.sd1, 1)) ms across the diagonal (fast, beat-to-beat) and SD2 \(Fmt.n($0.sd2, 1)) ms along it (slower changes)."
        } ?? "Each beat against the next. A wide cloud means high variability."
        Card(title: "Poincaré plot", info: .sd1sd2, subtitle: subtitle, height: 280) {
            Chart {
                LineMark(x: .value("RRₙ", lo), y: .value("RRₙ₊₁", lo), series: .value("s", "identity"))
                    .foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                LineMark(x: .value("RRₙ", hi), y: .value("RRₙ₊₁", hi), series: .value("s", "identity"))
                    .foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ForEach(pts) { p in
                    PointMark(x: .value("RRₙ", p.x), y: .value("RRₙ₊₁", p.y))
                        .foregroundStyle(Palette.measure.opacity(0.55)).symbolSize(18)
                }
                if let pc {
                    ForEach(Self.ellipse(center: analysis.meanRR, sd1: pc.sd1, sd2: pc.sd2)) { e in
                        LineMark(x: .value("RRₙ", e.x), y: .value("RRₙ₊₁", e.y), series: .value("s", "ellipse"))
                            .foregroundStyle(Palette.calm).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartXScale(domain: lo...hi)
            .chartYScale(domain: lo...hi)
            .chartXAxisLabel("RRₙ ms")
            .chartYAxisLabel("RRₙ₊₁ ms")
            .aspectRatio(1, contentMode: .fit)
        }
    }

    /// SD1/SD2 ellipse: SD2 along the identity line, SD1 across it, centred on the mean interval.
    private static func ellipse(center c: Double, sd1: Double, sd2: Double) -> [P] {
        let r = 1 / 2.0.squareRoot()
        return (0...72).map { i in
            let th = Double(i) / 72 * 2 * .pi
            let a = sd2 * cos(th), b = sd1 * sin(th)
            return P(id: i, x: c + r * (a - b), y: c + r * (a + b))
        }
    }
}

private struct SpectrumCard: View {
    let analysis: MorningAnalysis
    let morning: Morning

    var body: some View {
        let peak = morning.breathingBpm.flatMap { $0 > 0 ? $0 / 60 : nil }
        let breathingText = (peak == nil
            ? "No clear breathing peak this morning, so no breathing rate."
            : "The dashed line marks your breathing rate.") + slowBreathingText
        Card(title: "Spectrum", info: .hf,
             subtitle: "How the variability splits by speed. Green is breathing speed (HF \(Fmt.n(morning.hfMs2)) ms²), violet is slower regulation (LF \(Fmt.n(morning.lfMs2)) ms²). \(breathingText)") {
            Chart {
                RectangleMark(xStart: .value("f", 0.04), xEnd: .value("f", 0.15)).foregroundStyle(Palette.calm.opacity(0.12))
                RectangleMark(xStart: .value("f", 0.15), xEnd: .value("f", 0.40)).foregroundStyle(Palette.good.opacity(0.12))
                ForEach(analysis.spectrum) { s in
                    AreaMark(x: .value("Hz", s.f), y: .value("PSD", s.p)).foregroundStyle(Palette.accent.opacity(0.30))
                    LineMark(x: .value("Hz", s.f), y: .value("PSD", s.p)).foregroundStyle(Palette.accent)
                }
                if let peak {
                    RuleMark(x: .value("Hz", peak))
                        .foregroundStyle(Palette.good).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(Fmt.n(morning.breathingBpm)) breaths/min").font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: 0.02...0.5)
            .chartXAxisLabel("Hz")
            .chartYAxisLabel("ms²/Hz")
        }
    }

    /// Below 9 breaths a minute the breathing-driven variation moves into the LF band and inflates LF/HF on its own
    /// (Saboul 2014, docs/evidence.md section J).
    private var slowBreathingText: String {
        guard let bpm = morning.breathingBpm, bpm < 9 else { return "" }
        return " Slow breathing: LF/HF is not interpretable this morning."
    }
}

/// Every stored number for the morning, each with its explanation.
private struct MetricsTable: View {
    let morning: Morning
    let assessment: Assessment
    let poincare: Poincare?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All numbers").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("Measured", Fmt.dayTime.string(from: morning.date))
                row("Duration", "\(Fmt.n(morning.durationS)) s after \(Fmt.n(morning.settleS)) s settling")
                row("Clean beats", "\(morning.beats)", .quality)
                row("Rejected", "\(morning.artefacts) · \(Fmt.n(morning.artefactPct, 1)) %", .quality)
                Divider()
                row("Resting HR", "\(Fmt.n(morning.meanHR, 1)) bpm", .restingHR)
                row("Mean RR", "\(Fmt.n(morning.meanRR)) ms", .meanRR)
                row("lnRMSSD", Fmt.n(morning.lnRMSSD, 2), .lnRMSSD)
                row("RMSSD", "\(Fmt.n(morning.rmssd, 1)) ms", .rmssd)
                row("SDNN", "\(Fmt.n(morning.sdnn, 1)) ms", .sdnn)
                row("pNN50", "\(Fmt.n(morning.pnn50, 1)) %", .pnn50)
                if let sd1 = poincare?.sd1 ?? morning.sd1, let sd2 = poincare?.sd2 ?? morning.sd2 {
                    row("SD1 / SD2", "\(Fmt.n(sd1, 1)) / \(Fmt.n(sd2, 1)) ms", .sd1sd2)
                }
                row("Stress index", Fmt.n(morning.stressIndex, 1), .stressIndex)
                Divider()
                row("Readiness score", assessment.score.map { "\($0) of 100" } ?? "–", .score)
                row("Regeneration", assessment.regeneration.map { "\(Fmt.n($0, 1)) of 10" } ?? "–", .regeneration)
                row("Stress", assessment.stress.map { "\(Fmt.n($0, 1)) of 10" } ?? "–", .stress)
                Divider()
                row("HF power", "\(Fmt.n(morning.hfMs2)) ms²", .hf)
                row("LF power", "\(Fmt.n(morning.lfMs2)) ms²", .lf)
                row("LF/HF", Fmt.n(morning.lfHf, 2), .lfHf)
                row("Breathing", "\(Fmt.n(morning.breathingBpm, 1)) /min", .breathing)
                Divider()
                row("Source", morning.deviceName.isEmpty ? morning.source : "\(morning.source) · \(morning.deviceName)")
            }
            .font(.callout)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func row(_ name: String, _ value: String, _ info: Metric? = nil) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Text(name).foregroundStyle(.secondary)
                if let info { InfoButton(metric: info) }
            }
            Text(value).monospacedDigit().gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
