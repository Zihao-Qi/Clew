import AppKit
import ClewDomain
import Observation
import SwiftUI

/// The note box (SPEC "Notes"): from any app, a small panel under the menu bar to write a
/// thought down in seconds; then "Saved. Back to: <task>" for 3 seconds. The panel takes
/// the keyboard without bringing Clew to the front, so the app in front stays there.
@MainActor
final class NoteBox: NSObject, NSWindowDelegate {
    static let shared = NoteBox()
    weak var model: AppModel?

    let state = NoteBoxState()
    private var panel: NotePanel?
    private var banner: NSPanel?
    private var bannerTask: Task<Void, Never>?
    /// Where the draft is kept: this Mac's preferences, so it survives quitting.
    static var defaults = UserDefaults.standard
    static let draftKey = "noteDraft"
    /// One size for the box and its banner: what was typed, "Saved" and "Back to"
    /// (user, 2026-11-24: the text changed size on Return).
    static let textFont = NSFont.systemFont(ofSize: NSFont.systemFontSize + 2)

    var isOpen: Bool { panel?.isVisible == true }
    var isBannerShown: Bool { banner?.isVisible == true }
    var bannerFrame: NSRect? { banner?.frame }
    #if DEBUG
    /// For the debug check: the box's title bar is fully hidden.
    var titleBarHidden: Bool {
        guard let panel else { return false }
        return panel.titlebarSeparatorStyle == .none
            && [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .allSatisfy { panel.standardWindowButton($0)?.isHidden ?? true }
            && (panel.contentView as? NSHostingView<NoteBoxView>)?.safeAreaRegions.isEmpty == true
    }

    /// For the debug check: how far the note field and the banner's copy of the text are
    /// scrolled.
    var scrolledBy: (field: CGFloat?, banner: CGFloat?) {
        (Self.scrollView(in: panel?.contentView)?.contentView.bounds.minY,
         Self.scrollView(in: banner?.contentView)?.contentView.bounds.minY)
    }

    /// For the debug check: the copies of typed text the banner draws (one while it sweeps).
    var bannerTextViews: Int {
        func count(_ view: NSView) -> Int { (view is NSTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) } }
        return banner?.contentView.map(count) ?? 0
    }

    /// For the debug check: where the typed text is drawn, against the field showing it
    /// (in the field's coordinates). Fully inside means it is all visible.
    var textAndField: (text: NSRect, field: NSRect)? {
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NoteTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let host = panel?.contentView, let view = find(host), let scroll = view.enclosingScrollView,
              let layout = view.layoutManager, let container = view.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        return (scroll.convert(used, from: view), scroll.bounds)
    }
    #endif
    #if DEBUG
    /// The debug check types into the box directly (the app is not in front there).
    var panelForChecks: NSPanel? { panel }
    #endif
    var bannerText: String? { state.banner }

