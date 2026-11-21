import ClewDomain
import Foundation
import Testing

/// SPEC 2026-11-21: a task's steps as shown, from its steps, step ticks and own ticks.
@Suite struct TaskStepsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let task = UUID()

    func step(_ title: String, _ key: Double, deleted: Bool = false) -> Step {
        Step(id: UUID(), taskId: task, title: title, sortKey: key, createdAt: t0, updatedAt: t0,
             deletedAt: deleted ? t0 : nil)
    }

    @Test func deletedStepsAndOtherTasksStepsAreLeftOut() {
        let a = step("a", 1), gone = step("gone", 2, deleted: true)
        let other = Step(id: UUID(), taskId: UUID(), title: "other", sortKey: 0, createdAt: t0, updatedAt: t0)
        let shown = TaskSteps.make(taskId: task, steps: [a, gone, other], ticks: [], taskTicks: [])
        #expect(shown.entries.map(\.step.title) == ["a"])
        #expect(shown.total == 1 && shown.done == 0 && shown.fraction == 0)
    }

    @Test func theBarFillsByStepsDone() {
        let a = step("a", 1), b = step("b", 2), c = step("c", 3)
        let tick = StepTick(id: UUID(), stepId: b.id, taskId: task, localDay: LocalDay(string: "2026-11-21")!, at: t0, source: .user)
        let shown = TaskSteps.make(taskId: task, steps: [a, b, c], ticks: [tick], taskTicks: [])
        #expect(shown.done == 1 && shown.total == 3 && abs(shown.fraction - 1.0 / 3) < 1e-9)
        #expect(shown.entries.map(\.step.title) == ["b", "a", "c"])
    }
}
