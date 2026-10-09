import CoreHaptics
import UIKit

/// Single-pulse haptic cues for the end of a measurement, felt with eyes closed. No-op on hardware without haptics
/// (iPad, Simulator).
@MainActor
enum Haptics {
    private static let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard supported else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
