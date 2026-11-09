import ClewDomain
import Foundation

/// One-click export (SPEC §8, ARCHITECTURE §7): versioned JSON of definitions and
/// facts, including deleted items and voided facts, so nothing is lost.
public struct ExportDocument: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var clewExportVersion: Int
    public var exportedAt: Date
    public var records: ExportRecords

    public init(exportedAt: Date, records: ExportRecords) {
        self.clewExportVersion = Self.currentVersion
        self.exportedAt = exportedAt
        self.records = records
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.timestamp.string(from: date))
        }
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ExportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = timestamp.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 time: \(text)")
            }
            return date
        }
        let document = try decoder.decode(ExportDocument.self, from: data)
        guard document.clewExportVersion == currentVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown export version"))
        }
        return document
    }

    /// UTC with milliseconds, the precision the database keeps.
    private static var timestamp: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

/// "Done means used" (SPEC): days with at least one tick, shown only in Settings.
public struct ActiveDays: Hashable, Sendable {
    public let last7: Int
    public let last14: Int

    public init(last7: Int, last14: Int) {
        self.last7 = last7
        self.last14 = last14
    }
}

extension Clew {
    public func exportDocument() throws -> ExportDocument {
        let records = try storeForQueries.read { try $0.allRecords() }
        return ExportDocument(exportedAt: clockForQueries.now(), records: records)
    }

    /// Counted over the 7 and 14 days ending today (today included).
    public func activeDays() throws -> ActiveDays {
        let today = currentDay()
        let days = try storeForQueries.read { try $0.activeDays(from: today.adding(days: -13)) }
        let inWindow = days.filter { $0 <= today }
        return ActiveDays(
            last7: inWindow.filter { $0 >= today.adding(days: -6) }.count,
            last14: inWindow.count
        )
    }
}
