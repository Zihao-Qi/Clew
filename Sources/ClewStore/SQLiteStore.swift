import ClewCore
import ClewDomain
import Foundation
import GRDB

public enum StoreError: Error, Equatable {
    case corruptRow(table: String, column: String)
}

/// The GRDB implementation of `ClewStore`. One process owns the database (ADR-1).
public final class SQLiteStore: ClewStore {
    let writer: any DatabaseWriter

    /// Opens (creating if needed) the database at `url` in WAL mode and migrates it.
    public static func open(at url: URL) throws -> SQLiteStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try SQLiteStore(writer: DatabasePool(path: url.path))
    }

    /// An empty in-memory database, for tests.
    public static func inMemory() throws -> SQLiteStore {
        try SQLiteStore(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator.migrate(writer)
    }

    public func read<T>(_ body: (any StoreReader) throws -> T) throws -> T {
        try writer.read { db in try body(Access(db)) }
    }

    public func write<T>(_ body: (any StoreWriter) throws -> T) throws -> T {
        try writer.write { db in try body(Access(db)) }
    }

    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> any StoreObservation {
        let observation = DatabaseRegionObservation(tracking: Table("item"), Table("checkIn"), Table("plan"), Table("goalRound"),
                                                     Table("reminder"), Table("settings"), Table("laterReview"))
        let cancellable = observation.start(in: writer, onError: { _ in }, onChange: { _ in onChange() })
        return Observation(cancellable)
    }
}

private final class Observation: StoreObservation, @unchecked Sendable {
    // AnyDatabaseCancellable is thread-safe; it is only cancelled.
    private let cancellable: AnyDatabaseCancellable
    init(_ cancellable: AnyDatabaseCancellable) { self.cancellable = cancellable }
    func cancel() { cancellable.cancel() }
}

// MARK: - Access

private struct Access: StoreWriter {
    let db: Database
    init(_ db: Database) { self.db = db }

    func item(id: UUID) throws -> Item? {
        try Row.fetchOne(db, sql: "SELECT * FROM item WHERE id = ?", arguments: [id.uuidString]).map(Self.item)
    }

    func items(inStates states: Set<ItemState>) throws -> [Item] {
        guard !states.isEmpty else { return [] }
        let marks = Self.marks(states.count)
        return try Row.fetchAll(
            db, sql: "SELECT * FROM item WHERE deletedAt IS NULL AND state IN (\(marks))",
            arguments: StatementArguments(states.map(\.rawValue))
        ).map(Self.item)
    }

    func checkIn(id: UUID) throws -> CheckIn? {
        try Row.fetchOne(db, sql: "SELECT * FROM checkIn WHERE id = ?", arguments: [id.uuidString]).map(Self.checkIn)
    }

