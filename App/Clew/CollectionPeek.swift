import AppKit
import ClewCore
import ClewDomain
import SwiftUI

/// The hover panel beside a collection row (SPEC 2026-11-13, "A peek on hover"): only
/// what is left, one title per line. `PeekState` (Core) decides when it is open; this
/// controller feeds it and shows or hides one borderless, never-key panel attached to
/// the menu's window.
@MainActor
final class PeekController {
    static let shared = PeekController()

    static let width: CGFloat = 280
    static let lineHeight: CGFloat = 22
    static let maxLines = 12

    private var state = PeekState()
    private weak var menuWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var model: AppModel?
    /// The collection row under the pointer, and a view behind each row (its frame on
    /// screen is read when the panel opens).
    private var currentRow: Source?
    private var rowViews: [Source: WeakView] = [:]
    struct WeakView { weak var view: NSView? }
    private var panel: PeekPanel?
    private var shown: Source?
    private var timer: Timer?
    /// Counts the menu becoming key: a deferred "menu closed" from before is stale.
    private var epoch = 0
    /// Between the menu losing the keyboard and the deferred close: nothing new is timed.
    private var menuLeaving = false

    // MARK: Events from the list

    /// The list's window: the menu. Its closing (or losing key) ends the peek, one
    /// main-queue turn later so a press in the panel is handled first.
    func attach(window: NSWindow?, model: AppModel) {
        self.model = model
        guard window !== menuWindow else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        menuWindow = window
        epoch += 1
        guard let window else { return }
        observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { PeekController.shared.menuGoing(window) }
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                let peek = PeekController.shared
                peek.epoch += 1
                // Key again before the deferred close: carry on where it was.
                peek.menuLeaving = false
                peek.sync()
            }
        })
    }

    /// The menu is closing or lost the keyboard: nothing may open from now on (a timer
    /// due on this turn is stopped at once), and the panel closes one turn later, so a
    /// press in it is handled first. A later "became key" makes that close stale.
    private func menuGoing(_ window: NSWindow) {
        timer?.invalidate()
        timer = nil
        menuLeaving = true
        let token = epoch
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let peek = PeekController.shared
                guard peek.menuWindow === window, peek.epoch == token, !window.isKeyWindow else { return }
                peek.apply { $0.menuClosed() }
                peek.menuLeaving = false
            }
        }
    }

    /// The pointer moved in the list. Its position is read on screen from AppKit, so no
    /// coordinate conversion can differ from where the panel is placed.
    /// The row under it is found here too, from the rows' frames on screen: SwiftUI's
    /// `onHover` for the row can arrive after this event, which made the rest start
    /// only on a second movement (it felt slow).
    func pointerMoved() {
        let screen = NSEvent.mouseLocation
        currentRow = row(at: screen)
        apply { $0.pointer(on: currentRow, at: PeekPoint(x: screen.x, y: screen.y), now: Date()) }
    }

    /// The pointer left the list's window.
    func pointerLeftList() {
        currentRow = nil
        apply { $0.pointerLeftRows(now: Date()) }
    }

    private func row(at point: NSPoint) -> Source? {
        for (source, anchor) in rowViews {
            guard let view = anchor.view, let window = view.window, window === menuWindow,
                  !view.isHiddenOrHasHiddenAncestor else { continue }
            if window.convertToScreen(view.convert(view.visibleRect, to: nil)).contains(point) { return source }
        }
        return nil
    }

    fileprivate func rowView(_ source: Source, _ view: NSView) { rowViews[source] = WeakView(view: view) }

    func rowClicked() { apply { $0.rowClicked() } }
    func dragChanged(_ active: Bool) { apply { $0.dragChanged(active) } }

    func listLeft() {
        currentRow = nil
        apply { $0.listLeft() }
    }

    /// The lists changed: one with nothing left closes its panel.
    func collectionsChanged(_ summaries: [CollectionSummary]) {
        for summary in summaries where summary.toWatch == 0 { apply { $0.emptied(summary.source) } }
        if let shown, !summaries.contains(where: { $0.source == shown }) { apply { $0.emptied(shown) } }
    }

    fileprivate func panelHover(_ inside: Bool) { apply { $0.panelHover(inside, now: Date()) } }

    // MARK: State to panel

    private func apply(_ change: (inout PeekState) -> Void) {
        change(&state)
        sync()
    }

    private func sync() {
        if state.open != shown {
            if let source = state.open, show(source) {
                shown = source
            } else {
                hide()
                // A panel that could not be placed (or has nothing) is not open.
                if state.open != nil { state.emptied(state.open!) }
            }
        }
        timer?.invalidate()
        timer = nil
        if !menuLeaving, let deadline = state.deadline {
            timer = Timer.scheduledTimer(withTimeInterval: max(0.01, deadline.timeIntervalSinceNow), repeats: false) { _ in
                MainActor.assumeIsolated { PeekController.shared.apply { $0.tick(now: Date()) } }
            }
        }
    }

    private func show(_ source: Source) -> Bool {
        guard let model, let menu = menuWindow, let rowView = rowViews[source]?.view, let rowWindow = rowView.window,
              let screen = menu.screen ?? NSScreen.main,
              let page = model.collection(source) else { return false }
        let row = rowWindow.convertToScreen(rowView.convert(rowView.bounds, to: nil))
        let entries = page.inProgress + page.notStarted
        guard !entries.isEmpty else { return false }
        let lines = min(entries.count, Self.maxLines)
        let height = CGFloat(lines) * Self.lineHeight + 2 * PeekList.inset
        let place = peekFrame(menu: Self.rect(menu.frame), row: Self.rect(row), visible: Self.rect(screen.visibleFrame),
                              width: Self.width, height: height)
        state.placed(on: place.side)
        let panel = self.panel ?? PeekPanel()
        self.panel = panel
        panel.show(PeekList(model: model, source: source))
        panel.setFrame(NSRect(x: place.frame.x, y: place.frame.y, width: place.frame.width, height: place.frame.height),
                       display: true)
        if panel.parent !== menu {
            panel.parent?.removeChildWindow(panel)
            menu.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        return true
    }

    private func hide() {
        shown = nil
        guard let panel else { return }
        // A child ordered out with its parent would come back with it: detach first.
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Drop the rows, so a press cut short (the browser came forward) leaves nothing.
        panel.clear()
    }

    private static func rect(_ r: CGRect) -> PeekRect {
        PeekRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }
}

