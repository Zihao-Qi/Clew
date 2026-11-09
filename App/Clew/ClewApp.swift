import AppKit
import ClewDomain
import SwiftUI

@main
struct ClewApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if let link = ProcessInfo.processInfo.environment["CLEW_FETCH_TITLE"] {
            Snapshot.fetchTitleAndExit(link)
        }
        if ProcessInfo.processInfo.environment["CLEW_RECONCILE_TEST"] != nil {
            Snapshot.reconcileTestAndExit()
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
            MenuBarLabel(today: model.today)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Clew Settings"), id: SettingsView.windowID) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The menu bar title: `done/total` for today (SPEC §1).
struct MenuBarLabel: View {
    let today: TodayList?

    var body: some View {
        if let today, today.total > 0 {
            Text("\(Image(systemName: "checklist")) \(today.done)/\(today.total)")
                .accessibilityLabel(Text("Clew, \(today.done) of \(today.total) done"))
        } else {
            Image(systemName: "checklist")
                .accessibilityLabel(Text("Clew"))
        }
    }
}

enum Screen: Equatable {
    case list, add, pick
    case detail(UUID)
    /// `back` is where Save or Cancel returns to: the list or that item's details.
    case edit(Item, back: Back)

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
                case .pick: PickView(model: model) { screen = .list }
                case .detail(let id):
                    DetailView(model: model, itemId: id,
                               onEdit: { screen = .edit($0, back: .detail) },
                               onBack: { screen = .list })
                case .edit(let item, let back):
                    EditView(model: model, item: item) { screen = back == .detail ? .detail(item.id) : .list }
                }
            }
        }
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Opening the list always shows today as it is now.
            model.refresh()
        }
        .onChange(of: screen) { model.notice = nil }
    }
}
