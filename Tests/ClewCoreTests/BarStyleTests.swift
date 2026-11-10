import ClewCore
import ClewDomain
import Foundation
import Testing

@Suite struct BarStyleTests {
    let store = FakeStore()
    var clew: Clew { Clew(store: store, clock: TestClock(Date(timeIntervalSince1970: 1_800_000_000)), zones: FixedZone("UTC")) }

    @Test func behindTheTitleByDefaultAndSwitchable() throws {
        #expect(try clew.barStyle() == .behindTitle)
        try clew.setBarStyle(.underTitle)
        #expect(try clew.barStyle() == .underTitle)
        try clew.setBarStyle(.behindTitle)
        #expect(try clew.barStyle() == .behindTitle)
    }

    @Test func anUnknownStyleFallsBackToTheDefault() throws {
        // e.g. written by a newer Clew that has a third style.
        try store.write { try $0.saveSetting("progressBarStyle", json: "\"ring\"", updatedAt: Date()) }
        #expect(try clew.barStyle() == .behindTitle)
    }
}
