import Charts
import HRVCore
import SwiftUI

/// Live heart rate from the band at any time of day: HR trend, beat-to-beat intervals and rolling HRV.
/// Not a morning measurement: nothing is stored and the verdict is not touched.
struct LiveMonitorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = LiveMonitorSession()

    var body: some View {
        NavigationStack {
            Group {
                if let failure = session.failure {
                    ContentUnavailableView {
                        Label("No heart rate", systemImage: "antenna.radiowaves.left.and.right.slash")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { restart() }.prominentButton()
                    }
                } else if session.heartRate == nil {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text(session.statusText).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LiveContent(session: session)
                }
            }
            .navigationTitle("Live heart rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { session.stop(); dismiss() }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.start(source: SourceFactory.make())
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
    }

    private func restart() {
        session.stop()
        session = LiveMonitorSession()
        session.start(source: SourceFactory.make())
    }
}

private struct LiveContent: View {
    let session: LiveMonitorSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeartRateHeader(session: session)
                LiveCard(title: "Heart rate", subtitle: "last \(Self.minutes(session.hrSeries)) · bpm") {
                    Chart(session.hrSeries) { p in
                        AreaMark(x: .value("s", p.t), yStart: .value("min", lowHR), yEnd: .value("bpm", p.bpm))
                            .foregroundStyle(LinearGradient(colors: [Palette.measure.opacity(0.35), Palette.measure.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("s", p.t), y: .value("bpm", p.bpm))
                            .foregroundStyle(Palette.measure)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: lowHR...highHR)
                    .chartXAxis(.hidden)
                }
                LiveCard(title: "Beat to beat", subtitle: "last \(session.beats.count) beats · RR ms\(session.beats.contains { !$0.accepted } ? " · rejected in amber" : "")") {
                    Chart(session.beats) { b in
                        LineMark(x: .value("s", b.t), y: .value("RR", b.rr))
                            .foregroundStyle(Palette.calm)
                            .interpolationMethod(.monotone)
                        if !b.accepted {
                            PointMark(x: .value("s", b.t), y: .value("RR", b.rr)).foregroundStyle(Palette.caution)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxis(.hidden)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    Stat("RMSSD 60 s", Fmt.n(session.rolling?.rmssd, 1), "ms", info: .rmssd)
                    Stat("SDNN 60 s", Fmt.n(session.rolling?.sdnn, 1), "ms", info: .sdnn)
                    Stat("Last beat", Fmt.n(session.lastRR), "ms", info: .meanRR)
                    Stat("Breathing", Fmt.n(session.breathingBpm.flatMap { $0 > 0 ? $0 : nil }, 1), "/min", info: .breathing)
                    Stat("HR min · max", "\(session.minHR.map(String.init) ?? "–") · \(session.maxHR.map(String.init) ?? "–")", "bpm")
                    Stat("Artefacts", Fmt.n(session.artefactPct), "%", info: .quality)
                }
                Text("RMSSD and SDNN cover the last minute, breathing the last two. Live values move with posture, talking and activity, so they are not comparable with the morning measurement. Nothing here is saved.")
                    .font(.caption).foregroundStyle(.secondary)
                if let battery = session.battery {
                    HStack(spacing: 6) {
                        Text(session.deviceName).foregroundStyle(.secondary)
                        BatteryLabel(percent: battery)
                    }
                    .font(.footnote)
                }
            }
            .padding()
        }
    }

    private var lowHR: Int { max(0, (session.hrSeries.map(\.bpm).min() ?? 50) - 5) }
    private var highHR: Int { (session.hrSeries.map(\.bpm).max() ?? 100) + 5 }

    static func minutes(_ series: [LiveMonitorSession.HRPoint]) -> String {
        guard let first = series.first, let last = series.last else { return "0 s" }
        let span = Int(last.t - first.t)
        return span < 60 ? "\(span) s" : "\(span / 60) min"
    }
}

private struct HeartRateHeader: View {
    let session: LiveMonitorSession
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "heart.fill")
                .font(.system(size: 40))
                .foregroundStyle(Palette.measure)
                .scaleEffect(pulse ? 1.18 : 1)
                .animation(.spring(response: 0.18, dampingFraction: 0.5), value: pulse)
                .onChange(of: session.beatCount) { _, _ in
                    pulse = true
                    Task { try? await Task.sleep(nanoseconds: 150_000_000); pulse = false }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.heartRate.map(String.init) ?? "–")
                        .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: session.heartRate)
                    Text("bpm").foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(Self.clock(session.elapsed)).monospacedDigit()
                    if let mean = session.meanHR { Text("avg \(Fmt.n(mean))") }
                    if !session.connected {
                        Label("reconnecting", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(Palette.caution)
                    } else if session.skinContact == false {
                        Label("no skin contact", systemImage: "hand.raised")
                            .foregroundStyle(Palette.caution)
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : Fmt.mmss(s)
    }
}

private struct LiveCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content().frame(height: 120)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    LiveMonitorView()
}
