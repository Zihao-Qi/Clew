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

    var isOpen: Bool { panel?.isVisible == true }
    var isBannerShown: Bool { banner?.isVisible == true }
    #if DEBUG
    /// The debug check types into the box directly (the app is not in front there).
    var panelForChecks: NSPanel? { panel }
    #endif
    var bannerText: String? { state.banner }

    /// The shortcut or ✎ Note: opens the box (or focuses it); a showing banner gives way.
    func open() {
        closeBanner()
        if let panel, panel.isVisible {
            panel.makeKey()
            return
        }
        state.context = model?.noteContext()
        state.text = Self.defaults.string(forKey: Self.draftKey) ?? ""
        state.focusRequest += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // One line to start; the editor measures its text and sets the height (review).
        place(panel, height: 50)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Return: saves, then the banner. Nothing but spaces and line breaks does nothing.
    func save() {
        guard QuickNote.cleaned(state.text) != nil, let model else { return }
        guard model.addNote(state.text, during: state.context) else { return }
        Self.defaults.removeObject(forKey: Self.draftKey)
        state.text = ""
        closePanel()
        showBanner()
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
    }

    // MARK: The banner

    private func showBanner() {
        let text: String
        if let context = state.context {
            text = String(localized: "Saved. Back to: \(context.title)\(context.detail)")
        } else {
            text = String(localized: "Saved.")
        }
        state.banner = text
        let banner = self.banner ?? makeBanner()
        self.banner = banner
        place(banner, height: 64)
        banner.alphaValue = 1
        banner.orderFrontRegardless()
        NSAccessibility.post(element: banner, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
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
        let panel = NotePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 90),
                              styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered,
                              defer: true)
        configure(panel)
        panel.contentView = NSHostingView(rootView: NoteBoxView(box: self, state: state))
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

    /// Centred under the menu bar of the screen the pointer is on.
    private func place(_ panel: NSPanel, height: CGFloat) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: 440, height: height)
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8,
                              width: size.width, height: size.height), display: false)
    }

    /// The box grows with its text, keeping its top where it is.
    func resize(to height: CGFloat) {
        guard let panel else { return }
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
    /// Bumped each time the box opens, so the field takes the keyboard again.
    var focusRequest = 0
}

struct NoteBoxView: View {
    let box: NoteBox
    let state: NoteBoxState

    var body: some View {
        NoteEditorField(text: Binding(get: { state.text }, set: { state.text = $0 }),
                        placeholder: String(localized: "A thought to keep…"),
                        focusRequest: state.focusRequest, maxLines: 4,
                        onSubmit: { box.save() }, onCancel: { box.close() },
                        onHeight: { box.resize(to: $0 + 28) })
            .accessibilityLabel(Text("Note"))
            .padding(14)
            .frame(width: 440, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .debugFrame("noteBox")
    }
}

/// "Saved. Back to: Write the intro": larger, tinted with the accent colour, easy to
/// notice (user, 2026-11-22). A click closes it.
struct NoteBannerView: View {
    let state: NoteBoxState
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Group {
                if let context = state.context {
                    (Text("Saved. Back to: ") + Text(verbatim: context.title).bold() + Text(verbatim: context.detail))
                } else {
                    Text("Saved.")
                }
            }
            .font(.title3)
            .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 440, height: 64)
        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Closes"))
        .debugFrame("noteBanner")
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
        view.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
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
