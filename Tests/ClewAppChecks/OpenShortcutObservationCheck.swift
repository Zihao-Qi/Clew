import AppKit
import Carbon.HIToolbox
import ClewCore
import Observation
import os

/// Run with `bash scripts/check-open-shortcut.sh`. Uses only this process's hotkeys;
/// never launches Clew, sends keystrokes, or opens its database.
@main
struct OpenShortcutObservationCheck {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let hotkey = OpenShortcutHotkey.shared
        hotkey.start()
        hotkey.apply(nil)
        defer { hotkey.apply(nil) }

        // Own an otherwise unlikely combination to force a real Carbon conflict.
        let shortcut = OpenShortcut(keyCode: 79, command: true, shift: true,
                                    option: true, control: true, glyph: "F18")
        var owner: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,
            UInt32(cmdKey | shiftKey | optionKey | controlKey),
            EventHotKeyID(signature: 0x54455354, id: 2),
            GetApplicationEventTarget(), 0, &owner)
        require(status == noErr && owner != nil, "SETUP: reserve the test combination (status \(status))")
        defer { if let owner { UnregisterEventHotKey(owner) } }

        // Same ordering as the recorder: apply while suspended, then resume after
        // the model refresh. Settings must observe the later result directly.
        hotkey.suspend()
        hotkey.apply(shortcut)
        require(hotkey.registrationError == nil, "No error before registration")
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = OpenShortcutHotkey.shared.registrationError
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        hotkey.resume()
        require(hotkey.registrationError != nil, "Conflict produces an error")
        require(changes.withLock { $0 } == 1, "Resuming publishes the error to Settings")

        // When the conflict goes away, both the error and the displayed warning
        // must clear. Observation is one-shot, so re-arm just as a view redraw does.
        UnregisterEventHotKey(owner!)
        owner = nil
        withObservationTracking {
            _ = OpenShortcutHotkey.shared.registrationError
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        hotkey.resume()
        require(hotkey.registrationError == nil, "Successful retry clears the error")
        require(changes.withLock { $0 } == 2, "Successful retry publishes the cleared error")
        print("PASS: shortcut conflict and recovery both update Settings observation")
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
