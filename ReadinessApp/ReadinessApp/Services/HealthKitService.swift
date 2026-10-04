import Foundation
import HealthKit

/// Writes each morning's HRV (SDNN, the HRV measure Apple Health uses) and resting heart rate to Apple Health.
/// Samples carry a sync identifier per morning, so saving twice replaces instead of duplicating, and deleting a
/// morning in the app can remove exactly its samples.
@MainActor
final class HealthKitService {
    static let shared = HealthKitService()

    private let store = HKHealthStore()
    private let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
    private let restingType = HKQuantityType(.restingHeartRate)
    private var types: Set<HKSampleType> { [hrvType, restingType] }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Real measurements only: the band, or rows imported from the Mac tool. Replays count in the Simulator so the
    /// flow can be tested there; demo data never goes to Health.
    static func shouldSave(_ m: Morning) -> Bool {
        if m.source == "band" || m.source == "import" { return true }
        return AppSettings.isSimulator && m.source == "replay"
    }

    /// Shows the Health permission sheet the first time; afterwards returns immediately.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: types, read: [])
    }

    /// Health only tells an app whether it may write, so this is exact for our write-only use.
    var canWrite: Bool { types.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized } }
    var wasAsked: Bool { types.allSatisfy { store.authorizationStatus(for: $0) != .notDetermined } }

    func save(_ m: Morning) async throws {
        guard Self.shouldSave(m), m.sdnn.isFinite, m.meanHR.isFinite, m.meanHR > 0 else { return }
        let end = m.date
        let start = m.durationS > 0 ? end.addingTimeInterval(-m.durationS) : end
        let device = HKDevice(name: m.deviceName.isEmpty ? nil : m.deviceName, manufacturer: nil, model: nil,
                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                              localIdentifier: nil, udiDeviceIdentifier: nil)
        func meta(_ kind: String) -> [String: Any] {
            [HKMetadataKeySyncIdentifier: Self.syncID(m, kind), HKMetadataKeySyncVersion: 1,
             HKMetadataKeyWasUserEntered: false]
        }
        let hrv = HKQuantitySample(type: hrvType, quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: m.sdnn),
                                   start: start, end: end, device: device, metadata: meta("sdnn"))
        let resting = HKQuantitySample(type: restingType, quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: m.meanHR),
                                       start: start, end: end, device: device, metadata: meta("resting"))
        try await store.save([hrv, resting])
        m.healthSaved = true
    }

    /// Saves every real morning not yet in Health. Returns how many were written.
    func saveAll(_ mornings: [Morning]) async throws -> Int {
        var n = 0
        for m in mornings where !m.healthSaved && Self.shouldSave(m) {
            try await save(m)
            n += 1
        }
        return n
    }

    /// Removes this app's samples for the given mornings. Health only lets an app delete what it wrote itself.
    func delete(_ mornings: [Morning]) async {
        let ids = mornings.filter(\.healthSaved).flatMap { [Self.syncID($0, "sdnn"), Self.syncID($0, "resting")] }
        guard !ids.isEmpty, canWrite else { return }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: ids)
        for type in [hrvType, restingType] {
            _ = try? await store.deleteObjects(of: type, predicate: predicate)
        }
    }

    private static func syncID(_ m: Morning, _ kind: String) -> String { "readiness.\(m.id.uuidString).\(kind)" }
}
