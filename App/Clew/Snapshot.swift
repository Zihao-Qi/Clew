#if DEBUG
import AppKit
import ClewCore
import ClewDomain
import ClewStore
import SwiftUI
import UserNotifications

/// Development only: render each screen to a PNG with sample data, then exit.
/// `CLEW_RENDER_PNG=1 Clew.app/Contents/MacOS/Clew` writes into the container's tmp
/// folder and prints the path. It never opens the real database.
@MainActor
enum Snapshot {
    /// `CLEW_FETCH_TITLE=<url>`: fetch one title through the sandboxed app and print it.
    static func fetchTitleAndExit(_ link: String) -> Never {
        Task { @MainActor in
            let model = AppModel(clew: nil)
            let title = await model.fetchTitle(for: URL(string: link)!)
            print("title:", title ?? "<nil>")
            exit(title == nil ? 1 : 0)
        }
        RunLoop.main.run()
        exit(1)
    }

    /// `CLEW_RECONCILE_TEST=1`: checks the adapter against the real notification
    /// center with far-future requests (year 2030, never shown), then removes them.
    static func reconcileTestAndExit() -> Never {
        Task { @MainActor in
            let adapter = NotificationsAdapter { _ in }
            let fire = Date(timeIntervalSince1970: 1_900_000_000)
            func plan(_ titles: [String]) -> [PlannedNotification] {
                titles.enumerated().map { i, t in
                    PlannedNotification(id: "clew.selftest.\(i)", fireAt: fire.addingTimeInterval(Double(i) * 60),
                                        content: .reminder(itemId: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i)")!,
                                                           title: t, canOpen: false, canMoveToLater: true))
                }
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            print("authorization:", settings.authorizationStatus.rawValue, "(2 = authorized)")
            let before = await adapter.pendingIds().filter { !$0.hasPrefix("clew.selftest") }
            await adapter.applyNow(plan(["a", "b", "c"]))
            print("1 add:", adapter.lastChange.added, "remove:", adapter.lastChange.removed)
            await adapter.applyNow(plan(["a", "b", "c"]))
            print("2 same plan → add:", adapter.lastChange.added, "remove:", adapter.lastChange.removed)
            await adapter.applyNow(plan(["a", "B", "c"]))
            print("3 one title changed → add:", adapter.lastChange.added, "remove:", adapter.lastChange.removed)
            print("  pending:", await adapter.pendingIds().filter { $0.hasPrefix("clew.selftest") })
            await adapter.applyNow([])
            print("4 empty plan → remove:", adapter.lastChange.removed)
            let after = await adapter.pendingIds()
            print("  left:", after.filter { $0.hasPrefix("clew.selftest") }, "others untouched:", before.allSatisfy(after.contains) || before.isEmpty)
            exit(0)
        }
        RunLoop.main.run()
        exit(1)
    }

