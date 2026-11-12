import AppKit
import Carbon.HIToolbox
import ClewCore
import Foundation
import os

/// Registers the global shortcut that opens today's list. Carbon hotkeys work in the
/// sandbox and need no Accessibility permission (SPEC Tech; decided 2026-11-11).
@MainActor
final class OpenShortcutHotkey {
    static let shared = OpenShortcutHotkey()

    private var started = false
    private var suspended = false
    private var current: OpenShortcut?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Set when Carbon refuses the shortcut (often because another app owns it).
    private(set) var registrationError: String?
    private static let signature: OSType = 0x434C4557 // 'CLEW'
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)
    private static let log = Logger(subsystem: "io.github.zihao-qi.clew", category: "OpenShortcut")

    /// Stored as a static C function pointer so InstallEventHandler keeps a valid
    /// thunk for the process lifetime (an inline closure is not guaranteed to last).
    private static let eventHandler: EventHandlerUPP = { _, _, _ in
        DispatchQueue.main.async { MenuBarExtraToggle.toggle() }
        return noErr
    }

    private init() {}

    func start() {
        started = true
        installHandlerIfNeeded()
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
            Self.trace("InstallEventHandler failed: \(status)")
        } else {
            Self.trace("InstallEventHandler ok")
        }
    }

    private func register(_ shortcut: OpenShortcut?) {
        unregister()
        guard let shortcut, shortcut.isAllowed else {
            registrationError = nil
            Self.trace("register skipped shortcut=\(shortcut?.display ?? "nil") allowed=\(shortcut?.isAllowed == true)")
            return
        }
        var ref: EventHotKeyRef?
        let modifiers = carbonModifiers(shortcut)
        let ident = Self.hotKeyID
        let status = RegisterEventHotKey(shortcut.keyCode, modifiers, ident, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            registrationError = nil
            Self.trace("RegisterEventHotKey ok \(shortcut.display) keyCode=\(shortcut.keyCode) modifiers=\(modifiers)")
        } else {
            registrationError = Self.couldNotRegister
            Self.trace("RegisterEventHotKey failed: \(status) \(shortcut.display) keyCode=\(shortcut.keyCode) modifiers=\(modifiers)")
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

    static func trace(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }

}

/// Opens or closes the menu bar list by clicking Clew's own status item. That is
/// in-process and needs no Accessibility permission; SwiftUI has no public API to
/// present a `MenuBarExtra` window.
enum MenuBarExtraToggle {
    @MainActor
    static func toggle() {
        OpenShortcutHotkey.trace("hotkey pressed")
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Activation is not always finished in this turn; click on the next one.
        DispatchQueue.main.async {
            clickStatusItem()
        }
    }

    @MainActor
    private static func clickStatusItem() {
        guard let button = statusItemButton() else {
            let names = NSApp.windows.map(\.className).joined(separator: ",")
            OpenShortcutHotkey.trace("toggle: no status item button; windows=[\(names)]")
            return
        }
        OpenShortcutHotkey.trace("toggle: performClick title=\(button.title)")
        button.performClick(nil)
    }

    @MainActor
    private static func statusItemButton() -> NSStatusBarButton? {
        let bar = NSStatusBar.system
        // `items` is not public; it is an NSPointerArray, so a Swift
        // [NSStatusItem] or NSArray cast is nil and looks like "no item".
        if let pointers = bar.value(forKey: "items") as? NSPointerArray {
            for index in 0..<pointers.count {
                guard let pointer = pointers.pointer(at: index) else { continue }
                let item = Unmanaged<NSStatusItem>.fromOpaque(pointer).takeUnretainedValue()
                if let button = item.button { return button }
            }
        }
        // Fallback: MenuBarExtra's status item window is already in this process.
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let item = window.value(forKey: "statusItem") as? NSStatusItem, let button = item.button {
                return button
            }
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
