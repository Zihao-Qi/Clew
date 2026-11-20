import AppKit
import Carbon.HIToolbox
import ClewCore
import Foundation
import Observation
import os

/// Registers the global shortcut that opens today's list. Carbon hotkeys work in the
/// sandbox and need no Accessibility permission (SPEC Tech; decided 2026-11-11).
@Observable @MainActor
final class OpenShortcutHotkey {
    static let shared = OpenShortcutHotkey()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var current: OpenShortcut?
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    /// Set when Carbon refuses the shortcut (often because another app owns it).
    private(set) var registrationError: String?
    private static let signature: OSType = 0x434C4557 // 'CLEW'
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    /// Stored as a static C function pointer so InstallEventHandler keeps a valid
    /// thunk for the process lifetime (an inline closure is not guaranteed to last).
    private static let eventHandler: EventHandlerUPP = { _, _, _ in
        MenuBarExtraToggle.log.notice("open shortcut pressed")
        DispatchQueue.main.async { MenuBarExtraToggle.toggle() }
        return noErr
    }

    private init() {}

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
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &spec,
            nil,
            &handlerRef
        )
        if status != noErr {
            handlerRef = nil
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
        guard handlerRef != nil else { return }
        var ref: EventHotKeyRef?
        let modifiers = carbonModifiers(shortcut)
        let ident = Self.hotKeyID
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
            guard let item = statusItem(), usesSession(item) else {
                clickButton()
                return
            }
            if cancelSession(item) {
                log.notice("list closed (session)")
            } else {
                openSession(item, retry: true)
            }
        }
    }

    /// Closes the open menu now, from inside it (SPEC 2026-11-13: opening Settings closes
    /// the menu). Synchronous, while the menu is surely open: `NSWindow.close()` hides it
    /// but SwiftUI still counts it open (the next click on the menu bar then does
    /// nothing), and a deferred click could reopen a menu that closed by itself in between.
    @MainActor
    static func closeMenu() {
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

    /// Asks the item to begin a session (the list opens). Soon after launch a request is
    /// sometimes ignored (found on macOS 27), so it is asked once more if none began.
    @MainActor
    private static func openSession(_ item: NSStatusItem, retry: Bool) {
        guard item.responds(to: requestSession) else {
            log.error("list not opened: the status item cannot request a session on this macOS")
            return
        }
        _ = item.perform(requestSession)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if session(item) != nil {
                log.notice("list opened (session)")
            } else if retry {
                log.notice("session request ignored; asking once more")
                openSession(item, retry: false)
            } else {
                log.error("list not opened: the session request was ignored twice")
            }
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
