import Foundation
import HRVCore

enum HeartRateEvent {
    case status(String)
    case connected(device: String, battery: Int?)
    case sample(HeartRateSample)
    /// Battery level (%) read or notified after connecting.
    case battery(Int)
    case disconnected
    case failed(String)
}

/// Anything that produces heart-rate samples: the real band over Bluetooth, or a replayed recording.
protocol HeartRateSource: AnyObject {
    var displayName: String { get }
    /// 1 for a live sensor; a replay running N× faster reports N so the measurement clock keeps pace.
    var clockRate: Double { get }
    func events() -> AsyncStream<HeartRateEvent>
    func stop()
}

enum SourceFactory {
    /// The band on a device when enabled (phase 3); otherwise the selected recorded session.
    static func make() -> HeartRateSource {
        if AppSettings.useBand, !AppSettings.isSimulator, let ble = BLESourceRegistry.make?() {
            return ble
        }
        return ReplayHeartRateSource.fixture(named: AppSettings.replayFixture, speed: AppSettings.replaySpeed)
            ?? ReplayHeartRateSource(beats: [], speed: 1, deviceName: "No recording")
    }
}

/// Phase 3 registers the CoreBluetooth source here; until then the app replays recordings everywhere.
enum BLESourceRegistry {
    static var make: (() -> HeartRateSource)?
}
