import ClewCore
import ClewDomain
import Foundation
import Testing

private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
}

/// SPEC "Notes" (2026-11-22): writing, editing, Done, Make a task, Delete, the shortcut.
@Suite struct NoteTests {
    let store = FakeStore()
    let clock = TestClock(at(22, 10))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("America/New_York")) }
    func later(_ minutes: Int) { clock.set(clock.now().addingTimeInterval(TimeInterval(minutes * 60))) }

    @Test func aNoteKeepsItsTextWhenAndDuringWhat() throws {
        let task = try clew.addItem(NewItem(title: "Write the intro", shape: .today)).id
        let note = try clew.addNote("  Call the bank\nabout the card  \n", during: (task, "Write the intro"))
        #expect(note.text == "Call the bank\nabout the card" && note.createdAt == at(22, 10))
        #expect(note.duringItemId == task && note.duringTitle == "Write the intro" && note.isOpen)
        #expect(throws: ClewError.emptyTitle) { try clew.addNote(" \n \t") }
        let long = try clew.addNote(String(repeating: "a", count: 1200))
        #expect(long.text.count == QuickNote.maxLength)
        // The task going later never changes the note: its title then stays.
        try clew.deleteItem(itemId: task)
        let kept = try clew.notes().open.first { $0.id == note.id }
        #expect(kept?.duringTitle == "Write the intro" && kept?.duringItemId == task)
    }

    @Test func openNewestFirstDoneMostRecentlyDoneFirstDeletedNowhere() throws {
        let a = try clew.addNote("a"); later(1)
        let b = try clew.addNote("b"); later(1)
        let c = try clew.addNote("c"); later(1)
        #expect(try clew.notes().open.map(\.text) == ["c", "b", "a"])
        try clew.setNoteDone(id: b.id, true); later(1)
        try clew.setNoteDone(id: a.id, true)
        try clew.deleteNote(id: c.id)
        let notes = try clew.notes()
        #expect(notes.open.isEmpty && notes.done.map(\.text) == ["a", "b"])
        try clew.undeleteNote(id: c.id)
        #expect(try clew.notes().open.map(\.text) == ["c"])
        // Undo brings it back as it was: a done note stays done.
        try clew.deleteNote(id: a.id)
        try clew.undeleteNote(id: a.id)
        #expect(try clew.notes().done.map(\.text) == ["a", "b"])
    }

    @Test func editingChangesOnlyAnOpenNoteAndNeverToNothing() throws {
        let n = try clew.addNote("first")
        try clew.editNote(id: n.id, text: " second \n")
        #expect(try clew.notes().open.first?.text == "second")
        #expect(throws: ClewError.emptyTitle) { try clew.editNote(id: n.id, text: " \n ") }
        #expect(try clew.notes().open.first?.text == "second")
        try clew.setNoteDone(id: n.id, true)
        #expect(throws: ClewError.notAllowed) { try clew.editNote(id: n.id, text: "third") }
    }

    @Test func makeATaskFromTheFirstLineAsTypedAndTheNoteIsDone() throws {
        let n = try clew.addNote("\n  https://example.com read this  \nmore")
        let item = try clew.makeTask(fromNote: n.id, in: .today)
        #expect(item.title == "https://example.com read this" && item.url == nil && item.titleOrigin == .typed)
        let onToday = try clew.today().rows.contains { $0.id == item.id }
        #expect(item.kind == .once && onToday)
        let done = try #require(try clew.notes().done.first)
        #expect(done.taskId == item.id && done.madeTo == .today && done.doneAt == at(22, 10))
        #expect(throws: ClewError.notAllowed) { try clew.makeTask(fromNote: n.id, in: .later) }

        let m = try clew.addNote(String(repeating: "b", count: 300))
        let later = try clew.makeTask(fromNote: m.id, in: .later)
        #expect(later.title.count == Clew.maxTitleLength && later.title.hasSuffix("…") && later.state == .later)
        #expect(try clew.notes().done.first { $0.id == m.id }?.madeTo == .later)

        // Not done opens it again and forgets the task; the task stays.
        try clew.setNoteDone(id: n.id, false)
        let open = try #require(try clew.notes().open.first { $0.id == n.id })
        #expect(open.taskId == nil && open.madeTo == nil && open.doneAt == nil)
        #expect(try clew.today().rows.contains { $0.id == item.id })
    }

    @Test func theNoteShortcutStartsAtOptionCommandPeriodUnlessTheListHasItAndThatChoiceIsKept() throws {
        #expect(try clew.writeNoteShortcut() == .writeNoteDefault)
        // A Mac whose list shortcut is already ⌥⌘.: the note's starts with none, kept.
        let oldStore = FakeStore()
        let json = String(decoding: try JSONEncoder().encode(OpenShortcut.writeNoteDefault), as: UTF8.self)
        try oldStore.write { try $0.saveSetting("openListShortcut", json: json, updatedAt: at(1, 9)) }   // set before Notes
        let other = Clew(store: oldStore, clock: clock, zones: FixedZone("America/New_York"))
        #expect(try other.writeNoteShortcut() == nil)
        try other.settleWriteNoteShortcut()
        try other.setOpenListShortcut(.default)
        #expect(try other.writeNoteShortcut() == nil)              // never turned on by itself
        // Settled on a fresh Mac: ⌥⌘. is saved.
        try clew.settleWriteNoteShortcut()
        try clew.setOpenListShortcut(nil)
        #expect(try clew.writeNoteShortcut() == .writeNoteDefault)
    }

    @Test func theTwoShortcutsNeverClash() throws {
        #expect(throws: ClewError.shortcutTaken) { try clew.setWriteNoteShortcut(.default) }
        #expect(throws: ClewError.shortcutTaken) { try clew.setOpenListShortcut(.writeNoteDefault) }
        try clew.setWriteNoteShortcut(nil)
        #expect(try clew.writeNoteShortcut() == nil)
        try clew.setOpenListShortcut(.writeNoteDefault)              // free now
        #expect(try clew.openListShortcut() == .writeNoteDefault)
    }

    @Test func notesAreExportedAndOldExportsStillRead() throws {
        _ = try clew.addNote("keep me")
        let doc = try clew.exportDocument()
        #expect(doc.records.quickNotes.map(\.text) == ["keep me"])
        let data = try doc.encoded()
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var records = try #require(json["records"] as? [String: Any])
        records["quickNotes"] = nil
        json["records"] = records
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect((try? decoder.decode(ExportDocument.self, from: old))?.records.quickNotes.isEmpty == true)
    }
}
