import Foundation
import HRVCore
import SwiftData

/// In-memory store filled from the bundled demo CSVs, for previews and the Settings "load demo data" action.
enum PreviewData {
    @MainActor
    static func container() -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Morning.self, configurations: config)
        loadDemo(into: container.mainContext)
        return container
    }

    /// `days` keeps only the last N demo mornings (plus today's replay), e.g. to see the baseline panel.
    @MainActor
    static func loadDemo(into context: ModelContext, days: Int? = nil) {
        if var text = MorningStore.fixtureText("demo-history") {
            if let days {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                text = ([lines[0]] + lines.dropFirst().suffix(days)).joined(separator: "\n") + "\n"
            }
            _ = try? MorningStore.importCSV(text, into: context, source: "demo")
        }
        if let morning = replayMorning(fixture: "morning-session", date: .now) {
            context.insert(morning)
            try? context.save()
        }
    }

    /// Run a recorded session through the same pipeline as a live measurement.
    static func replayMorning(fixture: String, date: Date, settleS: Double = 15) -> Morning? {
        guard let text = MorningStore.fixtureText(fixture) else { return nil }
        let beats = SessionCSV.beats(fromText: text)
        let buffer = RRBuffer()
        var allRR: [Double] = [], allElapsed: [Double] = []
        for b in beats {
            guard let rr = b.rrMs else { continue }
            allRR.append(rr); allElapsed.append(b.elapsedS)
            if b.elapsedS >= settleS { buffer.add(rr, at: b.elapsedS) }
        }
        guard let m = buffer.metrics() else { return nil }
        return Morning(date: date, metrics: m, spectral: buffer.spectral(), settleS: settleS, rrMs: buffer.values,
                       beatTimes: buffer.beatTimes, allRR: allRR, allElapsed: allElapsed, source: "replay", deviceName: "Elonga-0007631")
    }

    /// Synthetic daily records for previews of the assessment views.
    static func records(_ n: Int) -> [DayRecord] {
        (0..<n).map { i in
            let when = Calendar.current.date(byAdding: .day, value: i - n + 1, to: .now)!
            return DayRecord(when: when, lnRMSSD: 4.0 + Double(i % 3) * 0.05, rmssd: 55, meanHR: 52 + Double(i % 2),
                             sdnn: 60, beats: 120, artefactPct: 2)
        }
    }
}
