#if DEBUG
import AppKit
import ClewCore
import ClewDomain
import ClewGateway
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
    /// Limitations: one run showed "details +0" for every row tap while buttons still
    /// worked; the cause is unproven (possibly the test window not becoming active).
    /// Hover can't be simulated. Both are checked by hand.
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
                // A live row: re-rendered from the model like the app's list (a fixed row
                // value would keep rating the tick that existed when the test began).
                let host = NSHostingView(rootView: LiveRow(model: model, onOpen: { details += 1 }).frame(width: 340))
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
                    // Real timestamps and a short press, like a person's click: a tap
                    // recognizer can ignore events stamped 0.
                    for (i, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime + Double(i) * 0.06,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: i,
                                                   clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
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
                // Rating dots on. A goal's +1 shows no dots, so the count stays visible
                // while ticking (goals are rated on hover, which can't be simulated).
                model.setRatingsEnabled(true)
                model.refresh()
                let countBefore = row().progressAmount
                try await click(22)
                try await click(22)
                print("goal: no dots after +1s:", model.ratingPrompt == nil,
                      "| count grew by 2:", row().progressAmount == countBefore + 2)
                // A habit's tick shows the hint; its fifth dot records "great"; unrated, they fade.
                let habit = try clew.addItem(NewItem(title: "Stretch", shape: .habit(.daily)))
                model.refresh()
                let habitHost = NSHostingView(rootView: LiveRow(model: model, onOpen: {}, itemId: habit.id).frame(width: 340))
                let habitWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -9_000, width: 340, height: size.height),
                                           styleMask: [.titled], backing: .buffered, defer: false)
                habitWindow.contentView = habitHost
                habitWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                @MainActor func clickHabit(_ x: CGFloat) async throws {
                    let p = habitHost.convert(NSPoint(x: x, y: size.height / 2), to: nil)
                    for (i, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime + Double(i) * 0.06,
                                                   windowNumber: habitWindow.windowNumber, context: nil, eventNumber: i,
                                                   clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                        NSApp.postEvent(e, atStart: false)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                }
                @MainActor func habitRow() -> TodayRow? { model.today?.rows.first { $0.id == habit.id } }
                try await clickHabit(22)
                print("habit: dots shown after a tick:", model.ratingPrompt?.itemId == habit.id)
                try await clickHabit(321)             // the fifth dot at the right end
                print("habit: rated:", habitRow()?.lastTickToday?.rating.map(String.init) ?? "none")
                try await clickHabit(22)              // undo the tick
                try await clickHabit(22)              // tick again, leave it unrated
                try await Task.sleep(for: .milliseconds(4500))
                print("habit: dots gone 4.5 s after an unrated tick:", model.ratingPrompt == nil)
                exit(0)
            } catch {
                print("click test failed:", error)
                exit(1)
            }
        }
    }

    private struct LiveRow: View {
        let model: AppModel
        let onOpen: () -> Void
        var itemId: UUID? = nil
        var body: some View {
            if let row = itemId.flatMap({ id in model.today?.rows.first { $0.id == id } }) ?? model.today?.rows.first {
                RowView(row: row, model: model, onEdit: {}, onOpen: onOpen)
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
                // (Clew.dragSlot, dragShift, clampDrag); the drag itself is checked by hand.
                exit(0)
            } catch {
                print("drop test failed:", error)
                exit(1)
            }
        }
    }

    /// `CLEW_RESTORE_TEST=1`: the app model's real restore path on a temporary
    /// database (never the user's): back up, change, restore, then undo the restore.
    /// `CLEW_GATEWAY_TEST=1`: inside the sandbox, listen on 127.0.0.1, pair and import
    /// one video over real HTTP, with a throwaway Keychain item and an in-memory
    /// database. Prints each step and exits.
    static func gatewayTestAndExit() -> Never {
        Task { @MainActor in
            do {
                let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
                let keychain = KeychainCredentials(account: "debug-gateway-test")
                keychain.remove()
                defer { keychain.remove() }
                let gateway = try Gateway(clew: clew, credentials: keychain, allowedOrigins: [BrowserConnection.extensionOrigin])
                let listener = GatewayListener(gateway: gateway)
                let port = try await listener.start()
                print("listening on 127.0.0.1:\(port)")
                let base = "http://127.0.0.1:\(port)/v1"
                let session = URLSession(configuration: .ephemeral)
                func post(_ path: String, _ body: [String: Any], token: String? = nil) async throws -> (Int, [String: Any]) {
                    var r = URLRequest(url: URL(string: base + path)!)
                    r.httpMethod = "POST"
                    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    r.setValue(BrowserConnection.extensionOrigin, forHTTPHeaderField: "Origin")
                    if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    r.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (data, response) = try await session.data(for: r)
                    return ((response as! HTTPURLResponse).statusCode,
                            (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
                }
                let code = gateway.startPairing().code
                let (pairStatus, paired) = try await post("/pair", ["code": code, "name": "debug"])
                print("pair:", pairStatus, "keychain clients:", (try? keychain.load().count) ?? -1)
                guard let token = paired["token"] as? String else { print("FAIL: no token"); exit(1) }
                let (importStatus, answer) = try await post("/import", [
                    "source": "extension.youtube", "listTotal": 1,
                    "entries": [["externalRef": "dQw4w9WgXcQ", "title": "Debug video"]],
                    "scan": ["found": 1, "parsed": 1, "selectorVersion": "debug"],
                ], token: token)
                print("import:", importStatus, answer["laterCount"] ?? "-", "later:", try clew.laterItems().map(\.title))
                let (bad, _) = try await post("/import", ["source": "extension.youtube", "entries": []], token: "wrong")
                print("wrong token:", bad)
                listener.stop()
                exit(pairStatus == 200 && importStatus == 200 && bad == 401 ? 0 : 1)
            } catch {
                print("FAIL:", error)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(1)
    }

    static func restoreTestAndExit() -> Never {
        Task { @MainActor in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clew-restore-test-\(UUID().uuidString)")
            let model = AppModel(databaseAt: dir.appendingPathComponent("clew.sqlite"), notify: false)
            @MainActor func titles() -> String { (model.today?.rows ?? []).map(\.item.title).joined(separator: ",") }
            _ = model.add(NewItem(title: "A", shape: .habit(.daily)))
            try? await Task.sleep(for: .milliseconds(500))         // the daily backup runs in the background
            let first = model.backupList()
            print("backups after launch:", first.map(\.url.lastPathComponent))
            _ = model.add(NewItem(title: "B", shape: .habit(.daily)))
            print("before restore:", titles())
            guard let backup = first.first else { print("FAIL: no backup"); exit(1) }
            print("restore →", await model.restore(backup))
            print("after restore:", titles())
            _ = model.add(NewItem(title: "C", shape: .habit(.daily)))   // the reopened database works
            print("after adding C:", titles())
            if let safety = model.backupList().first(where: \.isSafetyCopy) {
                print("undo →", await model.restore(safety))
                print("after undo:", titles())
            }
            print("backups now:", model.backupList().map(\.url.lastPathComponent))
            try? FileManager.default.removeItem(at: dir)
            exit(0)
        }
        RunLoop.main.run()
        exit(1)
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
            // Rating dots on, and "Stretch" just ticked, so the list shows them.
            model.setRatingsEnabled(true)
            model.refresh()
            if let stretch = model.today?.rows.first(where: { $0.item.title == "Stretch" }) { model.tap(stretch) }
            for (name, screen) in [("list", Screen.list), ("add", .add), ("pick", .pick),
                                   ("edit", .edit(editing, back: .list)), ("detail", .detail(editing.id))] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let file = dir.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png")
                    render(RootView(model: model, screen: screen), appearance: appearance, to: file)
                }
            }
            render(MenuBarLabel(today: model.today).padding(4), appearance: .aqua, to: dir.appendingPathComponent("label.png"))
            for pane in SettingsView.Pane.allCases {
                render(SettingsView(model: model, pane: pane), appearance: .aqua,
                       to: dir.appendingPathComponent("settings-\(pane.rawValue)-light.png"))
            }
            render(SettingsView(model: model, pane: .data), appearance: .darkAqua, to: dir.appendingPathComponent("settings-data-dark.png"))
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
            for _ in 0..<(daysAgo % 4 == 0 ? 3 : 1) { _ = try? clew.checkIn(itemId: course.id) }
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
        // A Later item saved 7 weeks ago, so the picker asks "still want this?".
        clock.date = now.addingTimeInterval(-49 * 86_400)
        _ = try clew.addItem(NewItem(title: "Rust ownership article", url: URL(string: "https://medium.com/x"), shape: .later))
        clock.date = now
        for title in ["Talk on attention", "Interview prep video"] {
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
