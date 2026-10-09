import Charts
import HRVCore
import SwiftData
import SwiftUI

struct MeasureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Morning.date) private var mornings: [Morning]
    @AppStorage(AppSettings.baselineResetsKey) private var baselineResets = ""
    @State private var session = MeasurementSession()
    var autoStart = false

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle:
                    IntroView(settleS: session.settleS, durationS: session.durationS) {
                        session.start(source: SourceFactory.make(), context: context)
                    }
                case .connecting:
                    ConnectingView(status: session.statusText)
                case .settling, .measuring:
                    LiveMeasureView(session: session)
                case .result:
                    if let morning = session.result {
                        ResultView(morning: morning, assessment: MorningStore.assessment(for: morning, in: mornings, resets: AppSettings.parseResets(baselineResets))) { dismiss() }
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Measurement failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { session.start(source: SourceFactory.make(), context: context) }
                            .prominentButton()
                    }
                }
            }
            .navigationTitle("Morning measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.phase == .result ? "Done" : "Cancel") {
                        session.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(session.phase.isRunning)
        .onChange(of: session.phase.isRunning, initial: true) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            if autoStart, session.phase == .idle { session.start(source: SourceFactory.make(), context: context) }
        }
    }
}

private struct IntroView: View {
    let settleS: Double
    let durationS: Double
    let start: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bed.double.fill").font(.system(size: 56)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 12) {
                Step(n: 1, text: "Right after waking, before coffee, phone or getting up.")
                Step(n: 2, text: "Heart-rate sensor on and awake, snug with good skin contact (chest strap electrodes moistened).")
                Step(n: 3, text: "Lie on your back, arm relaxed, breathe normally.")
                Step(n: 4, text: "\(Fmt.mmss(settleS)) to settle, then \(Fmt.mmss(durationS)) of measurement. The clock starts with the first heartbeat. If too many beats are rejected, it measures up to \(Int(AppSettings.maxExtensionS)) s longer.")
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            if AppSettings.useBand, let battery = AppSettings.bandBattery, battery < AppSettings.lowBatteryPercent {
                Label("The sensor was at \(battery) % last time. Charge it if the measurement drops out.",
                      systemImage: BatteryLabel.symbol(battery))
                    .font(.footnote).foregroundStyle(Palette.alert)
            }
            Spacer()
            Button(action: start) {
                Label("Start", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity)
            }
            .prominentButton()
            .controlSize(.large)
        }
        .padding()
    }

    private struct Step: View {
        let n: Int
        let text: String
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(n)").font(.headline).frame(width: 28, height: 28).background(Circle().fill(.tint.opacity(0.2)))
                Text(text).font(.callout)
            }
        }
    }
}

private struct ConnectingView: View {
    let status: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(status).foregroundStyle(.secondary)
            Text("If nothing happens: is the sensor on and awake? Is another app or a watch connected to it?")
                .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct LiveMeasureView: View {
    let session: MeasurementSession

    var body: some View {
        let settling = session.phase == .settling
        let extending = !settling && session.extending
        let total = settling ? session.settleS : extending ? AppSettings.maxExtensionS : session.durationS
        let remaining = settling ? session.settleRemaining : extending ? session.extensionRemaining : session.measureRemaining
        let ringColor = settling ? Palette.calm : extending ? Palette.caution : Palette.measure
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(ringColor.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: total > 0 ? CGFloat(1 - remaining / total) : 0)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: remaining)
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(session.heartRate.map(String.init) ?? "–").font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("bpm").foregroundStyle(.secondary)
                    }
                    Text(settling ? "settling \(Fmt.mmss(remaining))" : Fmt.mmss(remaining))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(settling ? Palette.calm : .primary)
                    if extending {
                        Text("extending · \(session.cleanBeatsNeeded) more clean beats")
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(Palette.caution)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 170)
                    }
                }
            }
            .frame(width: 220, height: 220)
            .padding(.top)

            Text(session.statusText).font(.callout).foregroundStyle(.secondary)

            Chart(session.tachogram.suffix(70)) { p in
                LineMark(x: .value("s", p.t), y: .value("RR", p.rr))
                    .foregroundStyle(Palette.measure)
                    .interpolationMethod(.monotone)
                if !p.accepted {
                    PointMark(x: .value("s", p.t), y: .value("RR", p.rr)).foregroundStyle(Palette.caution)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .chartYAxisLabel("RR ms")
            .frame(height: 120)
            .padding(.horizontal)

            HStack(spacing: 10) {
                Stat("RMSSD 60 s", Fmt.n(session.liveRMSSD, 1), "ms")
                Stat("Beats", "\(session.cleanBeats)", "")
                Stat("Artefacts", Fmt.n(session.artefactPct), "%")
            }
            .padding(.horizontal)

            if session.artefactPct > 10, session.cleanBeats > 10 {
                Label("Hold the arm still and relax the hand", systemImage: "hand.raised")
                    .font(.footnote).foregroundStyle(Palette.caution)
            }
            if session.interrupted {
                Label("Connection dropped during the measurement; the clock paused while reconnecting", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.footnote).foregroundStyle(Palette.caution)
            }
            Spacer()
            if let batt = session.battery {
                HStack(spacing: 6) {
                    Text(session.deviceName).foregroundStyle(.secondary)
                    BatteryLabel(percent: batt)
                }
                .font(.footnote)
            }
        }
        .padding(.bottom)
    }
}

struct ResultView: View {
    let morning: Morning
    let assessment: Assessment
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VerdictCard(assessment: assessment)
                CheckInCard(morning: morning)
                WhySection(assessment: assessment)
                NumbersSection(morning: morning)
                NavigationLink { MorningDetailView(morning: morning) } label: {
                    Label("Beats, spectrum and details", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: done) { Text("Done").font(.headline).frame(maxWidth: .infinity) }
                .prominentButton().controlSize(.large).padding().background(.bar)
        }
    }
}

#Preview {
    MeasureView().modelContainer(PreviewData.container())
}
