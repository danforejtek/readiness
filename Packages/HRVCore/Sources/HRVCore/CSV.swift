import Foundation

/// Minimal CSV support compatible with the files written by the `hrmon` Mac tool.
public enum CSV {
    /// Parse a CSV text with a header row into dictionaries. Handles double-quoted fields.
    public static func parse(_ text: String) -> (headers: [String], rows: [[String: String]]) {
        var lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init)
        guard !lines.isEmpty else { return ([], []) }
        let headers = splitLine(lines.removeFirst())
        let rows = lines.map { line -> [String: String] in
            let fields = splitLine(line)
            var row: [String: String] = [:]
            for (i, h) in headers.enumerated() { row[h] = i < fields.count ? fields[i] : "" }
            return row
        }
        return (headers, rows)
    }

    static func splitLine(_ line: String) -> [String] {
        var out: [String] = [], field = "", quoted = false
        var it = line.makeIterator()
        while let ch = it.next() {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == ",", !quoted { out.append(field); field = ""; continue }
            field.append(ch)
        }
        out.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        return out
    }

    public static func line(_ fields: [String]) -> String {
        fields.map { f in f.contains(",") || f.contains("\"") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f }
            .joined(separator: ",")
    }
}

/// `sessions/readiness.csv` rows ⇄ `DayRecord`s.
public enum ReadinessCSV {
    public static let dateFormat = "yyyy-MM-dd HH:mm"
    public static let columns = ["date", "duration_s", "beats", "mean_hr", "mean_rr_ms", "rmssd_ms", "ln_rmssd", "sdnn_ms",
                                 "pnn50_pct", "artefact_pct", "quality", "lf_ms2", "hf_ms2", "lf_hf", "breathing_bpm", "settle_s",
                                 // morning check-in and origin (phase 6); not used by the verdict, only for tuning
                                 "feeling", "tags", "source",
                                 // beat-derived (phase A1): Poincaré SD1/SD2 and Baevsky's stress index
                                 "sd1_ms", "sd2_ms", "stress_index"]

    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Readiness.calendar
        f.timeZone = Readiness.calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = dateFormat
        return f
    }

    static func double(_ row: [String: String], _ key: String) -> Double? {
        guard let v = row[key], !v.isEmpty else { return nil }
        return Double(v)
    }

    /// One record per calendar day; the best-quality measurement of the day wins. Port of `records_from_rows`.
    public static func records(from rows: [[String: String]]) -> [DayRecord] {
        let fmt = formatter()
        var perDay: [Date: DayRecord] = [:]
        for row in rows {
            guard let d = row["date"], let when = fmt.date(from: d),
                  let ln = double(row, "ln_rmssd"), let hr = double(row, "mean_hr") else { continue }
            let rec = DayRecord(when: when, lnRMSSD: ln, rmssd: double(row, "rmssd_ms") ?? 0, meanHR: hr,
                                sdnn: double(row, "sdnn_ms") ?? 0, beats: Int(double(row, "beats") ?? 0),
                                artefactPct: double(row, "artefact_pct") ?? 0, hfMs2: double(row, "hf_ms2"),
                                lfMs2: double(row, "lf_ms2"), breathingRate: double(row, "breathing_bpm"),
                                meanRR: double(row, "mean_rr_ms"), sd1: double(row, "sd1_ms"), sd2: double(row, "sd2_ms"),
                                stressIndex: double(row, "stress_index"))
            if let prev = perDay[rec.day], prev.artefactPct <= rec.artefactPct { continue }
            perDay[rec.day] = rec
        }
        return perDay.keys.sorted().map { perDay[$0]! }
    }

    public static func records(fromText text: String) -> [DayRecord] { records(from: CSV.parse(text).rows) }

    /// Build a `readiness.csv` row (same columns as the Mac tool) from a finished measurement.
    public static func row(when: Date, metrics m: HRVMetrics, spectral sp: SpectralMetrics?, settleS: Double,
                           poincare pc: Poincare? = nil, stressIndex si: Double? = nil) -> [String: String] {
        let quality = m.artefactPct < 5 ? "good" : m.artefactPct < 15 ? "fair" : "poor"
        func s(_ x: Double, _ d: Int) -> String { String(format: "%.\(d)f", x) }
        return [
            "date": formatter().string(from: when), "duration_s": s(m.durationS, 0), "beats": String(m.n),
            "mean_hr": s(m.meanHR, 1), "mean_rr_ms": s(m.meanRR, 1), "rmssd_ms": s(m.rmssd, 1), "ln_rmssd": s(m.lnRMSSD, 2),
            "sdnn_ms": s(m.sdnn, 1), "pnn50_pct": s(m.pnn50, 1), "artefact_pct": s(m.artefactPct, 1), "quality": quality,
            "lf_ms2": sp.map { s($0.lfMs2, 0) } ?? "", "hf_ms2": sp.map { s($0.hfMs2, 0) } ?? "",
            "lf_hf": sp.flatMap { $0.lfHf.isFinite ? s($0.lfHf, 2) : nil } ?? "",
            "breathing_bpm": sp?.breathingRateBpm.map { s($0, 1) } ?? "", "settle_s": s(settleS, 0),
            "sd1_ms": pc.map { s($0.sd1, 1) } ?? "", "sd2_ms": pc.map { s($0.sd2, 1) } ?? "",
            "stress_index": si.map { s($0, 1) } ?? "",
        ]
    }

    public static func text(rows: [[String: String]]) -> String {
        ([CSV.line(columns)] + rows.map { r in CSV.line(columns.map { r[$0] ?? "" }) }).joined(separator: "\n") + "\n"
    }
}

/// Per-beat session CSV (`sessions/<timestamp>.csv`): rows with elapsed seconds and RR.
public enum SessionCSV {
    public struct Beat: Equatable, Sendable { public let elapsedS: Double; public let hr: Int; public let rrMs: Double? }

    public static func beats(fromText text: String) -> [Beat] {
        CSV.parse(text).rows.compactMap { row in
            guard let el = Double(row["elapsed_s"] ?? ""), let hr = Int(row["hr_bpm"] ?? "") else { return nil }
            return Beat(elapsedS: el, hr: hr, rrMs: Double(row["rr_ms"] ?? ""))
        }
    }
}
