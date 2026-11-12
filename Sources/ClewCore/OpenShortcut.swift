import Foundation

/// A keyboard shortcut that opens today's list from anywhere (SPEC 2026-11-11).
/// Stored in Settings so it is included in backups and export. `nil` in the setting
/// means the user cleared it; a missing setting means the default, ⌘..
public struct OpenShortcut: Equatable, Sendable, Hashable, Codable {
    /// Hardware key code (`kVK_ANSI_Period` is 47), as RegisterEventHotKey uses.
    public var keyCode: UInt32
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool
    /// The key as shown after the modifier symbols, e.g. "." or "K".
    public var glyph: String

    public init(keyCode: UInt32, command: Bool, shift: Bool, option: Bool, control: Bool, glyph: String) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.glyph = glyph
    }

    /// ⌘. — Command-Period (decided 2026-11-11).
    public static let `default` = OpenShortcut(
        keyCode: 47, command: true, shift: false, option: false, control: false, glyph: "."
    )

    /// At least Command, Option or Control, so a bare or Shift-only key cannot be global.
    public var hasStrongModifier: Bool { command || option || control }

    /// Shortcuts that must stay with the system or the front app: Quit, Close, Hide,
    /// Minimise, Space (Spotlight when Control is also used, and a reserved Command
    /// space on some layouts), Tab, and Escape. Reserved letters are matched by
    /// `glyph` (from the active keyboard layout) so Command-Q stays blocked on
    /// Dvorak and other non-QWERTY sources. Space, Tab and Escape use hardware
    /// key codes, which do not change with layout.
    public var isReserved: Bool {
        guard command || control else { return false }
        switch keyCode {
        case 49, 48, 53: return true // Space Tab Escape
        default: break
        }
        switch glyph.uppercased() {
        case "Q", "W", "H", "M": return true
        default: return false
        }
    }

    public var isAllowed: Bool { hasStrongModifier && !isReserved && !glyph.isEmpty }

    /// Modifier symbols in the usual Mac order, then the key: "⌘.".
    public var display: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        text += glyph
        return text
    }
}

extension Clew {
    static let openListShortcutKey = "openListShortcut"

    /// The shortcut that opens the list: the default when never set, `nil` when the
    /// user has cleared it, and the default again if the stored value cannot be read.
    public func openListShortcut() throws -> OpenShortcut? {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.openListShortcutKey) else { return .default }
            if json == "null" { return nil }
            return OpenShortcut.decode(json) ?? .default
        }
    }

    public func setOpenListShortcut(_ shortcut: OpenShortcut?) throws {
        if let shortcut, !shortcut.isAllowed {
            // Do not save a shortcut that would steal Quit or have no modifier.
            return
        }
        let now = clockForQueries.now()
        let json: String
        if let shortcut {
            json = String(decoding: try JSONEncoder().encode(shortcut), as: UTF8.self)
        } else {
            json = "null"
        }
        try storeForQueries.write { try $0.saveSetting(Self.openListShortcutKey, json: json, updatedAt: now) }
    }
}

extension OpenShortcut {
    static func decode(_ json: String) -> OpenShortcut? {
        try? JSONDecoder().decode(OpenShortcut.self, from: Data(json.utf8))
    }
}
