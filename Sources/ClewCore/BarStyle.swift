import ClewDomain
import Foundation

/// How progress is drawn on a row (goals' counts, videos' watch progress, and later
/// timers): the user picks one in Settings (decided 2026-11-09).
public enum ProgressBarStyle: String, Codable, Sendable, CaseIterable {
    /// The row's own rounded background fills from the left, behind the title.
    case behindTitle
    /// A long bar under the title, reaching almost to the end of the row.
    case underTitle
    /// No bar: goals show their count only, videos nothing.
    case off
}

extension Clew {
    static let barStyleKey = "progressBarStyle"
    public static let defaultBarStyle = ProgressBarStyle.behindTitle

    public func barStyle() throws -> ProgressBarStyle {
        try storeForQueries.read { r in
            guard let json = try r.setting(Self.barStyleKey) else { return Self.defaultBarStyle }
            // An unknown value (e.g. from a newer version) falls back to the default.
            return (try? JSONDecoder().decode(ProgressBarStyle.self, from: Data(json.utf8))) ?? Self.defaultBarStyle
        }
    }

    public func setBarStyle(_ style: ProgressBarStyle) throws {
        let now = clockForQueries.now()
        let json = String(decoding: try JSONEncoder().encode(style), as: UTF8.self)
        try storeForQueries.write { try $0.saveSetting(Self.barStyleKey, json: json, updatedAt: now) }
    }
}
