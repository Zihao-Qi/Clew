import AppKit
import Carbon.HIToolbox
import ClewCore

// These module-local shims shadow only the two imported Carbon calls in this
// check executable. Production source is compiled unchanged; success delegates
// to Carbon itself. Counters prove that failure injection actually ran.
@MainActor private var refuseHandler = true
@MainActor private var installAttempts = 0
@MainActor private var registrationAttempts = 0

@MainActor
func InstallEventHandler(_ target: EventTargetRef?, _ handler: EventHandlerUPP?,
                         _ count: Int, _ types: UnsafePointer<EventTypeSpec>?,
                         _ data: UnsafeMutableRawPointer?, _ result: UnsafeMutablePointer<EventHandlerRef?>?) -> OSStatus {
    installAttempts += 1
    if refuseHandler { return OSStatus(-50) }
    return Carbon.InstallEventHandler(target, handler, count, types, data, result)
}

@MainActor
func RegisterEventHotKey(_ key: UInt32, _ modifiers: UInt32, _ id: EventHotKeyID,
                         _ target: EventTargetRef?, _ options: UInt32,
                         _ result: UnsafeMutablePointer<EventHotKeyRef?>?) -> OSStatus {
    registrationAttempts += 1
    return Carbon.RegisterEventHotKey(key, modifiers, id, target, options, result)
}

@main
struct OpenShortcutHandlerFailureCheck {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let hotkey = OpenShortcutHotkey.shared
        let shortcut = OpenShortcut(keyCode: 79, command: true, shift: true,
                                    option: true, control: true, glyph: "F18")
        hotkey.apply(shortcut) // The live model can apply before start().
        hotkey.start()
        defer { hotkey.apply(nil) }
        require(installAttempts > 0, "SETUP: handler failure injection was reached")
        require(hotkey.registrationError != nil, "Handler failure stays visible")
        require(registrationAttempts == 0, "No hotkey is reserved without a handler")

        hotkey.apply(nil)
        require(hotkey.registrationError == nil, "Disabling needs no handler")
        hotkey.apply(shortcut)
        require(hotkey.registrationError != nil, "Re-enabling reports the handler failure")
        require(registrationAttempts == 0, "Retry cannot reserve a handlerless hotkey")

        refuseHandler = false
        hotkey.apply(shortcut)
        require(installAttempts >= 3, "A later apply retries handler installation")
        require(registrationAttempts == 1, "Recovered handler allows registration")
        require(hotkey.registrationError == nil, "Recovery clears the handler error")
        print("PASS: handler failure stays visible, reserves no hotkey, and can recover")
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
