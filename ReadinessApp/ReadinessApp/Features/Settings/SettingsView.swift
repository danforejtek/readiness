import HRVCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Morning.date) private var mornings: [Morning]
    @AppStorage(AppSettings.settleSecondsKey) private var settleSeconds = 15.0
    @AppStorage(AppSettings.measureSecondsKey) private var measureSeconds = 120.0
    @AppStorage(AppSettings.useBandKey) private var useBand = !AppSettings.isSimulator
    @AppStorage(AppSettings.replayFixtureKey) private var replayFixture = "morning-session"
    @AppStorage(AppSettings.replaySpeedKey) private var replaySpeed = 1.0
    @AppStorage(AppSettings.bandNameKey) private var bandName: String?
    @AppStorage(AppSettings.healthEnabledKey) private var healthEnabled = false
    @AppStorage(AppSettings.reminderEnabledKey) private var reminderEnabled = false
    @AppStorage(AppSettings.reminderMinutesKey) private var reminderMinutes = 390
    @State private var healthMessage: String?
    @State private var reminderMessage: String?
    @State private var healthBusy = false
    private var router = AppRouter.shared
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var confirmDelete = false
    @State private var exportURLs: [URL]?

    var body: some View {
        NavigationStack {
            Form {
                Section("Morning protocol") {
                    Stepper("Settle: \(Int(settleSeconds)) s", value: $settleSeconds, in: 0...60, step: 5)
                    Stepper("Measure: \(Int(measureSeconds)) s", value: $measureSeconds, in: 60...300, step: 30)
                    Text("Elonga uses 120 s. Keep the same protocol every day so values stay comparable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Heart-rate source") {
                    Toggle("Use the Bluetooth band", isOn: $useBand)
                        .disabled(AppSettings.isSimulator || BLESourceRegistry.make == nil)
                    if AppSettings.isSimulator {
                        Text("The Simulator has no Bluetooth; recordings are replayed instead.").font(.footnote).foregroundStyle(.secondary)
                    } else if let bandName {
                        LabeledContent("Remembered band", value: bandName)
                        Button("Forget band") { AppSettings.forgetBand() }
                        Text("The next measurement connects to this band first. Forget it to pick up a different sensor.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("No band remembered yet. The first measurement connects to the first heart-rate sensor it finds (press the band's button so it blinks blue) and remembers it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Recording to replay", selection: $replayFixture) {
                        ForEach(MorningStore.fixtureSessions, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        Text("Replay speed")
                        Slider(value: $replaySpeed, in: 1...20, step: 1)
                        Text("\(Int(replaySpeed))×").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Section {
                    Toggle("Morning reminder", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("Time", selection: reminderTime, displayedComponents: .hourAndMinute)
                        if let nextReminder = router.nextReminder {
                            LabeledContent("Next reminder", value: nextReminder.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let reminderMessage { Text(reminderMessage).font(.footnote).foregroundStyle(.orange) }
                } header: {
                    Text("Reminder")
                } footer: {
                    Text("A notification at this time each morning, skipped on days you have already measured. Tapping it opens the measurement.")
                }
                .onChange(of: reminderEnabled) { _, on in Task { await reminderToggled(on) } }
                .onChange(of: reminderMinutes) { _, _ in replanReminders() }

                if HealthKitService.isAvailable {
                    Section {
                        Toggle("Save to Apple Health", isOn: $healthEnabled)
                            .disabled(healthBusy)
                        if healthEnabled {
                            let pending = mornings.filter { !$0.healthSaved && HealthKitService.shouldSave($0) }.count
                            Button { Task { await saveAllToHealth() } } label: {
                                Label(pending == 0 ? "All measurements are in Apple Health" : "Save \(pending) earlier measurements",
                                      systemImage: "heart.text.square")
                            }
                            .disabled(pending == 0 || healthBusy)
                        }
                        if let healthMessage { Text(healthMessage).font(.footnote).foregroundStyle(.secondary) }
                    } header: {
                        Text("Apple Health")
                    } footer: {
                        Text("Writes heart rate variability (as SDNN, the measure Apple Health uses) and resting heart rate after each measurement with the band. RMSSD, the score and the verdict stay in this app. Deleting a measurement here also removes its Health entries.")
                    }
                    .onChange(of: healthEnabled) { _, on in if on { Task { await enableHealth() } } }
                }

                Section("Data") {
                    LabeledContent("Measurements", value: "\(mornings.count)")
                    Button { showImporter = true } label: { Label("Import readiness.csv", systemImage: "square.and.arrow.down") }
                    if let urls = exportURLs {
                        ShareLink(items: urls) {
                            Label("Share export (\(mornings.count) mornings, \(urls.count) files)", systemImage: "square.and.arrow.up")
                        }
                        Text("readiness.csv has one row per morning with your check-ins; readiness-beats.csv has every beat. AirDrop both to the Mac and run `hrmon analyze` (see docs/tuning.md).")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button { exportURLs = writeExport() } label: { Label("Prepare CSV export", systemImage: "doc.text") }
                            .disabled(mornings.isEmpty)
                    }
                    Button { loadDemo() } label: { Label("Load demo history", systemImage: "wand.and.stars") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete all measurements", systemImage: "trash") }
                        .disabled(mornings.isEmpty)
                    if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("About") {
                    NavigationLink { MethodView() } label: { Label("How the verdict works", systemImage: "questionmark.circle") }
                    Text("Readiness reproduces the open morning-HRV method (lnRMSSD and resting HR against your own 60-day baseline, normal range ± 0.5 SD). It is a training aid, not a medical device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
                importMessage = handleImport(result)
            }
            .confirmationDialog("Delete all \(mornings.count) measurements?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    let targets = mornings
                    Task {
                        await HealthKitService.shared.delete(targets)
                        for m in targets { context.delete(m) }
                        try? context.save()
                        exportURLs = nil
                    }
                }
            } message: {
                Text("Entries this app wrote to Apple Health are removed too.")
            }
            .onChange(of: mornings.count) { _, _ in exportURLs = nil }
            .task { router.nextReminder = await ReminderService.nextFireDate() }
        }
    }

    private var reminderTime: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: reminderMinutes / 60, minute: reminderMinutes % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            reminderMinutes = (c.hour ?? 6) * 60 + (c.minute ?? 30)
        }
    }

    private func replanReminders() {
        let measured = MorningStore.measuredToday(in: context)
        Task { await ReminderService.reschedule(measuredToday: measured) }
    }

    private func reminderToggled(_ on: Bool) async {
        reminderMessage = nil
        if on, !(await ReminderService.requestPermission()) {
            reminderEnabled = false
            reminderMessage = "Notifications are off for Readiness. Allow them in Settings › Notifications › Readiness."
            return
        }
        replanReminders()
    }

    private func enableHealth() async {
        healthBusy = true
        defer { healthBusy = false }
        do {
            try await HealthKitService.shared.requestAuthorization()
        } catch {
            healthEnabled = false
            healthMessage = "Apple Health is not available: \(error.localizedDescription)"
            return
        }
        if HealthKitService.shared.canWrite {
            healthMessage = "New measurements are saved to Apple Health."
        } else {
            healthEnabled = false
            healthMessage = "Readiness may not write to Apple Health. Allow it in the Health app › Profile › Apps › Readiness."
        }
    }

    private func saveAllToHealth() async {
        healthBusy = true
        defer { healthBusy = false }
        do {
            let n = try await HealthKitService.shared.saveAll(mornings)
            try? context.save()
            healthMessage = "Saved \(n) measurements to Apple Health."
        } catch {
            healthMessage = "Saving failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<URL, Error>) -> String {
        switch result {
        case .failure(let error):
            return "Import failed: \(error.localizedDescription)"
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let n = try MorningStore.importCSV(text, into: context)
                return "Imported \(n) new rows from \(url.lastPathComponent)."
            } catch {
                return "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func loadDemo() {
        PreviewData.loadDemo(into: context)
        importMessage = "Demo history loaded (synthetic 35 days plus one replayed real morning)."
    }

    private func writeExport() -> [URL]? {
        let dir = FileManager.default.temporaryDirectory
        let summary = dir.appendingPathComponent("readiness.csv")
        let beats = dir.appendingPathComponent("readiness-beats.csv")
        do {
            try MorningStore.exportCSV(mornings).write(to: summary, atomically: true, encoding: .utf8)
            try MorningStore.exportBeatsCSV(mornings).write(to: beats, atomically: true, encoding: .utf8)
            return [summary, beats]
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }
}

#Preview {
    SettingsView().modelContainer(PreviewData.container())
}
