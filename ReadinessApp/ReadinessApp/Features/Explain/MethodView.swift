import HRVCore
import SwiftUI

/// "How the verdict works": the whole method in plain language, so no number is a black box.
struct MethodView: View {
    var body: some View {
        List {
            Section("The measurement") {
                Para("Measure right after waking, before you get up, coffee or phone. Lie on your back in the same position every day. Empty your bladder first, or always do the same. A full bladder raises your blood pressure.")
                Para("Put on your heart-rate sensor so it sits snugly with good skin contact: a chest strap with moistened electrodes, or an armband on the forearm. The first \(Int(AppSettings.settleSeconds)) seconds let your heart rate level off after lying down and are not used; studies let it settle for about a minute. The next \(Int(AppSettings.measureSeconds)) seconds are measured. If too many beats are rejected and fewer than \(AppSettings.minCleanBeats) clean ones are in by then, the app keeps measuring for up to \(Int(AppSettings.maxExtensionS)) seconds more.")
                Para("Breathe normally. Moving, talking or a loose sensor produce rejected beats and a less reliable result.")
                Para("An optical armband measures pulse-rate variability: the pulse at your arm, not the heart's electrical signal that an ECG chest strap records. At rest the two agree well, but the optical signal is more sensitive to arm movement, so keep the arm still.")
            }
            Section("Your normal") {
                Para("Each morning gives two numbers: lnRMSSD, your heart rate variability, and resting heart rate.")
                Para("Your normal is the average of the previous 60 days, today excluded. Your normal range is that average plus or minus half a standard deviation. Sports scientists use this band as the smallest change that matters.")
                Para("The app needs \(Readiness.minBaselineDays) mornings before it gives verdicts. It keeps learning for two months, so the range adapts to fitness changes.")
                Para("Noisy mornings, the ones marked low confidence, are left out of your average and range once there are seven clean mornings, so one bad reading does not shift your normal.")
                Para("The 7-day HRV average can flag fatigue only once at least \(Readiness.weekMinDays) mornings fall in the seven days. A study of how often athletes need to measure (Plews and colleagues, 2014) found that three mornings a week reproduce the weekly picture; fewer can mislead.")
            }
            Section("The verdict") {
                Rule(status: .rest, text: "HRV 1.5 or more standard deviations below normal, or resting HR 1.5 or more above, or HRV at least 1 below together with resting HR at least 1 above, or the illness warning.")
                Rule(status: .moderate, text: "HRV 1 or more standard deviations below normal, or resting HR more than 1 above, or the 7-day HRV average below your normal range (with at least \(Readiness.weekMinDays) mornings in the week).")
                Para("A single morning's HRV only counts from 1 standard deviation below normal. Between the edge of your range and there it is day-to-day noise: about one ordinary morning in three lands below the range. The training studies that guided athletes by HRV acted on the 7-day average, or on single mornings at least 1 standard deviation down (Kiviniemi and colleagues, 2007; Plews and colleagues, 2012–2013). So the 7-day average keeps the half-standard-deviation range.")
                Rule(status: .ready, text: "Everything else: HRV and resting HR where they usually are, or better.")
            }
            Section("Possible illness") {
                Para("A morning is flagged when resting HR is at least 1.5 standard deviations and 4 bpm above normal while HRV is at least 1 standard deviation below, or when resting HR alone is at least 2.5 standard deviations and 4 bpm above normal.")
                Para("The warning needs \(Readiness.illnessMinDays) flagged mornings in a row. A single one only adds a note, and the verdict follows the usual rules: one morning like this is often alcohol, poor sleep, travel or stress. The published detectors also look at several days, not one (Mishra and colleagues, 2020; Alavi and colleagues, 2022). The streak counts consecutive calendar days, so a day without a measurement ends it.")
                Para("This pattern often shows up one to three days before a cold or other infection, but alcohol, poor sleep, travel and stress produce it too. The limits are this app's rules of thumb, not taken from a study.")
            }
            Section("The score") {
                Para(Metric.score.explanation)
            }
            Section("Stress and Regeneration") {
                Para("Both compare you with your own previous 60 days, the same clean mornings the verdict uses, in your own standard deviations.")
                Para("Regeneration is your HRV, lnRMSSD, against your own normal. Nothing else goes in: SD1 is RMSSD divided by √2 and mean RR is just the inverse of heart rate, so adding them would count the same thing twice.")
                Para("Stress is strain or load: two thirds resting HR, one third SD2, the slower variation, where less counts as more strain. That second part is the Stress Score of Naranjo Orellana and colleagues (2015) on a logarithmic scale. Mornings imported without beats have no SD2 and use resting HR alone. No heart measurement this short can show stress hormones or nerve activity directly, so read Stress as a load signal, whatever its cause.")
                Para("The comparison becomes the number: 5 + 2 × the comparison, kept between 0 and 10. So 5 is your normal, 4–6 is your normal range (half a standard deviation either way), and 2 points are one standard deviation.")
                Para("Both appear after \(Readiness.minBaselineDays) mornings.")
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
