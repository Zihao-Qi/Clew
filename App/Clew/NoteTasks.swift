import ClewAgent
import ClewAI
import ClewDomain
import SwiftUI

/// Notes to tasks on the Notes page (SPEC "Notes to tasks", AI-5): one request at a time
/// (✨ on a note, or Sort with ✨), and what each note shows under it. Never kept: leaving
/// the page, the menu closing, the rollover, losing ready or the Notes choice no longer
/// allowing it drop everything.
@MainActor @Observable
final class NoteTaskAsk {
    enum Shown: Equatable {
        case suggestion(NoteSuggestion)
        case failed
        case usageLimit
    }
    enum Asking: Equatable {
        case one(UUID)
        case sort
    }

    private(set) var asking: Asking?
    /// Under each note: its suggestion, the thought line, or a failure.
    private(set) var shown: [UUID: Shown] = [:]
    /// Sort's own failure, at the top of the page.
    private(set) var sortFailure: Shown?
    /// The notes' text when sent: a note changed since gets nothing.
    @ObservationIgnored private var sent: [UUID: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    #if DEBUG
    /// The debug render's state for every new page.
    static var preset: (@MainActor (NoteTaskAsk) -> Void)?
    init() { Self.preset?(self) }
    /// The debug render's state.
    func showForRender(_ shown: [UUID: Shown], sortFailure: Shown? = nil, asking: Asking? = nil) {
        self.shown = shown
        self.sortFailure = sortFailure
        self.asking = asking
    }
    #endif

    var isBusy: Bool { asking != nil }
    /// Something Esc would cancel or drop.
    var hasAnything: Bool { asking != nil || !shown.isEmpty || sortFailure != nil }

    /// ✨ on a note: that note's text only.
    func ask(_ note: QuickNote, model: AppModel) {
        guard let ai = model.ai, ai.canSuggestFromNotes, asking == nil, note.isOpen else { return }
        let input = NoteToTask.Input(note: note.text, at: Date(), calendar: .current)
        shown[note.id] = nil
        let mine = begin(.one(note.id), sent: [note.id: note.text])
        task = Task {
            let result = await ai.noteToTask(input)
            guard mine == generation, !Task.isCancelled else { return }
            asking = nil
            switch result {
            case .success(let suggestion):
                if stillAsSent(note.id, model) { shown[note.id] = .suggestion(suggestion) }
            case .failure(let failure) where failure.provider == .usageLimit:
                shown[note.id] = .usageLimit
            case .failure(let failure) where failure.provider == .signInEnded:
                dropAll()   // ready is gone: ✨ and everything go
            case .failure:
                shown[note.id] = .failed
                clearLater { if $0.shown[note.id] == .failed { $0.shown[note.id] = nil } }
            }
        }
    }

    /// Sort with ✨: every open note (up to 20, newest first); it replaces what shows.
    func sort(model: AppModel) {
        guard let ai = model.ai, ai.canSuggestFromNotes, ai.notesAccess == .all, asking == nil,
              model.openNotes.count >= 2 else { return }
        let notes = model.openNotes.map { (id: $0.id, text: $0.text) }
        let made = SortNotes.input(notes, at: Date(), calendar: .current)
        shown = [:]
        sortFailure = nil
        let mine = begin(.sort, sent: Dictionary(uniqueKeysWithValues: notes.prefix(SortNotes.sentAtMost).map { ($0.id, $0.text) }))
        task = Task {
            let result = await ai.sortNotes(made.input, job: SortNotes(ids: made.ids))
            guard mine == generation, !Task.isCancelled else { return }
            asking = nil
            switch result {
            case .success(let suggestions):
                var count = 0
                for (id, suggestion) in suggestions where stillAsSent(id, model) {
                    shown[id] = .suggestion(suggestion)
                    count += 1
                }
                // All changed meanwhile: it ends quietly.
                if count > 0 {
                    AccessibilityNotification.Announcement(count == 1 ? String(localized: "Suggestion for 1 note")
                                                           : String(localized: "Suggestions for \(count) notes")).post()
                }
            case .failure(let failure) where failure.provider == .usageLimit:
                sortFailure = .usageLimit
            case .failure(let failure) where failure.provider == .signInEnded:
                dropAll()
            case .failure:
                sortFailure = .failed
                clearLater { if $0.sortFailure == .failed { $0.sortFailure = nil } }
            }
        }
    }

    private func begin(_ what: Asking, sent texts: [UUID: String]) -> Int {
        generation += 1
        task?.cancel()
        asking = what
        sent = texts
        return generation
    }

    private func stillAsSent(_ id: UUID, _ model: AppModel) -> Bool {
        guard let note = model.openNotes.first(where: { $0.id == id }) else { return false }
        return sent[id] == note.text
    }

    private func clearLater(_ clear: @escaping @MainActor (NoteTaskAsk) -> Void) {
        let mine = generation
        Task {
            try? await Task.sleep(for: .seconds(5))
            if mine == generation { clear(self) }
        }
    }

    /// Cancel: what is asking stops; nothing appears later.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        asking = nil
    }

