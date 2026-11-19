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
}
