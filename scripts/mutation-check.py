#!/usr/bin/env python3
"""Mutation check for AGENTS.md rule 1: every test must fail against a deliberately
broken implementation.

Each entry breaks one rule in the source on purpose, runs the named test targets and
reports which tests failed. "SURVIVED" means no test noticed: add or fix a test.
"PATTERN NOT UNIQUE" means the source moved on; update or drop that entry. The
source file is always restored, even on error.

  python3 -I scripts/mutation-check.py . [first] [last]      # default: all
"""
import json, pathlib, re, subprocess, sys

repo = pathlib.Path(sys.argv[1])
D, C, S = "Sources/ClewDomain/", "Sources/ClewCore/", "Sources/ClewStore/"
M = [
 # Domain
 ("D1 naive instant-4h", D+"LocalDay.swift", "self = hour < rolloverHour ? wallDay.adding(days: -1) : wallDay",
  "self = { let c2 = calendar.dateComponents([.year, .month, .day], from: instant.addingTimeInterval(-Double(rolloverHour) * 3600)); return LocalDay(year: c2.year!, month: c2.month!, day: c2.day!)! }()", "ClewDomainTests"),
 ("D2 <= rollover", D+"LocalDay.swift", "hour < rolloverHour ?", "hour <= rolloverHour ?", "ClewDomainTests"),
 ("D3 ignore zone", D+"LocalDay.swift", "        calendar.timeZone = zone\n        let c =", "        calendar.timeZone = TimeZone(identifier: \"UTC\")!\n        let c =", "ClewDomainTests"),
 ("D4 sunday weeks", D+"LocalDay.swift", "adding(days: -(weekday.rawValue - 1))", "adding(days: -(weekday.rawValue % 7))", "ClewDomainTests"),
 ("D5 weekday offset", D+"LocalDay.swift", "((ordinal + 3) % 7 + 7) % 7", "((ordinal + 4) % 7 + 7) % 7", "ClewDomainTests"),
 ("D6 leap rule", D+"LocalDay.swift", "(year % 4 == 0 && year % 100 != 0) || year % 400 == 0", "year % 4 == 0", "ClewDomainTests"),
 ("D7 civil bug", D+"LocalDay.swift", "let y = yoe + era * 400 + (m <= 2 ? 1 : 0)", "let y = yoe + era * 400", "ClewDomainTests"),
 ("D8 lax parse", D+"LocalDay.swift", "parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,", "parts.count == 3,", "ClewDomainTests"),
 ("D9 rollover same day", D+"LocalDay.swift", "year: next.year, month: next.month, day: next.day", "year: today.year, month: today.month, day: today.day", "ClewDomainTests"),
 ("D10 future once", D+"Today.swift", "planned <= day else", "planned <= day.adding(days: 99) else", "ClewDomainTests"),
 ("D11 once done earlier", D+"Today.swift", "return facts.lifetimeAmount > 0 ? .notDue : .due", "return .due", "ClewDomainTests"),
 ("D12 voided counts", D+"Today.swift", "recent.lazy.filter { !$0.isVoided && $0.localDay == day }", "recent.lazy.filter { $0.localDay == day }", "ClewDomainTests"),
 ("D13 state ignored", D+"Today.swift", "guard item.state == .active, item.deletedAt == nil else { return .notDue }", "", "ClewDomainTests"),
 ("D14 weekdays always", D+"Today.swift", "return days.contains(day.weekday) ? .due : .notDue", "return .due", "ClewDomainTests"),
 ("D15 >n", D+"Today.swift", "facts.distinctDays(inWeekOf: day) >= n", "facts.distinctDays(inWeekOf: day) > n", "ClewDomainTests"),
 ("D16 non-distinct", D+"Today.swift", "Set(recent.lazy.filter { !$0.isVoided && $0.localDay.isInSameWeek(as: day) }.map(\\.localDay)).count", "recent.lazy.filter { !$0.isVoided && $0.localDay.isInSameWeek(as: day) }.count", "ClewDomainTests"),
 ("D17 goal never finishes", D+"Today.swift", "facts.lifetimeAmount >= target, !tickedToday", "facts.lifetimeAmount >= target + 1_000_000, !tickedToday", "ClewDomainTests"),
 ("D18 show satisfied", D+"Today.swift", "guard state == .due || state == .doneToday else", "guard state != .notDue else", "ClewDomainTests"),
 ("D19 ignore sortKey", D+"Today.swift", ".sorted { ($0.sortKey, $0.createdAt, $0.id.uuidString) < ($1.sortKey, $1.createdAt, $1.id.uuidString) }", ".sorted { $0.id.uuidString < $1.id.uuidString }", "ClewDomainTests"),
 ("D20 lifetime=today", D+"Today.swift", "lifetimeAmount: f.lifetimeAmount)", "lifetimeAmount: f.amount(on: day))", "ClewDomainTests"),
 ("D21 json key", D+"Item.swift", "case v, type, days, times", "case v, type, days = \"weekdays\", times", "ClewDomainTests"),
 ("D22 version ignored", D+"Item.swift", "        guard v == Self.version else {\n            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: \"Unknown schedule version \\(v)\")\n        }", "        _ = v", "ClewDomainTests"),
 ("D23 day as int", D+"LocalDay.swift", "try container.encode(description)", "try container.encode(ordinal)", "ClewDomainTests"),
 # Core
 ("C1 no trim", C+"Clew.swift", "let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)", "let title = raw", "ClewCoreTests"),
 ("C2 wall-day plan", C+"Clew.swift", "    public func currentDay() -> LocalDay {\n        LocalDay(of: clock.now(), in: zones.current(), rolloverHour: rolloverHour)", "    public func currentDay() -> LocalDay {\n        LocalDay(of: clock.now(), in: zones.current(), rolloverHour: 0)", "ClewCoreTests"),
 ("C3 later never link", C+"Clew.swift", "(url == nil ? .once : .link,", "(.once,", "ClewCoreTests"),
 ("C4 sortKey 0", C+"Clew.swift", "sortKey: (try w.maxSortKey() ?? 0) + 1,", "sortKey: 0,", "ClewCoreTests"),
 ("C5a no max title", C+"Clew.swift", "guard title.count <= maxTitleLength else", "guard title.count <= 10_000 else", "ClewCoreTests"),
 ("C5b any scheme", C+"Clew.swift", "scheme == \"http\" || scheme == \"https\",\n              let host = url.host, !host.isEmpty\n        else { throw ClewError.invalidURL }", "!scheme.isEmpty\n        else { throw ClewError.invalidURL }", "ClewCoreTests"),
 ("C5c target 0", C+"Clew.swift", "(1...maxTarget).contains(target)", "(0...maxTarget).contains(target)", "ClewCoreTests"),
 ("C5d empty weekdays", C+"Clew.swift", "case .weekdays(let days): guard !days.isEmpty else { throw ClewError.invalidSchedule }", "case .weekdays: break", "ClewCoreTests"),
 ("C5e 8 per week", C+"Clew.swift", "(1...7).contains(n)", "(1...8).contains(n)", "ClewCoreTests"),
 ("C6 no once-per-day", C+"Clew.swift", "if let existing = try w.checkIns(itemIds: [itemId], from: day).first(where: { $0.localDay == day }) {\n                    return existing\n                }", "", "ClewCoreTests"),
 ("C7 goal like habit", C+"Clew.swift", "if item.kind != .goal {", "if true {", "ClewCoreTests"),
 ("C8 zone/source", C+"Clew.swift", "timeZoneId: zone.identifier,\n                amount: 1, source: source", "timeZoneId: \"UTC\",\n                amount: 1, source: .user", "ClewCoreTests"),
 ("C9 tick later", C+"Clew.swift", "guard item.state == .active else { throw ClewError.notAllowed }\n            if item.kind", "if item.kind", "ClewCoreTests"),
 ("C10 redo once", C+"Clew.swift", "(try w.lifetimeAmounts(itemIds: [itemId])[itemId] ?? 0) > 0 {\n                    throw", "(try w.lifetimeAmounts(itemIds: [itemId])[itemId] ?? 0) > 1_000 {\n                    throw", "ClewCoreTests"),
 ("C11 undo first", C+"Clew.swift", "todays.max(by:", "todays.min(by:", "ClewCoreTests"),
 ("C12 undo any day", C+"Clew.swift", "let todays = try w.checkIns(itemIds: [itemId], from: day).filter { $0.localDay == day }", "let todays = try w.checkIns(itemIds: [itemId], from: day.adding(days: -7))", "ClewCoreTests"),
 ("C13 revoid", C+"Clew.swift", "guard !checkIn.isVoided else { return }", "", "ClewCoreTests"),
 ("C14 no plan fact", C+"Clew.swift", "try w.insert(Plan(id: makeID(), itemId: id, localDay: day, at: now, source: source))", "", "ClewCoreTests"),
 ("C15 no dedupe", C+"Clew.swift", "let ids = itemIds.filter { seen.insert($0).inserted }", "let ids = itemIds; _ = seen", "ClewCoreTests"),
 ("C16 four picks", C+"Clew.swift", "public static let maxPicks = 3", "public static let maxPicks = 4", "ClewCoreTests"),
 ("C17 pick any state", C+"Clew.swift", "guard item.state == .later else { throw ClewError.notAllowed }\n                sortKey", "sortKey", "ClewCoreTests"),
 ("C18 later habits", C+"Clew.swift", "guard item.kind == .once || item.kind == .link, item.state == .active,", "guard item.state == .active,", "ClewCoreTests"),
 ("C19 keep plannedDay", C+"Clew.swift", "            item.state = .later\n            item.plannedDay = nil", "            item.state = .later", "ClewCoreTests"),
 ("C20 later oldest first", C+"Clew.swift", "($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString)", "($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)", "ClewCoreTests"),
 ("C21 no updatedAt", C+"Clew.swift", "            item.title = title\n            item.url = url\n            item.updatedAt = now", "            item.title = title\n            item.url = url", "ClewCoreTests"),
 ("C22 once schedule ok", C+"Clew.swift", "guard edit.schedule == nil, edit.target == nil else { throw ClewError.notAllowed }", "break", "ClewCoreTests"),
 ("C23 no archive", C+"Clew.swift", "item.state = .archived", "item.state = .paused; item.state = .active", "ClewCoreTests"),
 ("C24 week from today", C+"Clew.swift", "r.checkIns(itemIds: ids, from: day.weekStart)", "r.checkIns(itemIds: ids, from: day)", "ClewCoreTests"),
 ("C25 lifetime=recent", C+"Clew.swift", "lifetimeAmount: lifetime[id] ?? 0)", "lifetimeAmount: (recent[id] ?? []).reduce(0) { $0 + $1.amount }); _ = lifetime", "ClewCoreTests"),
 ("C26 keep www", C+"QuickEntry.swift", "if host.hasPrefix(\"www.\") { host.removeFirst(4) }", "", "ClewCoreTests"),
 ("C27 url first only", C+"QuickEntry.swift", "words.firstIndex(where: { webURL($0) != nil })", "(words.first.flatMap { webURL($0) } != nil ? 0 : nil)", "ClewCoreTests"),
 ("C28 any scheme entry", C+"QuickEntry.swift", "scheme == \"http\" || scheme == \"https\", let host = url.host, !host.isEmpty", "!scheme.isEmpty", "ClewCoreTests"),
 ("C29 no collapse", C+"QuickEntry.swift", "return Parsed(title: words.joined(separator: \" \"), url: nil, isBareLink: false)", "return Parsed(title: text, url: nil, isBareLink: false)", "ClewCoreTests"),
 ("C30 no truncation", C+"QuickEntry.swift", "return full.count > 80 ? String(full.prefix(79)) + \"…\" : full", "return full", "ClewCoreTests"),
 # Store
 ("S1 no substance trigger", S+"Schema.swift", "OR NEW.source IS NOT OLD.source\n            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;\n\n            CREATE TRIGGER checkIn_void", "OR NEW.source IS NOT OLD.source\n            BEGIN SELECT 1; END;\n\n            CREATE TRIGGER checkIn_void", "ClewStoreTests"),
 ("S2 amount mutable", S+"Schema.swift", "OR NEW.timeZoneId IS NOT OLD.timeZoneId OR NEW.amount IS NOT OLD.amount", "OR NEW.timeZoneId IS NOT OLD.timeZoneId", "ClewStoreTests"),
 ("S3 unwhen trigger", S+"Schema.swift", "CREATE TRIGGER checkIn_substance_immutable BEFORE UPDATE ON checkIn\n            WHEN NEW.id IS NOT OLD.id", "CREATE TRIGGER checkIn_substance_immutable BEFORE UPDATE OF amount, localDay, at, timeZoneId, source, itemId ON checkIn\n            WHEN 1 OR NEW.id IS NOT OLD.id", "ClewStoreTests"),
 ("S4 revoid ok", S+"Schema.swift", "WHEN OLD.voidedAt IS NOT NULL\n              AND", "WHEN 0 AND OLD.voidedAt IS NOT NULL\n              AND", "ClewStoreTests"),
 ("S5 checkIn delete ok", S+"Schema.swift", "CREATE TRIGGER checkIn_no_delete BEFORE DELETE ON checkIn\n            BEGIN", "CREATE TRIGGER checkIn_no_delete BEFORE DELETE ON checkIn WHEN 0\n            BEGIN", "ClewStoreTests"),
 ("S6 item delete ok", S+"Schema.swift", "CREATE TRIGGER item_no_delete BEFORE DELETE ON item\n            BEGIN", "CREATE TRIGGER item_no_delete BEFORE DELETE ON item WHEN 0\n            BEGIN", "ClewStoreTests"),
 ("S7 plan delete ok", S+"Schema.swift", "CREATE TRIGGER plan_no_delete BEFORE DELETE ON plan\n            BEGIN", "CREATE TRIGGER plan_no_delete BEFORE DELETE ON plan WHEN 0\n            BEGIN", "ClewStoreTests"),
 ("S8 plan mutable", S+"Schema.swift", "OR NEW.source IS NOT OLD.source\n            BEGIN SELECT RAISE(ABORT, 'fact substance is immutable'); END;\n\n            CREATE TRIGGER plan_void", "OR NEW.source IS NOT OLD.source\n            BEGIN SELECT 1; END;\n\n            CREATE TRIGGER plan_void", "ClewStoreTests"),
 ("S9 plan revoid", S+"Schema.swift", "WHEN OLD.voidedAt IS NOT NULL AND NEW.voidedAt IS NOT OLD.voidedAt", "WHEN 0", "ClewStoreTests"),
 ("S10 voided in recent", S+"SQLiteStore.swift", "AND localDay >= ? AND voidedAt IS NULL", "AND localDay >= ?", "ClewStoreTests"),
 ("S11 voided in lifetime", S+"SQLiteStore.swift", "WHERE itemId IN (\\(Self.marks(itemIds.count))) AND voidedAt IS NULL\n                GROUP BY", "WHERE itemId IN (\\(Self.marks(itemIds.count)))\n                GROUP BY", "ClewStoreTests"),
 ("S12 deleted listed", S+"SQLiteStore.swift", "WHERE deletedAt IS NULL AND state IN", "WHERE state IN", "ClewStoreTests"),
 ("S13 no transaction", S+"SQLiteStore.swift", "try writer.write { db in try body(Access(db)) }", "try writer.writeWithoutTransaction { db in try body(Access(db)) }", "ClewStoreTests"),
 ("S14 observe plan only", S+"SQLiteStore.swift", "DatabaseRegionObservation(tracking: Table(\"item\"), Table(\"checkIn\"), Table(\"plan\"))", "DatabaseRegionObservation(tracking: Table(\"plan\"))", "ClewStoreTests"),
 ("S15 note dropped", S+"SQLiteStore.swift", "            note: row[\"note\"],", "            note: nil,", "ClewStoreTests"),
 ("S16 memory db", S+"SQLiteStore.swift", "return try SQLiteStore(writer: DatabasePool(path: url.path))", "return try SQLiteStore(writer: DatabaseQueue())", "ClewStoreTests"),
 ("S17 update ignores state", S+"SQLiteStore.swift", "progress = ?, state = ?, plannedDay = ?,", "progress = ?, state = state, plannedDay = ?, sortKey = sortKey + 0 * ?,", "ClewStoreTests"),
 ("D24 no rollover", D+"LocalDay.swift", "self = hour < rolloverHour ? wallDay.adding(days: -1) : wallDay", "self = wallDay", "ClewDomainTests"),
 ("D25 once same day only", D+"Today.swift", "planned <= day else", "planned == day else", "ClewDomainTests|ClewCoreTests"),
 ("D26 once ticked hidden", D+"Today.swift", "        if tickedToday { return .doneToday }\n        return facts.lifetimeAmount", "        return facts.lifetimeAmount", "ClewDomainTests"),
 ("D27 ticked any day", D+"Today.swift", "let tickedToday = facts.amount(on: day) > 0", "let tickedToday = facts.recent.contains { !$0.isVoided }", "ClewDomainTests"),
 ("D28 weekday decode", D+"Item.swift", "self = .weekdays(Set(try c.decode([Weekday].self, forKey: .days)))", "self = .weekdays([.monday])", "ClewDomainTests"),
 ("C31 undo returns stale", C+"Clew.swift", "return try w.checkIn(id: last.id)", "return last", "ClewCoreTests"),
]

lo = int(sys.argv[2]) if len(sys.argv) > 2 else 0
hi = int(sys.argv[3]) if len(sys.argv) > 3 else len(M)
results = []
for name, path, old, new, flt in M[lo:hi]:
    f = repo / path
    orig = f.read_text()
    if orig.count(old) != 1:
        results.append((name, f"PATTERN NOT UNIQUE ({orig.count(old)})", []))
        continue
    try:
        f.write_text(orig.replace(old, new))
        p = subprocess.run(["swift", "test", "--filter", flt], cwd=repo, capture_output=True, text=True, timeout=600)
        out = p.stdout + p.stderr
        failed = sorted(set(re.findall(r"✘ Test (\w+)\(", out)))
        if "error: compile" in out.lower() or ("error:" in out and not failed and "Build complete" not in out and p.returncode != 0 and "✘" not in out):
            verdict = "COMPILE ERROR"
            failed = [l for l in out.splitlines() if "error:" in l][:2]
        else:
            verdict = "KILLED" if failed else "SURVIVED"
        results.append((name, verdict, failed))
    finally:
        f.write_text(orig)
for name, verdict, failed in results:
    print(f"{name:28} {verdict:10} {', '.join(failed)}")
