import AppKit
import Carbon.HIToolbox
import ClewCore
import Foundation
import Observation
import os

/// Registers a global shortcut: the one that opens today's list, and the one that writes
/// a note (SPEC "Notes"). Carbon hotkeys work in the sandbox and need no Accessibility
/// permission (SPEC Tech; decided 2026-11-11). One Carbon handler serves both, by id.
@Observable @MainActor
final class OpenShortcutHotkey {
    static let shared = OpenShortcutHotkey(id: 1) {
        MenuBarExtraToggle.log.notice("open shortcut pressed")
        MenuBarExtraToggle.toggle()
    }
    static let note = OpenShortcutHotkey(id: 2) { NoteBox.shared.open() }
    static var all: [OpenShortcutHotkey] { [shared, note] }

    @ObservationIgnored private let hotKeyID: EventHotKeyID
    @ObservationIgnored private let action: @MainActor () -> Void
    @ObservationIgnored private var started = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var current: OpenShortcut?
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private static var handlerRef: EventHandlerRef?
    /// Set when Carbon refuses the shortcut (often because another app owns it).
    private(set) var registrationError: String?
    private static let signature: OSType = 0x434C4557 // 'CLEW'

    /// Stored as a static C function pointer so InstallEventHandler keeps a valid
    /// thunk for the process lifetime (an inline closure is not guaranteed to last).
    private static let eventHandler: EventHandlerUPP = { _, event, _ in
        var pressed = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr, pressed.signature == signature else { return OSStatus(eventNotHandledErr) }
        let id = pressed.id
        DispatchQueue.main.async { MainActor.assumeIsolated { fire(id) } }
        return noErr
    }

    private static func fire(_ id: UInt32) {
        all.first { $0.hotKeyID.id == id }?.action()
    }

    private init(id: UInt32, action: @escaping @MainActor () -> Void) {
        hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        self.action = action
    }

    func start() {
        started = true
        if !suspended { register(current) }
    }

    /// Apply the shortcut from Settings. `nil` means none is registered.
    /// Re-registers only when the shortcut actually changes, so a normal
    /// refresh after a tick does not drop the hotkey for a moment.
    func apply(_ shortcut: OpenShortcut?) {
        let changed = shortcut != current
        current = shortcut
        guard started, !suspended else {
            unregister()
            return
        }
        if changed || hotKeyRef == nil {
            register(shortcut)
        }
    }

    /// While the Settings field is recording, let the key go to the recorder instead.
    func suspend() {
        suspended = true
        unregister()
    }

    func resume() {
        suspended = false
        if started { register(current) }
    }

