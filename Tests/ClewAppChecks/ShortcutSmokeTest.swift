#if DEBUG
import AppKit
import Carbon.HIToolbox
import ClewCore
import ClewDomain
import ClewStore
import SwiftUI

/// Debug-only, in-process UI exercise. Launch the built app with
/// CLEW_SHORTCUT_SMOKE=1; never opens Clew's database or asks for permissions.
@MainActor
enum ShortcutSmokeTest {
    static func model() -> AppModel {
        do {
            let core = Clew(store: try SQLiteStore.inMemory(), clock: SystemClock(), zones: SystemTimeZone())
            try core.setOpenListShortcut(nil)
            let model = AppModel(clew: core, notify: false)
            DispatchQueue.main.async { Task { await run(model: model, core: core) } }
            return model
        } catch {
            fail("Cannot prepare in-memory fixture: \(error)")
        }
    }

    private static func settle() async {
        // A bounded UI animation/event-settling interval, not a polling loop.
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static func run(model: AppModel, core: Clew) async {
        await settle()
        let hotkey = OpenShortcutHotkey.shared
        hotkey.start()
        let initial = OpenShortcut(keyCode: 79, command: true, shift: true,
                                   option: true, control: true, glyph: "F18")
        model.setOpenListShortcut(initial)
        require(hotkey.registrationError == nil, "Register the isolated fixture shortcut")

        // Discovering the button only through public views is the candidate
        // mitigation under investigation, not an assumption that it always exists.
        require(NSApp.windows.contains { button(in: $0.contentView) != nil }, "Public view walk finds the real status button")
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        MenuBarExtraToggle.toggle()
        await settle()
        guard let menu = NSApp.windows.first(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) }) else {
            fail("Shortcut opens the actual MenuBarExtra window")
        }
        print("PASS: shortcut opens the actual MenuBarExtra")
        MenuBarExtraToggle.toggle()
        await settle()
        require(!menu.isVisible, "Second shortcut closes the MenuBarExtra")
        print("PASS: repeated shortcut closes the MenuBarExtra")

        var event: EventRef?
        require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                            EventAttributes(kEventAttributeUserEvent), &event) == noErr, "Create Carbon callback event")
        var id = EventHotKeyID(signature: 0x434C4557, id: 1)
        require(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  MemoryLayout<EventHotKeyID>.size, &id) == noErr, "Set callback identifier")
        require(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr, "Deliver the Carbon callback")
        if let event { ReleaseEvent(event) }
        await settle()
        require(menu.isVisible, "The installed Carbon handler opens the list")
        MenuBarExtraToggle.toggle()
        await settle()
        print("PASS: installed Carbon callback reaches the list")

        let host = NSHostingView(rootView: RecorderFixture(model: model).frame(width: 400, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 100, width: 400, height: 80),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle()

        await click(window, x: 340)
        require(available(initial), "Recording suspends the global shortcut")
        await key(window, code: 53, text: "\u{1b}")
        require(model.openListShortcut == initial && !available(initial), "Escape restores the existing shortcut")
        print("PASS: recorder captures Escape and restores the shortcut")

        await click(window, x: 340)
        await key(window, code: 40, text: "k", flags: [.command, .control, .option, .shift])
        let changed = OpenShortcut(keyCode: 40, command: true, shift: true,
                                   option: true, control: true, glyph: "K")
        require(model.openListShortcut == changed, "Actual recorder captures the changed shortcut")
        require(savedShortcut(core) == changed, "Recorder persists through the real model")
        require(hotkey.registrationError == nil && !available(changed), "Changed shortcut is registered")
        print("PASS: recorder changes, persists and registers the shortcut")

        await click(window, x: 340)
        await key(window, code: 51, text: "\u{7f}")
        require(model.openListShortcut == nil && savedShortcut(core) == nil, "Delete clears and saves the shortcut")
        require(available(changed), "Clearing releases the shortcut")
        print("PASS: Delete clears the shortcut and releases registration")

        model.setOpenListShortcut(initial)
        await settle()
        await click(window, x: 340)
        require(available(initial), "Recording before dismissal suspends registration")
        window.close()
        await settle()
        require(!available(initial), "Closing the recorder window resumes the shortcut")
        print("PASS: window close while recording resumes the shortcut")

        // Keep the closed recorder/host alive: a leaked process-wide monitor
        // would swallow this unrelated window's key even though recording ended.
        let sink = KeySink()
        let other = NSWindow(contentRect: NSRect(x: 40, y: 100, width: 200, height: 80),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.contentView = sink
        other.makeKeyAndOrderFront(nil)
        other.makeFirstResponder(sink)
        await settle()
        await key(other, code: 6, text: "z")
        require(sink.keyCount == 1, "Closing recording removes the process-wide key monitor")
        other.close()
        print("PASS: unrelated window still receives keys after recording closes")
        hotkey.apply(nil)
        print("PASS: isolated shortcut UI smoke test complete")
        fflush(stdout)
        exit(0)
    }

    private static func savedShortcut(_ core: Clew) -> OpenShortcut? {
        do { return try core.openListShortcut() }
        catch { fail("Cannot read fixture settings: \(error)") }
    }

    private static func button(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
    }

    private static func available(_ shortcut: OpenShortcut) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, UInt32(cmdKey | shiftKey | optionKey | controlKey),
            EventHotKeyID(signature: 0x534D4F4B, id: 2), GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    private static func click(_ window: NSWindow, x: CGFloat) async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 40), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        await settle()
    }

    private static func key(_ window: NSWindow, code: UInt16, text: String,
                            flags: NSEvent.ModifierFlags = []) async {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        NSApp.postEvent(event, atStart: false)
        await settle()
    }

    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }

    private final class KeySink: NSView {
        var keyCount = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keyCount += 1 }
    }

    private struct RecorderFixture: View {
        let model: AppModel
        var body: some View {
            OpenShortcutRecorder(shortcut: Binding(
                get: { model.openListShortcut },
                set: { model.setOpenListShortcut($0) }
            ))
            .padding(12)
        }
    }
}
#endif
