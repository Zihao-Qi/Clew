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
                NoteBannerView.sweepAlways = true
                print("  Reduce Motion on this Mac:", NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
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
                // A paused focus says so; a goal's running block counts until it is reached;
                // of a task's own block and a step's starting together, the task's.
                try clew.startFocus(itemId: intro, minutes: 25)
                try clew.pauseFocus()
                model.refresh()
                report("a paused focus says paused", model.noteContext()?.detail.contains("paused") == true)
                try clew.stopFocus()
                let pages = try clew.addItem(NewItem(title: "Read pages", shape: .goal(target: 2))).id
                let talk = try clew.addItem(NewItem(title: "Prepare the talk", shape: .today)).id
                let notes = try clew.addStep(taskId: talk, title: "Speech notes").id
                let earlier = blockStart.addingTimeInterval(-900)
                try clew.placeOnTimeline(itemId: pages, start: blockStart, minutes: 60)
                // Task blocks and a step's block started earlier; the goal's started last.
                let anna = try clew.addItem(NewItem(title: "Email Anna", shape: .today)).id   // after the talk in the list
                try clew.placeStepOnTimeline(stepId: notes, start: earlier, minutes: 90)
                try clew.placeOnTimeline(itemId: anna, start: earlier, minutes: 90)
                try clew.checkIn(itemId: pages)                                // 1 of 2: still needs something
                model.refresh()
                report("the block that started last is the task, a goal half done too", model.noteContext()?.itemId == pages)
                try clew.checkIn(itemId: pages)                                // reached
                model.refresh()
                report("a reached goal is not; of a task's own block and a step's starting together, the task's",
                       model.noteContext()?.itemId == anna && model.noteContext()?.title == "Email Anna")
                for b in model.timeline?.blocks ?? [] where b.block.itemId == anna { _ = model.removeBlock(b.id) }
                report("a step's block names task and step",
                       model.noteContext()?.itemId == talk && model.noteContext()?.title == "Prepare the talk - Speech notes")
                for b in model.timeline?.blocks ?? [] { _ = model.removeBlock(b.id) }

                // Times on the page: this Mac's clock; a weekday within 6 days; a date before.
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = .current
                let ref = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 15))!
                let sameDay = NoteTime.time(ref.addingTimeInterval(-3600), now: ref, calendar: cal)
                let sixDays = ref.addingTimeInterval(-6 * 86400)
                let twoDays = NoteTime.time(sixDays, now: ref, calendar: cal)
                let sevenDays = NoteTime.time(ref.addingTimeInterval(-7 * 86400), now: ref, calendar: cal)
                let month = NoteTime.time(ref.addingTimeInterval(-30 * 86400), now: ref, calendar: cal)
                let lastYear = NoteTime.time(ref.addingTimeInterval(-400 * 86400), now: ref, calendar: cal)
                report("note times: clock today, weekday this week, date before, year if not this year",
                       sameDay == ref.addingTimeInterval(-3600).formatted(date: .omitted, time: .shortened)
                       && twoDays == "\(sixDays.formatted(.dateTime.weekday(.abbreviated))) \(sixDays.formatted(date: .omitted, time: .shortened))"
                       && !sevenDays.contains(":") && !month.contains(":") && !month.contains("2026") && lastYear.contains("2025"))

                try clew.startFocus(itemId: intro, minutes: 25)
                model.refresh()

                // Real keys in the box.
                let box = NoteBox.shared
                box.open()
                try await Task.sleep(for: .milliseconds(400))
                guard let panel = box.panelForChecks else { report("the box opens", false); exit(1) }
                report("the box opens and takes the keyboard", box.isOpen && panel.isKeyWindow)
                if let visible = panel.screen?.visibleFrame {
                    report("it opens a quarter of the way down the screen, centred",
                           abs(panel.frame.maxY - (visible.maxY - visible.height / 4)) < 2
                           && abs(panel.frame.midX - visible.midX) < 2)
                }
                func key(_ chars: String, code: UInt16, shift: Bool = false) {
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                             context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                             isARepeat: false, keyCode: code)!
                    panel.sendEvent(e)
                }
                func type(_ text: String) { for c in text { key(String(c), code: 0) } }
                /// The banner's copy of the text, as the banner showing now drew it.
                @MainActor func sweptNow() -> CGRect? { DebugFrames.frames["sweptText\(box.state.bannerShown)"] }
                /// Return, then wait until the banner's copy of the text is drawn (a slow Mac
                /// takes longer), at most until the sweep settles.
                @MainActor func returnUntilSwept() async throws {
                    key("\r", code: 36)
                    for _ in 0..<20 where sweptNow() == nil {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try await Task.sleep(for: .milliseconds(30))   // one more frame for the scroll
                }
                let oneLine = panel.frame.height
                type("Call the bank")
                try await Task.sleep(for: .milliseconds(150))
                report("the text shows in full at the top of its field (user, 2026-11-23: it sat at the bottom)",
                       box.textAndField.map { $0.field.contains($0.text.insetBy(dx: 0.5, dy: 0.5)) && $0.text.minY - $0.field.minY < 1 } == true)
                key("\r", code: 36, shift: true)
                type("about the card")
                try await Task.sleep(for: .milliseconds(200))
                report("⇧Return starts a new line", box.state.text == "Call the bank\nabout the card" && box.isOpen)
                report("the box grows with its lines", panel.frame.height > oneLine + 10)
                let typed = DebugFrames.frames["noteText"]
                let lineHeight = box.textAndField.map { $0.text.height / 2 } ?? 0
                try await returnUntilSwept()
                let swept = sweptNow()
                print("  typed", typed as Any, "swept", swept as Any)
                report("while the band sweeps, the text stays the same size and place (user, 2026-11-24)",
                       typed != nil && swept != nil && abs(typed!.minY - swept!.minY) < 1 && abs(typed!.minX - swept!.minX) < 1
                       && abs(typed!.height - swept!.height) < 1)
                try await Task.sleep(for: .milliseconds(300))
                let saved = model.openNotes.first
                report("Return saves it with the task it was written during",
                       saved?.text == "Call the bank\nabout the card" && saved?.duringItemId == intro
                       && saved?.duringTitle == "Write the intro" && !box.isOpen)
                report("then the banner: Saved. Back to: the task, with its minutes left",
                       box.isBannerShown && box.bannerText?.hasPrefix("Saved. Back to: Write the intro · ") == true)
                try await Task.sleep(for: .milliseconds(900))
                report("the banner stays after the sweep, settled", box.isBannerShown && box.state.settled)
                let title = DebugFrames.frames["savedTitle"], back = DebugFrames.frames["backTo"]
                report("Saved and Back to are the typed text's size, one line each",
                       title.map { abs($0.height - lineHeight) < 1.5 } == true && back.map { abs($0.height - lineHeight) < 1.5 } == true)
                let whole = DebugFrames.frames["noteBanner"]
                report("… and fit inside the banner", whole != nil && [title, back].allSatisfy { $0.map { whole!.contains($0) } == true })
                try await Task.sleep(for: .milliseconds(1700))
                report("the banner goes by itself after about 2 seconds (sweep and 1.5 s)", !box.isBannerShown)

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
                report("it opens again one line tall, not as tall as before", abs(panel.frame.height - oneLine) < 2)
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
                // Five lines: the box is exactly as tall as what it draws (no gap, no line
                // above it), stops growing at four lines; saved, the banner is the same frame.
                box.open()
                try await Task.sleep(for: .milliseconds(300))
                var heights: [CGFloat] = []
                var fourShown = false
                for line in ["one", "two", "three", "four", "five"] {
                    if !heights.isEmpty { key("\r", code: 36, shift: true) }
                    type(line)
                    try await Task.sleep(for: .milliseconds(150))
                    heights.append(panel.frame.height)
                    if line == "four" { fourShown = box.textAndField.map { $0.field.contains($0.text.insetBy(dx: 0.5, dy: 0.5)) } == true }
                }
                let content = panel.contentView?.fittingSize.height ?? 0
                report("the box is as tall as its content, with no gap", abs(panel.frame.height - content) < 1)
                report("four lines show in full", fourShown)
                report("its title bar is fully hidden: no line, no buttons, content from the top", box.titleBarHidden)
                report("it grows line by line to four lines, then scrolls",
                       heights[1] > heights[0] && heights[2] > heights[1] && heights[3] > heights[2] && heights[4] == heights[3])
                key("\u{1b}", code: 53)                         // kept as a draft
                try await Task.sleep(for: .milliseconds(200))
                box.open()
                let atOpen = panel.frame.height                 // the first frame, before any delayed fit
                try await Task.sleep(for: .milliseconds(300))
                report("a four-line draft reopens at its full height at once",
                       abs(atOpen - heights[3]) < 1 && abs(panel.frame.height - heights[3]) < 1)
                // Saved past four lines: the band sweeps over the same last four lines.
                let field = box.scrolledBy.field ?? 0
                try await returnUntilSwept()
                let banner = box.scrolledBy.banner
                print("  field scrolled", field, "banner", banner as Any)
                report("five lines saved: the band sweeps over the same last four lines",
                       field > 10 && banner.map { abs($0 - field) < 1 } == true)
                box.closeBanner()
                // Scrolled back up before saving: the band sweeps over the first four.
                box.open()
                try await Task.sleep(for: .milliseconds(300))
                for (i, line) in ["one", "two", "three", "four", "five"].enumerated() {
                    if i > 0 { key("\r", code: 36, shift: true) }
                    type(line)
                }
                try await Task.sleep(for: .milliseconds(150))
                if let scroll = NoteBox.scrollView(in: panel.contentView) {
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                let returned = Date()
                try await returnUntilSwept()
                let sweptFrom = Date()                          // its sweep began just before
                print("  scrolled-up banner drawn after", sweptFrom.timeIntervalSince(returned), "s")
                print("  scrolled up: banner", box.scrolledBy.banner as Any)
                report("scrolled up and saved: the band sweeps over the same first four lines",
                       box.scrolledBy.banner.map { abs($0) < 1 } == true)
                box.closeBanner()
                // That banner closed mid-sweep; a one-line note saved just after it would have
                // settled: the old text never settles over the new (review).
                box.open()
                try await Task.sleep(for: .milliseconds(300))
                type("x")
                let small = DebugFrames.frames["noteText"]
                let wait = 0.55 - Date().timeIntervalSince(sweptFrom)   // just after it would have settled
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                try await returnUntilSwept()
                let after = sweptNow()
                var copies: Set<Int> = []
                for _ in 0..<8 {                                // through the old one's would-be settle
                    copies.insert(box.bannerTextViews)
                    try await Task.sleep(for: .milliseconds(25))
                }
                print("  saved just after a closed sweep (waited \(wait) s): typed", small as Any, "swept", after as Any, "copies", copies)
                report("a banner closed mid-sweep never settles over the next note",
                       wait > 0 && small != nil && small == after && copies == [1])   // wait > 0: it really was mid-sweep
                box.closeBanner()
                // No task: one line, no During; saved at once, the banner is the box's frame.
                try clew.stopFocus()
                model.refresh()
                box.open()
                try await Task.sleep(for: .milliseconds(300))
                type("short")
                let boxFrame = panel.frame
                report("one line with no task: a slim box", boxFrame.height < 56 && model.noteContext() == nil)
                let short = DebugFrames.frames["noteText"]
                try await returnUntilSwept()
                let shortSwept = sweptNow()
                print("  one line typed", short as Any, "swept", shortSwept as Any)
                report("one line: the text stays the same size and place too",
                       short != nil && short == shortSwept)
                try await Task.sleep(for: .milliseconds(800))
                let slim = DebugFrames.frames["noteBanner"], slimTitle = DebugFrames.frames["savedTitle"]
                report("… and Saved fits the slim banner", slim != nil && slimTitle.map { slim!.contains($0) } == true)
                report("the banner takes exactly the box's frame", box.bannerFrame == boxFrame)
                box.closeBanner()

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
                state.savedText = "Ask Sam about the venue"
                NoteBannerView.startSettled = true
                render(NoteBannerView(state: state, dismiss: {}).frame(height: 76).padding(10), appearance: look,
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
