import OSLog
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    private var router = AppRouter.shared
    @State private var showMeasure = false
    @State private var tab: String = AppSettings.debugTab ?? "today"

    var body: some View {
        TabView(selection: $tab) {
            TodayView(onMeasure: { showMeasure = true })
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag("today")
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag("trends")
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
                .tag("history")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .fullScreenCover(isPresented: $showMeasure) {
            MeasureView(autoStart: AppSettings.debugAutoMeasure)
        }
        .task {
            MorningStore.backfillBeatDerived(in: context)
            if AppSettings.debugLoadDemo { PreviewData.loadDemo(into: context) }
            if AppSettings.debugAutoMeasure { showMeasure = true }
            if AppSettings.debugHealthTest {
                UserDefaults.standard.set(true, forKey: AppSettings.healthEnabledKey)
                let log = Logger(subsystem: "com.danforejtek.readiness", category: "health")
                do {
                    try await HealthKitService.shared.requestAuthorization()
                    let all = (try? context.fetch(FetchDescriptor<Morning>())) ?? []
                    let n = try await HealthKitService.shared.saveAll(all)
                    try? context.save()
                    log.info("health test: canWrite=\(HealthKitService.shared.canWrite) saved=\(n) of \(all.count)")
                } catch {
                    log.error("health test failed: \(error.localizedDescription)")
                }
            }
            if AppSettings.debugExportTest,
               let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let all = (try? context.fetch(FetchDescriptor<Morning>())) ?? []
                try? MorningStore.exportCSV(all).write(to: docs.appendingPathComponent("readiness.csv"), atomically: true, encoding: .utf8)
                try? MorningStore.exportBeatsCSV(all).write(to: docs.appendingPathComponent("readiness-beats.csv"), atomically: true, encoding: .utf8)
            }
            if AppSettings.debugReminderTest {
                let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(60))
                UserDefaults.standard.set(true, forKey: AppSettings.reminderEnabledKey)
                UserDefaults.standard.set((c.hour ?? 0) * 60 + (c.minute ?? 0), forKey: AppSettings.reminderMinutesKey)
                _ = await ReminderService.requestPermission()
                replanReminders()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { replanReminders() }
        }
        .onChange(of: showMeasure) { _, shown in
            if !shown { replanReminders() }
        }
        .onChange(of: router.measureRequested, initial: true) { _, requested in
            guard requested else { return }
            router.measureRequested = false
            tab = "today"
            showMeasure = true
        }
    }
}

extension RootView {
    private func replanReminders() {
        let measured = MorningStore.measuredToday(in: context)
        Task { await ReminderService.reschedule(measuredToday: measured) }
    }
}

#Preview {
    RootView().modelContainer(PreviewData.container())
}
