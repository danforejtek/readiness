import HRVCore
import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Morning.date, order: .reverse) private var mornings: [Morning]
    @AppStorage(AppSettings.baselineResetsKey) private var baselineResets = ""

    var body: some View {
        // Every day assessed once (linear in the list), looked up per row by morning id. A second measurement on the
        // same day is not the day's representative, so only that row is assessed on its own.
        let resets = AppSettings.parseResets(baselineResets)
        let byMorning = Dictionary(MorningStore.dayAssessments(mornings, resets: resets).map { ($0.morning.id, $0.assessment) },
                                   uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List {
                ForEach(mornings) { m in
                    NavigationLink { MorningDetailView(morning: m) } label: {
                        HistoryRow(morning: m, assessment: byMorning[m.id] ?? MorningStore.assessment(for: m, in: mornings, resets: resets))
                    }
                }
                .onDelete { offsets in
                    let targets = offsets.map { mornings[$0] }
                    Task {
                        await HealthKitService.shared.delete(targets)
                        for m in targets { context.delete(m) }
                        try? context.save()
                    }
                }
            }
            .overlay {
                if mornings.isEmpty {
                    ContentUnavailableView("No measurements", systemImage: "list.bullet.rectangle",
                                           description: Text("Each morning measurement appears here."))
                }
            }
            .navigationTitle("History")
            .toolbar { EditButton() }
        }
    }
}

private struct HistoryRow: View {
    let morning: Morning
    let assessment: Assessment

    var body: some View {
        let a = assessment
        HStack(spacing: 12) {
            Circle().fill(a.status.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.dayTime.string(from: morning.date)).font(.subheadline.weight(.semibold))
                Text("HR \(Fmt.n(morning.meanHR)) · RMSSD \(Fmt.n(morning.rmssd)) ms · \(morning.quality)\(morning.hasBeats ? "" : " · imported")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = a.score { Text("\(s)").font(.headline).monospacedDigit() }
            if a.illness { Image(systemName: "thermometer.medium").foregroundStyle(Palette.alert) }
        }
    }
}

#Preview {
    HistoryView().modelContainer(PreviewData.container())
}
