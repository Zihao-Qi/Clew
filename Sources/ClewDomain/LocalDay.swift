import Foundation

/// A calendar day as the user lives it (ARCHITECTURE §4.3, ADR-3).
///
/// It is computed **once**, when a fact is created, and stored with that fact. It is
/// never recomputed from timestamps later. Date arithmetic on `LocalDay` is plain
/// integer arithmetic on the proleptic Gregorian calendar, so it has no time zone,
/// no locale and no DST.
public struct LocalDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Days since 1970-01-01. The single source of truth for ordering and arithmetic.
    public let ordinal: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
        self.ordinal = Self.daysFromCivil(year: year, month: month, day: day)
    }

    public init(ordinal: Int) {
        let (y, m, d) = Self.civilFromDays(ordinal)
        self.year = y
        self.month = m
        self.day = d
        self.ordinal = ordinal
    }

    /// The day the user is living in at `instant`.
    ///
    /// Before `rolloverHour` on the wall clock, it is still the previous day: a tick at
    /// 01:00 counts for the evening you are still in. The comparison is on the **wall
    /// clock** in `zone`, not `instant − rolloverHour` in absolute time, so the two
    /// DST days of the year are handled correctly.
    public init(of instant: Date, in zone: TimeZone, rolloverHour: Int) {
        precondition((0...23).contains(rolloverHour), "rolloverHour must be 0...23")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
        guard let year = c.year, let month = c.month, let day = c.day, let hour = c.hour,
              let wallDay = LocalDay(year: year, month: month, day: day)
        else {
            preconditionFailure("Gregorian calendar returned no date components")
        }
        self = hour < rolloverHour ? wallDay.adding(days: -1) : wallDay
    }

    /// `YYYY-MM-DD`. This is the storage form; it sorts the same as the days.
    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func adding(days: Int) -> LocalDay {
        LocalDay(ordinal: ordinal + days)
    }

    public var weekday: Weekday {
        // 1970-01-01 was a Thursday; Monday is index 0.
        let index = ((ordinal + 3) % 7 + 7) % 7
        return Weekday.allCases[index]
    }

    /// The Monday that starts this day's ISO-8601 week. Weeks start on Monday in every
    /// locale (SPEC decision); `Calendar.current` is never consulted.
    public var weekStart: LocalDay {
        adding(days: -(weekday.rawValue - 1))
    }

    public func isInSameWeek(as other: LocalDay) -> Bool {
        weekStart == other.weekStart
    }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    // MARK: - Civil calendar arithmetic (H. Hinnant, "chrono-compatible low-level date algorithms")

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return (y, m, d)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

extension LocalDay: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = LocalDay(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a YYYY-MM-DD day: \(string)")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// ISO-8601 weekday numbering: Monday = 1 … Sunday = 7.
public enum Weekday: Int, CaseIterable, Codable, Sendable, Comparable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The instant the wall clock in `zone` next reaches `rolloverHour`:00 after `instant`.
/// Used to refresh Today's list when the day changes.
public func nextRollover(after instant: Date, in zone: TimeZone, rolloverHour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let today = LocalDay(of: instant, in: zone, rolloverHour: rolloverHour)
    let next = today.adding(days: 1)
    let components = DateComponents(year: next.year, month: next.month, day: next.day, hour: rolloverHour)
    // If that wall-clock time does not exist (a DST gap), Calendar moves forward to
    // the first valid instant, which is still the start of the new day.
    return calendar.date(from: components) ?? instant.addingTimeInterval(3600)
}
