import ClewCore
import ClewDomain
import Foundation
import Testing

/// SPEC 2026-11-18, "The menu bar ring".
@Suite struct MenuBarStyleTests {
    let store = FakeStore()
    var clew: Clew { Clew(store: store, clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)), zones: FixedZone("UTC")) }

    @Test func ringByDefaultAndSwitchable() throws {
        #expect(try clew.menuBarStyle() == .ring)
        try clew.setMenuBarStyle(.count)
        #expect(try clew.menuBarStyle() == .count)
        try clew.setMenuBarStyle(.daruma)
        #expect(try clew.menuBarStyle() == .daruma)
        try clew.setMenuBarStyle(.ring)
        #expect(try clew.menuBarStyle() == .ring)
    }

    @Test func anUnknownStyleFallsBackToTheRing() throws {
        try store.write { try $0.saveSetting("menuBarStyle", json: "\"hand\"", updatedAt: Date()) }
        #expect(try clew.menuBarStyle() == .ring)
    }

    @Test func theRingsShape() {
        #expect(MenuBarRing(done: 0, total: 0) == nil)                          // the plain icon
        #expect(MenuBarRing(done: 0, total: 3) == .parts(done: 0, of: 3))       // the empty ring
        #expect(MenuBarRing(done: 1, total: 3) == .parts(done: 1, of: 3))
        #expect(MenuBarRing(done: 7, total: 8) == .parts(done: 7, of: 8))       // 8 still in parts
        #expect(MenuBarRing(done: 3, total: 9) == .share(1.0 / 3))              // over 8: smooth
        #expect(MenuBarRing(done: 0, total: 9) == .share(0))
        #expect(MenuBarRing(done: 3, total: 3) == .finished)
        #expect(MenuBarRing(done: 12, total: 12) == .finished)
        #expect(MenuBarRing(done: 1, total: 1) == .finished)
    }

    @Test func theDarumasFace() {
        #expect(DarumaStage.of(done: 0, total: 0) == nil)                        // the plain icon
        // 6 tasks: nothing 1, first 2, then 2–3 smile, 4–5 laugh, all 5.
        #expect((0...7).map { DarumaStage.of(done: $0, total: 6)! } == [1, 2, 3, 3, 4, 4, 5, 5])
        // 5 tasks: three counts between, the odd one smiles.
        #expect((0...5).map { DarumaStage.of(done: $0, total: 5)! } == [1, 2, 3, 3, 4, 5])
        // 4 tasks: one smiles, one laughs.
        #expect((0...4).map { DarumaStage.of(done: $0, total: 4)! } == [1, 2, 3, 4, 5])
        #expect((0...3).map { DarumaStage.of(done: $0, total: 3)! } == [1, 2, 3, 5])
        #expect((0...2).map { DarumaStage.of(done: $0, total: 2)! } == [1, 2, 5])
        #expect((0...1).map { DarumaStage.of(done: $0, total: 1)! } == [1, 5])
        // 10 tasks: 2–5 smile, 6–9 laugh.
        #expect((0...10).map { DarumaStage.of(done: $0, total: 10)! } == [1, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5])
    }
}
