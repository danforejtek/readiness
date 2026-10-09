import Foundation
import HRVCore
import SwiftUI

/// User-adjustable protocol and data-source settings (UserDefaults-backed).
enum AppSettings {
    static let settleSecondsKey = "settleSeconds"
    static let measureSecondsKey = "measureSeconds"
    static let replaySpeedKey = "replaySpeed"
    static let replayFixtureKey = "replayFixture"
    static let useBandKey = "useBand"
    static let bandIdentifierKey = "bandIdentifier"
    static let bandNameKey = "bandName"
    static let healthEnabledKey = "healthEnabled"
    static let reminderEnabledKey = "reminderEnabled"
    static let reminderMinutesKey = "reminderMinutes"
    static let appearanceKey = "appearance"
    static let bandBatteryKey = "bandBattery"
    static let bandBatteryDateKey = "bandBatteryDate"
    static let baselineResetsKey = "baselineResets"

    /// Measurement auto-extension, the same rule as `hrmon/protocol.py`: when the nominal time is up with fewer
    /// than `minCleanBeats` accepted beats, keep measuring until there are that many or `maxExtensionS` extra
    /// seconds have passed, whichever comes first.
    static let minCleanBeats = 80
    static let maxExtensionS: Double = 60

    static var settleSeconds: Double { UserDefaults.standard.object(forKey: settleSecondsKey) as? Double ?? 15 }
    static var measureSeconds: Double { UserDefaults.standard.object(forKey: measureSecondsKey) as? Double ?? 120 }
    static var replaySpeed: Double {
        if let env = ProcessInfo.processInfo.environment["READINESS_REPLAY_SPEED"], let v = Double(env) { return v }
        return UserDefaults.standard.object(forKey: replaySpeedKey) as? Double ?? 1
    }
    static var replayFixture: String { UserDefaults.standard.string(forKey: replayFixtureKey) ?? "morning-session" }
    static var useBand: Bool { UserDefaults.standard.object(forKey: useBandKey) as? Bool ?? !isSimulator }

    /// The band connected last time (CoreBluetooth identifier, stable per phone); nil until the first connection.
    static var bandIdentifier: UUID? {
        get { UserDefaults.standard.string(forKey: bandIdentifierKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: bandIdentifierKey) }
    }
    static var bandName: String? {
        get { UserDefaults.standard.string(forKey: bandNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: bandNameKey) }
    }
    static var healthEnabled: Bool { UserDefaults.standard.bool(forKey: healthEnabledKey) }
    static var reminderEnabled: Bool { UserDefaults.standard.bool(forKey: reminderEnabledKey) }
    /// Minutes after midnight; default 06:30.
    static var reminderMinutes: Int { UserDefaults.standard.object(forKey: reminderMinutesKey) as? Int ?? 390 }

    /// Last battery level the band reported (%) and when; the band only tells it while connected.
    static var bandBattery: Int? { UserDefaults.standard.object(forKey: bandBatteryKey) as? Int }
    /// Stored as seconds since 1970 so `@AppStorage` can observe it.
    static var bandBatteryDate: Date? {
        (UserDefaults.standard.object(forKey: bandBatteryDateKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func recordBandBattery(_ percent: Int, at date: Date = Date()) {
        UserDefaults.standard.set(percent, forKey: bandBatteryKey)
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: bandBatteryDateKey)
    }

    /// Days on which a new baseline was started (e.g. after switching sensors), oldest first. Stored as
    /// comma-separated start-of-day timestamps so views can observe it with `@AppStorage`; read it with `parseResets`.
    static var baselineResets: [Date] { parseResets(UserDefaults.standard.string(forKey: baselineResetsKey) ?? "") }

    static func parseResets(_ raw: String) -> [Date] {
        raw.split(separator: ",").compactMap { Double($0).map(Date.init(timeIntervalSince1970:)) }.sorted()
    }

    /// Start a new baseline with `day`'s morning (a measurement already taken that day included).
    static func startNewBaseline(on day: Date = Date()) {
        let start = Readiness.calendar.startOfDay(for: day)
        let resets = baselineResets.filter { $0 != start } + [start]
        UserDefaults.standard.set(resets.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: ","), forKey: baselineResetsKey)
    }

    static func undoLastBaselineReset() {
        let resets = baselineResets.dropLast()
        UserDefaults.standard.set(resets.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: ","), forKey: baselineResetsKey)
    }

    /// Below this the sensor may drop out mid-measurement; the app warns before the next one.
    static let lowBatteryPercent = 20

    static func forgetBand() {
        UserDefaults.standard.removeObject(forKey: bandIdentifierKey)
        UserDefaults.standard.removeObject(forKey: bandNameKey)
        UserDefaults.standard.removeObject(forKey: bandBatteryKey)
        UserDefaults.standard.removeObject(forKey: bandBatteryDateKey)
    }

    /// Debug launch environment (used by automated UI checks): READINESS_DEMO=1 loads the demo history,
    /// READINESS_TAB=today|trends|insights|history|settings picks the start tab, READINESS_AUTOMEASURE=1 starts a measurement.
    static var debugLoadDemo: Bool { ProcessInfo.processInfo.environment["READINESS_DEMO"] == "1" }
    /// READINESS_DEMO_DAYS=N keeps only the last N demo mornings (baseline screens).
    static var debugDemoDays: Int? { ProcessInfo.processInfo.environment["READINESS_DEMO_DAYS"].flatMap(Int.init) }
    static var debugTab: String? { ProcessInfo.processInfo.environment["READINESS_TAB"] }
    static var debugAutoMeasure: Bool { ProcessInfo.processInfo.environment["READINESS_AUTOMEASURE"] == "1" }
    /// READINESS_LIVE=1 opens the live heart-rate monitor at launch.
    static var debugLiveMonitor: Bool { ProcessInfo.processInfo.environment["READINESS_LIVE"] == "1" }
    /// READINESS_REMINDER_TEST=1 turns the reminder on for one minute from now (asks for permission once).
    /// READINESS_HEALTH_TEST=1 asks for Health access and saves every eligible morning (Simulator check).
    static var debugHealthTest: Bool { ProcessInfo.processInfo.environment["READINESS_HEALTH_TEST"] == "1" }
    /// READINESS_EXPORT_TEST=1 writes the two export files into the app's Documents folder at launch.
    static var debugExportTest: Bool { ProcessInfo.processInfo.environment["READINESS_EXPORT_TEST"] == "1" }
    static var debugReminderTest: Bool { ProcessInfo.processInfo.environment["READINESS_REMINDER_TEST"] == "1" }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}
