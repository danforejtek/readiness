import HRVCore
import SwiftData
import SwiftUI

struct TodayView: View {
    @Query(sort: \Morning.date) private var mornings: [Morning]
    @AppStorage(AppSettings.baselineResetsKey) private var baselineResets = ""
    @AppStorage(AppSettings.bandBatteryKey) private var bandBattery: Int?
    @AppStorage(AppSettings.useBandKey) private var useBand = !AppSettings.isSimulator
    @State private var confirmRemeasure = false
    @State private var showLive = false
    var onMeasure: () -> Void

    var body: some View {
        let latest = MorningStore.dayAssessments(mornings, resets: AppSettings.parseResets(baselineResets)).last
        // Demo rows do not count, same as the reminder (`MorningStore.measuredToday`).
        let measuredToday = mornings.contains { Calendar.current.isDateInToday($0.date) && $0.source != "demo" }
        let lowBattery = useBand && (bandBattery ?? 100) < AppSettings.lowBatteryPercent
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let latest {
                        WeekStripView(daily: MorningStore.dailyMornings(mornings))
                        if latest.assessment.score != nil {
                            TodayNumbersCard(assessment: latest.assessment,
                                             isToday: Calendar.current.isDateInToday(latest.morning.date))
                        }
                        VerdictCard(assessment: latest.assessment)
                        if !Calendar.current.isDateInToday(latest.morning.date) {
                            Label("Last measurement was \(Fmt.day.string(from: latest.morning.date)). Measure this morning for today's verdict.",
                                  systemImage: "clock")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        WhySection(assessment: latest.assessment)
                        NumbersSection(morning: latest.morning)
                        NavigationLink { MorningDetailView(morning: latest.morning) } label: {
                            Label("Beats, spectrum and details", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        EmptyToday()
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
            .toolbar {
                Menu {
                    // The escape hatch: once today is measured the big button is gone, but a noisy reading can be redone.
                    Button {
                        if measuredToday { confirmRemeasure = true } else { onMeasure() }
                    } label: {
                        Label(measuredToday ? "Measure again" : "Morning measurement", systemImage: "heart.text.square")
                    }
                    Button { showLive = true } label: {
                        Label("Live heart rate", systemImage: "waveform.path.ecg")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            .confirmationDialog("Measure again?", isPresented: $confirmRemeasure, titleVisibility: .visible) {
                Button("Start a new measurement", action: onMeasure)
            } message: {
                Text("Today already has a measurement. The new one is kept as well, and the cleaner of the two counts for today's verdict.")
            }
            .fullScreenCover(isPresented: $showLive) { LiveMonitorView() }
            .task { if AppSettings.debugLiveMonitor { showLive = true } }
            .safeAreaInset(edge: .bottom) {
                if !measuredToday || lowBattery {
                    VStack(spacing: 8) {
                        if lowBattery, let bandBattery {
                            Label("Sensor battery \(bandBattery) %. Charge it before the next measurement.",
                                  systemImage: BatteryLabel.symbol(bandBattery))
                                .font(.footnote).foregroundStyle(Palette.alert)
                        }
                        if !measuredToday {
                            Button(action: onMeasure) {
                                Label("Measure now", systemImage: "heart.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .prominentButton()
                            .controlSize(.large)
                        }
                    }
                    .padding()
                    .background(.bar)
                }
            }
        }
    }
}

struct WhySection: View {
    let assessment: Assessment

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(assessment.score == nil ? "This morning" : "Why").font(.headline)
            let r = assessment.record
            if let m = assessment.lnMean, let sd = assessment.lnSD {
                WhyRow(title: "Heart rate variability", info: .lnRMSSD,
                       value: "\(Fmt.n(r.lnRMSSD, 2))  ·  RMSSD \(Fmt.n(r.rmssd)) ms",
                       change: assessment.lnChange, direction: .higherIsBetter,
                       detail: Self.deviationText(assessment.zHRV, range: assessment.lnRange, digits: 2, unit: "",
                                                  above: "a sign of good recovery.",
                                                  below: "your body is dealing with more strain than usual.",
                                                  noiseFloor: Readiness.moderateZHRV)) {
                    RangeBar(value: r.lnRMSSD, mean: m, sd: sd, higherIsBetter: true, cautionFrom: -Readiness.moderateZHRV)
                }
            } else {
                WhyRow(title: "Heart rate variability", info: .lnRMSSD,
                       value: "\(Fmt.n(r.lnRMSSD, 2))  ·  RMSSD \(Fmt.n(r.rmssd)) ms",
                       change: assessment.lnChange, direction: .higherIsBetter,
                       detail: baselineText) { EmptyView() }
            }
            if let m = assessment.hrMean, let sd = assessment.hrSD {
                WhyRow(title: "Resting heart rate", info: .restingHR,
                       value: "\(Fmt.n(r.meanHR)) bpm",
                       change: assessment.hrChange, direction: .lowerIsBetter,
                       detail: Self.deviationText(assessment.zHR, range: assessment.hrRange, digits: 0, unit: " bpm",
                                                  above: "your heart is working harder than usual at rest.",
                                                  below: "usually a sign of good recovery.")) {
                    RangeBar(value: r.meanHR, mean: m, sd: sd, higherIsBetter: false)
                }
            } else {
                WhyRow(title: "Resting heart rate", info: .restingHR, value: "\(Fmt.n(r.meanHR)) bpm",
                       change: assessment.hrChange, direction: .lowerIsBetter,
                       detail: "Stored for your baseline.") { EmptyView() }
            }
            if let week = assessment.lnWeek, let m = assessment.lnMean, let sd = assessment.lnSD {
                WhyRow(title: "7-day HRV average", info: .weekAverage,
                       value: Fmt.n(week, 2),
                       detail: week >= m - 0.5 * sd
                           ? "Within or above your normal range. No sign of accumulated fatigue."
                           : assessment.weekN < Readiness.weekMinDays
                               ? "Below your normal range, but from only \(assessment.weekN) of the last 7 mornings: too few to show a trend."
                               : "Below your normal range. Fatigue has been building up over several days.") {
                    RangeBar(value: week, mean: m, sd: sd, higherIsBetter: true)
                }
            }
            WhyRow(title: "Signal quality", info: .quality,
                   value: "\(r.beats) clean beats · \(Fmt.n(r.artefactPct)) % rejected",
                   detail: r.lowQuality
                       ? "Noisy reading. Treat the verdict with caution."
                       : "Clean reading. The numbers can be trusted.") { EmptyView() }
            // While building the baseline the first note repeats the panel's progress, so it is left out.
            ForEach(assessment.score == nil ? Array(assessment.notes.dropFirst()) : assessment.notes, id: \.self) { note in
                Label(note, systemImage: "text.quote")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            NavigationLink { MethodView() } label: {
                Label("How the verdict works", systemImage: "questionmark.circle")
                    .font(.subheadline)
            }
        }
    }

    private var baselineText: String {
        let left = Readiness.minBaselineDays - assessment.baselineRecorded
        return left > 0
            ? "Your normal range appears after \(Readiness.minBaselineDays) mornings; \(left) more to go. Until then values are stored, not judged."
            : "Stored for your baseline. Your normal range appears with the next morning."
    }

    /// Plain-language position against the personal range, without statistics jargon. With `noiseFloor` (today's HRV:
    /// `Readiness.moderateZHRV`), a value below the range but above that z is day-to-day noise and does not change the
    /// verdict, so the text says so instead of naming a cause.
    static func deviationText(_ z: Double?, range: ClosedRange<Double>?, digits: Int, unit: String,
                              above: String, below: String, noiseFloor: Double? = nil) -> String {
        guard let z, let range else { return "" }
        let rangeText = "\(Fmt.n(range.lowerBound, digits))–\(Fmt.n(range.upperBound, digits))\(unit)"
        if abs(z) <= 0.5 { return "Inside your normal range of \(rangeText)." }
        if let noiseFloor, z < 0, z > noiseFloor {
            return "Slightly below your normal range of \(rangeText), within the day-to-day noise."
        }
        let size = abs(z) <= 1 ? "Slightly" : abs(z) <= 1.5 ? "Clearly" : "Far"
        return z > 0
            ? "\(size) above your normal range of \(rangeText): \(above)"
            : "\(size) below your normal range of \(rangeText): \(below)"
    }
}

struct WhyRow<Bar: View>: View {
    let title: String
    var info: Metric? = nil
    let value: String
    var change: Comparison? = nil
    var direction: MetricDirection = .higherIsBetter
    let detail: String
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let info { InfoButton(metric: info) }
                Spacer()
                Text(value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            bar()
            if let change { ChipRow(change: change, direction: direction) }
            if !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct NumbersSection: View {
    let morning: Morning

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Numbers").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                Stat("RMSSD", Fmt.n(morning.rmssd, 1), "ms", info: .rmssd)
                Stat("SDNN", Fmt.n(morning.sdnn, 1), "ms", info: .sdnn)
                Stat("pNN50", Fmt.n(morning.pnn50), "%", info: .pnn50)
                Stat("Mean RR", Fmt.n(morning.meanRR), "ms", info: .meanRR)
                Stat("HF power", Fmt.n(morning.hfMs2), "ms²", info: .hf)
                Stat("LF power", Fmt.n(morning.lfMs2), "ms²", info: .lf)
                Stat("LF/HF", Fmt.n(morning.lfHf, 2), "", info: .lfHf)
                Stat("Breathing", Fmt.n(morning.breathingBpm), "/min", info: .breathing)
                Stat("Stress index", Fmt.n(morning.stressIndex), "", info: .stressIndex)
                Stat("SD1 / SD2", "\(Fmt.n(morning.sd1)) / \(Fmt.n(morning.sd2))", "ms", info: .sd1sd2)
            }
            Text("Tap ⓘ for what each number means.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct Stat: View {
    let title: String
    let value: String
    let unit: String
    let info: Metric?
    init(_ title: String, _ value: String, _ unit: String, info: Metric? = nil) {
        self.title = title; self.value = value; self.unit = unit; self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if let info { InfoButton(metric: info) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyToday: View {
    var body: some View {
        ContentUnavailableView {
            Label("No measurements yet", systemImage: "heart.text.square")
        } description: {
            Text("Put on your heart-rate sensor right after waking, lie still, and tap Measure now. After seven mornings the app starts giving verdicts against your own baseline.")
        }
    }
}

#Preview {
    TodayView(onMeasure: {}).modelContainer(PreviewData.container())
}
