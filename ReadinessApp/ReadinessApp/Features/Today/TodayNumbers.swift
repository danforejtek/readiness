import HRVCore
import SwiftUI

/// "Today's numbers": Regeneration, Readiness and Stress as three rings, with the comparison chips.
struct TodayNumbersCard: View {
    let assessment: Assessment
    let isToday: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(isToday ? "Today's numbers" : "Last measurement").font(.headline)
                if assessment.provisional { Badge.provisional }
                Spacer(minLength: 4)
                Text(Fmt.dayTime.string(from: assessment.record.when)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .top, spacing: 8) {
                IndexColumn(title: "Regeneration", info: .regeneration, value: assessment.regeneration,
                            direction: .higherIsBetter, change: assessment.regenerationChange, tint: Palette.regeneration)
                ReadinessColumn(assessment: assessment)
                IndexColumn(title: "Stress", info: .stress, value: assessment.stress,
                            direction: .lowerIsBetter, change: assessment.stressChange, tint: Palette.stress)
            }
            if assessment.regeneration != nil || assessment.stress != nil {
                Text("Regeneration and Stress: 5 is your normal, 4–6 your normal range.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ColumnTitle: View {
    let title: String
    let info: Metric

    var body: some View {
        // Only the text is centred over the ring; the ⓘ hangs off its trailing edge.
        Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .overlay(alignment: .trailing) {
                InfoButton(metric: info)
                    .fixedSize()
                    .alignmentGuide(.trailing) { d in d[.leading] - 3 }
            }
    }
}

private struct IndexColumn: View {
    let title: String
    let info: Metric
    let value: Double?
    let direction: MetricDirection
    let change: Comparison
    /// The ring shows what is measured; the level label below says whether it is good.
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            ColumnTitle(title: title, info: info)
            if let value {
                let level = IndexLevel(value: value, direction: direction)
                RingGauge(fraction: value / 10, color: tint) {
                    Text(Fmt.n(value, 1)).font(.title2.weight(.bold)).monospacedDigit()
                    Text("/ 10").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title) \(Fmt.n(value, 1)) of 10, \(level.label(direction))")
                Text(level.label(direction)).font(.subheadline.weight(.semibold)).foregroundStyle(level.color)
                VStack(spacing: 6) {
                    ForEach(ChangeChip.chips(change, direction: direction), id: \.text) { chip in
                        ChipView(chip: chip, short: true)
                    }
                }
            } else {
                RingGauge(fraction: 0, color: .secondary) {
                    Text("–").font(.title2.weight(.bold))
                }
                Text("after \(Readiness.minBaselineDays) mornings").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ReadinessColumn: View {
    let assessment: Assessment

    var body: some View {
        let status = assessment.status
        VStack(spacing: 10) {
            ColumnTitle(title: "Readiness", info: .score)
            if let score = assessment.score {
                RingGauge(fraction: Double(score) / 100, color: Palette.readiness) {
                    Text("\(score)").font(.title2.weight(.bold)).monospacedDigit()
                    Text("/ 100").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Readiness score \(score) of 100, \(status.title)")
            } else {
                let total = Readiness.minBaselineDays
                RingGauge(fraction: Double(assessment.baselineRecorded) / Double(total), color: status.color) {
                    Text("\(assessment.baselineRecorded)/\(total)").font(.title3.weight(.bold)).monospacedDigit()
                    Text("mornings").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(status.title).font(.subheadline.weight(.semibold)).foregroundStyle(status.color)
                .multilineTextAlignment(.center)
            if assessment.score != nil {
                Text("75 = normal").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A progress ring with a label in the middle.
struct RingGauge<Label: View>: View {
    let fraction: Double
    let color: Color
    var size: CGFloat = 84
    var lineWidth: CGFloat = 9
    @ViewBuilder let label: () -> Label

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, fraction))))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0, content: label)
        }
        .frame(width: size, height: size)
    }
}

/// "▲ 8 % above average", green when the change is good for this metric, orange when it is not.
struct ChipView: View {
    let chip: ChangeChip
    var short = false

    var body: some View {
        Text(short ? chip.shortText : chip.text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel(chip.text)
    }

    private var color: Color {
        switch chip.isGood {
        case true?: return Palette.good
        case false?: return Palette.caution
        case nil: return .secondary
        }
    }
}

/// The chips of one comparison side by side, stacked when they do not fit.
struct ChipRow: View {
    let change: Comparison
    let direction: MetricDirection

    var body: some View {
        let chips = ChangeChip.chips(change, direction: direction)
        if !chips.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { ForEach(chips, id: \.text) { ChipView(chip: $0) } }
                VStack(alignment: .leading, spacing: 4) { ForEach(chips, id: \.text) { ChipView(chip: $0) } }
            }
        }
    }
}

extension IndexLevel {
    var color: Color {
        switch self {
        case .better, .normal: return Palette.good
        case .slightlyWorse: return Palette.caution
        case .clearlyWorse: return Palette.alert
        }
    }

    func label(_ direction: MetricDirection) -> String {
        let regeneration = direction == .higherIsBetter
        switch self {
        case .better: return regeneration ? "High" : "Low"
        case .normal: return "Normal"
        case .slightlyWorse: return regeneration ? "Low" : "Raised"
        case .clearlyWorse: return regeneration ? "Very low" : "High"
        }
    }
}
