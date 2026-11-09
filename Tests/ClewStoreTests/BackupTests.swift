import ClewCore
import ClewDomain
@testable import ClewStore
import Foundation
import GRDB
import Testing

private func day(_ s: String) -> LocalDay { LocalDay(string: s)! }

/// Each test gets its own folder with a real file database.
private struct Sandbox {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clew-backup-\(UUID().uuidString)")
    var db: URL { dir.appendingPathComponent("clew.sqlite") }
    var backups: Backups { Backups(databaseURL: db) }

    func clew(_ store: SQLiteStore) -> Clew {
        struct C: ClewDomain.Clock { func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) } }
        struct Z: TimeZoneSource { func current() -> TimeZone { TimeZone(identifier: "UTC")! } }
        return Clew(store: store, clock: C(), zones: Z())
    }

    func titles(_ store: SQLiteStore) throws -> [String] {
        try store.read { try $0.items(inStates: Set(ItemState.allCases)) }.map(\.title).sorted()
    }
}

@Suite struct BackupTests {
    @Test func oneCompressedBackupPerDay() throws {
        let box = Sandbox()
        let store = try SQLiteStore.open(at: box.db)
        _ = try box.clew(store).addItem(NewItem(title: "A", shape: .habit(.daily)))
        let entry = try #require(try box.backups.backUpIfNeeded(store, today: day("2026-11-09")))
        #expect(entry.day == day("2026-11-09") && !entry.isSafetyCopy)
        #expect(try box.backups.backUpIfNeeded(store, today: day("2026-11-09")) == nil) // not twice a day
        let raw = try Backups.decompress(try Data(contentsOf: entry.url))
        #expect(entry.bytes < raw.count)                                               // really compressed
        #expect(box.backups.list().count == 1)
    }

    @Test func pruningFollowsTheRetentionRule() throws {
        let box = Sandbox()
        let store = try SQLiteStore.open(at: box.db)
        let first = try #require(try box.backups.backUpIfNeeded(store, today: day("2026-08-01")))
        let content = try Data(contentsOf: first.url)
        let today = day("2026-11-09")
        let days = (0..<100).map { today.adding(days: -$0) }
        for d in days { try content.write(to: box.backups.directory.appendingPathComponent("clew-\(d).backup")) }
        try box.backups.prune(today: today)
        let left = Set(box.backups.list().map(\.day))
        #expect(left == BackupRetention.keep(days + [first.day], today: today))
        #expect(left.count == 22)
    }

    /// The whole cycle on real files: back up, change, restore (with a safety copy),
    /// then undo the restore from the safety copy.
    @Test func restoreSwapsInTheBackupAndCanBeUndone() throws {
        let box = Sandbox()
        var store = try SQLiteStore.open(at: box.db)
        _ = try box.clew(store).addItem(NewItem(title: "A", shape: .habit(.daily)))
        let backup = try #require(try box.backups.backUpIfNeeded(store, today: day("2026-11-08")))
        _ = try box.clew(store).addItem(NewItem(title: "B", shape: .habit(.daily)))

        try box.backups.stageRestore(backup, current: store, today: day("2026-11-09"))
        #expect(try box.titles(store) == ["A", "B"])                       // nothing replaced while open
        try store.close()
        store = try SQLiteStore.open(at: box.db)                             // applies the staged restore
        #expect(try box.titles(store) == ["A"])
        #expect(FileManager.default.fileExists(atPath: box.db.path + ".replaced"))

        let safety = try #require(box.backups.list().first { $0.isSafetyCopy })
        try box.backups.stageRestore(safety, current: store, today: day("2026-11-09"))
        try store.close()
        store = try SQLiteStore.open(at: box.db)
        #expect(try box.titles(store) == ["A", "B"])
        #expect(box.backups.list().filter(\.isSafetyCopy).count == 2)
    }

    @Test func aDamagedBackupIsRefusedAndNothingChanges() throws {
        let box = Sandbox()
        let store = try SQLiteStore.open(at: box.db)
        _ = try box.clew(store).addItem(NewItem(title: "A", shape: .habit(.daily)))
        try FileManager.default.createDirectory(at: box.backups.directory, withIntermediateDirectories: true)
        let bad = box.backups.directory.appendingPathComponent("clew-2026-11-01.backup")
        try Data("not a database".utf8).write(to: bad)
        let entry = try #require(box.backups.list().first)
        #expect(throws: BackupError.damaged) { try box.backups.stageRestore(entry, current: store, today: day("2026-11-09")) }
        #expect(!FileManager.default.fileExists(atPath: box.backups.pendingRestoreURL.path))
        #expect(try box.titles(store) == ["A"])
    }

    /// Compressed correctly, but the contents are not a Clew database: only the
    /// integrity check can catch this one.
    @Test func aWellCompressedButWrongFileIsRefused() throws {
        let box = Sandbox()
        let store = try SQLiteStore.open(at: box.db)
        _ = try box.clew(store).addItem(NewItem(title: "A", shape: .habit(.daily)))
        try FileManager.default.createDirectory(at: box.backups.directory, withIntermediateDirectories: true)
        let other = box.dir.appendingPathComponent("other.sqlite")
        let queue = try DatabaseQueue(path: other.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE notes (text TEXT)") }
        try queue.close()
        let wrong = box.backups.directory.appendingPathComponent("clew-2026-11-02.backup")
        try Backups.compress(try Data(contentsOf: other)).write(to: wrong)
        let entry = try #require(box.backups.list().first)
        #expect(throws: BackupError.damaged) { try box.backups.stageRestore(entry, current: store, today: day("2026-11-09")) }
        #expect(!FileManager.default.fileExists(atPath: box.backups.pendingRestoreURL.path))
        #expect(try box.titles(store) == ["A"])
    }

    @Test func aDamagedStagedFileAtLaunchIsDiscardedAndTheAppStillOpens() throws {
        let box = Sandbox()
        var store = try SQLiteStore.open(at: box.db)
        _ = try box.clew(store).addItem(NewItem(title: "A", shape: .habit(.daily)))
        try store.close()
        try Data("garbage".utf8).write(to: box.backups.pendingRestoreURL)
        store = try SQLiteStore.open(at: box.db)
        #expect(try box.titles(store) == ["A"])
        #expect(!FileManager.default.fileExists(atPath: box.backups.pendingRestoreURL.path))
    }

    @Test func onlyClewBackupNamesAreListed() {
        #expect(Backups.parse("clew-2026-11-09.backup")! == (day("2026-11-09"), false))
        #expect(Backups.parse("clew-2026-11-09-before-restore-2.backup")! == (day("2026-11-09"), true))
        #expect(Backups.parse("clew-2026-13-09.backup") == nil)
        #expect(Backups.parse("other-2026-11-09.backup") == nil)
        #expect(Backups.parse("clew-2026-11-09.sqlite") == nil)
        #expect(Backups.parse("clew-2026-11-09-extra.backup") == nil)
    }
}
