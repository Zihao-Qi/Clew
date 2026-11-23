import ClewDomain
import Foundation

/// Steps in a task (SPEC 2026-11-21): a one-off task split into a few steps, ticked one
/// by one. Only the task's own check-in ever counts as done; steps never count.
extension Clew {
    /// Once tasks and links can have steps; habits, goals and a collection's items cannot.
    public static func canHaveSteps(_ item: Item) -> Bool {
        (item.kind == .once || item.kind == .link) && !isCollectionItem(item)
    }

    /// Before any real day: live check-ins of a once task on any day.
    static let allDays = LocalDay(string: "1970-01-01")!

    /// The steps of these tasks, as shown. Tasks without steps are missing.
    public func steps(taskIds: [UUID]) throws -> [UUID: TaskSteps] {
        try storeForQueries.read { r in try Self.taskSteps(r, taskIds: taskIds) }
    }

    /// One task's steps (empty when it has none).
    public func steps(taskId: UUID) throws -> TaskSteps {
        try steps(taskIds: [taskId])[taskId] ?? TaskSteps(taskId: taskId, entries: [])
    }

    static func taskSteps(_ r: any StoreReader, taskIds: [UUID]) throws -> [UUID: TaskSteps] {
        let steps = try r.steps(taskIds: taskIds)
        guard !steps.isEmpty else { return [:] }
        let ids = Array(Set(steps.map(\.taskId)))
        let ticks = try r.stepTicks(taskIds: ids)
        let taskTicks = try r.checkIns(itemIds: ids, from: allDays)
        var result: [UUID: TaskSteps] = [:]
        for id in ids {
            result[id] = TaskSteps.make(taskId: id, steps: steps, ticks: ticks, taskTicks: taskTicks)
        }
        return result
    }

    /// A live task that can have steps, or an error.
    private static func stepTask(_ r: any StoreReader, _ taskId: UUID) throws -> Item {
        guard let task = try r.item(id: taskId), task.deletedAt == nil else { throw ClewError.itemNotFound }
        guard canHaveSteps(task) else { throw ClewError.notAllowed }
        return task
    }

    private static func isDone(_ r: any StoreReader, _ taskId: UUID) throws -> Bool {
        (try r.progressAmounts(itemIds: [taskId])[taskId] ?? 0) > 0
    }

    /// Add Step… (SPEC 2026-11-21): a new open step after the task's others. On a task
    /// done today it reopens the task (*changed* 2026-11-22, *user*): its tick is undone,
    /// the steps done before stay done. Not on a task done on an earlier day.
    @discardableResult
    public func addStep(taskId: UUID, title: String) throws -> Step {
        let title = try Self.validTitle(title)
        let now = clockForQueries.now()
        let today = currentDay()
        return try storeForQueries.write { w in
            _ = try Self.stepTask(w, taskId)
            if try Self.isDone(w, taskId) { try reopen(taskId, today: today, at: now, w) }
            let last = try w.steps(taskIds: [taskId]).map(\.sortKey).max()
            let step = Step(id: newID(), taskId: taskId, title: title, sortKey: (last ?? 0) + 1,
                            createdAt: now, updatedAt: now)
            try w.save(step)
            return step
        }
    }

