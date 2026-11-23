import ClewCore
import ClewDomain
import Foundation
import Observation

/// What the note box says it was written during, and where to go back to (SPEC "Notes").
struct NoteContext: Equatable {
    let itemId: UUID
    /// The task's title then (a step's block: "Prepare the talk - Speech notes").
    let title: String
    /// " · 12 min left", " · paused", or "".
    let detail: String
}

extension AppModel {
    /// The task a note is written during, chosen when the box opens (SPEC "Notes"): the
    /// focus timer's task if a focus (not a break) is running and its time is not up; else,
    /// with the timeline on, a block running now that still needs something.
    func noteContext(now: Date = Date()) -> NoteContext? {
        if let timer = focus, timer.phase == .focus, !timer.isOver(at: now), let task = item(timer.itemId) {
            let detail: String
            if timer.isPaused {
                detail = String(localized: " · paused")
            } else {
                let minutes = Int((timer.remaining(at: now) / 60).rounded(.up))
                detail = String(localized: " · \(minutes) min left")
            }
            return NoteContext(itemId: task.id, title: task.title, detail: detail)
        }
        guard timelineShown, let day = timeline else { return nil }
        let order = (today?.rows ?? []).map(\.id)
        let running = day.blocks.filter { b in
            guard b.block.start <= now, now < b.block.end else { return false }
            guard let row = row(b.block.itemId) else { return false }
            let taskNeeds = row.item.progress.target != nil ? !row.isGoalReached : !row.isDone
            guard taskNeeds else { return false }
            if let stepId = b.block.stepId { return stepEntry(stepId)?.isDone == false }
            return true
        }
        func rank(_ b: TimelineBlock) -> (Double, Int, Int, Int) {
            let listIndex = order.firstIndex(of: b.block.itemId) ?? Int.max
            let stepIndex = b.block.stepId.flatMap { id in allSteps(of: b.block.itemId).firstIndex { $0.id == id } } ?? -1
            // The one that started last, then a task's own block, then the list's and the steps' order.
            return (-b.block.start.timeIntervalSinceReferenceDate, b.block.stepId == nil ? 0 : 1, listIndex, stepIndex)
        }
        guard let pick = running.min(by: { rank($0) < rank($1) }) else { return nil }
        return NoteContext(itemId: pick.block.itemId, title: pick.title, detail: "")
    }

    @discardableResult
    func addNote(_ text: String, during context: NoteContext?) -> Bool {
        run { try $0.addNote(text, during: context.map { ($0.itemId, $0.title) }) }
    }

    @discardableResult
    func editNote(_ id: UUID, _ text: String) -> Bool {
        guard QuickNote.cleaned(text) != nil else { return false }   // nothing but spaces: kept as it was
        return run { try $0.editNote(id: id, text: text) }
    }

    func setNoteDone(_ id: UUID, _ done: Bool) { run { try $0.setNoteDone(id: id, done) } }

    func makeTask(fromNote id: UUID, in place: QuickNote.MadeTo) { run { try $0.makeTask(fromNote: id, in: place) } }

    func deleteNote(_ id: UUID) {
        guard run({ try $0.deleteNote(id: id) }) else { return }
        lastDeletedNote = id
        lastDeletedNoteTask?.cancel()
        lastDeletedNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.lastDeletedNote == id else { return }
            self?.lastDeletedNote = nil
        }
    }

    func undoDeleteNote() {
        guard let id = lastDeletedNote else { return }
        lastDeletedNote = nil
        run { try $0.undeleteNote(id: id) }
    }
}
