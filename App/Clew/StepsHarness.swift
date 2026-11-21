#if DEBUG
import AppKit
import ClewCore
import ClewDomain
import ClewStore
import SwiftUI

extension Snapshot {
    /// `CLEW_STEPS_TEST=1`: steps in a task (SPEC 2026-11-21) in the real list, with real
    /// mouse and key events in an off-screen window: a click unfolds at once (no wait for a
    /// second click), a double-click opens the details and leaves the fold as it was, a
    /// plain row's click does nothing, circles keep their own clicks, and Add Step…'s line
    /// (reached through its VoiceOver action). In-memory data. Hover (the held step, the
    /// Delete key) and the right-click menu are checked by hand.
    static func startStepsTest() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            var failures = 0
            @MainActor func report(_ name: String, _ ok: Bool) {
                if !ok { failures += 1 }
                print(ok ? "PASS" : "FAIL", name); fflush(stdout)
            }
            do {
                let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
                try clew.closeCalendarPrompt()
                try clew.setTimelineShown(false)
                let talk = try clew.addItem(NewItem(title: "Prepare the talk", shape: .today)).id
                let steps = try ["slides", "notes", "practice"].map { try clew.addStep(taskId: talk, title: $0).id }
                let milk = try clew.addItem(NewItem(title: "Buy milk", shape: .today)).id
                AppModel.foldDefaults = UserDefaults(suiteName: "clew-steps-test")!
                let model = AppModel(clew: clew, notify: false)
                model.setUnfolded(talk, false)
                model.refresh()
                let probe = StepsProbe()
                // A fixed window with the list at its top, as the menu grows downward: rows above
                // a task that unfolds stay where they are between two clicks.
                let host = NSHostingView(rootView: StepsListHarness(model: model, probe: probe)
                    .frame(width: 340, height: 500, alignment: .top))
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 340, height: 500),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(600))

                /// A probed view's frame in the window (bottom-left origin). The probes'
                /// global frames are measured from the window's top, title bar included.
                @MainActor func frame(_ key: String) -> NSRect? {
                    guard let r = DebugFrames.frames[key] else { return nil }
                    return NSRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
                }
                var number = 0
                /// `clicks` clicks at a point in the window, 60 ms apart, like a person's.
                @MainActor func mouse(_ p: NSPoint, clicks: Int = 1, settle: Int = 120) async throws {
                    for n in 1...clicks {
                        for (i, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                            number += 1
                            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime + Double(i) * 0.03,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                                       clickCount: n, pressure: type == .leftMouseDown ? 1 : 0)!
                            NSApp.postEvent(e, atStart: false)
                        }
                        try await Task.sleep(for: .milliseconds(60))
                    }
                    try await Task.sleep(for: .milliseconds(settle))
                }
                @MainActor func key(_ chars: String, code: UInt16 = 0) async throws {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                        NSApp.postEvent(e, atStart: false)
                    }
                    try await Task.sleep(for: .milliseconds(40))
                }
                @MainActor func type(_ text: String) async throws {
                    for c in text { try await key(String(c)) }
                    try await Task.sleep(for: .milliseconds(200))
                }
                @MainActor func shown() -> [String] {
                    (model.steps(of: talk)?.entries ?? []).map { ($0.isDone ? "✓" : "") + $0.step.title }
                }
                @MainActor func waitForDoubleClickToPass() async throws {
                    try await Task.sleep(for: .milliseconds(Int(NSEvent.doubleClickInterval * 1000) + 150))
                }

                guard let circle = frame("circle:\(talk)"), let milkCircle = frame("circle:\(milk)") else {
                    print("FAIL: rows not found", DebugFrames.frames.keys.sorted()); exit(1)
                }
                // Measured again before each click: unfolding grows the list, which moves
                // the rows in the window.
                var row: NSPoint { NSPoint(x: 200, y: (frame("circle:\(talk)") ?? circle).midY) }
                var milkRow: NSPoint { NSPoint(x: 200, y: (frame("circle:\(milk)") ?? milkCircle).midY) }
                print("talk row y:", row.y, "milk row y:", milkRow.y, "double-click interval:", NSEvent.doubleClickInterval,
                      "host:", host.frame, "raw:", DebugFrames.frames["circle:\(talk)"] as Any, "key:", window.isKeyWindow)

                // The off-screen window sometimes drops the first click after it opens: one
                // on empty space below the list first.
                try await mouse(NSPoint(x: 200, y: 20))
                try await waitForDoubleClickToPass()
                try await mouse(row, settle: 100)
                let atOnce = model.isUnfolded(talk)
                try await Task.sleep(for: .milliseconds(600))
                print("  after 100 ms:", atOnce, "after 700 ms:", model.isUnfolded(talk), "row:", row)
                report("a click unfolds a task with steps at once (100 ms)", atOnce && probe.opened.isEmpty)
                try await waitForDoubleClickToPass()
                try await mouse(row)
                report("a second click folds it", !model.isUnfolded(talk))
                try await waitForDoubleClickToPass()

                try await mouse(row, clicks: 2)
                report("a double-click opens the details and leaves it folded",
                       probe.opened == [talk] && !model.isUnfolded(talk))
                try await waitForDoubleClickToPass()
                model.setUnfolded(talk, true)
                try await Task.sleep(for: .milliseconds(200))
                try await mouse(row, clicks: 2)
                report("… and an unfolded one unfolded", probe.opened == [talk, talk] && model.isUnfolded(talk))
                try await waitForDoubleClickToPass()

                try await mouse(milkRow)
                try await waitForDoubleClickToPass()
                report("a click on a row without steps does nothing", probe.opened == [talk, talk])
                try await mouse(milkRow, clicks: 2)
                report("a double-click on it opens its details", probe.opened == [talk, talk, milk])
                try await waitForDoubleClickToPass()

                guard let practice = frame("circle:\(steps[2])") else { print("FAIL: step not found"); exit(1) }
                try await mouse(NSPoint(x: practice.midX, y: practice.midY))
                report("a step's circle ticks that step and not the task, and does not fold it",
                       shown() == ["✓practice", "slides", "notes"] && model.row(talk)?.isDone == false
                       && model.isUnfolded(talk))
                try await waitForDoubleClickToPass()
                let taskCircle = frame("circle:\(talk)") ?? circle
                try await mouse(NSPoint(x: taskCircle.midX, y: taskCircle.midY))
                report("the task's circle finishes it at once, steps and all, without folding it",
                       model.row(talk)?.isDone == true && shown().allSatisfy { $0.hasPrefix("✓") } && model.isUnfolded(talk))
                try await waitForDoubleClickToPass()
                let undoCircle = frame("circle:\(talk)") ?? taskCircle
                try await mouse(NSPoint(x: undoCircle.midX, y: undoCircle.midY))
                report("unticking it puts the steps back", shown() == ["✓practice", "slides", "notes"])
                try await waitForDoubleClickToPass()

                if let slides = frame("step:\(steps[0])") {
                    try await mouse(NSPoint(x: slides.midX, y: slides.midY))
                    try await waitForDoubleClickToPass()
                    let afterOne = probe.opened.count
                    try await mouse(NSPoint(x: slides.midX, y: slides.midY), clicks: 2)
                    report("a click on a step does nothing; a double-click opens its task's details",
                           afterOne == 3 && probe.opened.last == talk && probe.opened.count == 4)
                } else {
                    report("a step's row is found", false)
                }
                try await waitForDoubleClickToPass()

                // Add Step… through its VoiceOver action.
                model.setUnfolded(talk, false)
                try await Task.sleep(for: .milliseconds(200))
                DebugFrames.addStep?(talk)
                try await Task.sleep(for: .milliseconds(400))
                report("Add Step… unfolds the task", model.isUnfolded(talk))
                try await type("rest")
                try await key("\r", code: 36)
                try await Task.sleep(for: .milliseconds(300))
                report("Return adds the step after the others", shown() == ["✓practice", "slides", "notes", "rest"])
                try await type("stretch")
                try await key("\r", code: 36)
                try await Task.sleep(for: .milliseconds(300))
                report("… and the next line is open for another", shown().last == "stretch")
                try await key("\r", code: 36)
                try await Task.sleep(for: .milliseconds(300))
                report("Return on an empty line closes it", frame("newStep:\(talk)") == nil)
                DebugFrames.addStep?(talk)
                try await Task.sleep(for: .milliseconds(400))
                try await type("dropped")
                try await key("\u{1b}", code: 53)
                try await Task.sleep(for: .milliseconds(300))
                report("Esc closes it and drops what was typed",
                       frame("newStep:\(talk)") == nil && !shown().contains("dropped"))
                // Details: Esc closes the step line before it leaves the page (review).
                var backs = 0
                let detailHost = NSHostingView(rootView: DetailView(model: model, itemId: talk, onEdit: { _ in },
                                                                    onBack: { backs += 1 })
                    .frame(width: 340, height: 600, alignment: .top))
                let detailWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -9_000, width: 340, height: 600),
                                            styleMask: [.titled], backing: .buffered, defer: false)
                detailWindow.contentView = detailHost
                detailWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(Int(NSEvent.doubleClickInterval * 1000) + 400))
                @MainActor func detailClick(_ key: String) async throws {
                    guard let r = DebugFrames.frames[key] else { report("found \(key)", false); return }
                    let p = NSPoint(x: r.midX, y: detailWindow.frame.height - r.midY)
                    for (i, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                        number += 1
                        NSApp.postEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                                           timestamp: ProcessInfo.processInfo.systemUptime + Double(i) * 0.03,
                                                           windowNumber: detailWindow.windowNumber, context: nil,
                                                           eventNumber: number, clickCount: 1,
                                                           pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
                @MainActor func detailKey(_ chars: String, code: UInt16) async throws {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: detailWindow.windowNumber, context: nil,
                                                         characters: chars, charactersIgnoringModifiers: chars,
                                                         isARepeat: false, keyCode: code)!, atStart: false)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                }
                report("Details open with no step line", DebugFrames.frames["detailNew:\(talk)"] == nil && backs == 0)
                try await detailClick("detailAdd:\(talk)")
                report("Add Step opens the line", DebugFrames.frames["detailNew:\(talk)"] != nil)
                try await detailKey("\u{1b}", code: 53)
                report("Esc closes the line and stays on the page",
                       DebugFrames.frames["detailNew:\(talk)"] == nil && backs == 0)
                try await detailKey("\u{1b}", code: 53)
                report("then Esc goes back", backs == 1)
                _ = steps
                exit(failures == 0 ? 0 : 1)
            } catch {
                print("steps test failed:", error)
                exit(1)
            }
        }
    }

    /// `CLEW_STEPS_RENDER=1`: the list with tasks that have steps (folded, unfolded, a
    /// link's), a goal and a plain task for comparison, and a task's details, in light
    /// and dark, to the temporary folder's ClewSnapshots (stdout as in CLEW_RENDER_PNG).
    static func renderStepsAndExit() -> Never {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClewSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
            try clew.closeCalendarPrompt()
            try clew.setTimelineShown(false)
            let talk = try clew.addItem(NewItem(title: "Prepare the talk", shape: .today)).id
            let talkSteps = try ["Make slides", "Speech notes", "Practice"].map { try clew.addStep(taskId: talk, title: $0).id }
            try clew.tickStep(id: talkSteps[0])
            let move = try clew.addItem(NewItem(title: "Move flat", shape: .today)).id
            let moveSteps = try ["Boxes", "Van", "Pack", "Clean", "Keys"].map { try clew.addStep(taskId: move, title: $0).id }
            try clew.tickStep(id: moveSteps[0]); try clew.tickStep(id: moveSteps[1])
            _ = try clew.addItem(NewItem(title: "Buy milk", shape: .today))
            let read = try clew.addItem(NewItem(title: "Swift concurrency guide", url: URL(string: "https://www.swift.org/documentation/"),
                                                shape: .today)).id
            try clew.addStep(taskId: read, title: "Read part 1")
            try clew.addStep(taskId: read, title: "Try the examples")
            let books = try clew.addItem(NewItem(title: "Read 30 books", shape: .goal(target: 30))).id
            for _ in 0..<10 { try clew.checkIn(itemId: books) }
            AppModel.foldDefaults = UserDefaults(suiteName: "clew-steps-render")!
            let model = AppModel(clew: clew, notify: false)
            for id in [talk, move, read] { model.setUnfolded(id, id == talk) }
            model.refresh()
            for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(RootView(model: model), appearance: look, to: dir.appendingPathComponent("steps-list-\(name).png"))
                render(RootView(model: model, screen: .detail(talk)), appearance: look,
                       to: dir.appendingPathComponent("steps-detail-\(name).png"))
            }
            exit(0)
        } catch {
            print("render failed:", error)
            exit(1)
        }
    }

    @MainActor final class StepsProbe {
        var opened: [UUID] = []
    }

    /// The real list, its screen changes reported (a details page is noted, then the
    /// list comes back).
    private struct StepsListHarness: View {
        let model: AppModel
        let probe: StepsProbe
        @State private var screen: Screen = .list
        var body: some View {
            TodayListView(model: model, screen: $screen)
                .onChange(of: screen) { _, now in
                    if case .detail(let id) = now { probe.opened.append(id) }
                    if now != .list { screen = .list }
                }
        }
    }
}
#endif
