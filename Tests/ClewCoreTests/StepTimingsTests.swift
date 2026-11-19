import ClewCore
import Foundation
import Testing

/// SPEC 2026-11-19, "Slow refreshes are logged on this Mac".
@Suite struct StepTimingsTests {
    /// A clock that returns the given readings in turn (seconds).
    final class Readings: @unchecked Sendable {
        private let lock = NSLock()
        private var left: ArraySlice<Double>
        init(_ readings: [Double]) { left = readings[...] }
        func next() -> Double { lock.lock(); defer { lock.unlock() }; return left.popFirst() ?? 0 }
    }
    func clock(_ readings: [Double]) -> @Sendable () -> Double {
        let r = Readings(readings)
        return { r.next() }
    }

    @Test func stepsAreTheTimeBetweenMarks() {
        var t = StepTimings(now: clock([10.000, 10.020, 10.300, 10.305]))
        t.mark("today")
        t.mark("calendar")
        t.mark("focus")
        #expect(t.steps.map(\.name) == ["today", "calendar", "focus"])
        #expect(t.steps.map { Int($0.milliseconds.rounded()) } == [20, 280, 5])
        #expect(Int(t.totalMilliseconds.rounded()) == 305)
    }

    @Test func aQuickRefreshIsNotReported() {
        var t = StepTimings(now: clock([0, 0.040, 0.099]))
        t.mark("today"); t.mark("calendar")
        #expect(t.report("refresh") == nil)                                  // 99 ms
        var at = StepTimings(now: clock([0, 0.050, 0.100]))
        at.mark("today"); at.mark("calendar")
        #expect(at.report("refresh") == "refresh 100 ms: today 50, calendar 50")   // 100 ms: reported
    }

    @Test func aSlowRefreshNamesItsSlowestStepsFirst() {
        var t = StepTimings(now: clock([0, 0.020, 0.300, 0.3004, 0.310, 0.318, 0.330]))
        for name in ["today", "calendar", "settings", "focus", "schedule", "notifications"] { t.mark(name) }
        // Slowest first, at most four, under 1 ms left out.
        #expect(t.report("refresh") == "refresh 330 ms: calendar 280, today 20, notifications 12, focus 10")
        #expect(t.report("refresh", top: 2) == "refresh 330 ms: calendar 280, today 20")
        #expect(t.report("refresh", threshold: 400) == nil)
        // A step under 1 ms is left out even when there is room for it.
        var tiny = StepTimings(now: clock([0, 0.1500, 0.1504]))
        tiny.mark("today"); tiny.mark("focus")
        #expect(tiny.report("refresh") == "refresh 150 ms: today 150")
    }
}
