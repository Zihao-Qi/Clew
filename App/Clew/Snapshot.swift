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

    static func renderAndExit() -> Never {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClewSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
            try seed(clew)
            let model = AppModel(clew: clew, notify: false)
            let editing = try clew.today().rows[2].item
            for (name, screen) in [("list", Screen.list), ("add", .add), ("pick", .pick), ("edit", .edit(editing))] {
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

    private static func seed(_ clew: Clew) throws {
        let exercise = try clew.addItem(NewItem(title: "Exercise", shape: .habit(.daily)))
        let job = try clew.addItem(NewItem(title: "Apply to 1 job", shape: .today))
        let course = try clew.addItem(NewItem(title: "ML course", url: URL(string: "https://course.example"),
                                              shape: .goal(target: 30, schedule: .daily)))
        _ = try clew.addItem(NewItem(title: "Stretch", shape: .habit(.timesPerWeek(3))))
        _ = try clew.addItem(NewItem(title: "A very long item title that should truncate nicely in the row",
                                     shape: .today))
        for _ in 0..<10 { try clew.checkIn(itemId: course.id) }
        try clew.setReminder(itemId: course.id, time: TimeOfDay(hour: 18, minute: 0))
        var summaries = SummarySettings.defaults
        summaries.morningEnabled = true
        summaries.eveningEnabled = true
        try clew.setSummaries(summaries)
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
