import ClewAgent
import ClewDomain
import Foundation
import Observation

/// Clew's notes about the person and the record of what happened (docs/AGENT.md §7;
/// SPEC "Memory"). Its own file in Application Support, apart from Clew's data: not
/// facts, not in exports or backups. `nil` url: kept in memory only (debug checks).
@MainActor @Observable
final class MemoryBook {
    private(set) var notes: [Note] = []
    @ObservationIgnored private(set) var activity = Activity()
    @ObservationIgnored private let url: URL?

    private struct File: Codable {
        var version = 1
        var notes: [Note]
        var activity: Activity
    }

    init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        notes = file.notes
        activity = file.activity
    }

    static func defaultURL() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                     create: true)
            .appendingPathComponent("Clew", isDirectory: true).appendingPathComponent("memory.json")
    }

    /// Newest change first, as Settings › AI lists them.
    var shown: [Note] { notes.sorted { $0.changed > $1.changed } }
    var isFull: Bool { notes.count >= Memory.most }

    // MARK: The person's own changes (never checked: their text is theirs)

    func add(about: String, says: String) {
        guard !isFull else { return }
        notes.append(Memory.added(about: about, says: says, now: Date()))
        save()
    }

    func edit(_ id: UUID, about: String, says: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i] = Memory.edited(notes[i], about: about, says: says, now: Date())
        save()
    }

    /// True in "What Clew noticed": stays Clew's, and Clew never changes it again.
    func confirm(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].confirmed = Date()
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    /// Forget everything: all notes, the events and the suggested step ids.
    func forget() {
        notes = []
        activity.clear()
        save()
    }

    // MARK: Clew's changes and the record

    /// A note change that passed `Memory.apply` against these very notes.
    func replace(_ checked: [Note]) {
        notes = checked
        save()
    }

    func record(_ event: ActivityEvent) {
        activity.record(event)
        save()
    }

    func untick(_ tick: UUID) {
        guard activity.events.contains(where: { $0.tick == tick }) else { return }
        activity.untick(tick)
        save()
    }

    func suggested(_ step: UUID) {
        activity.suggested(step)
        save()
    }

    func sent(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        activity.sent(ids)
        save()
    }

    /// AI no longer ready: the record goes, the notes stay.
    func clearActivity() {
        guard activity != Activity() else { return }
        activity.clear()
        save()
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(notes: notes, activity: activity)).write(to: url, options: [.atomic])
        } catch {
            // The next change tries again; nothing else depends on it.
        }
    }
}
