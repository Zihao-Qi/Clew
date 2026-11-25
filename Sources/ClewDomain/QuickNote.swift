import Foundation

/// A thought the person wrote down mid-task (SPEC "Notes", 2026-11-22). A definition:
/// its text, done and task change; Delete is a tombstone; when and during what it was
/// written never change. Sent to AI only as Settings › AI › Notes allows (SPEC "Notes to tasks").
public struct QuickNote: Hashable, Sendable, Identifiable, Codable {
    /// Where Make a task put the task, kept with the note (moving the task later does not
    /// change it).
    public enum MadeTo: String, Hashable, Sendable, Codable { case today, later }

    public let id: UUID
    public var text: String
    public let createdAt: Date
    /// The task it was written during, and that task's title then.
    public let duringItemId: UUID?
    public let duringTitle: String?
    public var doneAt: Date?
    /// The task Make a task made, and where.
    public var taskId: UUID?
    public var madeTo: MadeTo?
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID, text: String, createdAt: Date, duringItemId: UUID? = nil, duringTitle: String? = nil,
                doneAt: Date? = nil, taskId: UUID? = nil, madeTo: MadeTo? = nil, updatedAt: Date,
                deletedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.duringItemId = duringItemId
        self.duringTitle = duringTitle
        self.doneAt = doneAt
        self.taskId = taskId
        self.madeTo = madeTo
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Not done and not deleted: counted in "3 notes ›".
    public var isOpen: Bool { doneAt == nil && deletedAt == nil }

    public static let maxLength = 1000

    /// A note's text as kept: nil when it is nothing but spaces and line breaks; cut at
    /// 1,000 characters. Inner line breaks stay.
    public static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    /// Make a task's title: the first line that is not empty, trimmed (the caller cuts
    /// it to the title limit as typing would).
    public static func taskTitle(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