    public func renameStep(id: UUID, title: String) throws {
        let title = try Self.validTitle(title)
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard var step = try w.step(id: id), step.deletedAt == nil else { throw ClewError.itemNotFound }
            guard step.title != title else { return }
            step.title = title
            step.updatedAt = now
            try w.save(step)
        }
    }

    /// Inside a write: a task done today is open again. A step tick that finished it
    /// stands only while the task's tick does, so it is replaced by a plain one first:
    /// that step stays done. Steps shown done only because the task's own circle finished
    /// it are open again, as when unticking.
    func reopen(_ taskId: UUID, today: LocalDay, at now: Date, _ w: any StoreWriter) throws {
        let ticks = try w.checkIns(itemIds: [taskId], from: Self.allDays)
        // Done on an earlier day: reopening would change a past day.
        guard !ticks.isEmpty, ticks.allSatisfy({ $0.localDay == today }) else { throw ClewError.notAllowed }
        let finishing = Set(ticks.map(\.id))
        for t in try w.stepTicks(taskIds: [taskId]) {
            guard let made = t.finishedCheckInId, finishing.contains(made) else { continue }
            try w.voidStepTick(id: t.id, at: now)
            try w.insert(StepTick(id: newID(), stepId: t.stepId, taskId: taskId, localDay: t.localDay, at: t.at,
                                  source: t.source, finishedCheckInId: nil))
        }
        for c in ticks { try w.voidCheckIn(id: c.id, at: now, reason: "undo") }
    }

    /// Delete a step: a tombstone. It never ticks or unticks the task (SPEC 2026-11-21).
    /// Its blocks of today go with it, in the same write.
    public func deleteStep(id: UUID) throws {
        let now = clockForQueries.now()
        let today = currentDay()
        try storeForQueries.write { w in
            guard var step = try w.step(id: id) else { throw ClewError.itemNotFound }
            guard step.deletedAt == nil else { return }
            step.deletedAt = now
            step.updatedAt = now
            try w.save(step)
            for var b in try w.timeBlocks(from: today) where b.stepId == id && b.removedAt == nil {
                b.removedAt = now
                b.updatedAt = now
                try w.save(b)
            }
        }
    }

    /// The Undo of "Deleted “Practice”": the step comes back where it was, with its ticks
    /// and without its blocks (as a task's Undo).
    public func undeleteStep(id: UUID) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard var step = try w.step(id: id), step.deletedAt != nil else { throw ClewError.notAllowed }
            step.deletedAt = nil
            step.updatedAt = now
            try w.save(step)
        }
    }

    /// Reorder (SPEC 2026-11-21): an open step goes to `index` among its task's open steps.
    /// Done steps keep their place (they are listed by when they were done).
    public func moveStep(id: UUID, toOpenIndex index: Int) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard let moving = try w.step(id: id), moving.deletedAt == nil else { throw ClewError.itemNotFound }
            let shown = try Self.taskSteps(w, taskIds: [moving.taskId])[moving.taskId]
            let open = (shown?.open ?? []).map(\.step)
            guard open.contains(where: { $0.id == id }) else { throw ClewError.notAllowed }
            var order = open.filter { $0.id != id }
            let to = min(max(index, 0), order.count)
            order.insert(moving, at: to)
            guard order.map(\.id) != open.map(\.id) else { return }
            // Midway between its new neighbours; every open step renumbered when there is
            // no room between them.
            let before = to > 0 ? order[to - 1].sortKey : nil
            let after = to + 1 < order.count ? order[to + 1].sortKey : nil
            var key: Double
            switch (before, after) {
            case let (b?, a?): key = (b + a) / 2
            case let (b?, nil): key = b + 1
            case let (nil, a?): key = a - 1
            default: key = moving.sortKey
            }
            if let b = before, let a = after, !(key > b && key < a) {
                for (i, var s) in order.enumerated() where s.sortKey != Double(i + 1) || s.id == id {
                    s.sortKey = Double(i + 1)
                    s.updatedAt = now
                    try w.save(s)
                }
                return
            }
            var moved = moving
            moved.sortKey = key
            moved.updatedAt = now
            try w.save(moved)
        }
    }

    /// Ticks a step. The last open step finishes the task: its check-in is made in the
    /// same write, and returned (nil otherwise). Nothing happens for a step already done,
    /// or a done task (all its steps show done).
    @discardableResult
    public func tickStep(id: UUID, source: Source = .user) throws -> CheckIn? {
        let now = clockForQueries.now()
        let zone = zonesForQueries.current()
        let day = LocalDay(of: now, in: zone, rolloverHour: rolloverHour)
        return try storeForQueries.write { w in
            guard let step = try w.step(id: id), step.deletedAt == nil else { throw ClewError.itemNotFound }
            let task = try Self.stepTask(w, step.taskId)
            guard task.state == .active || task.state == .later else { throw ClewError.notAllowed }
            return try tickStep(step, day: day, at: now, zone: zone, source: source, w)?.finished
        }
    }

    /// Inside a write: ticks an open step for `day` (a step block's end ticks for its own
    /// day). Nil when the step is not open (done, or its task is).
    func tickStep(_ step: Step, day: LocalDay, at now: Date, zone: TimeZone, source: Source,
                  _ w: any StoreWriter) throws -> (tick: StepTick, finished: CheckIn?)? {
        // A done task shows every step done: there is no open one to tick.
        let shown = try Self.taskSteps(w, taskIds: [step.taskId])[step.taskId]
        guard let open = shown?.open, open.contains(where: { $0.id == step.id }) else { return nil }
        var finished: CheckIn?
        if open.count == 1 {
            let checkIn = CheckIn(id: newID(), itemId: step.taskId, localDay: day, at: now,
                                  timeZoneId: zone.identifier, amount: 1, source: source)
            try w.insert(checkIn)
            finished = checkIn
        }
        let tick = StepTick(id: newID(), stepId: step.id, taskId: step.taskId, localDay: day, at: now,
                            source: source, finishedCheckInId: finished?.id)
        try w.insert(tick)
        return (tick, finished)
    }

    /// Unticks a step. On a done task this unticks the task too: its steps go back to how
    /// they were before its tick, and this step is open (SPEC 2026-11-21).
    public func untickStep(id: UUID) throws {
        let now = clockForQueries.now()
        try storeForQueries.write { w in
            guard let step = try w.step(id: id), step.deletedAt == nil else { throw ClewError.itemNotFound }
            try Self.untick(step, at: now, w)
        }
    }

    /// Inside a write: the step's ticks are voided, and its task's check-ins (a done task
    /// is unticked too).
    static func untick(_ step: Step, at now: Date, _ w: any StoreWriter) throws {
        for c in try w.checkIns(itemIds: [step.taskId], from: allDays) {
            try w.voidCheckIn(id: c.id, at: now, reason: "undo")
        }
        for t in try w.stepTicks(taskIds: [step.taskId]) where t.stepId == step.id {
            try w.voidStepTick(id: t.id, at: now)
        }
    }

    /// Whether a step tick stands: live, and the check-in it made (if any) not undone.
    static func stands(_ tickId: UUID?, taskId: UUID, _ r: any StoreReader) throws -> Bool {
        guard let tickId, let tick = try r.stepTicks(taskIds: [taskId]).first(where: { $0.id == tickId }) else {
            return false
        }
        guard let finished = tick.finishedCheckInId else { return true }
        return try r.checkIn(id: finished)?.isVoided == false
    }
}

/// A click on a task with steps folds or unfolds it at once; the double-click's second
/// click puts the fold back the way it was before its first click, and opens the details
/// (SPEC 2026-11-21). Works whether the second click also reports as a click or not.
public struct FoldClicks: Sendable {
    private var first: (id: UUID, wasUnfolded: Bool, at: Date)?

    public init() {}

    /// A click: the task's new state (the other way round).
    public mutating func click(_ id: UUID, unfolded: Bool, at now: Date, interval: TimeInterval) -> Bool {
        if let first, first.id == id, now.timeIntervalSince(first.at) < interval {
            // The second click of a double-click: the first one's record stays.
        } else {
            first = (id, unfolded, now)
        }
        return !unfolded
    }

    /// A double-click: the state to put back, or nil to leave it as it is.
    public mutating func doubleClick(_ id: UUID, at now: Date, interval: TimeInterval) -> Bool? {
        defer { first = nil }
        guard let first, first.id == id, now.timeIntervalSince(first.at) < interval * 2 else { return nil }
        return first.wasUnfolded
    }
}
