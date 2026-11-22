import ClewAgent
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
/// With AI ready, "What Clew noticed" below its lines (SPEC, AI-N); a card may hold
/// only that section when last week has nothing to show.
struct WeekCardView: View {
    let recap: WeekRecap?
    var noticed: [Note] = []
    var answer: (Note, Bool) -> Void = { _, _ in }
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last week")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let recap {
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
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(recap.map { Text(verbatim: WeekRecapText.spoken($0)) } ?? Text("Last week"))
                Button(action: onClose) {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Text("Close last week's card"))
                .accessibilityLabel(Text("Close last week's card"))
            }
            if !noticed.isEmpty {
                NoticedSection(notes: noticed, answer: answer)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

/// "Clew noticed": up to 3 of Clew's notes, each with True and Not really. Choosing only.
struct NoticedSection: View {
    let notes: [Note]
    let answer: (Note, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Clew noticed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: note.says)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if !note.about.isEmpty {
                            Text(verbatim: note.about).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 12) {
                        Button("True") { answer(note, true) }
                            .accessibilityLabel(Text("True: \(note.says)"))
                        Button("Not really") { answer(note, false) }
                            .accessibilityLabel(Text("Not really: \(note.says)"))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
