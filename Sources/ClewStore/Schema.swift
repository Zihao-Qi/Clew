import GRDB

/// Forward-only, versioned migrations (ARCHITECTURE §7). Never edit a shipped
/// migration; add a new one.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        return migrator
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
