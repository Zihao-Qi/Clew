import ClewCore
import ClewDomain
import Foundation
import Testing

@Suite struct ReorderTests {
    let store = FakeStore()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    var clew: Clew { Clew(store: store, clock: clock, zones: FixedZone("UTC")) }

    private func three() throws -> (Item, Item, Item) {
        let a = try clew.addItem(NewItem(title: "a", shape: .habit(.daily)))
        let b = try clew.addItem(NewItem(title: "b", shape: .habit(.daily)))
        let c = try clew.addItem(NewItem(title: "c", shape: .habit(.daily)))
        return (a, b, c)
    }

    @Test func movesBetweenNeighboursAndToEitherEnd() throws {
        let (a, b, c) = try three()
        try clew.moveItem(id: c.id, after: a.id, before: b.id)
        #expect(try clew.today().rows.map(\.item.title) == ["a", "c", "b"])
        try clew.moveItem(id: a.id, after: b.id, before: nil)
        #expect(try clew.today().rows.map(\.item.title) == ["c", "b", "a"])
        try clew.moveItem(id: a.id, after: nil, before: c.id)
        #expect(try clew.today().rows.map(\.item.title) == ["a", "c", "b"])
    }

    @Test func onlyTheMovedItemChanges() throws {
        let (a, b, c) = try three()
        clock.set(Date(timeIntervalSince1970: 1_800_000_060))
        try clew.moveItem(id: c.id, after: a.id, before: b.id) // both neighbours exist
        #expect(store.state.items[a.id] == a && store.state.items[b.id] == b)
        // A second move into the new, non-integer gap still touches nothing else.
        let movedFirst = try #require(store.state.items[c.id])
        try clew.moveItem(id: b.id, after: a.id, before: c.id)
        #expect(store.state.items[c.id] == movedFirst && store.state.items[a.id] == a)
        #expect(store.state.items[c.id]?.updatedAt == Date(timeIntervalSince1970: 1_800_000_060))
    }

    @Test func manyMovesIntoTheSameGapKeepOrder() throws {
        let (a, b, _) = try three()
        var above = a.id
        for i in 0..<40 {
            let x = try clew.addItem(NewItem(title: "x\(i)", shape: .habit(.daily)))
            try clew.moveItem(id: x.id, after: above, before: b.id)
            above = x.id
        }
        let titles = try clew.today().rows.map(\.item.title)
        #expect(Array(titles.prefix(42)) == ["a"] + (0..<40).map { "x\($0)" } + ["b"])
    }

    @Test func aBlockDraggedToTheListOpensAGapWhereItLands() throws {
        let spans = [(minY: 0.0, maxY: 30.0), (minY: 30.0, maxY: 60.0), (minY: 60.0, maxY: 90.0)]
        #expect(Clew.insertSlot(pointerY: -5, spans: spans) == 0)
        #expect(Clew.insertSlot(pointerY: 14, spans: spans) == 0)
        #expect(Clew.insertSlot(pointerY: 16, spans: spans) == 1)
        #expect(Clew.insertSlot(pointerY: 200, spans: spans) == 3)
        #expect(Clew.insertShift(index: 0, slot: 1, height: 30) == 0)
        #expect(Clew.insertShift(index: 1, slot: 1, height: 30) == 30)
        let ids = (0..<5).map { _ in UUID() }
        let (a, b, c, d, x) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        // b and x are on the timeline; x comes back into the gap before c.
        let shown = [a, c, d]
        #expect(Clew.insertNeighbours(at: 1, in: shown, within: ids, excluding: x) == (b, c))
        #expect(Clew.insertNeighbours(at: 0, in: shown, within: ids, excluding: x) == (nil, a))
        #expect(Clew.insertNeighbours(at: 3, in: shown, within: [a, b, c, d, x], excluding: x) == (d, nil))
        #expect(Clew.insertNeighbours(at: 3, in: shown, within: [a, c, d, b, x], excluding: x) == (d, b))
        #expect(Clew.insertNeighbours(at: 0, in: [], within: ids, excluding: x) == (nil, nil))
    }

    @Test func aDroppedRowTakesTheTargetsPlace() throws {
        let ids = (0..<4).map { _ in UUID() }
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        // Down: a onto c → after c, before d.
        #expect(Clew.dropNeighbours(dragged: a, onto: c, in: ids)! == (c, d))
        // Down to the end: a onto d → after d.
        #expect(Clew.dropNeighbours(dragged: a, onto: d, in: ids)! == (d, nil))
        // Up: d onto b → after a, before b.
        #expect(Clew.dropNeighbours(dragged: d, onto: b, in: ids)! == (a, b))
        // Up to the top: c onto a → before a.
        #expect(Clew.dropNeighbours(dragged: c, onto: a, in: ids)! == (nil, a))
        #expect(Clew.dropNeighbours(dragged: b, onto: b, in: ids) == nil)
        #expect(Clew.dropNeighbours(dragged: UUID(), onto: b, in: ids) == nil)
        // b is on the timeline, hidden: d onto c lands between b and c, never on b's key.
        let shown = [a, c, d]
        #expect(Clew.dropNeighbours(dragged: d, onto: c, in: shown, within: ids)! == (b, c))
        #expect(Clew.dropNeighbours(dragged: a, onto: c, in: shown, within: ids)! == (c, d))
        #expect(Clew.dropNeighbours(dragged: c, onto: a, in: [a, c], within: ids)! == (nil, a))
    }

