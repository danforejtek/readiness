import Foundation
import HRVCore

/// Replays a recorded session CSV in real time (or faster), cycling when it runs out so long measurements complete.
final class ReplayHeartRateSource: HeartRateSource {
    struct Packet { let elapsed: Double; let hr: Int; let rr: [Double] }

    let displayName: String
    var clockRate: Double { speed }
    private let packets: [Packet]
    private let speed: Double
    private var task: Task<Void, Never>?

    init(beats: [SessionCSV.Beat], speed: Double, deviceName: String) {
        displayName = deviceName
        self.speed = max(0.1, speed)
        var grouped: [Packet] = []
        for b in beats {
            if let last = grouped.last, last.elapsed == b.elapsedS {
                grouped[grouped.count - 1] = Packet(elapsed: last.elapsed, hr: b.hr, rr: last.rr + (b.rrMs.map { [$0] } ?? []))
            } else {
                grouped.append(Packet(elapsed: b.elapsedS, hr: b.hr, rr: b.rrMs.map { [$0] } ?? []))
            }
        }
        packets = grouped
    }

    static func fixture(named name: String, speed: Double) -> ReplayHeartRateSource? {
        guard let text = MorningStore.fixtureText(name) else { return nil }
        return ReplayHeartRateSource(beats: SessionCSV.beats(fromText: text), speed: speed, deviceName: "Replay · \(name)")
    }

    func events() -> AsyncStream<HeartRateEvent> {
        AsyncStream { continuation in
            let task = Task { [packets, speed, displayName] in
                func pause(_ seconds: Double) async throws {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) / speed * 1_000_000_000))
                }
                do {
                    continuation.yield(.status("Searching for the sensor…"))
                    try await pause(0.8)
                    guard !packets.isEmpty else {
                        continuation.yield(.failed("No recorded session available to replay."))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.connected(device: displayName, battery: 100))
                    var prev = packets[0].elapsed - 1
                    while !Task.isCancelled {
                        for p in packets {
                            try await pause(p.elapsed - prev)
                            prev = p.elapsed
                            continuation.yield(.sample(Self.sample(p)))
                        }
                        prev = packets[0].elapsed - 1   // loop with a one-second gap
                    }
                } catch {
                    // cancelled
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            self.task = task
        }
    }

    func stop() { task?.cancel() }

    static func sample(_ p: Packet) -> HeartRateSample {
        let flags: UInt8 = p.rr.isEmpty ? 0x00 : 0x10
        return HeartRateSample(heartRate: p.hr, skinContact: nil, energyExpendedKJ: nil, rrIntervalsMs: p.rr,
                               raw: [flags, UInt8(clamping: p.hr)])
    }
}