    /// `CLEW_CLICK_TEST=1`: real mouse clicks on one goal row in an off-screen window;
    /// prints what each click did. In-memory data; opens nothing.
    static func startClickTest() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1)) // let NSApplication start its event loop
            do {
                let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
                let goal = try clew.addItem(NewItem(title: "ML course", url: URL(string: "https://course.example"),
                                                    shape: .goal(target: 30, schedule: .daily)))
                try clew.checkIn(itemId: goal.id)
                try clew.checkIn(itemId: goal.id)
                let model = AppModel(clew: clew, notify: false)
                var opened: [URL] = []
                model.urlOpener = { opened.append($0) }
                var details = 0
                @MainActor func row() -> TodayRow { model.today!.rows[0] }
                let host = NSHostingView(rootView: RowView(row: row(), model: model, onEdit: {}, onOpen: { details += 1 })
                    .frame(width: 340))
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                print("window up", size); fflush(stdout)
                try await Task.sleep(for: .milliseconds(400))

                @MainActor func click(_ x: CGFloat, y: CGFloat = size.height / 2) async throws {
                    let p = host.convert(NSPoint(x: x, y: y), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1)!
                        NSApp.postEvent(e, atStart: false) // the queue, so a button's tracking loop sees mouseUp
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let titleWidth = ("ML course" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
                let spots: [(String, CGFloat)] = [
                    ("circle", 22), ("title", 60), ("link mark", 44 + titleWidth + 4 + 7),
                    ("blank space", 175), ("bar", 230), ("count", 290), ("minus", 322),
                    ("left margin", 4), ("right margin", 336),
                ]
                for (name, x) in spots + [("top padding", 150), ("bottom padding", 150)] {
                    let y: CGFloat = name == "top padding" ? size.height - 2 : name == "bottom padding" ? 2 : size.height / 2
                    let before = (details, row().todayAmount, opened.count)
                    try await click(x, y: y)
                    print(String(format: "%-12@ x=%3.0f → details %+d, today's +1s %+d, links opened %+d", name as NSString, x,
                                 details - before.0, row().todayAmount - before.1, opened.count - before.2)); fflush(stdout)
                }
                exit(0)
            } catch {
                print("click test failed:", error)
                exit(1)
            }
        }
    }

    /// `CLEW_DROP_TEST=1`: three rows; calls the drop logic the drag gesture uses.
    static func startDropTest() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            do {
                let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
                for t in ["A", "B", "C"] { _ = try clew.addItem(NewItem(title: t, shape: .habit(.daily))) }
                let model = AppModel(clew: clew, notify: false)
                @MainActor func order() -> String { model.today!.rows.map(\.item.title).joined() }
                print("start:", order())
                let rows = model.today!.rows
                print("drop() A onto C returned", model.drop(rows[0].id, onto: rows[2]), "→", order())
                print("drop() C onto A returned", model.drop(model.today!.rows[2].id, onto: model.today!.rows[0]), "→", order())

                // A real drag can't be simulated: SwiftUI checks the actual mouse-button state,
                // which posted events don't change. Row targeting is unit-tested in Core
                // (Clew.rowUnderDrag); the drag itself is checked by hand.
                exit(0)
            } catch {
                print("drop test failed:", error)
                exit(1)
            }
        }
    }

    static func renderAndExit() -> Never {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClewSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let clock = MovableClock()
            let clew = Clew(store: try SQLiteStore.inMemory(), clock: clock, zones: SystemTimeZone())
            try seed(clew, clock: clock)
            let model = AppModel(clew: clew, notify: false)
            let editing = try clew.today().rows[2].item
            for (name, screen) in [("list", Screen.list), ("add", .add), ("pick", .pick),
                                   ("edit", .edit(editing, back: .list)), ("detail", .detail(editing.id))] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let file = dir.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png")
                    render(RootView(model: model, screen: screen), appearance: appearance, to: file)
                }
            }
            render(MenuBarLabel(today: model.today).padding(4), appearance: .aqua, to: dir.appendingPathComponent("label.png"))
            render(SettingsView(model: model), appearance: .aqua, to: dir.appendingPathComponent("settings-light.png"))
            render(SettingsView(model: model), appearance: .darkAqua, to: dir.appendingPathComponent("settings-dark.png"))
            print(dir.path)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// A clock the snapshot can move into the past to seed history.
    final class MovableClock: Clock, @unchecked Sendable {
        var date = Date()
        func now() -> Date { date }
    }

    private static func seed(_ clew: Clew, clock: MovableClock) throws {
        let exercise = try clew.addItem(NewItem(title: "Exercise", shape: .habit(.daily)))
        let job = try clew.addItem(NewItem(title: "Apply to 1 job", shape: .today))
        let course = try clew.addItem(NewItem(title: "ML course", url: URL(string: "https://course.example"),
                                              shape: .goal(target: 30, schedule: .daily)))
        _ = try clew.addItem(NewItem(title: "Stretch", shape: .habit(.timesPerWeek(3))))
        _ = try clew.addItem(NewItem(title: "A very long item title that should truncate nicely in the row",
                                     shape: .today))
        // Some history for the details heatmap: a few days a week over ten weeks.
        let now = clock.date
        for daysAgo in stride(from: 70, through: 1, by: -1) where daysAgo % 3 != 0 && daysAgo % 7 != 5 {
            clock.date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            for _ in 0..<(daysAgo % 4 == 0 ? 3 : 1) { try? clew.checkIn(itemId: course.id) }
        }
        clock.date = now
        try clew.startNextRound(itemId: course.id)
        for _ in 0..<10 { try clew.checkIn(itemId: course.id) }
        try clew.setReminder(itemId: course.id, time: TimeOfDay(hour: 18, minute: 0))
        var summaries = SummarySettings.defaults
        summaries.morningEnabled = true
        summaries.eveningEnabled = true
        try clew.setSummaries(summaries)
        _ = try clew.addItem(NewItem(title: "Read papers", shape: .goal(target: 30, schedule: .daily)))
        let pages = try clew.addItem(NewItem(title: "Book pages", shape: .goal(target: 500, schedule: .daily)))
        for _ in 0..<120 { try clew.checkIn(itemId: pages.id) }
        let pushups = try clew.addItem(NewItem(title: "Push-ups", shape: .goal(target: 3, schedule: .daily)))
        for _ in 0..<3 { try clew.checkIn(itemId: pushups.id) }
        try clew.checkIn(itemId: exercise.id)
        try clew.checkIn(itemId: job.id)
        for title in ["Talk on attention", "Rust ownership article", "Interview prep video"] {
            _ = try clew.addItem(NewItem(title: title, url: URL(string: "https://youtube.com/watch?v=x"), shape: .later))
        }
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name, to file: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // AppKit-backed controls only draw in a window that is on screen.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file)
        // The container is protected from other apps (the terminal included), so
        // CLEW_RENDER_PNG=stdout also prints each image for the developer to decode.
        if ProcessInfo.processInfo.environment["CLEW_RENDER_PNG"] == "stdout" {
            print("PNG \(file.lastPathComponent) \(png.base64EncodedString())")
        }
    }
}
#endif