/// Borderless, never key: the menu keeps the keyboard and stays open.
final class PeekPanel: NSPanel {
    private let host = PeekHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ list: PeekList) {
        host.rootView = AnyView(list)
        title = list.name
        setAccessibilityLabel(list.name)
    }

    func clear() {
        host.rootView = AnyView(EmptyView())
    }
}

/// Clicks count on the first press (the panel is never key), and the pointer entering
/// or leaving it is reported from a tracking area that works in a non-key window.
final class PeekHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["peek"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: ["peek": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        MainActor.assumeIsolated { PeekController.shared.panelHover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { PeekController.shared.panelHover(false) }
    }
}

/// What the panel shows: the titles, nothing above them ("To read (4)" is only its name
/// for VoiceOver). A title opens on the press. Same glass as the menu on macOS 26.
struct PeekList: View {
    let model: AppModel
    let source: Source

    static let inset: CGFloat = 6
    static let cornerRadius: CGFloat = 12

    var entries: [CollectionEntry] {
        guard let page = model.collection(source) else { return [] }
        return page.inProgress + page.notStarted
    }

    var name: String {
        source == .extensionX ? String(localized: "To read (\(entries.count))")
                              : String(localized: "To watch (\(entries.count))")
    }

    var body: some View {
        // Reading `collections` re-renders the panel after every change, like the page.
        let _ = model.collections
        let list = entries
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { entry in PeekRow(entry: entry, model: model) }
            }
        }
        .frame(height: CGFloat(min(list.count, PeekController.maxLines)) * PeekController.lineHeight)
        .padding(.vertical, Self.inset)
        .frame(width: PeekController.width, alignment: .topLeading)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            // The menu (MenuBarExtra's window) is drawn with this glass; the old
            // material looked darker beside it.
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).clipShape(shape)
        }
    }
}

/// One title: opens on mouse-down (whether the menu closes on a click in another window
/// of the app is private; opening on the press works either way).
struct PeekRow: View {
    let entry: CollectionEntry
    let model: AppModel

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Text(entry.item.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: PeekController.lineHeight, alignment: .leading)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.08 : 0)).padding(.horizontal, 4))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                guard !pressed else { return }
                pressed = true
                open()
            }.onEnded { _ in pressed = false })
            .help(entry.item.url?.absoluteString ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Open \(entry.item.title)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
    }

    private func open() {
        if let url = entry.item.url { model.open(url) }
    }
}

/// Hands the list's window to the peek controller.
struct PeekWindowReader: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.model = model
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.model = model }

    final class ReaderView: NSView {
        var model: AppModel?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let model { PeekController.shared.attach(window: window, model: model) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Behind a collection row: lets the controller read the row's frame on screen.
struct PeekRowAnchor: NSViewRepresentable {
    let source: Source

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.source = source
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { view.source = source }

    final class AnchorView: NSView {
        var source: Source?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let source, window != nil { PeekController.shared.rowView(source, self) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
