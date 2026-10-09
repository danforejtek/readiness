import SwiftData
import SwiftUI

/// Morning check-in vocabulary, shared with the Mac tool (`hrmon/readiness.py` FEELINGS and TAGS).
enum CheckIn {
    struct Feeling: Identifiable { let id: Int; let title: String; let symbol: String }
    struct Tag: Identifiable { let id: String; let title: String; let symbol: String }

    static let feelings = [
        Feeling(id: 1, title: "Awful", symbol: "cloud.bolt.rain"),
        Feeling(id: 2, title: "Poor", symbol: "cloud.drizzle"),
        Feeling(id: 3, title: "OK", symbol: "cloud.sun"),
        Feeling(id: 4, title: "Good", symbol: "sun.min"),
        Feeling(id: 5, title: "Great", symbol: "sun.max"),
    ]

    static let tags = [
        Tag(id: "poor_sleep", title: "Poor sleep", symbol: "moon.zzz"),
        Tag(id: "alcohol", title: "Alcohol", symbol: "wineglass"),
        Tag(id: "sick", title: "Feeling sick", symbol: "thermometer.medium"),
        Tag(id: "hard_training", title: "Hard training yesterday", symbol: "figure.run"),
        Tag(id: "stress", title: "Stressed", symbol: "bolt.heart"),
        Tag(id: "late_meal", title: "Late meal", symbol: "fork.knife"),
    ]
}

/// "How do you feel?" plus context tags. Saved on the morning right away; used later to check whether the
/// verdicts match how you actually felt (`hrmon analyze`).
struct CheckInCard: View {
    @Bindable var morning: Morning
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How do you feel?").font(.headline)
            HStack(spacing: 6) {
                ForEach(CheckIn.feelings) { f in
                    let selected = morning.feeling == f.id
                    Button {
                        morning.feeling = selected ? nil : f.id
                        save()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: f.symbol).font(.title3)
                            Text(f.title).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(selected ? Palette.accent.opacity(0.2) : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Palette.accent : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(CheckIn.tags) { t in
                    let on = morning.tags.contains(t.id)
                    Button {
                        if on { morning.tags.removeAll { $0 == t.id } } else { morning.tags.append(t.id) }
                        save()
                    } label: {
                        Label(t.title, systemImage: t.symbol)
                            .font(.footnote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(on ? Palette.accent.opacity(0.2) : Color(.tertiarySystemFill), in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Palette.accent : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text("Not used for the verdict. After a few weeks it shows whether the verdicts match how you feel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func save() { try? context.save() }
}