    /// The scroll view inside a window's content: the note field's, or the banner's copy.
    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let found = view as? NSScrollView { return found }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    /// The shortcut or ✎ Note: opens the box (or focuses it); a showing banner gives way.
    func open() {
        closeBanner()
        if let panel, panel.isVisible {
            panel.makeKey()
            return
        }
        state.context = model?.noteContext()
        watchQuit()
        pauseFocusForNote()
        state.text = Self.defaults.string(forKey: Self.draftKey) ?? ""
        state.focusRequest += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Exactly as tall as what it holds, from the first frame (user, 2026-11-23).
        place(panel, height: 50)
        fitNow(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Return: saves, then the banner. Nothing but spaces and line breaks does nothing.
    func save() {
        guard QuickNote.cleaned(state.text) != nil, let model else { return }
        guard model.addNote(state.text, during: state.context) else { return }
        Self.defaults.removeObject(forKey: Self.draftKey)
        // The banner takes the box's place and size: it is the same box, saved.
        state.savedText = state.text
        // Scrolled as the field was (past four lines): nothing moves on Return (review).
        state.savedScroll = Self.scrollView(in: panel?.contentView)?.contentView.bounds.minY ?? 0
        if let panel { fitNow(panel) }   // the size it has now, not one a moment old (review)
        let frame = panel?.frame
        state.text = ""
        closePanel()
        showBanner(at: frame)
    }

    /// Esc, or a click elsewhere: the box closes and what was typed stays as the draft.
    func close() {
        keepDraft()
        closePanel()
    }

    private func keepDraft() {
        if QuickNote.cleaned(state.text) == nil {
            Self.defaults.removeObject(forKey: Self.draftKey)
        } else {
            Self.defaults.set(state.text, forKey: Self.draftKey)
        }
    }

    private func closePanel() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.delegate = self
        resumeFocusAfterNote()
    }

    // MARK: The focus stops while a note is written (SPEC "Notes", 2026-11-24, user)

    /// The focus this box paused: started again when the box closes (saved or not).
    private var pausedFocus: (item: UUID, started: Date)?
    private var quitObserver: NSObjectProtocol?

    /// Quitting with the box open keeps the draft and starts the focus again (review:
    /// it stayed paused; the panel's resign-key comes too late then).
    private func watchQuit() {
        guard quitObserver == nil else { return }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                self.keepDraft()
                self.resumeFocusAfterNote()
            }
        }
    }

    /// A running focus (not a break, not one already paused, its time not up) stops.
    private func pauseFocusForNote() {
        guard pausedFocus == nil, let model, let timer = model.focus, timer.phase == .focus,
              !timer.isPaused, !timer.isOver(at: Date()) else { return }
        model.pauseFocus()
        if model.focus?.isPaused == true { pausedFocus = (timer.itemId, timer.startedAt) }
    }

    /// Only the focus this box stopped starts again, and only if it is still paused.
    private func resumeFocusAfterNote() {
        guard let paused = pausedFocus else { return }
        pausedFocus = nil
        guard let model, let timer = model.focus, timer.itemId == paused.item, timer.startedAt == paused.started,
              timer.isPaused else { return }
        model.resumeFocus()
    }

    // MARK: The banner

    private func showBanner(at frame: NSRect?) {
        let text: String
        if let context = state.context {
            text = String(localized: "Saved. Back to: \(context.title)\(context.detail)")
        } else {
            text = String(localized: "Saved.")
        }
        state.banner = text
        // From the start: never a frame of the last banner's "Saved" (review).
        state.sweep = 0
        state.settled = false
        state.bannerShown += 1
        let banner = self.banner ?? makeBanner()
        self.banner = banner
        if let frame {
            // Exactly the box's frame: the same box, saved (user, 2026-11-23: it was narrower).
            banner.setFrame(frame, display: false)
        } else {
            place(banner, height: 64)
        }
        // A fade still running from the last banner stops here (review).
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            banner.animator().alphaValue = 1
        }
        banner.orderFrontRegardless()
        NSAccessibility.post(element: banner, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            // The sweep (about half a second), then 1.5 seconds of "Saved" (user,
            // 2026-11-23: 3 seconds was too long).
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.banner?.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }   // a newer banner keeps showing
            self?.closeBanner()
        }
    }

    func closeBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        banner?.orderOut(nil)
        state.banner = nil
    }

    // MARK: Windows

    private func makePanel() -> NotePanel {
        // Titled: a borderless panel never takes the keyboard while Clew is not in front.
        // Its title bar is hidden: no separator line, no buttons (user, 2026-11-23: a line
        // showed above the box), and the content draws from the very top.
        let panel = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 90),
                              styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered,
                              defer: true)
        configure(panel)
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let host = NSHostingView(rootView: NoteBoxView(box: self, state: state))
        host.safeAreaRegions = []
        panel.contentView = host
        panel.delegate = self
        return panel
    }

    private func makeBanner() -> NSPanel {
        let panel = BannerPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 64),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        configure(panel)
        panel.contentView = FirstClickHostingView(rootView: NoteBannerView(state: state) { [weak self] in self?.closeBanner() })
        return panel
    }

    private func configure(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
    }

    /// A quarter of the way down the screen the pointer is on, centred (user, 2026-11-23:
    /// right under the menu bar it sat too high).
    private func place(_ panel: NSPanel, height: CGFloat) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: 440, height: height)
        let top = visible.maxY - visible.height / 4
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height,
                              width: size.width, height: size.height), display: false)
    }

    /// The box is exactly as tall as its content, keeping its top where it is: no gap
    /// between the panel and what it draws (user, 2026-11-23: a line showed above it).
    /// The editor measured new text: the open box fits it (never a closed one, review).
    func fitToContent() {
        guard let panel, panel.isVisible else { return }
        fitNow(panel)
    }

    private func fitNow(_ panel: NSPanel) {
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        if height > 0 { resize(panel, to: height) }
    }

    private func resize(_ panel: NSPanel, to height: CGFloat) {
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }

    // A click elsewhere: the box closes and keeps the draft.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NotePanel) === panel, panel?.isVisible == true else { return }
        close()
    }
}

/// Knows whether ⇧ was held for the key being handled, however the key arrived.
final class NoteTextView: NSTextView {
    private(set) var shiftHeld = false
    override func keyDown(with event: NSEvent) {
        shiftHeld = event.modifierFlags.contains(.shift)
        defer { shiftHeld = false }
        super.keyDown(with: event)
    }
}

