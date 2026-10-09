import Foundation
import Observation

/// Connects to the band just long enough to read its battery, then lets go so other apps can use it.
/// The level is stored by `BLEHeartRateSource` (`AppSettings.bandBattery`); this only drives the button state.
@MainActor
@Observable
final class BandBatteryCheck {
    private(set) var running = false
    private(set) var status: String?
    private var task: Task<Void, Never>?

    func start() {
        guard !running, let source = BLESourceRegistry.make?() else { return }
        running = true
        status = nil
        task = Task { [weak self] in
            var result: String?
            for await event in source.events() {
                switch event {
                case .status(let s):
                    self?.status = s
                case .connected(let device, let battery):
                    result = battery == nil ? "\(device) does not report its battery." : nil
                    source.stop()
                case .failed(let message):
                    result = message
                default:
                    break
                }
                if Task.isCancelled { break }
            }
            source.stop()
            self?.status = result
            self?.running = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
        status = nil
    }
}
