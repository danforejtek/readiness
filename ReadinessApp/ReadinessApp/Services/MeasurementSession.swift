import Foundation
import HRVCore
import Observation
import SwiftData

/// Drives one morning measurement: connect → settle → measure → result, feeding HRVCore and persisting a `Morning`.
@MainActor
@Observable
final class MeasurementSession {
    enum Phase: Equatable { case idle, connecting, settling, measuring, result, failed(String) }

    struct TachoPoint: Identifiable { let id = UUID(); let t: Double; let rr: Double; let accepted: Bool }

    let settleS: Double
    let durationS: Double

    private(set) var phase: Phase = .idle
    private(set) var statusText = ""
    private(set) var deviceName = ""
    private(set) var battery: Int?
    private(set) var heartRate: Int?
    private(set) var lastRR: Double?
    private(set) var beatsReceived = 0
    private(set) var liveRMSSD: Double?
    private(set) var sessionMetrics: HRVMetrics?
    private(set) var recentHR: [Int] = []
    private(set) var tachogram: [TachoPoint] = []
    private(set) var settleRemaining: Double
    private(set) var measureRemaining: Double
    private(set) var result: Morning?
    private(set) var interrupted = false

    private let buffer = RRBuffer()
    private var allRR: [Double] = []
    private var allElapsed: [Double] = []
    private var t0: Date?
    private var pauseStarted: Date?
    private var pausedTotal: TimeInterval = 0
    private var source: HeartRateSource?
    private var streamTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var context: ModelContext?
    private var clockRate: Double = 1

    init(settleS: Double = AppSettings.settleSeconds, durationS: Double = AppSettings.measureSeconds) {
        self.settleS = settleS
        self.durationS = durationS
        settleRemaining = settleS
        measureRemaining = durationS
    }

    var artefactPct: Double { buffer.total > 0 ? 100 * Double(buffer.artefacts) / Double(buffer.total) : 0 }
    var cleanBeats: Int { buffer.values.count }

    var elapsed: TimeInterval {
        guard let t0 else { return 0 }
        let paused = pausedTotal + (pauseStarted.map { Date().timeIntervalSince($0) } ?? 0)
        return (Date().timeIntervalSince(t0) - paused) * clockRate
    }

    func start(source: HeartRateSource, context: ModelContext) {
        guard phase == .idle || phase == .result || phase.isFailed else { return }
        reset()
        self.source = source
        self.context = context
        clockRate = max(0.1, source.clockRate)
        phase = .connecting
        statusText = "Connecting…"
        streamTask = Task { [weak self] in
            for await event in source.events() {
                guard let self, !Task.isCancelled else { break }
                self.handle(event)
            }
        }
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.tick()
            }
        }
    }

    func cancel() {
        stopStreams()
        phase = .idle
    }

    private func reset() {
        stopStreams()
        heartRate = nil; lastRR = nil; beatsReceived = 0; liveRMSSD = nil; sessionMetrics = nil
        recentHR = []; tachogram = []; allRR = []; allElapsed = []; t0 = nil; pauseStarted = nil; pausedTotal = 0
        result = nil; interrupted = false; battery = nil; deviceName = ""
        settleRemaining = settleS; measureRemaining = durationS
        bufferReset()
    }

    private func bufferReset() {
        // RRBuffer has no reset; a fresh session object is normally created per measurement.
    }

    private func stopStreams() {
        streamTask?.cancel(); streamTask = nil
        tickTask?.cancel(); tickTask = nil
        source?.stop(); source = nil
    }

    private func handle(_ event: HeartRateEvent) {
        switch event {
        case .status(let s):
            statusText = s
        case .connected(let device, let batt):
            deviceName = device
            battery = batt
            statusText = "Connected to \(device)"
            if pauseStarted != nil { pausedTotal += Date().timeIntervalSince(pauseStarted!); pauseStarted = nil }
        case .sample(let s):
            onSample(s)
        case .disconnected:
            statusText = "Connection lost, reconnecting…"
            if t0 != nil, pauseStarted == nil { pauseStarted = Date(); interrupted = true }
        case .failed(let message):
            stopStreams()
            phase = .failed(message)
        }
    }

    private func onSample(_ s: HeartRateSample) {
        if t0 == nil {
            t0 = Date()
            phase = .settling
            statusText = "Settling… keep still"
        }
        let el = elapsed
        heartRate = s.heartRate
        if s.heartRate > 0 {
            recentHR.append(s.heartRate)
            if recentHR.count > 150 { recentHR.removeFirst(recentHR.count - 150) }
        }
        for rr in s.rrIntervalsMs {
            beatsReceived += 1
            lastRR = rr
            if el >= settleS {
                allRR.append(rr); allElapsed.append(el)
                let ok = buffer.add(rr, at: el)
                tachogram.append(TachoPoint(t: el - settleS, rr: rr, accepted: ok))
            }
        }
        liveRMSSD = buffer.metrics(window: 60)?.rmssd
        sessionMetrics = buffer.metrics()
    }

    private func tick() {
        guard t0 != nil, phase == .settling || phase == .measuring else { return }
        let el = elapsed
        settleRemaining = max(0, settleS - el)
        measureRemaining = max(0, settleS + durationS - el)
        if phase == .settling, el >= settleS {
            phase = .measuring
            statusText = "Measuring… breathe normally"
        }
        if el >= settleS + durationS { finish() }
    }

    private func finish() {
        stopStreams()
        guard let m = buffer.metrics(), m.n >= 30 else {
            phase = .failed("Not enough clean heartbeats (\(cleanBeats)). Tighten the band on the inner forearm, keep the arm still, and try again.")
            return
        }
        let morning = Morning(date: Date(), metrics: m, spectral: buffer.spectral(), settleS: settleS, rrMs: buffer.values,
                              beatTimes: buffer.beatTimes, allRR: allRR, allElapsed: allElapsed,
                              source: deviceName.hasPrefix("Replay") ? "replay" : "band", deviceName: deviceName)
        context?.insert(morning)
        try? context?.save()
        if AppSettings.healthEnabled {
            Task { [context] in
                try? await HealthKitService.shared.save(morning)
                try? context?.save()
            }
        }
        result = morning
        phase = .result
        statusText = "Done"
    }
}

extension MeasurementSession.Phase {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
    var isRunning: Bool { self == .connecting || self == .settling || self == .measuring }
}
