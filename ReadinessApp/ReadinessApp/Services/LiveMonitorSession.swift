import Foundation
import HRVCore
import Observation

/// Free-running heart-rate monitor, the phone's `hrmon monitor`: live HR, beats and rolling HRV with no
/// settle/measure protocol and nothing saved. Runs until the view closes it.
@MainActor
@Observable
final class LiveMonitorSession {
    struct HRPoint: Identifiable { let id = UUID(); let t: Double; let bpm: Int }
    struct BeatPoint: Identifiable { let id = UUID(); let t: Double; let rr: Double; let accepted: Bool }

    /// Rolling window for RMSSD/SDNN, as in `hrmon monitor --window 60`.
    static let hrvWindowS: Double = 60
    /// Breathing rate needs about two minutes of beats for a stable HF peak.
    static let breathingWindowS: Double = 120

    private(set) var connected = false
    private(set) var statusText = "Connecting…"
    private(set) var failure: String?
    private(set) var deviceName = ""
    private(set) var battery: Int?
    private(set) var heartRate: Int?
    private(set) var skinContact: Bool?
    private(set) var lastRR: Double?
    /// Bumped on every received beat; drives the heart pulse.
    private(set) var beatCount = 0
    private(set) var hrSeries: [HRPoint] = []
    private(set) var beats: [BeatPoint] = []
    private(set) var rolling: HRVMetrics?
    private(set) var breathingBpm: Double?
    private(set) var minHR: Int?
    private(set) var maxHR: Int?
    private(set) var meanHR: Double?
    private(set) var elapsed: TimeInterval = 0

    private let buffer = RRBuffer()
    @ObservationIgnored private var hrSum = 0
    @ObservationIgnored private var hrN = 0
    private var t0: Date?
    private var clockRate: Double = 1
    private var source: HeartRateSource?
    private var streamTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastSpectral: TimeInterval = -.infinity

    var artefactPct: Double { buffer.total > 0 ? 100 * Double(buffer.artefacts) / Double(buffer.total) : 0 }
    var cleanBeats: Int { buffer.values.count }

    func start(source: HeartRateSource) {
        guard self.source == nil else { return }
        self.source = source
        clockRate = max(0.1, source.clockRate)
        streamTask = Task { [weak self] in
            for await event in source.events() {
                guard let self, !Task.isCancelled else { break }
                self.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.tick()
            }
        }
    }

    func stop() {
        streamTask?.cancel(); streamTask = nil
        tickTask?.cancel(); tickTask = nil
        source?.stop(); source = nil
    }

    private var now: TimeInterval {
        guard let t0 else { return 0 }
        return Date().timeIntervalSince(t0) * clockRate
    }

    private func handle(_ event: HeartRateEvent) {
        switch event {
        case .status(let s):
            statusText = s
        case .connected(let device, let batt):
            connected = true
            deviceName = device
            battery = batt
            statusText = "Connected to \(device)"
        case .battery(let b):
            battery = b
        case .sample(let s):
            onSample(s)
        case .disconnected:
            connected = false
            statusText = "Connection lost, reconnecting…"
        case .failed(let message):
            failure = message
            stop()
        }
    }

    private func onSample(_ s: HeartRateSample) {
        if t0 == nil { t0 = Date() }
        let t = now
        skinContact = s.skinContact
        if s.heartRate > 0 {
            heartRate = s.heartRate
            hrSeries.append(HRPoint(t: t, bpm: s.heartRate))
            if hrSeries.count > 600 { hrSeries.removeFirst(hrSeries.count - 600) }   // ~10 min at 1 Hz
            hrSum += s.heartRate; hrN += 1
            meanHR = Double(hrSum) / Double(hrN)
            minHR = min(minHR ?? s.heartRate, s.heartRate)
            maxHR = max(maxHR ?? s.heartRate, s.heartRate)
        }
        for rr in s.rrIntervalsMs {
            lastRR = rr
            beatCount += 1
            let ok = buffer.add(rr, at: t)
            beats.append(BeatPoint(t: t, rr: rr, accepted: ok))
            if beats.count > 120 { beats.removeFirst(beats.count - 120) }
        }
        rolling = buffer.metrics(window: Self.hrvWindowS)
    }

    private func tick() {
        guard t0 != nil else { return }
        elapsed = now
        // The Lomb-Scargle spectrum is the expensive part; every 5 s is plenty for a breathing rate.
        if elapsed - lastSpectral >= 5 {
            lastSpectral = elapsed
            breathingBpm = buffer.spectral(window: Self.breathingWindowS)?.breathingRateBpm
        }
    }
}
