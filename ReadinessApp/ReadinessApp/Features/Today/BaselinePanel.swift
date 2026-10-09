import HRVCore
import SwiftUI

/// Shown instead of the verdict and the score rings until the personal baseline is complete:
/// how many mornings are in, what is still missing, and what unlocks afterwards.
struct BaselinePanel: View {
    let assessment: Assessment

    var body: some View {
        let total = Readiness.minBaselineDays
        let recorded = assessment.baselineRecorded
        let color = ReadinessStatus.baseline.color
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label("Building your baseline", systemImage: "hourglass")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(color)
                Spacer()
                Text("\(recorded) of \(total)")
                    .font(.headline).monospacedDigit()
            }
            Text("Readiness first learns what a normal morning looks like for you, then compares every new morning against it.")
                .font(.subheadline).foregroundStyle(.secondary)

            MorningSteps(recorded: recorded, total: total, color: color)

            Label(nextStep(recorded: recorded, total: total), systemImage: recorded >= total ? "checkmark.circle.fill" : "arrow.forward.circle")
                .font(.callout.weight(.medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("Unlocks after the baseline").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { unlocks }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Unlock(text: "Readiness score", symbol: "gauge.with.needle")
                            Unlock(text: "Illness warning", symbol: "thermometer.medium")
                        }
                        Unlock(text: "Regeneration & Stress", symbol: "circle.lefthalf.filled")
                    }
                }
            }

            HStack(spacing: 8) {
                if assessment.lowConfidence {
                    Badge(text: "Noisy reading", color: Palette.caution, symbol: "exclamationmark.triangle")
                }
                Text(Fmt.dayTime.string(from: assessment.record.when))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var unlocks: some View {
        Unlock(text: "Readiness score", symbol: "gauge.with.needle")
        Unlock(text: "Regeneration & Stress", symbol: "circle.lefthalf.filled")
        Unlock(text: "Illness warning", symbol: "thermometer.medium")
    }

    private func nextStep(recorded: Int, total: Int) -> String {
        let left = total - recorded
        if left <= 0 { return "Baseline complete. Your next morning brings the first readiness score." }
        return "\(left) more \(left == 1 ? "morning" : "mornings") to go, then the morning after brings your first score."
    }
}

/// One pill per baseline morning: filled for the mornings recorded, the latest one emphasised.
private struct MorningSteps: View {
    let recorded: Int
    let total: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { i in
                Capsule()
                    .fill(i <= recorded ? color : color.opacity(0.18))
                    .frame(height: i == recorded ? 10 : 8)
                    .overlay {
                        if i == recorded { Capsule().strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
                    }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

private struct Unlock: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

#Preview {
    VStack {
        BaselinePanel(assessment: Readiness.assess(PreviewData.records(3)))
        BaselinePanel(assessment: Readiness.assess(PreviewData.records(7)))
    }
    .padding()
}
