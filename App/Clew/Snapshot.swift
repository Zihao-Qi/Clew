#if DEBUG
import AppKit
import ClewCore
import ClewDomain
import ClewStore
import SwiftUI

/// Development only: render each screen to a PNG with sample data, then exit.
/// `CLEW_RENDER_PNG=1 Clew.app/Contents/MacOS/Clew` writes into the container's tmp
/// folder and prints the path. It never opens the real database.
@MainActor
enum Snapshot {
    static func renderAndExit() -> Never {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClewSnapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let clew = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
            try seed(clew)
            let model = AppModel(clew: clew)
            let editing = try clew.today().rows[2].item
            for (name, screen) in [("list", Screen.list), ("add", .add), ("pick", .pick), ("edit", .edit(editing))] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let file = dir.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png")
                    render(RootView(model: model, screen: screen), appearance: appearance, to: file)
                }
            }
            render(MenuBarLabel(today: model.today).padding(4), appearance: .aqua, to: dir.appendingPathComponent("label.png"))
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
        try clew.checkIn(itemId: exercise.id)
        try clew.checkIn(itemId: job.id)
        for title in ["Talk on attention", "Rust ownership article", "Interview prep video"] {
            _ = try clew.addItem(NewItem(title: title, url: URL(string: "https://youtube.com/watch?v=x"), shape: .later))
        }
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name, to file: URL) {
        let host = NSHostingView(rootView: view)
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
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
}
#endif
