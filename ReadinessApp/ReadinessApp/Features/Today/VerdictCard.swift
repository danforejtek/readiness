import HRVCore
import SwiftUI

struct VerdictCard: View {
    let assessment: Assessment

    var body: some View {
        if assessment.score == nil {
            BaselinePanel(assessment: assessment)
        } else {
            verdict
        }
    }

    @ViewBuilder private var verdict: some View {
        let status = assessment.status
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(status.title, systemImage: status.symbol)
                    .font(.title2.weight(.bold))
                Text(status.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if assessment.illness {
                        Badge(text: "Possible illness", color: Palette.alert, symbol: "thermometer.medium")
                    }
                    if assessment.lowConfidence {
                        Badge(text: "Low confidence", color: Palette.caution, symbol: "exclamationmark.triangle")
                    }
                }
                Text(Fmt.dayTime.string(from: assessment.record.when))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let score = assessment.score {
                ScoreRing(score: score, color: status.color)
                    .overlay(alignment: .topTrailing) { InfoButton(metric: .score).offset(x: 6, y: -6) }
            }
        }
        .padding()
        .background(status.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(status.color.opacity(0.5), lineWidth: 1))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

struct ScoreRing: View {
    let score: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)").font(.title.weight(.bold)).monospacedDigit()
                Text("/ 100").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityLabel("Readiness score \(score) of 100")
    }
}

/// Horizontal bar showing where a value sits relative to the personal normal range (mean ± 0.5 SD).
struct RangeBar: View {
    let value: Double
    let mean: Double
    let sd: Double
    let higherIsBetter: Bool
    var span: Double = 2.5   // SDs shown on each side

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Palette.good.opacity(0.35))
                    .frame(width: max(2, xPos(mean + 0.5 * sd, w) - xPos(mean - 0.5 * sd, w)))
                    .offset(x: xPos(mean - 0.5 * sd, w))
                Circle()
                    .fill(markerColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: xPos(value, w) - 7)
            }
        }
        .frame(height: 14)
        .accessibilityLabel("\(Fmt.n((value - mean) / sd, 1)) standard deviations from your normal")
    }

    private func xPos(_ v: Double, _ width: CGFloat) -> CGFloat {
        let z = max(-span, min(span, (v - mean) / sd))
        return CGFloat((z + span) / (2 * span)) * width
    }

    private var markerColor: Color {
        let z = (value - mean) / sd
        let bad = higherIsBetter ? -z : z
        if bad <= 0.5 { return Palette.good }
        if bad <= 1.5 { return Palette.caution }
        return Palette.alert
    }
}
