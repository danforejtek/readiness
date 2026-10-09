import SwiftUI

/// Plain-language explanation of every number the app shows. One place, so the wording stays consistent.
enum Metric: String, CaseIterable, Identifiable {
    case score, regeneration, stress, lnRMSSD, rmssd, restingHR, weekAverage, quality, sdnn, pnn50, meanRR, sd1sd2,
         stressIndex, hf, lf, lfHf, breathing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lnRMSSD: return "lnRMSSD"
        case .rmssd: return "RMSSD"
        case .restingHR: return "Resting heart rate"
        case .weekAverage: return "7-day HRV average"
        case .quality: return "Signal quality"
        case .sdnn: return "SDNN"
        case .pnn50: return "pNN50"
        case .meanRR: return "Mean RR"
        case .sd1sd2: return "SD1 and SD2"
        case .hf: return "HF power"
        case .lf: return "LF power"
        case .lfHf: return "LF/HF"
        case .breathing: return "Breathing rate"
        case .score: return "Readiness score"
        case .regeneration: return "Regeneration"
        case .stress: return "Stress"
        case .stressIndex: return "Stress index"
        }
    }

    var explanation: String {
        switch self {
        case .lnRMSSD:
            return "The natural logarithm of RMSSD. The logarithm makes changes comparable from day to day, so this is the value the verdict uses. Most adults sit between 3 and 5, but only your own trend matters."
        case .rmssd:
            return "How much consecutive heartbeats differ, in milliseconds. It mirrors the calming, recovering branch of the nervous system. Above your normal usually means well recovered; below it means your body is dealing with strain."
        case .restingHR:
            return "Average heart rate over the measurement. A rise of several beats per minute over your normal is one of the earliest signs of illness, stress or fatigue, often before you feel it."
        case .weekAverage:
            return "Average lnRMSSD over the last seven days, today included. A single low day is normal noise; a week below your range shows fatigue that has been building up. It only counts towards the verdict once at least 3 mornings fall in the seven days."
        case .quality:
            return "Share of intervals the filter rejected: values below 300 ms or above 2000 ms, or jumps of more than 20 % from the recent beats. Movement and a loose band cause them. After five consecutive consistent beats at a new level the filter re-synchronises: those five still count as rejected, and beats are accepted again from the sixth onwards, so a genuine change of heart rate during the measurement is not rejected for the rest of it. The difference between the beats on either side of a rejected one is left out of RMSSD, pNN50 and SD1, because it is not a real beat-to-beat change. Above 5 %, or fewer than 60 clean beats, the verdict is marked low confidence; many studies leave out recordings above about 5 %. The quality label in the CSV export is coarser: good below 5 %, fair below 15 %, poor above."
        case .sdnn:
            return "Standard deviation of all intervals between beats. It mixes beat-to-beat and slower changes, so it depends more on breathing and posture than RMSSD. Apple Health stores HRV as SDNN."
        case .pnn50:
            return "Share of consecutive beats that differ by more than 50 ms. It moves together with RMSSD."
        case .meanRR:
            return "Average time between two beats. 1000 ms equals 60 beats per minute."
        case .sd1sd2:
            return "From the Poincaré plot, where every beat is plotted against the next. SD1 is the width of the cloud across the diagonal, the fast beat-to-beat variation. It is RMSSD divided by √2, so it tells the same story as RMSSD and the app does not count it twice. SD2 is the length of the cloud along the diagonal, the slower variation; it makes up a third of the Stress number. Pairs of beats on either side of a rejected beat are left out."
        case .hf:
            return "Variation at breathing speed, 0.15–0.40 Hz or 9–24 breaths a minute. Your heart speeds up slightly when you breathe in and slows when you breathe out. It follows RMSSD closely."
        case .lf:
            return "Slower variation, 0.04–0.15 Hz, mainly from blood-pressure regulation. Breathing slower than 9 breaths a minute also lands here. A 2-minute recording holds only about five cycles of this band, so the value is indicative only and the verdict does not use it."
        case .lfHf:
            return "Ratio of slow to breathing-speed variation. It is often called a stress balance, but it shifts strongly with how you breathe: breathing slower than 9 breaths a minute pushes it up on its own. A 2-minute recording also holds only about five cycles of the LF band, so it is indicative only and the verdict does not use it."
        case .breathing:
            return "Estimated from the strongest peak of the spectrum between 6 and 30 breaths a minute (0.10–0.50 Hz), so slow breathing below the HF band is found too. The search also stops below half your heart rate (25 breaths a minute at 50 bpm), the fastest rhythm a once-per-beat signal can show. When there is no clear peak it is left empty. It is a check on the measurement: a morning with unusually fast or slow breathing is less comparable to the others."
        case .regeneration:
            return "Your HRV (lnRMSSD) this morning against your own normal of the last 60 days, from 0 to 10. 5 is your normal, 4–6 your normal range (half a standard deviation either way), and 2 points are one standard deviation. Higher means more beat-to-beat variation than usual, which usually means you are well recovered."
        case .stress:
            return "Strain or load on your body this morning against your own normal of the last 60 days, from 0 to 10. 5 is your normal, 4–6 your normal range (half a standard deviation either way), and 2 points are one standard deviation; higher means more strain than usual. Two thirds come from resting HR. One third comes from SD2, the slower variation, where less counts as more strain, following the Stress Score of Naranjo Orellana and colleagues. Mornings without SD2 use resting HR alone. Illness, alcohol, poor sleep, hard training and worry all raise it; no heart measurement this short can tell them apart."
        case .stressIndex:
            return "Baevsky's stress index. The intervals between beats are sorted into 50 ms bins; when most beats land in one narrow bin, the rhythm is rigid and the index is high. Resting values differ widely between people, from about 30 to several hundred. It is shown for reference only: it mostly repeats resting HR and SD2, so the Stress number does not use it. Needs at least 30 clean beats."
        case .score:
            return "75 is a normal day for you. HRV one standard deviation above your normal adds about 10 points; resting HR one standard deviation above takes about 5 off. The 0.65/0.35 weights and the 75 ± 15 scaling are this app's design choice, not part of a published method. The verdict colour comes from the rules in “How the verdict works”, not from the score alone."
        }
    }
}

/// Small ⓘ button that shows a metric's explanation in a popover.
struct InfoButton: View {
    let metric: Metric
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle").imageScale(.small).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(metric.title)")
        .popover(isPresented: $shown) {
            MetricExplanation(metric: metric)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct MetricExplanation: View {
    let metric: Metric
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.title).font(.headline)
            Text(metric.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 300, alignment: .leading)
    }
}
