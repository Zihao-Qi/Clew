import AppKit
import ClewCore
import ClewDomain
import SwiftUI

@main
struct ClewApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLEW_SHORTCUT_SMOKE"] != nil {
            _model = State(initialValue: ShortcutSmokeTest.model())
            return
        }
        if let link = ProcessInfo.processInfo.environment["CLEW_FETCH_TITLE"] {
            Snapshot.fetchTitleAndExit(link)
        }
        if ProcessInfo.processInfo.environment["CLEW_RECONCILE_TEST"] != nil {
            Snapshot.reconcileTestAndExit()
        }
        if ProcessInfo.processInfo.environment["CLEW_GATEWAY_TEST"] != nil {
            Snapshot.gatewayTestAndExit()
        }
        if ProcessInfo.processInfo.environment["CLEW_RESTORE_TEST"] != nil {
            Snapshot.restoreTestAndExit()
        }
        if ProcessInfo.processInfo.environment["CLEW_DROP_TEST"] != nil {
            _model = State(initialValue: AppModel(clew: nil, notify: false))
            Snapshot.startDropTest()
            return
        }
        if ProcessInfo.processInfo.environment["CLEW_CLICK_TEST"] != nil {
            // Mouse events need the real event loop, so the app starts (with no data and no
            // notifications) and the test runs once it is up.
            _model = State(initialValue: AppModel(clew: nil, notify: false))
            Snapshot.startClickTest()
            return
        }
        if ProcessInfo.processInfo.environment["CLEW_SCROLL_TEST"] != nil {
            _model = State(initialValue: AppModel(clew: nil, notify: false))
            Snapshot.startScrollTest()
            return
        }
        if ProcessInfo.processInfo.environment["CLEW_TIME_TEST"] != nil {
            _model = State(initialValue: AppModel(clew: nil, notify: false))
            Snapshot.startTimeFieldTest()
            return
        }
        if ProcessInfo.processInfo.environment["CLEW_NEWTASK_TEST"] != nil {
            _model = State(initialValue: AppModel(clew: nil, notify: false))
            Snapshot.startNewTaskTest()
            return
        }
        if ProcessInfo.processInfo.environment["CLEW_RENDER_PNG"] != nil {
            Snapshot.renderAndExit()
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model)
        } label: {
            MenuBarLabel(today: model.today, focus: model.focus, now: model.clockTick, style: model.menuBarStyle)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Clew Settings"), id: SettingsView.windowID) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The menu bar title: a ring, a Daruma or `done/total` for today (SPEC §1; 2026-11-18).
struct MenuBarLabel: View {
    let today: TodayList?
    var focus: FocusTimer? = nil
    /// The model's one-second tick (never a TimelineView here: inside a menu bar label
    /// it redraws the status item without end).
    var now = Date()
    var style = Clew.defaultMenuBarStyle

    var body: some View {
        if let focus {
            // The countdown, so it can be seen with the list closed (SPEC 2026-11-10).
            let left = RowView.clock(focus.remaining(at: now))
            let symbol = focus.phase == .rest ? "cup.and.saucer" : focus.isPaused ? "pause.circle" : "timer"
            Text("\(Image(systemName: symbol)) \(left)")
                .monospacedDigit()
                .accessibilityLabel(focus.phase == .rest ? Text("Clew, break, \(left) left")
                                                         : Text("Clew, focus, \(left) left"))
        } else if style == .ring, let today, let ring = MenuBarRing(done: today.done, total: today.total) {
            Image(nsImage: MenuBarRingImage.image(ring))
                .accessibilityLabel(Text("Clew, \(today.done) of \(today.total) done"))
        } else if style == .daruma, let today, let stage = DarumaStage.of(done: today.done, total: today.total) {
            Image(nsImage: DarumaImage.image(stage: stage))
                .accessibilityLabel(Text("Clew, \(today.done) of \(today.total) done"))
        } else if let today, today.total > 0 {
            // Just the numbers (user, 2026-11-18: no icon before them).
            Text(verbatim: "\(today.done)/\(today.total)")
                .monospacedDigit()
                .accessibilityLabel(Text("Clew, \(today.done) of \(today.total) done"))
        } else {
            Image(systemName: "checklist")
                .accessibilityLabel(Text("Clew"))
        }
    }
}

enum Screen: Equatable {
    case list, add
    case detail(UUID)
    /// An imported list's page (YouTube Watch Later).
    case collection(Source)
    /// `back` is where Save or Cancel returns to: the list or that item's details.
    case edit(Item, back: Back)
    /// "Put on timeline…" (block nil) or a block's "Move to…" (SPEC 2026-11-10).
    case place(UUID, block: UUID?)

    enum Back: Equatable { case list, detail }
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var screen: Screen

    init(model: AppModel, screen: Screen = .list) {
        self.model = model
        _screen = State(initialValue: screen)
    }

    var body: some View {
        Group {
            if let message = model.fatalMessage {
                Text(message).padding(16)
            } else {
                switch screen {
                case .list: TodayListView(model: model, screen: $screen)
                case .add: AddView(model: model) { screen = .list }
                case .detail(let id):
                    DetailView(model: model, itemId: id,
                               onEdit: { screen = .edit($0, back: .detail) },
                               onBack: { screen = .list })
                case .collection(let source):
                    // One page per list: its folded groups never carry over to the other.
                    CollectionView(model: model, source: source) { screen = .list }.id(source)
                case .edit(let item, let back):
                    EditView(model: model, item: item) { screen = back == .detail ? .detail(item.id) : .list }
                case .place(let itemId, let block):
                    PlaceView(model: model, itemId: itemId, blockId: block) { screen = .list }
                }
            }
        }
        .frame(width: 340)
        // Last week's card (SPEC 2026-11-15): one opening of the menu's own window.
        // It also refreshes the menu once per opening, on any screen (SPEC 2026-11-19:
        // it used to refresh a second time for any window becoming key, Settings too).
        .background(MenuSessionWatcher(model: model, onList: screen == .list))
        .onChange(of: screen) { model.notice = nil }
    }
}

/// Reports the menu's own window opening (becoming key) and closing (losing key or
/// closing) to the model, for last week's card. Filtered to its own window: Settings
/// and system panels becoming key are not an opening.
struct MenuSessionWatcher: NSViewRepresentable {
    let model: AppModel
    let onList: Bool

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.model = model
        view.onList = onList
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) {
        view.model = model
        view.onList = onList
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        weak var model: AppModel?
        var onList = true
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.opened() }
            })
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model?.menuClosed() }
                })
            }
            // The first opening after launch: the window may already be key when this
            // view joins it, so no "became key" will come for this opening. Next turn,
            // not while SwiftUI is attaching views.
            if window.isKeyWindow {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.window?.isKeyWindow == true else { return }
                        self.opened()
                    }
                }
            }
        }

        private func opened() { model?.menuOpened(onList: onList) }
    }
}
