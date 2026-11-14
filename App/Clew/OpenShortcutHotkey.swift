import AppKit
import Carbon.HIToolbox
import ClewCore
import Foundation
import Observation

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

/// Opens or closes the menu bar list by clicking Clew's own status item. That is
/// in-process and needs no Accessibility permission; SwiftUI has no public API to
/// present a `MenuBarExtra` window.
enum MenuBarExtraToggle {
    @MainActor
    static func toggle() {
        NSApp.activate()
        // Activation is not always finished in this turn; click on the next one.
        DispatchQueue.main.async {
            clickStatusItem()
        }
    }

    /// Closes the open menu now, from inside it (SPEC 2026-11-13: opening Settings closes
    /// the menu). A synchronous click on the status item, while the menu is surely open:
    /// `NSWindow.close()` hides it but SwiftUI still counts it open (the next click on
    /// the menu bar then does nothing), and a deferred click could reopen a menu that
    /// closed by itself in between.
    @MainActor
    static func closeMenu() {
        clickStatusItem()
    }

    @MainActor
    private static func clickStatusItem() {
        guard let button = statusItemButton() else { return }
        button.performClick(nil)
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
