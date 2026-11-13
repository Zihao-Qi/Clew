import AppKit
import ClewCore
import SwiftUI

/// The double-click's name box on the timeline (SPEC 2026-11-13): where it is. A new
/// `id` for every box, so a box opened elsewhere starts empty.
struct NewTaskDraft: Equatable {
    let id = UUID()
    let start: Date
    let minutes: Int

    var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }

    /// A 30-minute block at the quarter hour `minutesIn` after the day's start, cut at
    /// the day's end, as the block Core will make.
    init(minutesIn: Double, day: TimelineDay) {
        start = Clew.quarterStart(minutesIn: minutesIn, day: day)
        minutes = min(Clew.blockDefaultMinutes, TimelineMetrics.room(after: start, in: day))
    }
}

/// A small name field shaped like the block it will make. Return saves; Esc, an empty
/// name, a click anywhere else and the menu closing drop it.
struct NewTaskBox: View {
    let model: AppModel
    let draft: NewTaskDraft
    let close: () -> Void

    @State private var text = ""
    /// The title fetched for a pasted link: recorded as fetched only if left as it is.
    @State private var fetchedTitle: String?
    @State private var fetchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    TextField(text: $text) { Text("Name or link") }
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .focused($focused)
                        // Return and Esc while an input method is composing belong to it:
                        // onSubmit and onExitCommand only see them once it has finished.
                        .onSubmit(save)
                        .onExitCommand(perform: cancel)
                        .accessibilityLabel(Text("New task at \(TimelineMetrics.time(draft.start))"))
                    if fetchTask != nil {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(Text("Fetching the title"))
                    }
                }
                .padding(.horizontal, 5)
                .padding(.top, 2)
            }
            .frame(height: max(CGFloat(draft.minutes) * TimelineMetrics.pointsPerMinute - 1, 18))
            .background(OutsideClickWatcher(onOutside: cancel))
            .onChange(of: text) { textChanged() }
            // On the next turn: a box opened by a double-click elsewhere appears while the
            // old box's field still has the keyboard, and would lose it to the window.
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onDisappear { fetchTask?.cancel() }
    }

    private func textChanged() {
        // A pasted link gets its page title, as in `+ add`.
        let parsed = QuickEntry.parse(text)
        guard parsed.isBareLink, let url = parsed.url else { return }
        let typed = text
        fetchTask?.cancel()
        fetchTask = Task {
            let title = await model.fetchTitle(for: url)
            guard !Task.isCancelled else { return }
            fetchTask = nil
            if let title, text == typed {
                fetchedTitle = title
                text = "\(title) \(url.absoluteString)"
            }
        }
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return cancel() }
        fetchTask?.cancel()
        fetchTask = nil
        // Refused (a name too long): the box stays with its text, and the notice says why.
        if model.addOnTimeline(text, fetchedTitle: fetchedTitle, at: draft.start) { close() }
    }

    private func cancel() {
        fetchTask?.cancel()
        close()
    }
}

/// Calls `onOutside` for a mouse-down anywhere but on this view (in the menu or another
/// window), and when the menu stops being key or closes. The click itself still goes
/// where it was going: the callback runs after it.
struct OutsideClickWatcher: NSViewRepresentable {
    let onOutside: () -> Void

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.onOutside = onOutside
        return view
    }

    func updateNSView(_ view: WatchView, context: Context) {
        view.onOutside = onOutside
    }

    static func dismantleNSView(_ view: WatchView, coordinator: ()) {
        view.stop()
    }

    final class WatchView: NSView {
        var onOutside: (() -> Void)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let mine = self.window else { return }
                    let inside = event.window === mine
                        && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    if !inside { self.fire() }
                }
                return event
            }
            // The menu closing (or another app taking the keyboard) drops the box.
            observers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.fire() }
                }
            }
        }

        /// After the current event, so a click that closes the box still does its own job.
        private func fire() {
            DispatchQueue.main.async { [weak self] in self?.onOutside?() }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach(NotificationCenter.default.removeObserver)
            monitor = nil
            observers = []
        }
    }
}
