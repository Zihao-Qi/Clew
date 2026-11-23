#if DEBUG
import AppKit
import ClewCore
import ClewDomain
import ClewStore
import SwiftUI

extension Snapshot {
    /// `CLEW_NOTES_TEST=1` (SPEC "Notes"): the task a note is written during, real keys in
    /// the note box (Return, ⇧Return, Esc), the draft, the banner, and the page's commands.
    static func startNotesTest() {
        Task { @MainActor in
            var failures = 0
            func report(_ name: String, _ ok: Bool) {
                if !ok { failures += 1 }
                print(ok ? "PASS" : "FAIL", name); fflush(stdout)
            }
            do {
                let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
                try clew.closeCalendarPrompt()
                let intro = try clew.addItem(NewItem(title: "Write the intro", shape: .today)).id
                let milk = try clew.addItem(NewItem(title: "Buy milk", shape: .today)).id
                let model = AppModel(clew: clew, notify: false)
                let defaults = UserDefaults(suiteName: "clew-notes-test")!
                defaults.removePersistentDomain(forName: "clew-notes-test")
                NoteBox.defaults = defaults
                NoteBox.shared.model = model
                try clew.settleWriteNoteShortcut()
                model.refresh()
                report("the note shortcut starts as ⌥⌘.", model.writeNoteShortcut == .writeNoteDefault)

                // The task chosen when the box opens.
                let now = Date()
                let blockStart = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 900).rounded(.down) * 900)
                try clew.setTimelineShown(true)
                try clew.placeOnTimeline(itemId: milk, start: blockStart, minutes: 60)
                model.refresh()
                report("a block running now that still needs something is the task",
                       model.noteContext()?.itemId == milk && model.noteContext()?.title == "Buy milk")
                try clew.startFocus(itemId: intro, minutes: 25)
                model.refresh()
                let context = model.noteContext()
                report("a running focus comes first, with its minutes left",
                       context?.itemId == intro && context?.detail.contains("25") == true)
                if let row = model.row(milk) { model.tap(row) }
                try clew.stopFocus()
                model.refresh()
                report("a done task's block is not chosen; nothing running: no task", model.noteContext() == nil)
                try clew.startFocus(itemId: intro, minutes: 25)
                model.refresh()

                // Real keys in the box.
                let box = NoteBox.shared
                box.open()
                try await Task.sleep(for: .milliseconds(400))
                guard let panel = box.panelForChecks else { report("the box opens", false); exit(1) }
                report("the box opens and takes the keyboard", box.isOpen && panel.isKeyWindow)
                func key(_ chars: String, code: UInt16, shift: Bool = false) {
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                             isARepeat: false, keyCode: code)!
                    panel.sendEvent(e)
                }
                func type(_ text: String) { for c in text { key(String(c), code: 0) } }
                type("Call the bank")
                key("\r", code: 36, shift: true)
                type("about the card")
                try await Task.sleep(for: .milliseconds(200))
                report("⇧Return starts a new line", box.state.text == "Call the bank\nabout the card" && box.isOpen)
                key("\r", code: 36)
                try await Task.sleep(for: .milliseconds(300))
                let saved = model.openNotes.first
                report("Return saves it with the task it was written during",
                       saved?.text == "Call the bank\nabout the card" && saved?.duringItemId == intro
                       && saved?.duringTitle == "Write the intro" && !box.isOpen)
                report("then the banner: Saved. Back to: the task, with its minutes left",
                       box.isBannerShown && box.bannerText?.hasPrefix("Saved. Back to: Write the intro · ") == true)
                try await Task.sleep(for: .milliseconds(3600))
                report("the banner goes by itself after 3 seconds", !box.isBannerShown)

                box.open()
                try await Task.sleep(for: .milliseconds(300))
                type("   ")
                key("\r", code: 36)
                try await Task.sleep(for: .milliseconds(200))
                report("Return with nothing but spaces does nothing", box.isOpen && model.openNotes.count == 1)
                type("half a thought")
                key("\u{1b}", code: 53)
                try await Task.sleep(for: .milliseconds(200))
                report("Esc closes it and keeps the draft",
                       !box.isOpen && defaults.string(forKey: NoteBox.draftKey) == "   half a thought" && model.openNotes.count == 1)
                box.open()
                try await Task.sleep(for: .milliseconds(300))
                report("the draft is back when it opens again", box.state.text == "   half a thought")
                box.close()

                // The page's commands.
                if let note = model.openNotes.first {
                    model.makeTask(fromNote: note.id, in: .later)
                    report("Make a task: a Later task from the first line; the note is done, → Later",
                           model.goalsAndLater.contains { $0.item.title == "Call the bank" }
                           && model.doneNotes.first?.madeTo == .later && model.openNotes.isEmpty)
                    model.deleteNote(note.id)
                    report("Delete, then Undo brings it back as it was", model.doneNotes.isEmpty && model.lastDeletedNote == note.id)
                    model.undoDeleteNote()
                    report("… done, under Done", model.doneNotes.first?.id == note.id)
                }
                report("the two shortcuts never clash",
                       model.setWriteNoteShortcut(.default) == "Already used to open the list."
                       && model.setOpenListShortcut(.writeNoteDefault) == "Already used to write a note.")
            } catch {
                report("setup: \(error)", false)
            }
            print(failures == 0 ? "ALL PASS" : "\(failures) FAILED"); fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `CLEW_NOTES_RENDER=1`: the note box, the banner, the Notes page and the list's count
    /// line, light and dark.
    static func renderNotesAndExit() -> Never {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClewSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
            try clew.closeCalendarPrompt()
            try clew.setTimelineShown(false)
            let intro = try clew.addItem(NewItem(title: "Write the intro", shape: .today)).id
            _ = try clew.addItem(NewItem(title: "Buy milk", shape: .today))
            try clew.addNote("Ask Sam about the venue", during: (intro, "Write the intro"))
            try clew.addNote("Call the bank about the card\nbefore Friday")
            let done = try clew.addNote("Look up train times", during: (intro, "Write the intro"))
            try clew.makeTask(fromNote: done.id, in: .later)
            let model = AppModel(clew: clew, notify: false)
            let state = NoteBoxState()
            state.context = NoteContext(itemId: intro, title: "Write the intro", detail: String(localized: " · 12 min left"))
            for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(RootView(model: model), appearance: look, to: dir.appendingPathComponent("notes-list-\(name).png"))
                render(RootView(model: model, screen: .notes), appearance: look,
                       to: dir.appendingPathComponent("notes-page-\(name).png"))
                render(NoteBoxView(box: NoteBox.shared, state: state).padding(10), appearance: look,
                       to: dir.appendingPathComponent("notes-box-\(name).png"))
                render(NoteBannerView(state: state, dismiss: {}).padding(10), appearance: look,
                       to: dir.appendingPathComponent("notes-banner-\(name).png"))
            }
            exit(0)
        } catch {
            print("render failed:", error)
            exit(1)
        }
    }
}
#endif