    private func installHandlerIfNeeded() {
        guard Self.handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &spec,
            nil,
            &Self.handlerRef
        )
        if status != noErr {
            Self.handlerRef = nil
            registrationError = Self.couldNotRegister
        }
    }

    private func register(_ shortcut: OpenShortcut?) {
        unregister()
        guard let shortcut, shortcut.isAllowed else {
            registrationError = nil
            return
        }
        installHandlerIfNeeded()
        guard Self.handlerRef != nil else { return }
        var ref: EventHotKeyRef?
        let modifiers = carbonModifiers(shortcut)
        let ident = hotKeyID
        let status = RegisterEventHotKey(shortcut.keyCode, modifiers, ident, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registrationError = nil
        } else {
            registrationError = Self.couldNotRegister
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func carbonModifiers(_ shortcut: OpenShortcut) -> UInt32 {
        var value: UInt32 = 0
        if shortcut.command { value |= UInt32(cmdKey) }
        if shortcut.shift { value |= UInt32(shiftKey) }
        if shortcut.option { value |= UInt32(optionKey) }
        if shortcut.control { value |= UInt32(controlKey) }
        return value
    }

    static let couldNotRegister = String(localized: "Clew couldn't register this shortcut. Another app may already be using it.")
}

/// Opens or closes the menu bar list through Clew's own status item, in-process (no
/// Accessibility permission); SwiftUI has no public API to present a `MenuBarExtra` window.
///
/// macOS 14–26: clicking the item's button. macOS 27 (user, 2026-11-20; found on the
/// macOS 27 Mac): the button has no target or action, and a click goes through the item's
/// "expanded interface session" (`NSStatusItem.expandedInterfaceDelegate`, which SwiftUI
/// sets). There the list is closed with the public `expandedInterfaceSession.cancel()`,
/// and opened with the item's private `_requestExpandedInterfaceSession` (checked first;
/// nothing public opens it).
enum MenuBarExtraToggle {
    /// What the shortcut did: `/usr/bin/log show --predicate 'subsystem == "io.github.zihao-qi.clew"'`.
    static let log = Logger(subsystem: "io.github.zihao-qi.clew", category: "menu-bar")

    @MainActor
    static func toggle() {
        NSApp.activate()
        // Activation is not always finished in this turn; act on the next one.
        DispatchQueue.main.async {
            generation += 1
            guard let item = statusItem(), usesSession(item) else {
                clickButton()
                return
            }
            if cancelSession(item) {
                log.notice("list closed (session)")
            } else {
                openSession(item, retry: true, generation: generation)
            }
        }
    }

    /// Closes the open menu now, from inside it (SPEC 2026-11-13: opening Settings closes
    /// the menu). Synchronous, while the menu is surely open: `NSWindow.close()` hides it
    /// but SwiftUI still counts it open (the next click on the menu bar then does
    /// nothing), and a deferred click could reopen a menu that closed by itself in between.
    @MainActor
    static func closeMenu() {
        generation += 1
        if let item = statusItem(), usesSession(item) {
            if cancelSession(item) { log.notice("list closed from inside (session)") }
            return
        }
        clickButton()
    }

    // MARK: macOS 27: the expanded interface session

    // The macOS 27 names are called by selector, checked first: CI's SDK may be older
    // than 27, where they would not compile (they are public from the macOS 27 SDK on).
    private static let delegateSelector = Selector(("expandedInterfaceDelegate"))
    private static let sessionSelector = Selector(("expandedInterfaceSession"))
    private static let cancelSelector = Selector(("cancel"))

    /// The item's expanded interface goes through a delegate (macOS 27 and later, when
    /// SwiftUI set one).
    @MainActor
    static func usesSession(_ item: NSStatusItem) -> Bool {
        item.responds(to: delegateSelector) && item.perform(delegateSelector)?.takeUnretainedValue() != nil
    }

    /// The open session, if any.
    @MainActor
    private static func session(_ item: NSStatusItem) -> NSObject? {
        guard item.responds(to: sessionSelector) else { return nil }
        return item.perform(sessionSelector)?.takeUnretainedValue() as? NSObject
    }

    /// Ends the open session (the list closes). False if none is open.
    @MainActor
    private static func cancelSession(_ item: NSStatusItem) -> Bool {
        guard let session = session(item), session.responds(to: cancelSelector) else { return false }
        _ = session.perform(cancelSelector)
        return true
    }

    private static let requestSession = Selector(("_requestExpandedInterfaceSession"))

    /// Each toggle and close: a request's later check gives up once another came (review:
    /// it must never reopen a list closed in between).
    @MainActor private static var generation = 0

    /// Asks the item to begin a session (the list opens). Soon after launch a request is
    /// sometimes ignored (found on macOS 27), so it is asked once more if none began
    /// within 0.3 s.
    @MainActor
    private static func openSession(_ item: NSStatusItem, retry: Bool, generation asked: Int) {
        guard item.responds(to: requestSession) else {
            log.error("list not opened: the status item cannot request a session on this macOS")
            return
        }
        _ = item.perform(requestSession)
        watch(item, retry: retry, generation: asked, checksLeft: 6)
    }

    /// Looks for the session at once, then every 50 ms: once seen, the list opened, so
    /// a later close (Esc, a click away) is never mistaken for an ignored request.
    @MainActor
    private static func watch(_ item: NSStatusItem, retry: Bool, generation asked: Int, checksLeft: Int) {
        if session(item) != nil {
            log.notice("list opened (session)")
            return
        }
        guard asked == generation else { return }      // another press or close came since
        if checksLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                watch(item, retry: retry, generation: asked, checksLeft: checksLeft - 1)
            }
        } else if retry {
            log.notice("session request ignored; asking once more")
            openSession(item, retry: false, generation: asked)
        } else {
            log.error("list not opened: the session request was ignored twice")
        }
    }

    // MARK: macOS 14–26: the button

    @MainActor
    private static func clickButton() {
        guard let button = statusItemButton() else {
            log.error("list not opened: no menu bar button found")
            return
        }
        button.performClick(nil)
        log.notice("menu bar button clicked")
    }

    private static let statusItemOfButton = Selector(("_statusItem"))

    /// Clew's status item, from its button (private `_statusItem`, checked first).
    @MainActor
    static func statusItem() -> NSStatusItem? {
        guard let button = statusItemButton(), button.responds(to: statusItemOfButton) else { return nil }
        return button.perform(statusItemOfButton)?.takeUnretainedValue() as? NSStatusItem
    }

    @MainActor
    private static func statusItemButton() -> NSStatusBarButton? {
        // Search only this process's public views. Missing/changed SwiftUI view
        // structure returns nil rather than risking an Objective-C KVC exception.
        for window in NSApp.windows {
            if let button = statusBarButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    @MainActor
    private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let button = statusBarButton(in: sub) { return button }
        }
        return nil
    }
}
