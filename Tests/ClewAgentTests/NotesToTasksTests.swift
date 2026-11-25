@testable import ClewAgent
import ClewAI
import Foundation
import Testing

/// SPEC "Notes to tasks", docs/AGENT.md §5, §7: what is sent, what is kept of an answer,
/// and that a note never shapes Memory.
@Suite struct NotesToTasksTests {
    typealias Scripted = AgentTests.Scripted
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a Friday, 08:00 UTC
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    var bank: NoteToTask.Input { NoteToTask.Input(note: "bank card?? call them, then order a new one", at: t0, calendar: utc) }

    func answer(_ item: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: item), as: UTF8.self)
    }
    func task(_ title: Any = "Call the bank about the card", where place: Any = "later", reason: Any = "Errands fit the afternoon",
              steps: [String] = []) -> [String: Any] {
        ["kind": "task", "title": title, "where": place, "reason": reason, "steps": steps]
    }
    func suggest(_ item: [String: Any], _ input: NoteToTask.Input? = nil) -> NoteSuggestion? {
        try? NoteToTask().validate(answer(item), input: input ?? bank).get()
    }
    func refused(_ text: String) -> Set<JobFailure.Reason>? {
        if case .failure(let f) = NoteToTask().validate(text, input: bank) { return f.reasons }
        return nil
    }

    @Test func sendsTheNoteTheTimeAndNothingElse() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bank)) as! [String: Any]
        #expect(Set(json.keys) == ["now", "note"])
        #expect(json["note"] as? String == "bank card?? call them, then order a new one")
        #expect((json["now"] as? [String: String]) == ["weekday": "Friday", "time": "08:00"])
        let long = String(repeating: "a", count: 1000)
        #expect(NoteToTask.Input(note: long, at: t0, calendar: utc).note.count == 1000)   // all of it
        #expect(NoteToTask().carriesNotes(bank) && !NoteToTask().untrusted(bank))
        #expect(NoteToTask().instructions.contains("steps only when") || NoteToTask().instructions.contains("Give steps only when"))
    }

    @Test func keepsATaskWithItsSteps() {
        #expect(suggest(task(where: "today", steps: ["1. Find the card's last 4 digits", "- Call the number on the back."]))
            == .task(title: "Call the bank about the card", today: true, reason: "Errands fit the afternoon",
                     steps: ["Find the card's last 4 digits", "Call the number on the back"]))
        #expect(suggest(task()) == .task(title: "Call the bank about the card", today: false,
                                         reason: "Errands fit the afternoon", steps: []))
        #expect(suggest(["kind": "thought", "title": NSNull(), "where": NSNull(), "reason": NSNull(), "steps": []]) == .thought)
    }

    @Test func dropsBadStepsButKeepsTheTask() {
        let eighty = String(repeating: "a", count: 80)
        let kept = suggest(task(steps: ["Call", "call", "", "Two\nlines", eighty + "b", eighty, "c", "d", "e", "f", "g"]))
        #expect(kept == .task(title: "Call the bank about the card", today: false, reason: "Errands fit the afternoon",
                              steps: ["Call", eighty, "c", "d", "e"]))
    }

    @Test func refusesABadTitleReasonOrPlace() {
        #expect(suggest(task("Two\nlines")) == nil)
        #expect(suggest(task(String(repeating: "a", count: 81))) == nil)
        #expect(suggest(task(String(repeating: "a", count: 80))) != nil)
        #expect(suggest(task("  ")) == nil)
        #expect(suggest(task(reason: "A\nB")) == nil)
        #expect(suggest(task(reason: String(repeating: "a", count: 81))) == nil)
        #expect(suggest(task(reason: NSNull())) == nil)
        #expect(suggest(task(where: "tomorrow")) == nil)
        #expect(suggest(task(where: NSNull())) == nil)
        #expect(refused(answer(task("Two\nlines"))) == [.lineBreak, .none])
    }

    @Test func bannedWordsPassOnlyFromTheNoteItself() {
        let adhd = NoteToTask.Input(note: "read the ADHD paper", at: t0, calendar: utc)
        #expect(suggest(task("Read the ADHD paper"), adhd) != nil)
        #expect(suggest(task("Read the ADHD paper")) == nil)                         // the bank note doesn't carry it
        #expect(suggest(task(reason: "You're behind schedule")) == nil)
        #expect(suggest(task(steps: ["Stop being lazy", "Call"])) == .task(
            title: "Call the bank about the card", today: false, reason: "Errands fit the afternoon", steps: ["Call"]))
    }

    @Test func refusesAnythingButTheSchema() {
        #expect(refused("not json") == [.schema])
        var extra = task(); extra["why"] = "x"
        #expect(refused(answer(extra)) == [.schema])
        var withId = task(); withId["id"] = "q1"
        #expect(refused(answer(withId)) == [.schema])                             // an id belongs to Sort only
        var noSteps = task(); noSteps["steps"] = nil
        #expect(refused(answer(noSteps)) == [.schema])
        var odd = task(); odd["kind"] = "idea"
        #expect(refused(answer(odd)) == [.schema, .none])
    }

    // MARK: Sort with ✨

    var notes: [(id: UUID, text: String)] { (0..<3).map { (UUID(), ["bank card??", "a nice quote", "milk, eggs"][$0]) } }

    @Test func sortSendsShortIdsAndAtMostTwenty() throws {
        let three = notes
        let made = SortNotes.input(three, at: t0, calendar: utc)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(made.input)) as! [String: Any]
        #expect(Set(json.keys) == ["now", "notes"])
        #expect((json["notes"] as? [[String: String]])?.map { $0["id"] } == ["q1", "q2", "q3"])
        #expect(made.ids == ["q1": three[0].id, "q2": three[1].id, "q3": three[2].id])
        let many = (0..<25).map { (UUID(), "note \($0)") }
        #expect(SortNotes.input(many, at: t0, calendar: utc).input.notes.map(\.text) == (0..<20).map { "note \($0)" })
        #expect(SortNotes(ids: made.ids).carriesNotes(made.input))
    }

    @Test func sortKeepsEachPassingNoteAndDropsTheRest() {
        let three = notes
        let made = SortNotes.input(three, at: t0, calendar: utc)
        let job = SortNotes(ids: made.ids)
        func items(_ list: [[String: Any]]) -> Result<[UUID: NoteSuggestion], JobFailure> {
            job.validate(answer(["notes": list]), input: made.input)
        }
        var bankTask = task(); bankTask["id"] = "q1"
        var bad = task("A\nB"); bad["id"] = "q3"
        var unknown = task(); unknown["id"] = "q9"
        var badFirst = task("A\nB"); badFirst["id"] = "q2"
        var thenGood = ["kind": "thought", "title": NSNull(), "where": NSNull(), "reason": NSNull(), "steps": []] as [String: Any]
        thenGood["id"] = "q2"
        var again = task("Another"); again["id"] = "q1"
        let kept = try? items([bankTask, bad, unknown, badFirst, thenGood, again]).get()
        #expect(kept?[three[0].id] == .task(title: "Call the bank about the card", today: false,
                                            reason: "Errands fit the afternoon", steps: []))
        #expect(kept?[three[1].id] == .thought)          // a failing entry, then a passing one for the same id
        #expect(kept?[three[2].id] == nil && kept?.count == 2)
        if case .failure(let f) = items([bad, unknown]) { #expect(f.reasons.contains(.none)) } else { Issue.record("none passed: a failure") }
        if case .failure(let f) = items([task()]) { #expect(f.reasons.contains(.unknownId)) } else { Issue.record("no id") }
    }

    // MARK: What next? with the person's notes

    @Test func whatNextCarriesAtMostTwentyNotesCut() throws {
        let candidates = [WhatNext.Candidate(itemId: UUID(), title: "Write the intro", typed: true, kind: .once),
                          WhatNext.Candidate(itemId: UUID(), title: "Reply to Anna", typed: true, kind: .once)]
        let none = WhatNext.input(candidates, at: t0, calendar: utc, freeMinutes: nil)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(none.input)) as! [String: Any]
        #expect(plain["notes"] == nil && !WhatNext(ids: none.ids).carriesNotes(none.input))
        let long = String(repeating: "x", count: 300)
        let many = [long] + (1..<25).map { "note \($0)" }
        let with = WhatNext.input(candidates, at: t0, calendar: utc, freeMinutes: nil, notes: many)
        #expect(with.input.notes.count == 20 && with.input.notes[0].count == 200 && with.input.notes[1] == "note 1")
        #expect(WhatNext(ids: with.ids).carriesNotes(with.input))
    }

    // MARK: Memory

    @Test func aRequestCarryingANoteSendsNoActivityAndKeepsNoNote() async throws {
        let event = ActivityEvent.make(.taskTicked, at: t0, calendar: utc, task: "Write intro", typed: true)
        let note = Note(id: UUID(), about: "Writing", says: "Goes better before noon", from: .clew, made: t0, changed: t0)
        var item = task()
        item["note"] = ["action": "add", "id": NSNull(), "about": "Bank", "says": "Forgets the bank", "based_on": "a note"]
        let provider = Scripted(events: [.text(answer(item)), .done])
        let run = await Agent.run(NoteToTask(), input: bank, memory: MemoryContext(notes: [note], events: [event]),
                                  model: "m", provider: provider)
        #expect((try? run.result.get()) != nil)
        #expect(run.note == nil && run.sentEvents.isEmpty)
        let sent = try #require(JSONSerialization.jsonObject(with: Data(provider.calls.requests[0].input.utf8)) as? [String: Any])
        let memory = sent["memory"] as? [String: Any]
        #expect((memory?["activity"] as? [Any])?.isEmpty == true && (memory?["notes"] as? [Any])?.count == 1)
    }
}