/// The banner never takes the keyboard (review).
final class BannerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on the banner counts at once, though Clew is not in front (as the peek's).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Takes the keyboard although Clew is not in front.
final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class NoteBoxState {
    var text = ""
    var context: NoteContext?
    var banner: String?
    /// What was just saved: the sweep passes over it before "Saved" shows.
    var savedText = ""
    /// How far the field was scrolled when it was saved.
    var savedScroll: CGFloat = 0
    /// The banner's sweep (0 to 1) and whether it has settled into the bar.
    var sweep: CGFloat = 0
    var settled = false
    /// Bumped each time the banner shows, so its animation runs again.
    var bannerShown = 0
    /// Bumped each time the box opens, so the field takes the keyboard again.
    var focusRequest = 0
}

/// "During: Write the intro", under the note: in the box and in the banner's sweep.
struct NoteDuringLine: View {
    let title: String
    var body: some View {
        (Text("During: ") + Text(verbatim: title))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct NoteBoxView: View {
    let box: NoteBox
    let state: NoteBoxState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoteEditorField(text: Binding(get: { state.text }, set: { state.text = $0 }),
                            placeholder: String(localized: "A thought to keep…"),
                            focusRequest: state.focusRequest, maxLines: 4,
                            onSubmit: { box.save() }, onCancel: { box.close() },
                            onHeight: { _ in box.fitToContent() })
                .debugFrame("noteText")
                .accessibilityLabel(Text("Note"))
            if let context = state.context {
                // What it is written during (SPEC "Notes", 2026-11-23).
                NoteDuringLine(title: context.title)
                    .debugFrame("noteDuring")
            }
        }
        .padding(14)
        .frame(width: 440, alignment: .topLeading)
        .menuGlass(cornerRadius: 12)
        .debugFrame("noteBox")
    }
}

/// The box, saved (SPEC "Notes", 2026-11-23): an accent band sweeps across what was
/// typed, settles as the bar the timeline gives the block running now, and the text
/// becomes "✓ Saved / Back to: <task>". A click closes it.
struct NoteBannerView: View {
    let state: NoteBoxState
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var sweep: CGFloat { state.sweep }
    private var settled: Bool { state.settled }
    #if DEBUG
    /// The debug render shows the settled banner (an image cannot wait for the sweep).
    static var startSettled = false
    /// The debug check sweeps even on a Mac with Reduce Motion on (as CI's may be).
    static var sweepAlways = false
    #endif

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // The band sweeps left to right and fades where it is; the thin bar on the
                // left edge fades in. Nothing goes back (user, 2026-11-24: it felt like a
                // failed save).
                Rectangle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: geo.size.width * sweep)
                    .opacity(settled ? 0 : 1)
                    .debugFrame("band\(state.bannerShown)")
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .opacity(settled ? 1 : 0)
                Group {
                    if settled {
                        saved
                    } else {
                        // Just as it was typed, During and all: the same size and place.
                        VStack(alignment: .leading, spacing: 6) {
                            NoteTextShown(text: state.savedText, scrolledBy: state.savedScroll, maxLines: 4)
                                .debugFrame("sweptText\(state.bannerShown)")   // one per banner, for the debug check
                                .id(state.bannerShown)   // new for each banner (review: a reused one lost its scroll; not reproduced here)
                            if let context = state.context {
                                NoteDuringLine(title: context.title)
                                    .debugFrame("sweptDuring\(state.bannerShown)")
                            }
                        }
                        .padding(14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: settled ? .leading : .topLeading)
            }
        }
        .frame(width: 440)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))   // the bar keeps to the corners
        .menuGlass(cornerRadius: 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .task(id: state.bannerShown) { await play() }
        // What it says, from the first frame (review: the swept text has no label).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: state.banner ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Closes"))
        .accessibilityAction(.default, dismiss)
        .debugFrame("noteBanner")
    }

    private var saved: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved")   // not bold (user, 2026-11-24)
                    .debugFrame("savedTitle")
                if let context = state.context {
                    (Text("Back to: ") + Text(verbatim: context.title).bold() + Text(verbatim: context.detail))
                        .foregroundStyle(.secondary)
                        .debugFrame("backTo")
                        .lineLimit(2)
                }
            }
        }
        .font(Font(NoteBox.textFont))
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private func play() async {
        let shown = state.bannerShown
        var still = reduceMotion
        #if DEBUG
        still = (still && !Self.sweepAlways) || Self.startSettled
        #endif
        guard !still else {
            state.settled = true
            return
        }
        withAnimation(.easeInOut(duration: 0.45)) { state.sweep = 1 }
        try? await Task.sleep(for: .milliseconds(470))
        // A newer save restarted it: that one settles in its own time; a closed banner
        // never settles behind the next note (review).
        guard !Task.isCancelled, state.bannerShown == shown, state.banner != nil else { return }
        withAnimation(.easeOut(duration: 0.25)) { state.settled = true }
    }
}