    func checkIns(itemIds: [UUID], from: LocalDay) throws -> [CheckIn] {
        guard !itemIds.isEmpty else { return [] }
        var args = itemIds.map(\.uuidString)
        args.append(from.description)
        return try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM checkIn
                WHERE itemId IN (\(Self.marks(itemIds.count))) AND localDay >= ? AND voidedAt IS NULL
                ORDER BY at
                """,
            arguments: StatementArguments(args)
        ).map(Self.checkIn)
    }

    func roundStarts(itemIds: [UUID]) throws -> [UUID: Date] {
        guard !itemIds.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT itemId, MAX(startedAt) AS start FROM goalRound
                WHERE itemId IN (\(Self.marks(itemIds.count))) AND voidedAt IS NULL
                GROUP BY itemId
                """,
            arguments: StatementArguments(itemIds.map(\.uuidString))
        )
        var result: [UUID: Date] = [:]
        for row in rows {
            result[try Self.uuid(row, "itemId", table: "goalRound")] = row["start"]
        }
        return result
    }

    func progressAmounts(itemIds: [UUID]) throws -> [UUID: Int] {
        guard !itemIds.isEmpty else { return [:] }
        // Dates are stored as UTC "yyyy-MM-dd HH:mm:ss.SSS" text, which sorts in time order.
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.itemId, SUM(c.amount) AS total
                FROM checkIn c
                LEFT JOIN (
                    SELECT itemId, MAX(startedAt) AS start FROM goalRound
                    WHERE voidedAt IS NULL GROUP BY itemId
                ) r ON r.itemId = c.itemId
                WHERE c.itemId IN (\(Self.marks(itemIds.count))) AND c.voidedAt IS NULL
                  AND (r.start IS NULL OR c.at >= r.start)
                GROUP BY c.itemId
                """,
            arguments: StatementArguments(itemIds.map(\.uuidString))
        )
        var result: [UUID: Int] = [:]
        for row in rows {
            result[try Self.uuid(row, "itemId", table: "checkIn")] = row["total"]
        }
        return result
    }

    func plans(itemId: UUID) throws -> [Plan] {
        try Row.fetchAll(db, sql: "SELECT * FROM plan WHERE itemId = ? ORDER BY at", arguments: [itemId.uuidString])
            .map(Self.plan)
    }

    func goalRounds(itemId: UUID) throws -> [GoalRound] {
        try Row.fetchAll(db, sql: "SELECT * FROM goalRound WHERE itemId = ? ORDER BY startedAt",
                         arguments: [itemId.uuidString]).map(Self.goalRound)
    }

    func insert(_ g: GoalRound) throws {
        try db.execute(
            sql: """
                INSERT INTO goalRound (id, itemId, startedAt, localDay, target, source, voidedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [g.id.uuidString, g.itemId.uuidString, g.startedAt, g.localDay.description, g.target,
                        g.source.rawValue, g.voidedAt]
        )
    }

    func activeDays(from: LocalDay) throws -> Set<LocalDay> {
        let days = try String.fetchAll(
            db, sql: "SELECT DISTINCT localDay FROM checkIn WHERE voidedAt IS NULL AND localDay >= ?",
            arguments: [from.description]
        )
        return Set(try days.map { text in
            guard let day = LocalDay(string: text) else { throw StoreError.corruptRow(table: "checkIn", column: "localDay") }
            return day
        })
    }

    func allRecords() throws -> ExportRecords {
        ExportRecords(
            items: try Row.fetchAll(db, sql: "SELECT * FROM item ORDER BY createdAt, id").map(Self.item),
            checkIns: try Row.fetchAll(db, sql: "SELECT * FROM checkIn ORDER BY at, id").map(Self.checkIn),
            plans: try Row.fetchAll(db, sql: "SELECT * FROM plan ORDER BY at, id").map(Self.plan),
            goalRounds: try Row.fetchAll(db, sql: "SELECT * FROM goalRound ORDER BY startedAt, id").map(Self.goalRound),
            reminders: try Row.fetchAll(db, sql: "SELECT * FROM reminder ORDER BY updatedAt, id").map(Self.reminder),
            settings: try Row.fetchAll(db, sql: "SELECT * FROM settings ORDER BY key").map { row in
                SettingRecord(key: try Self.required(row, "key", table: "settings"),
                              value: try Self.required(row, "value", table: "settings"),
                              updatedAt: try Self.required(row, "updatedAt", table: "settings"))
            },
            laterReviews: try Row.fetchAll(db, sql: "SELECT * FROM laterReview ORDER BY at, id").map(Self.laterReview)
        )
    }

    func laterReviews(itemIds: [UUID]) throws -> [LaterReview] {
        guard !itemIds.isEmpty else { return [] }
        return try Row.fetchAll(
            db, sql: "SELECT * FROM laterReview WHERE voidedAt IS NULL AND itemId IN (\(Self.marks(itemIds.count))) ORDER BY at",
            arguments: StatementArguments(itemIds.map(\.uuidString))
        ).map(Self.laterReview)
    }

    func letGoCount() throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM laterReview WHERE decision = 'letGo' AND voidedAt IS NULL") ?? 0
    }

    func insert(_ r: LaterReview) throws {
        try db.execute(
            sql: "INSERT INTO laterReview (id, itemId, decision, at, localDay, source, voidedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [r.id.uuidString, r.itemId.uuidString, r.decision.rawValue, r.at, r.localDay.description,
                        r.source.rawValue, r.voidedAt]
        )
    }

    func reminders() throws -> [Reminder] {
        try Row.fetchAll(db, sql: "SELECT * FROM reminder WHERE deletedAt IS NULL ORDER BY itemId").map(Self.reminder)
    }

    func setting(_ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
    }

    func save(_ r: Reminder) throws {
        try db.execute(
            sql: """
                INSERT INTO reminder (id, itemId, hour, minute, enabled, updatedAt, deletedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET itemId = excluded.itemId, hour = excluded.hour,
                    minute = excluded.minute, enabled = excluded.enabled, updatedAt = excluded.updatedAt,
                    deletedAt = excluded.deletedAt
                """,
            arguments: [r.id.uuidString, r.itemId.uuidString, r.time.hour, r.time.minute, r.enabled, r.updatedAt,
                        r.deletedAt]
        )
    }

    func saveSetting(_ key: String, json: String, updatedAt: Date) throws {
        try db.execute(
            sql: """
                INSERT INTO settings (key, value, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                """,
            arguments: [key, json, updatedAt]
        )
    }

    func maxSortKey() throws -> Double? {
        try Double.fetchOne(db, sql: "SELECT MAX(sortKey) FROM item")
    }

    func insert(_ item: Item) throws {
        try db.execute(
            sql: """
                INSERT INTO item (id, kind, title, url, note, parentId, schedule, progress, state, plannedDay,
                                  sortKey, source, externalRef, createdAt, updatedAt, deletedAt, titleOrigin)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: try Self.itemArguments(item)
        )
    }

    func update(_ item: Item) throws {
        var args = try Self.itemArguments(item)
        args += [item.id.uuidString]
        try db.execute(
            sql: """
                UPDATE item SET id = ?, kind = ?, title = ?, url = ?, note = ?, parentId = ?, schedule = ?,
                    progress = ?, state = ?, plannedDay = ?, sortKey = ?, source = ?, externalRef = ?,
                    createdAt = ?, updatedAt = ?, deletedAt = ?, titleOrigin = ?
                WHERE id = ?
                """,
            arguments: args
        )
    }

    func insert(_ c: CheckIn) throws {
        try db.execute(
            sql: """
                INSERT INTO checkIn (id, itemId, localDay, at, timeZoneId, amount, rating, ratedAt, source,
                                     voidedAt, voidReason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                c.id.uuidString, c.itemId.uuidString, c.localDay.description, c.at, c.timeZoneId, c.amount,
                c.rating, c.ratedAt, c.source.rawValue, c.voidedAt, c.voidReason,
            ]
        )
    }

    func voidCheckIn(id: UUID, at: Date, reason: String) throws {
        // The trigger rejects re-voiding; the WHERE clause is not what enforces it.
        try db.execute(
            sql: "UPDATE checkIn SET voidedAt = ?, voidReason = ? WHERE id = ?",
            arguments: [at, reason, id.uuidString]
        )
    }

    func insert(_ p: Plan) throws {
        try db.execute(
            sql: "INSERT INTO plan (id, itemId, localDay, at, source, voidedAt) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [p.id.uuidString, p.itemId.uuidString, p.localDay.description, p.at, p.source.rawValue,
                        p.voidedAt]
        )
    }

    // MARK: Mapping

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ row: Row, _ column: String) throws -> T {
        guard let text: String = row[column] else { throw StoreError.corruptRow(table: "item", column: column) }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private static func itemArguments(_ i: Item) throws -> StatementArguments {
        [
            i.id.uuidString, i.kind.rawValue, i.title, i.url?.absoluteString, i.note, i.parentId?.uuidString,
            try json(i.schedule), try json(i.progress), i.state.rawValue, i.plannedDay?.description,
            i.sortKey, i.source.rawValue, i.externalRef, i.createdAt, i.updatedAt, i.deletedAt,
            i.titleOrigin.rawValue,
        ]
    }

    private static func item(_ row: Row) throws -> Item {
        let t = "item"
        return Item(
            id: try uuid(row, "id", table: t),
            kind: try raw(row, "kind", table: t),
            title: try required(row, "title", table: t),
            titleOrigin: try raw(row, "titleOrigin", table: t),
            url: (row["url"] as String?).flatMap(URL.init(string:)),
            note: row["note"],
            parentId: try optionalUUID(row, "parentId", table: t),
            schedule: try decodeJSON(Schedule.self, row, "schedule"),
            progress: try decodeJSON(ProgressSpec.self, row, "progress"),
            state: try raw(row, "state", table: t),
            plannedDay: try optionalDay(row, "plannedDay", table: t),
            sortKey: try required(row, "sortKey", table: t),
            source: try raw(row, "source", table: t),
            externalRef: row["externalRef"],
            createdAt: try required(row, "createdAt", table: t),
            updatedAt: try required(row, "updatedAt", table: t),
            deletedAt: row["deletedAt"]
        )
    }

    private static func checkIn(_ row: Row) throws -> CheckIn {
        let t = "checkIn"
        return CheckIn(
            id: try uuid(row, "id", table: t),
            itemId: try uuid(row, "itemId", table: t),
            localDay: try day(row, "localDay", table: t),
            at: try required(row, "at", table: t),
            timeZoneId: try required(row, "timeZoneId", table: t),
            amount: try required(row, "amount", table: t),
            rating: row["rating"],
            ratedAt: row["ratedAt"],
            source: try raw(row, "source", table: t),
            voidedAt: row["voidedAt"],
            voidReason: row["voidReason"]
        )
    }

    private static func goalRound(_ row: Row) throws -> GoalRound {
        let t = "goalRound"
        return GoalRound(
            id: try uuid(row, "id", table: t),
            itemId: try uuid(row, "itemId", table: t),
            startedAt: try required(row, "startedAt", table: t),
            localDay: try day(row, "localDay", table: t),
            target: try required(row, "target", table: t),
            source: try raw(row, "source", table: t),
            voidedAt: row["voidedAt"]
        )
    }

    private static func reminder(_ row: Row) throws -> Reminder {
        let t = "reminder"
        guard let time = TimeOfDay(hour: try required(row, "hour", table: t), minute: try required(row, "minute", table: t))
        else { throw StoreError.corruptRow(table: t, column: "hour") }
        return Reminder(
            id: try uuid(row, "id", table: t),
            itemId: try uuid(row, "itemId", table: t),
            time: time,
            enabled: try required(row, "enabled", table: t),
            updatedAt: try required(row, "updatedAt", table: t),
            deletedAt: row["deletedAt"]
        )
    }

    private static func laterReview(_ row: Row) throws -> LaterReview {
        let t = "laterReview"
        return LaterReview(
            id: try uuid(row, "id", table: t),
            itemId: try uuid(row, "itemId", table: t),
            decision: try raw(row, "decision", table: t),
            at: try required(row, "at", table: t),
            localDay: try day(row, "localDay", table: t),
            source: try raw(row, "source", table: t),
            voidedAt: row["voidedAt"]
        )
    }

    private static func plan(_ row: Row) throws -> Plan {
        let t = "plan"
        return Plan(
            id: try uuid(row, "id", table: t),
            itemId: try uuid(row, "itemId", table: t),
            localDay: try day(row, "localDay", table: t),
            at: try required(row, "at", table: t),
            source: try raw(row, "source", table: t),
            voidedAt: row["voidedAt"]
        )
    }

    fileprivate static func required<T: DatabaseValueConvertible>(_ row: Row, _ column: String, table: String) throws -> T {
        guard let value: T = row[column] else { throw StoreError.corruptRow(table: table, column: column) }
        return value
    }

    private static func raw<T: RawRepresentable>(_ row: Row, _ column: String, table: String) throws -> T
    where T.RawValue == String {
        guard let text: String = row[column], let value = T(rawValue: text) else {
            throw StoreError.corruptRow(table: table, column: column)
        }
        return value
    }

    fileprivate static func uuid(_ row: Row, _ column: String, table: String) throws -> UUID {
        guard let text: String = row[column], let id = UUID(uuidString: text) else {
            throw StoreError.corruptRow(table: table, column: column)
        }
        return id
    }

    private static func optionalUUID(_ row: Row, _ column: String, table: String) throws -> UUID? {
        guard let text: String = row[column] else { return nil }
        guard let id = UUID(uuidString: text) else { throw StoreError.corruptRow(table: table, column: column) }
        return id
    }

    private static func day(_ row: Row, _ column: String, table: String) throws -> LocalDay {
        guard let day = try optionalDay(row, column, table: table) else {
            throw StoreError.corruptRow(table: table, column: column)
        }
        return day
    }

    private static func optionalDay(_ row: Row, _ column: String, table: String) throws -> LocalDay? {
        guard let text: String = row[column] else { return nil }
        guard let day = LocalDay(string: text) else { throw StoreError.corruptRow(table: table, column: column) }
        return day
    }

    private static func marks(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ", ")
    }
}
