import ClewCore
import ClewDomain
import Foundation
import GRDB

public enum BackupError: Error, Equatable {
    case compressionUnavailable
    case notABackup
    /// The staged file failed `PRAGMA integrity_check` or is not a Clew database.
    case damaged
}

/// Rolling backups and staged restore (ARCHITECTURE §7). Backups are compressed
/// copies made with SQLite's online backup, one per day, in `Backups/` next to the
/// database. Restore is never live: the chosen backup is staged next to the database
/// and swapped in by `applyPendingRestore` only while the database is closed.
public final class Backups: Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let url: URL
        public let day: LocalDay
        /// Made automatically just before a restore, so the restore can be undone.
        public let isSafetyCopy: Bool
        public let bytes: Int
        public var id: URL { url }
    }

    public let databaseURL: URL
    public let directory: URL
    /// Safety copies are kept apart from the daily rotation; the newest few stay.
    public static let safetyCopiesKept = 3

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        self.directory = databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    var pendingRestoreURL: URL { databaseURL.appendingPathExtension("restore") }

    // MARK: Listing

    /// Newest first.
    public func list() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.compactMap { url in
            guard let (day, safety) = Self.parse(url.lastPathComponent) else { return nil }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Entry(url: url, day: day, isSafetyCopy: safety, bytes: bytes)
        }
        .sorted { ($0.day, $0.isSafetyCopy ? 1 : 0, $0.url.lastPathComponent) > ($1.day, $1.isSafetyCopy ? 1 : 0, $1.url.lastPathComponent) }
    }

    /// `clew-2026-11-09.backup` or `clew-2026-11-09-before-restore-<n>.backup`.
    static func parse(_ name: String) -> (LocalDay, Bool)? {
        guard name.hasPrefix("clew-"), name.hasSuffix(".backup") else { return nil }
        let core = name.dropFirst("clew-".count).dropLast(".backup".count)
        guard core.count >= 10, let day = LocalDay(string: String(core.prefix(10))) else { return nil }
        let rest = core.dropFirst(10)
        if rest.isEmpty { return (day, false) }
        return rest.hasPrefix("-before-restore") ? (day, true) : nil
    }

    // MARK: Making backups

    /// Makes today's backup if there is none yet, then prunes. Returns the new entry.
    @discardableResult
    public func backUpIfNeeded(_ store: SQLiteStore, today: LocalDay) throws -> Entry? {
        guard !list().contains(where: { $0.day == today && !$0.isSafetyCopy }) else { return nil }
        let url = try backUp(store, name: "clew-\(today).backup")
        try prune(today: today)
        // By name: listed URLs may differ in form (/var vs /private/var).
        return list().first { $0.url.lastPathComponent == url.lastPathComponent }
    }

    /// A copy taken just before a restore.
    @discardableResult
    func safetyCopy(_ store: SQLiteStore, today: LocalDay) throws -> URL {
        let n = list().filter { $0.isSafetyCopy && $0.day == today }.count + 1
        let url = try backUp(store, name: "clew-\(today)-before-restore-\(n).backup")
        let safety = list().filter(\.isSafetyCopy)
        for old in safety.dropFirst(Self.safetyCopiesKept) { try? FileManager.default.removeItem(at: old.url) }
        return url
    }

    private func backUp(_ store: SQLiteStore, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = directory.appendingPathComponent(".\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: raw) }
        let copy = try DatabaseQueue(path: raw.path)
        try store.writer.backup(to: copy)   // SQLite online backup: consistent while in use
        // The copy inherits WAL mode from the live database; make it one self-contained
        // file (a WAL-mode file cannot be opened read-only without its side files).
        try copy.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try copy.close()
        let target = directory.appendingPathComponent(name)
        try Self.compress(try Data(contentsOf: raw)).write(to: target, options: .atomic)
        return target
    }

    /// Deletes daily backups that `BackupRetention` no longer keeps.
    public func prune(today: LocalDay) throws {
        let dailies = list().filter { !$0.isSafetyCopy }
        let keep = BackupRetention.keep(dailies.map(\.day), today: today)
        for entry in dailies where !keep.contains(entry.day) {
            try FileManager.default.removeItem(at: entry.url)
        }
    }

    // MARK: Restore

    /// Step 1 of a restore: take a safety copy of the current data, then unpack the
    /// chosen backup next to the database and check it. Nothing is replaced yet.
    public func stageRestore(_ entry: Entry, current store: SQLiteStore, today: LocalDay) throws {
        guard Self.parse(entry.url.lastPathComponent) != nil else { throw BackupError.notABackup }
        try safetyCopy(store, today: today)
        let raw = try Self.decompress(try Data(contentsOf: entry.url))
        try raw.write(to: pendingRestoreURL, options: .atomic)
        guard Self.isHealthyClewDatabase(pendingRestoreURL) else {
            try? FileManager.default.removeItem(at: pendingRestoreURL)
            throw BackupError.damaged
        }
    }

    /// Step 2, with the database closed (at launch, or after `SQLiteStore.close()`):
    /// checks the staged file again and swaps it in. The replaced files are kept as
    /// `*.replaced`. Returns false if nothing was staged.
    @discardableResult
    public static func applyPendingRestore(databaseURL: URL) throws -> Bool {
        let fm = FileManager.default
        let pending = databaseURL.appendingPathExtension("restore")
        guard fm.fileExists(atPath: pending.path) else { return false }
        guard isHealthyClewDatabase(pending) else {
            try? fm.removeItem(at: pending)
            throw BackupError.damaged
        }
        for suffix in ["", "-wal", "-shm"] {
            let current = URL(fileURLWithPath: databaseURL.path + suffix)
            let replaced = URL(fileURLWithPath: databaseURL.path + ".replaced" + suffix)
            try? fm.removeItem(at: replaced)
            if fm.fileExists(atPath: current.path) { try fm.moveItem(at: current, to: replaced) }
        }
        try fm.moveItem(at: pending, to: databaseURL)
        return true
    }

    static func isHealthyClewDatabase(_ url: URL) -> Bool {
        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: url.path, configuration: config) else { return false }
        defer { try? queue.close() }
        return (try? queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok"
                && (try db.tableExists("grdb_migrations")) && (try db.tableExists("item"))
        }) ?? false
    }

    // MARK: Compression (LZFSE: about 4x smaller for Clew's data)

    static func compress(_ data: Data) throws -> Data {
        #if canImport(Darwin)
        return try (data as NSData).compressed(using: .lzfse) as Data
        #else
        throw BackupError.compressionUnavailable
        #endif
    }

    static func decompress(_ data: Data) throws -> Data {
        #if canImport(Darwin)
        do { return try (data as NSData).decompressed(using: .lzfse) as Data } catch { throw BackupError.damaged }
        #else
        throw BackupError.compressionUnavailable
        #endif
    }
}
