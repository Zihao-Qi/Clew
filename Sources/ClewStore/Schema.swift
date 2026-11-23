import ClewDomain
import Foundation
import GRDB

/// Forward-only, versioned migrations (ARCHITECTURE §7). Never edit a shipped
/// migration; add a new one.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        migrator.registerMigration("v2-rounds-titleOrigin", migrate: v2)
        migrator.registerMigration("v3-reminders-settings", migrate: v3)
        migrator.registerMigration("v4-later-reviews", migrate: v4)
        migrator.registerMigration("v5-five-point-ratings", migrate: v5)
        migrator.registerMigration("v6-watch-progress", migrate: v6)
        migrator.registerMigration("v7-focus-sessions", migrate: v7)
        migrator.registerMigration("v8-time-blocks", migrate: v8)
        migrator.registerMigration("v9-time-slots", migrate: v9)
        migrator.registerMigration("v10-plan-today-key", migrate: v10)
        migrator.registerMigration("v11-goals-without-schedule", migrate: v11)
        migrator.registerMigration("v12-one-day-reminders", migrate: v12)
        migrator.registerMigration("v13-priority", migrate: v13)
        migrator.registerMigration("v14-steps", migrate: v14)
        migrator.registerMigration("v15-step-blocks", migrate: v15)
        migrator.registerMigration("v16-quick-notes", migrate: v16)
        return migrator
    }

    /// Notes (SPEC 2026-11-22): the person's own, definitions with tombstones; when and
    /// during what a note was written never change.
    private static func v16(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE quickNote (
                id            TEXT PRIMARY KEY NOT NULL,
                text          TEXT NOT NULL,
                createdAt     DATETIME NOT NULL,
                duringItemId  TEXT,
                duringTitle   TEXT,
                doneAt        DATETIME,
                taskId        TEXT,
                madeTo        TEXT CHECK (madeTo IN ('today', 'later')),
                updatedAt     DATETIME NOT NULL,
                deletedAt     DATETIME
            );

            CREATE TRIGGER quickNote_no_delete BEFORE DELETE ON quickNote
            BEGIN SELECT RAISE(ABORT, 'notes are removed with a tombstone, never deleted'); END;

            CREATE TRIGGER quickNote_fixed BEFORE UPDATE ON quickNote
            WHEN NEW.id IS NOT OLD.id OR NEW.createdAt IS NOT OLD.createdAt
              OR NEW.duringItemId IS NOT OLD.duringItemId OR NEW.duringTitle IS NOT OLD.duringTitle
            BEGIN SELECT RAISE(ABORT, 'a note keeps when and during what it was written'); END;
            """)
    }

    /// A step on the timeline (SPEC 2026-11-21): a block may be a step's, which it keeps;
    /// its tick is a step tick.
    private static func v15(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE timeBlock ADD COLUMN stepId TEXT REFERENCES step(id);
            ALTER TABLE timeBlock ADD COLUMN stepTickId TEXT REFERENCES stepTick(id);
            DROP TRIGGER timeBlock_fixed;
            CREATE TRIGGER timeBlock_fixed BEFORE UPDATE ON timeBlock
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId OR NEW.localDay IS NOT OLD.localDay
              OR NEW.placedAt IS NOT OLD.placedAt OR NEW.stepId IS NOT OLD.stepId
            BEGIN SELECT RAISE(ABORT, 'a time block keeps its task, step, day and placing'); END;
            """)
    }

    /// Steps in a task (SPEC 2026-11-21): steps are definitions (tombstoned, never
    /// deleted; a step keeps its task); their ticks are facts (voided, never deleted or
    /// changed in substance), kept apart from check-ins so they never count as done.
    private static func v14(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE step (
                id         TEXT PRIMARY KEY NOT NULL,
                taskId     TEXT NOT NULL REFERENCES item(id),
                title      TEXT NOT NULL,
                sortKey    REAL NOT NULL,
                createdAt  DATETIME NOT NULL,
                updatedAt  DATETIME NOT NULL,
                deletedAt  DATETIME
            );
            CREATE INDEX step_task ON step(taskId);

            CREATE TRIGGER step_no_delete BEFORE DELETE ON step
            BEGIN SELECT RAISE(ABORT, 'steps are removed with a tombstone, never deleted'); END;

            CREATE TRIGGER step_fixed BEFORE UPDATE ON step
            WHEN NEW.id IS NOT OLD.id OR NEW.taskId IS NOT OLD.taskId OR NEW.createdAt IS NOT OLD.createdAt
            BEGIN SELECT RAISE(ABORT, 'a step keeps its task'); END;

            CREATE TABLE stepTick (
                id                 TEXT PRIMARY KEY NOT NULL,
                stepId             TEXT NOT NULL REFERENCES step(id),
                taskId             TEXT NOT NULL REFERENCES item(id),
                localDay           TEXT NOT NULL,
                at                 DATETIME NOT NULL,
                source             TEXT NOT NULL,
                finishedCheckInId  TEXT REFERENCES checkIn(id),
                voidedAt           DATETIME
            );
            CREATE INDEX stepTick_task ON stepTick(taskId);

            CREATE TRIGGER stepTick_no_delete BEFORE DELETE ON stepTick
            BEGIN SELECT RAISE(ABORT, 'facts are never deleted'); END;

            CREATE TRIGGER stepTick_substance_immutable BEFORE UPDATE ON stepTick
            WHEN NEW.id IS NOT OLD.id OR NEW.stepId IS NOT OLD.stepId OR NEW.taskId IS NOT OLD.taskId
              OR NEW.localDay IS NOT OLD.localDay OR NEW.at IS NOT OLD.at OR NEW.source IS NOT OLD.source
              OR NEW.finishedCheckInId IS NOT OLD.finishedCheckInId
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;

            CREATE TRIGGER stepTick_void_monotonic BEFORE UPDATE ON stepTick
            WHEN OLD.voidedAt IS NOT NULL AND NEW.voidedAt IS NOT OLD.voidedAt
            BEGIN SELECT RAISE(ABORT, 'voids are monotonic'); END;
            """)
    }

    /// Priority tasks (SPEC 2026-11-19): a definition field; every existing task is not one.
    private static func v13(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE item ADD COLUMN priority INTEGER NOT NULL DEFAULT 0 CHECK (priority IN (0, 1))")
    }

    /// A reminder for today only (SPEC 2026-11-15): its Clew day; null is every day,
    /// which every existing reminder stays.
    private static func v12(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE reminder ADD COLUMN day TEXT")
    }

    /// Goals lose their schedule and time slot (SPEC 2026-11-15): they live in Goals &
    /// Later. A goal with a live, undecided block first gets a plan for that block's own
    /// day, so the block stays (moved to Today). Runs once; no clock (the plan's `at` is
    /// the block's `placedAt`). Facts are only inserted, never changed.
    private static func v11(_ db: Database) throws {
        let blocks = try Row.fetchAll(db, sql: """
            SELECT b.itemId, b.localDay, MIN(b.placedAt) AS placedAt FROM timeBlock b
            JOIN item i ON i.id = b.itemId
            WHERE i.kind = 'goal' AND i.deletedAt IS NULL AND i.state = 'active'
              AND b.removedAt IS NULL AND b.decidedAt IS NULL
              AND NOT EXISTS (SELECT 1 FROM plan p WHERE p.itemId = b.itemId AND p.localDay = b.localDay
                              AND p.voidedAt IS NULL)
            GROUP BY b.itemId, b.localDay
            """)
        for row in blocks {
            try db.execute(sql: "INSERT INTO plan (id, itemId, localDay, at, source) VALUES (?, ?, ?, ?, 'user')",
                           arguments: [UUID().uuidString, row["itemId"] as String, row["localDay"] as String,
                                       row["placedAt"] as DatabaseValue])
        }
        // Encoded as the store encodes item definitions (sorted keys).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let unscheduled = String(decoding: try encoder.encode(Schedule.unscheduled), as: UTF8.self)
        try db.execute(sql: "UPDATE item SET schedule = ?, slot = NULL WHERE kind = 'goal'", arguments: [unscheduled])
    }

    /// Moved to Today (SPEC 2026-11-15): a plan's place in Today's order. Part of the
    /// fact's substance, so the immutability trigger now covers it.
    private static func v10(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE plan ADD COLUMN todaySortKey REAL;
            DROP TRIGGER plan_substance_immutable;
            CREATE TRIGGER plan_substance_immutable BEFORE UPDATE ON plan
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId
              OR NEW.localDay IS NOT OLD.localDay OR NEW.at IS NOT OLD.at
              OR NEW.source IS NOT OLD.source OR NEW.todaySortKey IS NOT OLD.todaySortKey
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;
            """)
    }

    /// A repeating task's time slot, and where a block came from (SPEC 2026-11-10).
    private static func v9(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE item ADD COLUMN slot TEXT;
            ALTER TABLE timeBlock ADD COLUMN origin TEXT NOT NULL DEFAULT 'hand' CHECK (origin IN ('hand', 'slot'));
            ALTER TABLE timeBlock ADD COLUMN touchedAt DATETIME;
            ALTER TABLE timeBlock ADD COLUMN askedAt DATETIME;
            ALTER TABLE timeBlock ADD COLUMN releasedAt DATETIME;
            """)
    }

    /// The day timeline's blocks (v1.2): definitions, removed with a tombstone, never
    /// deleted (SPEC decision 2026-11-10). A block's day, item and placing never change.
    private static func v8(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE timeBlock (
                id         TEXT PRIMARY KEY NOT NULL,
                itemId     TEXT NOT NULL REFERENCES item(id),
                localDay   TEXT NOT NULL,
                start      DATETIME NOT NULL,
                minutes    INTEGER NOT NULL CHECK (minutes BETWEEN 15 AND 1500 AND minutes % 15 = 0),
                placedAt   DATETIME NOT NULL,
                updatedAt  DATETIME NOT NULL,
                decidedAt  DATETIME,
                tickId     TEXT REFERENCES checkIn(id),
                coverId    TEXT REFERENCES checkIn(id),
                removedAt  DATETIME
            );
            CREATE INDEX timeBlock_day ON timeBlock(localDay, start);

            CREATE TRIGGER timeBlock_no_delete BEFORE DELETE ON timeBlock
            BEGIN SELECT RAISE(ABORT, 'time blocks are removed with a tombstone, never deleted'); END;

            CREATE TRIGGER timeBlock_fixed BEFORE UPDATE ON timeBlock
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId OR NEW.localDay IS NOT OLD.localDay
              OR NEW.placedAt IS NOT OLD.placedAt
            BEGIN SELECT RAISE(ABORT, 'a time block keeps its task, day and placing'); END;
            """)
    }

    /// Focus sessions (v1.2): facts, voided never deleted (SPEC decision 2026-11-10).
    private static func v7(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE focusSession (
                id        TEXT PRIMARY KEY NOT NULL,
                itemId    TEXT NOT NULL REFERENCES item(id),
                localDay  TEXT NOT NULL,
                at        DATETIME NOT NULL,
                minutes   INTEGER NOT NULL CHECK (minutes BETWEEN 1 AND 720),
                kind      TEXT NOT NULL CHECK (kind IN ('timer', 'manual')),
                voidedAt  DATETIME
            );
            CREATE INDEX focusSession_item ON focusSession(itemId, localDay);

            CREATE TRIGGER focusSession_no_delete BEFORE DELETE ON focusSession
            BEGIN SELECT RAISE(ABORT, 'facts are never deleted'); END;

            CREATE TRIGGER focusSession_substance_immutable BEFORE UPDATE ON focusSession
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId OR NEW.localDay IS NOT OLD.localDay
              OR NEW.at IS NOT OLD.at OR NEW.minutes IS NOT OLD.minutes OR NEW.kind IS NOT OLD.kind
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;

            CREATE TRIGGER focusSession_void_monotonic BEFORE UPDATE ON focusSession
            WHEN OLD.voidedAt IS NOT NULL AND NEW.voidedAt IS NOT OLD.voidedAt
            BEGIN SELECT RAISE(ABORT, 'voids are monotonic'); END;
            """)
    }

    /// Watch progress (v1.1): latest state, one row per item (ARCHITECTURE §4.2).
    private static func v6(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE watchProgress (
                itemId      TEXT PRIMARY KEY NOT NULL REFERENCES item(id),
                fraction    REAL NOT NULL CHECK (fraction BETWEEN 0 AND 1),
                observedAt  DATETIME NOT NULL,
                source      TEXT NOT NULL
            );
            """)
    }

    /// Ratings go from 3 points to 5 (rough, meh, okay, good, great). SQLite cannot
    /// change a CHECK constraint, so the table is rebuilt and its index and fact
    /// triggers recreated. Existing ratings map meh→meh (1→2), fine→okay (2→3),
    /// great→great (3→5); rating is a mutable field (ARCHITECTURE §4.2), so this is not
    /// a change of fact substance. DROP TABLE's implicit delete fires no triggers.
    private static func v5(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE checkIn_new (
                id          TEXT PRIMARY KEY NOT NULL,
                itemId      TEXT NOT NULL REFERENCES item(id),
                localDay    TEXT NOT NULL,
                at          DATETIME NOT NULL,
                timeZoneId  TEXT NOT NULL,
                amount      INTEGER NOT NULL DEFAULT 1 CHECK (amount >= 1),
                rating      INTEGER CHECK (rating BETWEEN 1 AND 5),
                ratedAt     DATETIME,
                source      TEXT NOT NULL,
                voidedAt    DATETIME,
                voidReason  TEXT
            );
            INSERT INTO checkIn_new
                SELECT id, itemId, localDay, at, timeZoneId, amount,
                       CASE rating WHEN 1 THEN 2 WHEN 2 THEN 3 WHEN 3 THEN 5 ELSE rating END,
                       ratedAt, source, voidedAt, voidReason
                FROM checkIn;
            DROP TABLE checkIn;
            ALTER TABLE checkIn_new RENAME TO checkIn;
            CREATE INDEX checkIn_item_day ON checkIn(itemId, localDay);

            CREATE TRIGGER checkIn_no_delete BEFORE DELETE ON checkIn
            BEGIN SELECT RAISE(ABORT, 'facts are never deleted'); END;

            CREATE TRIGGER checkIn_substance_immutable BEFORE UPDATE ON checkIn
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId
              OR NEW.localDay IS NOT OLD.localDay OR NEW.at IS NOT OLD.at
              OR NEW.timeZoneId IS NOT OLD.timeZoneId OR NEW.amount IS NOT OLD.amount
              OR NEW.source IS NOT OLD.source
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;

            CREATE TRIGGER checkIn_void_monotonic BEFORE UPDATE ON checkIn
            WHEN OLD.voidedAt IS NOT NULL
              AND (NEW.voidedAt IS NOT OLD.voidedAt OR NEW.voidReason IS NOT OLD.voidReason)
            BEGIN SELECT RAISE(ABORT, 'voids are monotonic'); END;
            """)
    }

    /// "Still want this?" answers: a fact (never updated in substance, never deleted).
    private static func v4(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE laterReview (
                id        TEXT PRIMARY KEY NOT NULL,
                itemId    TEXT NOT NULL REFERENCES item(id),
                decision  TEXT NOT NULL CHECK (decision IN ('keep', 'letGo')),
                at        DATETIME NOT NULL,
                localDay  TEXT NOT NULL,
                source    TEXT NOT NULL,
                voidedAt  DATETIME
            );
            CREATE INDEX laterReview_item ON laterReview(itemId);

            CREATE TRIGGER laterReview_no_delete BEFORE DELETE ON laterReview
            BEGIN SELECT RAISE(ABORT, 'facts are never deleted'); END;

            CREATE TRIGGER laterReview_substance_immutable BEFORE UPDATE ON laterReview
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId OR NEW.decision IS NOT OLD.decision
              OR NEW.at IS NOT OLD.at OR NEW.localDay IS NOT OLD.localDay OR NEW.source IS NOT OLD.source
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;

            CREATE TRIGGER laterReview_void_monotonic BEFORE UPDATE ON laterReview
            WHEN OLD.voidedAt IS NOT NULL AND NEW.voidedAt IS NOT OLD.voidedAt
            BEGIN SELECT RAISE(ABORT, 'voids are monotonic'); END;
            """)
    }

    /// Reminders and settings: definitions (row-level last writer wins by updatedAt;
    /// reminders are tombstoned, never deleted).
    private static func v3(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE reminder (
                id         TEXT PRIMARY KEY NOT NULL,
                itemId     TEXT NOT NULL REFERENCES item(id),
                hour       INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),
                minute     INTEGER NOT NULL CHECK (minute BETWEEN 0 AND 59),
                enabled    BOOLEAN NOT NULL,
                updatedAt  DATETIME NOT NULL,
                deletedAt  DATETIME
            );
            -- One live reminder per item (SPEC §6: one notification at a chosen time).
            CREATE UNIQUE INDEX reminder_item ON reminder(itemId) WHERE deletedAt IS NULL;

            CREATE TRIGGER reminder_no_delete BEFORE DELETE ON reminder
            BEGIN SELECT RAISE(ABORT, 'reminders are soft-deleted, never deleted'); END;

            CREATE TABLE settings (
                key        TEXT PRIMARY KEY NOT NULL,
                value      TEXT NOT NULL,   -- JSON
                updatedAt  DATETIME NOT NULL
            );
            """)
    }

    /// Goal rounds (a fact), and where each item's title came from.
    private static func v2(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE item ADD COLUMN titleOrigin TEXT NOT NULL DEFAULT 'typed'
                CHECK (titleOrigin IN ('typed', 'fetched'));

            CREATE TABLE goalRound (
                id         TEXT PRIMARY KEY NOT NULL,
                itemId     TEXT NOT NULL REFERENCES item(id),
                startedAt  DATETIME NOT NULL,
                localDay   TEXT NOT NULL,
                target     INTEGER NOT NULL CHECK (target >= 1),
                source     TEXT NOT NULL,
                voidedAt   DATETIME
            );
            CREATE INDEX goalRound_item ON goalRound(itemId, startedAt);

            CREATE TRIGGER goalRound_no_delete BEFORE DELETE ON goalRound
            BEGIN SELECT RAISE(ABORT, 'facts are never deleted'); END;

            CREATE TRIGGER goalRound_substance_immutable BEFORE UPDATE ON goalRound
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId
              OR NEW.startedAt IS NOT OLD.startedAt OR NEW.localDay IS NOT OLD.localDay
              OR NEW.target IS NOT OLD.target OR NEW.source IS NOT OLD.source
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;

            CREATE TRIGGER goalRound_void_monotonic BEFORE UPDATE ON goalRound
            WHEN OLD.voidedAt IS NOT NULL AND NEW.voidedAt IS NOT OLD.voidedAt
            BEGIN SELECT RAISE(ABORT, 'voids are monotonic'); END;
            """)
    }

    private static func v1(_ db: Database) throws {
        // Definitions: edited freely, soft-deleted (ADR-2).
        try db.execute(sql: """
            CREATE TABLE item (
                id          TEXT PRIMARY KEY NOT NULL,
                kind        TEXT NOT NULL CHECK (kind IN ('once', 'habit', 'goal', 'link')),
                title       TEXT NOT NULL,
                url         TEXT,
                note        TEXT,
                parentId    TEXT REFERENCES item(id),
                schedule    TEXT NOT NULL,   -- versioned JSON (Schedule)
                progress    TEXT NOT NULL,   -- versioned JSON (ProgressSpec)
                state       TEXT NOT NULL CHECK (state IN ('active', 'later', 'paused', 'archived')),
                plannedDay  TEXT,            -- YYYY-MM-DD
                sortKey     REAL NOT NULL,
                source      TEXT NOT NULL,
                externalRef TEXT,
                createdAt   DATETIME NOT NULL,
                updatedAt   DATETIME NOT NULL,
                deletedAt   DATETIME
            );
            CREATE UNIQUE INDEX item_source_externalRef ON item(source, externalRef)
                WHERE externalRef IS NOT NULL;
            CREATE INDEX item_state ON item(state) WHERE deletedAt IS NULL;

            -- Tombstones, never hard deletes (ARCHITECTURE §8).
            CREATE TRIGGER item_no_delete BEFORE DELETE ON item
            BEGIN SELECT RAISE(ABORT, 'items are soft-deleted, never deleted'); END;
            """)

        // Facts: inserted, never updated in substance, never deleted (ADR-2, AGENTS.md
        // rule 6). The only mutable CheckIn fields are rating/ratedAt and the
        // monotonic voidedAt/voidReason (ARCHITECTURE §4.2).
        try db.execute(sql: """
            CREATE TABLE checkIn (
                id          TEXT PRIMARY KEY NOT NULL,
                itemId      TEXT NOT NULL REFERENCES item(id),
                localDay    TEXT NOT NULL,   -- YYYY-MM-DD, computed once at creation
                at          DATETIME NOT NULL,
                timeZoneId  TEXT NOT NULL,
                amount      INTEGER NOT NULL DEFAULT 1 CHECK (amount >= 1),
                rating      INTEGER CHECK (rating BETWEEN 1 AND 3),
                ratedAt     DATETIME,
                source      TEXT NOT NULL,
                voidedAt    DATETIME,
                voidReason  TEXT
            );
            CREATE INDEX checkIn_item_day ON checkIn(itemId, localDay);

            CREATE TRIGGER checkIn_no_delete BEFORE DELETE ON checkIn
            BEGIN SELECT RAISE(ABORT, 'facts are never deleted'); END;

            CREATE TRIGGER checkIn_substance_immutable BEFORE UPDATE ON checkIn
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId
              OR NEW.localDay IS NOT OLD.localDay OR NEW.at IS NOT OLD.at
              OR NEW.timeZoneId IS NOT OLD.timeZoneId OR NEW.amount IS NOT OLD.amount
              OR NEW.source IS NOT OLD.source
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;

            CREATE TRIGGER checkIn_void_monotonic BEFORE UPDATE ON checkIn
            WHEN OLD.voidedAt IS NOT NULL
              AND (NEW.voidedAt IS NOT OLD.voidedAt OR NEW.voidReason IS NOT OLD.voidReason)
            BEGIN SELECT RAISE(ABORT, 'voids are monotonic'); END;
            """)

        try db.execute(sql: """
            CREATE TABLE plan (
                id        TEXT PRIMARY KEY NOT NULL,
                itemId    TEXT NOT NULL REFERENCES item(id),
                localDay  TEXT NOT NULL,
                at        DATETIME NOT NULL,
                source    TEXT NOT NULL,
                voidedAt  DATETIME
            );
            CREATE INDEX plan_item ON plan(itemId);

            CREATE TRIGGER plan_no_delete BEFORE DELETE ON plan
            BEGIN SELECT RAISE(ABORT, 'facts are never deleted'); END;

            CREATE TRIGGER plan_substance_immutable BEFORE UPDATE ON plan
            WHEN NEW.id IS NOT OLD.id OR NEW.itemId IS NOT OLD.itemId
              OR NEW.localDay IS NOT OLD.localDay OR NEW.at IS NOT OLD.at
              OR NEW.source IS NOT OLD.source
            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;

            CREATE TRIGGER plan_void_monotonic BEFORE UPDATE ON plan
            WHEN OLD.voidedAt IS NOT NULL AND NEW.voidedAt IS NOT OLD.voidedAt
            BEGIN SELECT RAISE(ABORT, 'voids are monotonic'); END;
            """)
    }
}
