import Foundation

/// Times the steps of one piece of work, for the slow-refresh log (SPEC 2026-11-19):
/// step names and milliseconds only. The clock is injected (seconds, monotonic), so
/// Core never reads it.
public struct StepTimings: Sendable {
    public struct Step: Equatable, Sendable {
        public let name: String
        public let milliseconds: Double
    }

    public private(set) var steps: [Step] = []
    private let now: @Sendable () -> Double
    private let start: Double
    private var last: Double

    public init(now: @escaping @Sendable () -> Double) {
        self.now = now
        start = now()
        last = start
    }

    /// Ends the step running since the previous mark (or the start).
    public mutating func mark(_ name: String) {
        let t = now()
        steps.append(Step(name: name, milliseconds: (t - last) * 1000))
        last = t
    }

    /// From the start to the last mark.
    public var totalMilliseconds: Double { (last - start) * 1000 }

    /// nil under `threshold` ms; otherwise "refresh 312 ms: calendar 280, today 20",
    /// the slowest `top` steps first, each rounded to whole ms (steps under 1 ms left out).
    public func report(_ label: String, threshold: Double = 100, top: Int = 4) -> String? {
        guard totalMilliseconds >= threshold else { return nil }
        let slowest = steps
            .filter { $0.milliseconds >= 1 }
            .sorted { $0.milliseconds > $1.milliseconds }
            .prefix(top)
            .map { "\($0.name) \(Int($0.milliseconds.rounded()))" }
        return "\(label) \(Int(totalMilliseconds.rounded())) ms: " + slowest.joined(separator: ", ")
    }
}
