import AppKit
import ClewCore
import SwiftUI

/// Settings › General: shows the current shortcut, records a new one, or clears it.
struct OpenShortcutRecorder: View {
    @Binding var shortcut: OpenShortcut?
    var onChange: (OpenShortcut?) -> Void

    @State private var recording = false

    var body: some View {
        HStack {
            Text("Shortcut")
            Spacer()
            Button(action: startRecording) {
                Group {
                    if recording {
                        Text("Type a shortcut")
                    } else if let shortcut {
                        Text(shortcut.display)
                    } else {
                        Text("None")
                    }
                }
                    .monospaced()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorderAccessibilityLabel)
            if shortcut != nil, !recording {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear shortcut"))
            }
        }
        .background {
            if recording {
                ShortcutCapture(onKey: { handle($0) }, onCancel: { stopRecording() })
                    .frame(width: 0, height: 0)
            }
        }
        .onChange(of: recording) { _, on in
            if on { OpenShortcutHotkey.shared.suspend() } else { OpenShortcutHotkey.shared.resume() }
        }
        .onDisappear { if recording { stopRecording() } }
    }

    private var recorderAccessibilityLabel: Text {
        if recording {
            Text("Type a shortcut")
        } else if let shortcut {
            Text("Open the list shortcut, \(shortcut.display)")
        } else {
            Text("Open the list shortcut, \(Text("None"))")
        }
    }

    private func startRecording() {
        recording = true
    }

    private func stopRecording() {
        recording = false
        OpenShortcutHotkey.shared.resume()
    }

    private func clear() {
        shortcut = nil
        onChange(nil)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Escape: leave the existing shortcut.
            stopRecording()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete: clear.
            shortcut = nil
            onChange(nil)
            stopRecording()
            return
        }
        guard let next = OpenShortcut(event: event) else { return }
        guard next.isAllowed else { return } // keep recording
        shortcut = next
        onChange(next)
        stopRecording()
    }
}

/// A tiny view that swallows key downs while a shortcut is being recorded.
private struct ShortcutCapture: NSViewRepresentable {
    var onKey: (NSEvent) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: ()) {
        view.stop()
    }

    final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            window.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.onKey?(event)
                return nil
            }
            // A closed SwiftUI/AppKit window can retain its hosting view; neither
            // onDisappear nor viewDidMoveToWindow is guaranteed to run on close.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                    self?.onCancel?()
                }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            monitor = nil
            closeObserver = nil
        }

        override var acceptsFirstResponder: Bool { true }
    }
}

extension OpenShortcut {
    /// From a key-down in the Settings recorder.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let raw = event.charactersIgnoringModifiers ?? ""
        let glyph = OpenShortcut.glyph(for: event.keyCode, characters: raw)
        guard !glyph.isEmpty else { return nil }
        self.init(
            keyCode: UInt32(event.keyCode),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            glyph: glyph
        )
    }

    static func glyph(for keyCode: UInt16, characters: String) -> String {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            break
        }
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        if first.isLetter { return String(first).uppercased() }
        return String(first)
    }
}
