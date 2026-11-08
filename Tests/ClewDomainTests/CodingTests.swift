import ClewDomain
import Foundation
import Testing

/// The stored JSON shape is a contract: rows written today must decode after any
/// refactor of the Swift enums.
@Suite struct CodingTests {
    private func encode(_ value: some Encodable) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    @Test func scheduleJSONIsVersionedAndStable() throws {
        #expect(try encode(Schedule.daily) == #"{"type":"daily","v":1}"#)
        #expect(try encode(Schedule.weekdays([.friday, .monday])) == #"{"days":[1,5],"type":"weekdays","v":1}"#)
        #expect(try encode(Schedule.timesPerWeek(3)) == #"{"times":3,"type":"timesPerWeek","v":1}"#)
        #expect(try encode(Schedule.unscheduled) == #"{"type":"unscheduled","v":1}"#)
        #expect(try encode(ProgressSpec.counter(target: 30)) == #"{"target":30,"type":"counter","v":1}"#)
        #expect(try encode(ProgressSpec.none) == #"{"type":"none","v":1}"#)
    }

    @Test func scheduleRoundTrips() throws {
        for s: Schedule in [.daily, .weekdays([.sunday, .tuesday]), .timesPerWeek(4), .unscheduled] {
            let back = try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(s))
            #expect(back == s)
        }
    }

    @Test func unknownVersionOrTypeIsRejected() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Schedule.self, from: Data(#"{"v":2,"type":"daily"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Schedule.self, from: Data(#"{"v":1,"type":"fortnightly"}"#.utf8))
        }
    }

    @Test func localDayEncodesAsISODateString() throws {
        #expect(try encode([LocalDay(string: "2026-11-08")!]) == #"["2026-11-08"]"#)
    }
}