    func dropAll() {
        cancel()
        shown = [:]
        sortFailure = nil
    }

    /// Esc: cancels what is asking; else drops what shows. False: nothing to do (Esc goes back).
    func escape() -> Bool {
        if asking != nil { cancel(); return true }
        if !shown.isEmpty || sortFailure != nil {
            shown = [:]
            sortFailure = nil
            return true
        }
        return false
    }

    /// Not now, OK, or a failure's Not now under a note.
    func dismiss(_ id: UUID) { shown[id] = nil }
    func dismissSortFailure() { sortFailure = nil }

    /// Add to Today / Add to Later: the task with its title and steps, in one click.
    func add(_ id: UUID, today: Bool, model: AppModel) {
        guard case .suggestion(.task(let title, _, _, let steps))? = shown[id] else { return }
        shown[id] = nil
        model.makeTask(fromNote: id, in: today ? .today : .later, title: title, steps: steps)
    }

    /// A note being edited: its request stops and what shows under it goes.
    func editing(_ id: UUID) {
        if asking == .one(id) { cancel() }
        shown[id] = nil
    }

    /// Keeps the page in step: a note done, deleted, made a task or changed loses what
    /// shows under it (and its request); ✨ not allowed any more drops everything.
    func update(_ model: AppModel) {
        guard model.ai?.canSuggestFromNotes == true else { return dropAll() }
        if asking == .sort, model.ai?.notesAccess != .all { cancel() }
        let open = Dictionary(uniqueKeysWithValues: model.openNotes.map { ($0.id, $0.text) })
        if case .one(let id) = asking, open[id] != sent[id] { cancel() }
        for id in shown.keys where open[id] == nil || (sent[id] != nil && open[id] != sent[id]) { shown[id] = nil }
    }
}

extension AppModel {
    func makeTask(fromNote id: UUID, in place: QuickNote.MadeTo, title: String, steps: [String]) {
        run { try $0.makeTask(fromNote: id, in: place, title: title, steps: steps) }
    }
}

/// Under a note: asking, its suggestion, the thought line, or a failure.
struct NoteTaskRow: View {
    let note: QuickNote
    let ask: NoteTaskAsk
    let model: AppModel

    var body: some View {
        Group {
            if ask.asking == .one(note.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { ask.cancel() }
                        .accessibilityLabel(Text("Cancel suggestion"))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Suggesting a task"))
            } else if let shown = ask.shown[note.id] {
                switch shown {
                case .suggestion(.task(let title, let today, let reason, let steps)):
                    card(title: title, today: today, reason: reason, steps: steps)
                case .suggestion(.thought):
                    HStack(alignment: .firstTextBaseline) {
                        Text("This looks like a thought to keep.").foregroundStyle(.secondary)
                        Spacer()
                        Button("OK") { ask.dismiss(note.id) }
                    }
                case .failed:
                    failure(Text("Couldn't suggest a task. Try again."))
                case .usageLimit:
                    failure(Text("ChatGPT usage limit reached"), usage: true)
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.leading, 28)
        .debugFrame("noteTask:\(note.id)")
    }

    private func card(title: String, today: Bool, reason: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "circle.dotted").foregroundStyle(.tertiary).imageScale(.small)
                        .accessibilityHidden(true)
                    Text(verbatim: step).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
            // Always in this order; the suggested one highlighted, not bound to Return.
            HStack(spacing: 10) {
                choice(Text("Add to Today"), suggested: today) { ask.add(note.id, today: true, model: model) }
                    .accessibilityLabel(Text("Add to Today: \(title)"))
                choice(Text("Add to Later"), suggested: !today) { ask.add(note.id, today: false, model: model) }
                    .accessibilityLabel(Text("Add to Later: \(title)"))
                Button("Not now") { ask.dismiss(note.id) }
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(today ? Text("Suggested task for Today: \(title). \(steps.joined(separator: ", ")). \(reason)")
                                  : Text("Suggested task for Later: \(title). \(steps.joined(separator: ", ")). \(reason)"))
    }

    @ViewBuilder
    private func choice(_ label: Text, suggested: Bool, action: @escaping () -> Void) -> some View {
        if suggested {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(action: action) { label }
        }
    }

    private func failure(_ text: Text, usage: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            text.foregroundStyle(.secondary)
            if usage {
                Link("Manage usage", destination: ChatGPT.usageURL)
                    .buttonStyle(.link)
                    .accessibilityLabel(Text("Manage ChatGPT usage"))
            }
            Spacer()
            Button("Not now") { ask.dismiss(note.id) }
        }
    }
}
