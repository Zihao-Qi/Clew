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

    /// What the shortcut did, for `log show --predicate 'subsystem == "io.github.zihao-qi.clew"'`.
    static let log = Logger(subsystem: "io.github.zihao-qi.clew", category: "menu-bar")

    /// Ways to click the icon, tried in order (user, 2026-11-20: on macOS 27 the first
    /// found nothing, so the shortcut and Settings' closing did nothing).
    enum Way: CaseIterable {
        /// An `NSStatusBarButton` in one of this app's windows (macOS 14–26).
        case statusBarButton
        /// Any button in the menu bar's window.
        case anyButton
        /// A click sent straight to the menu bar window, in-process.
        case click
    }

    #if DEBUG
    /// The smoke test tries one way at a time.
    @MainActor static var only: Way?
    #endif

    @MainActor
    private static func clickStatusItem() {
        // What there is to click, each time: a way may "succeed" and still open nothing.
        log.notice("windows: \(describeWindows(), privacy: .public)")
        for way in Way.allCases {
            #if DEBUG
            if let only, only != way { continue }
            #endif
            if attempt(way) {
                log.notice("menu bar icon clicked: \(String(describing: way), privacy: .public)")
                return
            }
        }
        log.error("menu bar icon not found")
    }

    @MainActor
    private static func attempt(_ way: Way) -> Bool {
        switch way {
        case .statusBarButton:
            guard let button = statusItemButton() else { return false }
            button.performClick(nil)
            return true
        case .anyButton:
            guard let button = statusWindows().lazy.compactMap({ firstButton(in: $0.contentView) }).first else { return false }
            button.performClick(nil)
            return true
        case .click:
            guard let window = statusWindows().first, let view = window.contentView else { return false }
            let at = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
            // The up waits in the queue, so a button's tracking loop ends on it.
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            return true
        }
    }

    /// This app's menu bar windows: the status bar's, never the list's own window.
    @MainActor
    private static func statusWindows() -> [NSWindow] {
        NSApp.windows.filter { w in
            let name = String(describing: type(of: w))
            guard !name.contains("MenuBarExtra"), w.frame.height <= 60 else { return false }
            return name.contains("StatusBar") || w.level.rawValue >= NSWindow.Level.statusBar.rawValue
        }
    }

    @MainActor
    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for sub in view.subviews {
            if let button = firstButton(in: sub) { return button }
        }
        return nil
    }

    /// Each window's class, level and frame, with its views' classes a few levels down.
    @MainActor
    private static func describeWindows() -> String {
        func views(_ view: NSView?, _ depth: Int) -> String {
            guard let view, depth < 4 else { return "" }
            let kids = view.subviews.map { views($0, depth + 1) }.filter { !$0.isEmpty }
            return String(describing: type(of: view)) + (kids.isEmpty ? "" : "[" + kids.joined(separator: ",") + "]")
        }
        return NSApp.windows.map { w in
            "\(type(of: w)) level=\(w.level.rawValue) frame=\(NSStringFromRect(w.frame)) visible=\(w.isVisible) views=\(views(w.contentView, 0))"
        }.joined(separator: " | ")
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
