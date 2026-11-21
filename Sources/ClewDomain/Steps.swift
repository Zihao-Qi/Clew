import Foundation

/// A step of a one-off task (SPEC "Steps in a task", 2026-11-21): a definition, edited
/// freely and removed with a tombstone, never deleted (ADR-2). Steps live in their own
/// table, not as items, so nothing that lists or counts items ever sees one.
public struct Step: Hashable, Sendable, Identifiable, Codable {
    public let id: UUID
    /// The task it belongs to; never changes.
    public let taskId: UUID
    public var title: String
    /// Its place among its task's steps.
    public var sortKey: Double
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID, taskId: UUID, title: String, sortKey: Double, createdAt: Date, updatedAt: Date,
                deletedAt: Date? = nil) {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.sortKey = sortKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// A step ticked: a fact, voided never deleted. Step ticks never count as a task done
/// (only the task's own `CheckIn` does), so they are kept apart from check-ins.
public struct StepTick: Hashable, Sendable, Identifiable, Codable {
    public let id: UUID
    public let stepId: UUID
    public let taskId: UUID
    public let localDay: LocalDay
    public let at: Date
    public let source: Source
    /// The task's check-in this tick made, when it was the last open step. The tick
    /// stands only while that check-in does: unticking the task opens this step again
    /// (SPEC: "when the tick came from its last step, that step is open again").
    public let finishedCheckInId: UUID?
    public var voidedAt: Date?

    public init(id: UUID, stepId: UUID, taskId: UUID, localDay: LocalDay, at: Date, source: Source,
                finishedCheckInId: UUID? = nil, voidedAt: Date? = nil) {
        self.id = id
        self.stepId = stepId
        self.taskId = taskId
        self.localDay = localDay
        self.at = at
        self.source = source
        self.finishedCheckInId = finishedCheckInId
        self.voidedAt = voidedAt
    }
}

/// A task's steps as shown: done steps first in the order they were done, then the open
/// ones in the user's order (SPEC 2026-11-21). Derived, never stored.
public struct TaskSteps: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let step: Step
        /// When it was done: its own tick, or the task's when the task was finished at once.
        public let doneAt: Date?
        public var id: UUID { step.id }
        public var isDone: Bool { doneAt != nil }
    }

    public let taskId: UUID
    public let entries: [Entry]

    public var total: Int { entries.count }
    public var done: Int { entries.filter(\.isDone).count }
    public var isEmpty: Bool { entries.isEmpty }
    /// The open steps, in the user's order.
    public var open: [Entry] { entries.filter { !$0.isDone } }
    /// Share done, for the row's bar.
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

    public init(taskId: UUID, entries: [Entry]) {
        self.taskId = taskId
        self.entries = entries
    }

    /// `steps`: the task's live steps. `ticks`: its live (not voided) step ticks.
    /// `taskTicks`: the task's live check-ins (any day): while one stands, the task is
    /// done and so is every step. A tick that finished the task stands only while that
    /// check-in does.
    public static func make(taskId: UUID, steps: [Step], ticks: [StepTick], taskTicks: [CheckIn]) -> TaskSteps {
        let live = steps.filter { $0.taskId == taskId && $0.deletedAt == nil }
        let taskTickIds = Set(taskTicks.filter { $0.itemId == taskId && !$0.isVoided }.map(\.id))
        let taskDoneAt = taskTicks.filter { $0.itemId == taskId && !$0.isVoided }.map(\.at).min()
        var own: [UUID: Date] = [:]
        for t in ticks where t.taskId == taskId && t.voidedAt == nil {
            if let finished = t.finishedCheckInId, !taskTickIds.contains(finished) { continue }
            own[t.stepId] = min(own[t.stepId] ?? t.at, t.at)
        }
        let entries = live.map { s in Entry(step: s, doneAt: own[s.id] ?? taskDoneAt) }
        let done = entries.filter(\.isDone).sorted { a, b in
            (a.doneAt!, a.step.sortKey, a.step.id.uuidString) < (b.doneAt!, b.step.sortKey, b.step.id.uuidString)
        }
        let open = entries.filter { !$0.isDone }.sorted { a, b in
            (a.step.sortKey, a.step.createdAt, a.step.id.uuidString) < (b.step.sortKey, b.step.createdAt, b.step.id.uuidString)
        }
        return TaskSteps(taskId: taskId, entries: done + open)
    }
}