extension View {
    /// The menu's own glass on macOS 26 (as the peek), the regular material before.
    @ViewBuilder
    func menuGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape).clipShape(shape)
        }
    }
}

/// What was typed, drawn just as the note field draws it (same text view, font and line
/// height), at most `maxLines` lines: on Return nothing moves or changes size.
struct NoteTextShown: NSViewRepresentable {
    let text: String
    var scrolledBy: CGFloat = 0
    var maxLines = 4

    func makeNSView(context: Context) -> NSScrollView {
        let start = NSRect(x: 0, y: 0, width: 412, height: 22)
        let scroll = NSScrollView(frame: start)
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = false
        let view = NSTextView(frame: start)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.font = NoteBox.textFont
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityElement(false)
        scroll.setAccessibilityElement(false)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        settle(scroll)
    }

    /// Laid out at its width and scrolled as the field was, before it is drawn.
    private func settle(_ scroll: NSScrollView) {
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager,
              let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        view.sizeToFit()
        let most = max(0, view.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, scrolledBy), most)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 412
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager,
              let container = view.textContainer else { return nil }
        if abs(view.frame.width - width) > 0.5 { view.setFrameSize(NSSize(width: width, height: view.frame.height)) }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: NoteBox.textFont)
        let used = max(line, layout.usedRect(for: container).height)
        let height = max(min(used, line * CGFloat(maxLines)).rounded(.up), 22)   // as the field: at least 22
        scroll.setFrameSize(NSSize(width: width, height: height))
        settle(scroll)
        return CGSize(width: width, height: height)
    }
}

/// A plain text editor for notes: Return submits, ⇧Return starts a new line at the cursor,
/// Esc cancels; at most 1,000 characters; grows to `maxLines` lines, then scrolls.
struct NoteEditorField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var focusRequest = 0
    var maxLines = 4
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var onHeight: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let start = NSRect(x: 0, y: 0, width: 412, height: 22)
        let scroll = NSScrollView(frame: start)
        scroll.drawsBackground = false
        // No room left for the box's hidden title bar: the text starts at the top
        // (user, 2026-11-23: it sat at the bottom, almost hidden).
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        let view = NoteTextView(frame: start)
        view.minSize = NSSize(width: 0, height: 22)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        view.delegate = context.coordinator
        view.font = NoteBox.textFont
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.string = text
        context.coordinator.placeholder(in: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text; view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)) }
        context.coordinator.updatePlaceholder(view)
        if context.coordinator.focused != focusRequest {
            context.coordinator.focused = focusRequest
            context.coordinator.height = -1   // measure again: the box opens at its text's height
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
        }
        context.coordinator.measure(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // Wrapped at the width it is given (the Notes page is narrower than the box).
        if let width = proposal.width, width.isFinite, width > 0, let view = nsView.documentView as? NSTextView,
           abs(view.frame.width - width) > 0.5 {
            nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height))
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            context.coordinator.height = -1
            context.coordinator.measure(view)
        }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 412
        return CGSize(width: width, height: max(context.coordinator.height, 22))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditorField
        var focused = -1
        var height: CGFloat = 22
        private var hint: NSTextField?

        init(_ parent: NoteEditorField) { self.parent = parent }

        func placeholder(in view: NSTextView) {
            let label = NSTextField(labelWithString: parent.placeholder)
            label.font = view.font
            label.textColor = .placeholderTextColor
            label.frame.origin = .zero
            label.sizeToFit()
            view.addSubview(label)
            hint = label
            updatePlaceholder(view)
        }

        func updatePlaceholder(_ view: NSTextView) { hint?.isHidden = !view.string.isEmpty }

        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: view.font ?? .systemFont(ofSize: 15))
            let used = max(line, layout.usedRect(for: container).height)
            let next = min(used, line * CGFloat(parent.maxLines)).rounded(.up)
            guard abs(next - height) > 0.5 else { return }
            height = next
            DispatchQueue.main.async { [parent] in parent.onHeight(next) }
            view.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            updatePlaceholder(view)
            measure(view)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text else { return true }
            let length = (textView.string as NSString).length - range.length + (text as NSString).length
            return length <= QuickNote.maxLength
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if (textView as? NoteTextView)?.shiftHeld == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