    @Test func dropThenMoveGivesTheExpectedOrder() throws {
        let (a, b, c) = try three()
        let order = try clew.today().rows.map(\.id)
        let (above, below) = try #require(Clew.dropNeighbours(dragged: a.id, onto: c.id, in: order))
        try clew.moveItem(id: a.id, after: above, before: below)
        #expect(try clew.today().rows.map(\.id) == [b.id, c.id, a.id])
    }

    /// Halving one gap runs out of Double precision after about 50 moves; the list is
    /// then renumbered and the order still holds.
    @Test func eightyMovesIntoTheSameGapStillKeepOrder() throws {
        let (a, b, c) = try three()
        var below = b.id
        for i in 0..<80 {
            let x = try clew.addItem(NewItem(title: "x\(i)", shape: .habit(.daily)))
            try clew.moveItem(id: x.id, after: a.id, before: below) // right after a, as the UI would
            below = x.id
        }
        let titles = try clew.today().rows.map(\.item.title)
        #expect(titles == ["a"] + (0..<80).reversed().map { "x\($0)" } + ["b", "c"])
        #expect(Set(store.state.items.values.map(\.sortKey)).count == store.state.items.count)
        _ = c
    }

    @Test func theSlotIsTheRowUnderThePointer() {
        // Rows at 0–30, 30–60, 60–100 (the last taller, like a celebration row).
        let spans = [(minY: 0.0, maxY: 30.0), (minY: 30.0, maxY: 60.0), (minY: 60.0, maxY: 100.0)]
        #expect(Clew.dragSlot(pointerY: 5, spans: spans) == 0)
        #expect(Clew.dragSlot(pointerY: 29.9, spans: spans) == 0)
        #expect(Clew.dragSlot(pointerY: 30, spans: spans) == 1)   // a boundary belongs below
        #expect(Clew.dragSlot(pointerY: 99, spans: spans) == 2)
        #expect(Clew.dragSlot(pointerY: -40, spans: spans) == 0)  // above the list
        #expect(Clew.dragSlot(pointerY: 400, spans: spans) == 2)  // below the list
        #expect(Clew.dragSlot(pointerY: 10, spans: []) == nil)
    }

    @Test func aDraggedRowStaysInsideTheList() {
        let list = (minY: 0.0, maxY: 100.0)
        let middle = (minY: 30.0, maxY: 60.0)
        #expect(Clew.clampDrag(translation: 10, row: middle, list: list) == 10)
        #expect(Clew.clampDrag(translation: 80, row: middle, list: list) == 40)    // bottom meets 100
        #expect(Clew.clampDrag(translation: -80, row: middle, list: list) == -30)  // top meets 0
        let last = (minY: 60.0, maxY: 100.0)
        #expect(Clew.clampDrag(translation: 25, row: last, list: list) == 0)       // already at the bottom
    }

    @Test func rowsInBetweenMakeRoomTheOthersStay() {
        // Dragging row 1 (30 pt) down to slot 3 in five rows: rows 2 and 3 move up.
        #expect((0..<5).map { Clew.dragShift(index: $0, from: 1, to: 3, draggedHeight: 30) } == [0, 0, -30, -30, 0])
        // Dragging row 3 up to slot 0: rows 0, 1, 2 move down.
        #expect((0..<5).map { Clew.dragShift(index: $0, from: 3, to: 0, draggedHeight: 30) } == [30, 30, 30, 0, 0])
        // Not moved yet: nothing shifts.
        #expect((0..<5).map { Clew.dragShift(index: $0, from: 2, to: 2, draggedHeight: 30) } == [0, 0, 0, 0, 0])
    }

    /// The preview and the drop agree: dropping on the slot's row gives the order the
    /// shifted rows showed.
    @Test func theDropLandsWhereThePreviewShowedIt() throws {
        let ids = (0..<5).map { _ in UUID() }
        for (from, to) in [(1, 3), (3, 0), (0, 4), (4, 1)] {
            var preview = ids
            preview.insert(preview.remove(at: from), at: to)
            let (after, before) = try #require(Clew.dropNeighbours(dragged: ids[from], onto: ids[to], in: ids))
            let landed = preview.firstIndex(of: ids[from])!
            #expect(after == (landed > 0 ? preview[landed - 1] : nil))
            #expect(before == (landed + 1 < preview.count ? preview[landed + 1] : nil))
        }
    }

    @Test func nonsenseMovesAreRejected() throws {
        let (a, b, _) = try three()
        #expect(throws: ClewError.notAllowed) { try clew.moveItem(id: a.id, after: b.id, before: a.id) }
        #expect(throws: ClewError.notAllowed) { try clew.moveItem(id: a.id, after: b.id, before: b.id) }
        #expect(throws: ClewError.itemNotFound) { try clew.moveItem(id: UUID(), after: a.id, before: nil) }
        let gone = try clew.addItem(NewItem(title: "gone", shape: .today))
        try clew.deleteItem(itemId: gone.id)
        #expect(throws: ClewError.notAllowed) { try clew.moveItem(id: a.id, after: gone.id, before: nil) }
    }
}
