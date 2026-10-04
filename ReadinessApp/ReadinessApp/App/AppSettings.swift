import Foundation
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

    static func forgetBand() {
        UserDefaults.standard.removeObject(forKey: bandIdentifierKey)
        UserDefaults.standard.removeObject(forKey: bandNameKey)
    }

    /// Debug launch environment (used by automated UI checks): READINESS_DEMO=1 loads the demo history,
    /// READINESS_TAB=today|trends|history|settings picks the start tab, READINESS_AUTOMEASURE=1 starts a measurement.
    static var debugLoadDemo: Bool { ProcessInfo.processInfo.environment["READINESS_DEMO"] == "1" }
    static var debugTab: String? { ProcessInfo.processInfo.environment["READINESS_TAB"] }
    static var debugAutoMeasure: Bool { ProcessInfo.processInfo.environment["READINESS_AUTOMEASURE"] == "1" }
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
