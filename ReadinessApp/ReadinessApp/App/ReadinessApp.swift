import SwiftData
import SwiftUI

@main
struct ReadinessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppSettings.appearanceKey) private var appearance = Appearance.dark
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Morning.self)
        } catch {
            fatalError("Could not create the SwiftData store: \(error)")
        }
    }()

    init() {
        // The real band; `SourceFactory` still falls back to replay in the Simulator or when the toggle is off.
        BLESourceRegistry.make = { BLEHeartRateSource() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.colorScheme)
                .tint(Palette.accent)
        }
        .modelContainer(container)
    }
}
