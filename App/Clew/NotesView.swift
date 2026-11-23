import ClewCore
import ClewDomain
import SwiftUI

/// The Notes page (SPEC "Notes"): open notes newest first, each with Make a task, Done and
/// Delete; then Done (N), folded each time the page opens.
struct NotesView: View {
    let model: AppModel
    let onBack: () -> Void

    @State private var showsDone = false
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var listHeight: CGFloat = 0
    private static let maxListHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) { Label("Today", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(editing == nil ? .cancelAction : nil)
                .accessibilityLabel(Text("Back"))
            Text("Notes").font(.headline).accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.openNotes.isEmpty {
                        Text(emptyText).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.openNotes) { note in openRow(note) }
                    if !model.doneNotes.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showsDone.toggle() }
                        } label: {
                            Label {
                                Text("Done (\(model.doneNotes.count))")
                            } icon: {
                                Image(systemName: showsDone ? "chevron.down" : "chevron.right").imageScale(.small)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityValue(showsDone ? Text("Unfolded") : Text("Folded"))
                        if showsDone {
                            ForEach(model.doneNotes) { note in doneRow(note) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, Self.maxListHeight))

            if model.lastDeletedNote != nil {
                HStack(spacing: 8) {
                    Text("Deleted note")
                    Spacer(minLength: 4)
                    Button("Undo") { model.undoDeleteNote() }
                        .accessibilityLabel(Text("Undo deleting the note"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .debugFrame("notesPage")
        .onDisappear { model.lastDeletedNote = nil }
    }

    private var emptyText: String {
        if let shortcut = model.writeNoteShortcut {
            String(localized: "No open notes. Press \(shortcut.display) any time to write one down.")
        } else {
            String(localized: "No open notes. Use ✎ Note any time to write one down.")
        }
    }

    @ViewBuilder
    private func openRow(_ note: QuickNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if editing == note.id {
                NoteEditorField(text: $draft, placeholder: "", focusRequest: 1, maxLines: 6,
                                onSubmit: { finishEditing(note, save: true) },
                                onCancel: { finishEditing(note, save: false) })
                    .accessibilityLabel(Text("Edit note"))
                    .background(OutsideClickWatcher(onOutside: { finishEditing(note, save: true) }))
                    .debugFrame("noteEdit:\(note.id)")
            } else {
                Text(verbatim: note.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { startEditing(note) }
                    .debugFrame("note:\(note.id)")
            }
            Text(verbatim: NoteTime.caption(note)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 12) {
                Spacer(minLength: 4)
                Menu {
                    Button("Today") { model.makeTask(fromNote: note.id, in: .today) }
                    Button("Later") { model.makeTask(fromNote: note.id, in: .later) }
                } label: { Text("Make a task").font(.caption) }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Make a task"))
                Button("Done") { model.setNoteDone(note.id, true) }
                    .accessibilityLabel(Text("Done"))
                Button { model.deleteNote(note.id) } label: { Image(systemName: "trash") }
                    .help(Text("Delete"))
                    .accessibilityLabel(Text("Delete"))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .contextMenu {
            Button("Make a task in Today") { model.makeTask(fromNote: note.id, in: .today) }
            Button("Make a task in Later") { model.makeTask(fromNote: note.id, in: .later) }
            Button("Done") { model.setNoteDone(note.id, true) }
            Button("Delete", role: .destructive) { model.deleteNote(note.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(note.text), \(NoteTime.caption(note))"))
        .accessibilityActions {
            Button("Edit") { startEditing(note) }
            Button("Make a task in Today") { model.makeTask(fromNote: note.id, in: .today) }
            Button("Make a task in Later") { model.makeTask(fromNote: note.id, in: .later) }
            Button("Done") { model.setNoteDone(note.id, true) }
            Button("Delete") { model.deleteNote(note.id) }
        }
        Divider()
    }

    @ViewBuilder
    private func doneRow(_ note: QuickNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: note.text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Group {
                    if let made = note.madeTo {
                        Text(verbatim: "\(NoteTime.caption(note)) · ") + (made == .today ? Text("→ Today") : Text("→ Later"))
                    } else {
                        Text(verbatim: NoteTime.caption(note))
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Not done") { model.setNoteDone(note.id, false) }
                Button { model.deleteNote(note.id) } label: { Image(systemName: "trash") }
                    .help(Text("Delete"))
                    .accessibilityLabel(Text("Delete"))
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .contextMenu {
            Button("Not done") { model.setNoteDone(note.id, false) }
            Button("Delete", role: .destructive) { model.deleteNote(note.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(doneLabel(note))
        .accessibilityActions {
            Button("Not done") { model.setNoteDone(note.id, false) }
            Button("Delete") { model.deleteNote(note.id) }
        }
    }

    private func doneLabel(_ note: QuickNote) -> Text {
        let base = Text(verbatim: "\(note.text), \(NoteTime.caption(note))")
        switch note.madeTo {
        case .today?: return base + Text(verbatim: ", ") + Text("made a task in Today")
        case .later?: return base + Text(verbatim: ", ") + Text("made a task in Later")
        case nil: return base
        }
    }

    private func startEditing(_ note: QuickNote) {
        guard editing != note.id else { return }
        draft = note.text
        editing = note.id
    }

    /// Return or a click elsewhere saves; Esc keeps the note as it was. Nothing but
    /// spaces is not saved.
    private func finishEditing(_ note: QuickNote, save: Bool) {
        guard editing == note.id else { return }
        editing = nil
        if save, draft != note.text { model.editNote(note.id, draft) }
    }
}

/// "10:42 · during Write the intro" (SPEC "Notes"): this Mac's clock format; "Mon 10:42"
/// within the last 6 days; "Nov 12" before that (with the year if not this year).
enum NoteTime {
    static func caption(_ note: QuickNote, now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = time(note.createdAt, now: now, calendar: calendar)
        guard let during = note.duringTitle else { return when }
        return String(localized: "\(when) · during \(during)")
    }

    static func time(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let clock = date.formatted(date: .omitted, time: .shortened)
        if days == 0 { return clock }
        if days > 0, days <= 6 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(clock)" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
