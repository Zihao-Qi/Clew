import ClewDomain
import SwiftUI

/// The text of last week's card (SPEC 2026-11-15), shared by the menu's card and
/// Settings › Progress: numbers only, never a comparison or anything missed.
enum WeekRecapText {
    /// "23 done · 3 h 20 min focus" ("N done" left out when 0).
    static func main(_ r: WeekRecap) -> String? {
        var parts: [String] = []
        if r.done > 0 { parts.append(String(localized: "\(r.done) done")) }
        if r.focusMinutes > 0 { parts.append(String(localized: "\(FocusSection.duration(r.focusMinutes)) focus")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "4 watched · 2 read", only the lists that have some.
    static func collections(_ r: WeekRecap) -> String? {
        var parts: [String] = []
        if let n = r.watched, n > 0 { parts.append(String(localized: "\(n) watched")) }
        if let n = r.read, n > 0 { parts.append(String(localized: "\(n) read")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// For VoiceOver: "Last week: 23 done, 3 hours, 20 minutes of focus, 4 watched, Exercise on 4 days".
    static func spoken(_ r: WeekRecap) -> String {
        var parts: [String] = []
        if r.done > 0 { parts.append(String(localized: "\(r.done) done")) }
        if r.focusMinutes > 0 {
            let time = Duration.seconds(r.focusMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
            parts.append(String(localized: "\(time) of focus"))
        }
        if let n = r.watched, n > 0 { parts.append(String(localized: "\(n) watched")) }
        if let n = r.read, n > 0 { parts.append(String(localized: "\(n) read")) }
        for h in r.highlights { parts.append((h.count == 1 ? String(localized: "\(h.title) on 1 day") : String(localized: "\(h.title) on \(h.count) days"))) }
        return String(localized: "Last week: \(parts.joined(separator: ", "))")
    }
}

/// The highlights line: titles truncate, counts never do.
struct WeekHighlights: View {
    let highlights: [WeekRecap.Highlight]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(highlights.enumerated()), id: \.element.itemId) { index, h in
                if index > 0 { Text(verbatim: "·").foregroundStyle(.tertiary) }
                Text(verbatim: h.title).lineLimit(1).truncationMode(.tail)
                Text(verbatim: "\(h.count)×").monospacedDigit().fixedSize()
            }
        }
        // Read as words, not "·" and "4×" (the card replaces this with its own label).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: highlights.map { $0.count == 1 ? String(localized: "\($0.title) on 1 day") : String(localized: "\($0.title) on \($0.count) days") }
            .joined(separator: ", ")))
    }
}

/// Last week's card at the very top of the menu: shown once a week, for one opening.
struct WeekCardView: View {
    let recap: WeekRecap
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Last week")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let main = WeekRecapText.main(recap) {
                    Text(verbatim: main).monospacedDigit()
                }
                if let lists = WeekRecapText.collections(recap) {
                    Text(verbatim: lists).monospacedDigit()
                }
                if !recap.highlights.isEmpty {
                    WeekHighlights(highlights: recap.highlights)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WeekRecapText.spoken(recap)))
            Button(action: onClose) {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(Text("Close last week's card"))
            .accessibilityLabel(Text("Close last week's card"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}
