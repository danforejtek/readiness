import HRVCore
import SwiftUI

/// "How the verdict works": the whole method in plain language, so no number is a black box.
struct MethodView: View {
    var body: some View {
        List {
            Section("The measurement") {
                Para("Measure right after waking, before you get up, coffee or phone. Lie on your back in the same position every day.")
                Para("Put on your heart-rate sensor so it sits snugly with good skin contact: a chest strap with moistened electrodes, or an armband on the forearm. The first 15 seconds let your heart settle and are not used. The next 120 seconds are measured.")
                Para("Breathe normally. Moving, talking or a loose sensor produce rejected beats and a less reliable result.")
            }
            Section("Your normal") {
                Para("Each morning gives two numbers: lnRMSSD, your heart rate variability, and resting heart rate.")
                Para("Your normal is the average of the previous 60 days, today excluded. Your normal range is that average plus or minus half a standard deviation. Sports scientists use this band as the smallest change that matters.")
                Para("The app needs \(Readiness.minBaselineDays) mornings before it gives verdicts. It keeps learning for two months, so the range adapts to fitness changes.")
            }
            Section("The verdict") {
                Rule(status: .rest, text: "HRV 1.5 or more standard deviations below normal, or resting HR 1.5 or more above, or HRV at least 1 below together with resting HR at least 1 above, or the illness warning.")
                Rule(status: .moderate, text: "HRV below your normal range, or resting HR more than 1 standard deviation above normal, or the 7-day HRV average below your range.")
                Rule(status: .ready, text: "Everything else: HRV and resting HR where they usually are, or better.")
            }
            Section("Possible illness") {
                Para("Raised when resting HR is at least 1.5 standard deviations and 4 bpm above normal while HRV is at least 1 standard deviation below, or when resting HR alone is 2.5 standard deviations above.")
                Para("This combination often shows up a day or two before cold symptoms. Several days in a row make it more convincing than a single morning.")
            }
            Section("The score") {
                Para(Metric.score.explanation)
            }
            Section("Stress and Regeneration") {
                Para("Regeneration and Stress follow the PNS and SNS indices of Kubios HRV, a standard research tool. Kubios compares you with population norms; this app compares you with your own previous 60 days, like the verdict.")
                Para("Regeneration is the average of three comparisons: mean RR, RMSSD and SD1. Stress averages resting HR, the square root of the stress index, and SD2, where less slow variation counts as more stress. Each comparison is in your own standard deviations.")
                Para("The average becomes the number: 5 + 2 × the average, kept between 0 and 10. So 5 is your normal, 4–6 is your normal range (half a standard deviation either way), and 2 points are one standard deviation.")
                Para("Both appear after \(Readiness.minBaselineDays) mornings. Mornings imported without beats have no SD1, SD2 or stress index; the numbers then use the parts that are there.")
                Para("“Above average” compares today with the average of your previous 60 days; for Regeneration and Stress the average is 5. “Since last measurement” compares with the previous morning. Neither number changes the verdict.")
            }
            Section("Limits") {
                Para("Alcohol, a late meal, poor sleep, caffeine, a full bladder or a stressful dream all move the numbers. One odd morning means little; a pattern over several mornings is what counts.")
                Para("Optical sensors (armbands, watches) are noisier than an ECG chest strap, so check the signal quality line. Stick with one sensor: switching changes your values a little, so start a new baseline in Settings when you do.")
                Para("Readiness is a training aid, not a medical device. See a doctor about symptoms, not about a score.")
            }
            Section("What the numbers mean") {
                ForEach(Metric.allCases) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.title).font(.subheadline.weight(.semibold))
                        Text(m.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("How the verdict works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Para: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View { Text(text).font(.callout) }
    }

    private struct Rule: View {
        let status: ReadinessStatus
        let text: String
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.symbol).foregroundStyle(status.color).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.subheadline.weight(.semibold))
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview { NavigationStack { MethodView() } }
