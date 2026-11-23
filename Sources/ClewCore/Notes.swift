import ClewDomain
import Foundation

/// Notes (SPEC "Notes", 2026-11-22): a thought written down mid-task, kept as the
/// person's own data. Never sent to AI.
extension Clew {
    /// Open notes newest first, and done ones most recently done first.
    public func notes() throws -> (open: [QuickNote], done: [QuickNote]) {
        let all = try storeForQueries.read { try $0.quickNotes() }
        let open = all.filter(\.isOpen).sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        let done = all.filter { $0.doneAt != nil }
            .sorted { ($0.doneAt ?? .distantPast, $0.id.uuidString) > ($1.doneAt ?? .distantPast, $1.id.uuidString) }
        return (open, done)
    }

    /// Saves a note; spaces and line breaks alone are nothing (`emptyTitle`).
    @discardableResult
    public func addNote(_ text: String, during: (itemId: UUID, title: String)? = nil) throws -> QuickNote {
        guard let text = QuickNote.cleaned(text) else { throw ClewError.emptyTitle }
        let now = clockForQueries.now()
        let note = QuickNote(id: newID(), text: text, createdAt: now, duringItemId: during?.itemId,
                             duringTitle: during?.title, updatedAt: now)
        try storeForQueries.write { try $0.save(note) }
        return note
    }

    /// Edits an open note's text in place; nothing but spaces is not saved.
    public func editNote(id: UUID, text: String) throws {
        guard let text = QuickNote.cleaned(text) else { throw ClewError.emptyTitle }
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard var note = try w.quickNote(id: id), note.deletedAt == nil else { throw ClewError.itemNotFound }
            guard note.doneAt == nil else { throw ClewError.notAllowed }   // done notes are not edited
            guard note.text != text else { return }
            note.text = text
            note.updatedAt = now
            try w.save(note)
        }
    }

    /// Done keeps the note under Done; Not done opens it again and forgets its task.
    public func setNoteDone(id: UUID, _ done: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard var note = try w.quickNote(id: id), note.deletedAt == nil else { throw ClewError.itemNotFound }
            if done {
                guard note.doneAt == nil else { return }
                note.doneAt = now
            } else {
                guard note.doneAt != nil else { return }
                note.doneAt = nil
                note.taskId = nil
                note.madeTo = nil
            }
            note.updatedAt = now
            try w.save(note)
        }
    }

    /// Make a task: a one-off task in Today or Later titled by the note's first line that
    /// is not empty, as typed (never a link); the note becomes done, in the same write.
    @discardableResult
    public func makeTask(fromNote id: UUID, in place: QuickNote.MadeTo) throws -> Item {
        let now = clockForQueries.now()
        let day = LocalDay(of: now, in: zonesForQueries.current(), rolloverHour: rolloverHour)
        return try storeForQueries.write { w in
            guard var note = try w.quickNote(id: id), note.isOpen else { throw ClewError.notAllowed }
            guard let line = QuickNote.taskTitle(note.text) else { throw ClewError.emptyTitle }
            let title = line.count > Self.maxTitleLength ? String(line.prefix(Self.maxTitleLength - 1)) + "…" : line
            let item = try insertNewItem(NewItem(title: title, shape: place == .today ? .today : .later),
                                         source: .user, now: now, day: day, w)
            note.doneAt = now
            note.taskId = item.id
            note.madeTo = place
            note.updatedAt = now
            try w.save(note)
            return item
        }
    }

    /// Delete is a tombstone; Undo brings the note back as it was, open or done.
    public func deleteNote(id: UUID) throws {
        try setNoteDeleted(id, true)
    }

    public func undeleteNote(id: UUID) throws {
        try setNoteDeleted(id, false)
    }

    private func setNoteDeleted(_ id: UUID, _ deleted: Bool) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard var note = try w.quickNote(id: id) else { throw ClewError.itemNotFound }
            guard (note.deletedAt != nil) != deleted else { return }
            note.deletedAt = deleted ? now : nil
            note.updatedAt = now
            try w.save(note)
        }
    }

    // MARK: The shortcut that writes a note

    static let writeNoteShortcutKey = "writeNoteShortcut"

    /// The shortcut that writes a note: ⌥⌘. when never set, unless the list's shortcut is
    /// ⌥⌘. (then none); `nil` when cleared. `settleWriteNoteShortcut` saves that first
    /// choice, so changing the list's shortcut later never turns ⌥⌘. on by itself.
    public func writeNoteShortcut() throws -> OpenShortcut? {
        let stored = try storeForQueries.read { try $0.setting(Self.writeNoteShortcutKey) }
        guard let json = stored else { return try Self.firstNoteShortcut(list: openListShortcut()) }
        if json == "null" { return nil }
        guard let shortcut = OpenShortcut.decode(json), shortcut.isAllowed else { return nil }
        return shortcut
    }

    static func firstNoteShortcut(list: OpenShortcut?) -> OpenShortcut? {
        list == .writeNoteDefault ? nil : .writeNoteDefault
    }

    /// At launch: a note shortcut never set gets its first choice, saved.
    public func settleWriteNoteShortcut() throws {
        guard try storeForQueries.read({ try $0.setting(Self.writeNoteShortcutKey) }) == nil else { return }
        try saveShortcut(Self.firstNoteShortcut(list: try openListShortcut()), key: Self.writeNoteShortcutKey)
    }

    /// Sets the note's shortcut; refused (`shortcutTaken`) when it is the list's.
    public func setWriteNoteShortcut(_ shortcut: OpenShortcut?) throws {
        if let shortcut, !shortcut.isAllowed { return }
        if let shortcut, shortcut == (try openListShortcut()) { throw ClewError.shortcutTaken }
        try saveShortcut(shortcut, key: Self.writeNoteShortcutKey)
    }

    func saveShortcut(_ shortcut: OpenShortcut?, key: String) throws {
        let now = clockForQueries.now()
        let json = try shortcut.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
        try storeForQueries.write { try $0.saveSetting(key, json: json, updatedAt: now) }
    }
}

extension OpenShortcut {
    /// ⌥⌘. — Option-Command-Period writes a note (SPEC "Notes").
    public static let writeNoteDefault = OpenShortcut(
        keyCode: 47, command: true, shift: false, option: true, control: false, glyph: "."
    )
}
