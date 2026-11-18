import AppKit
import SwiftUI

/// The long list's scroll view, so a drag near its edge can scroll it (user, 2026-11-18).
/// SwiftUI's ScrollView on macOS is an NSScrollView underneath; `ScrollViewFinder`, put
/// inside its content, hands it over.
@MainActor final class ListScroller {
    weak var scrollView: NSScrollView?

    /// How far the list is scrolled down, in points (0 at the top).
    var offset: CGFloat {
        get { scrollView?.contentView.bounds.origin.y ?? 0 }
        set {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newValue))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// The furthest it can scroll.
    var maxOffset: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        return document.frame.height - scrollView.contentView.bounds.height
    }
}

/// Finds the NSScrollView around it and gives it to `scroller`.
struct ScrollViewFinder: NSViewRepresentable {
    let scroller: ListScroller

    func makeNSView(context: Context) -> NSView { FinderView(scroller: scroller) }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? FinderView)?.scroller = scroller
        if let found = view.enclosingScrollView { scroller.scrollView = found }
    }

    final class FinderView: NSView {
        var scroller: ListScroller
        init(scroller: ListScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let found = enclosingScrollView { scroller.scrollView = found }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
