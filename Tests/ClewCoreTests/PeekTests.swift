import ClewCore
import ClewDomain
import Foundation
import Testing

/// SPEC 2026-11-13, "A peek on hover": when the panel beside a collection row opens and
/// closes, and where it goes.
@Suite struct PeekTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func p(_ x: Double, _ y: Double = 500) -> PeekPoint { PeekPoint(x: x, y: y) }

    /// The pointer arrives on the YouTube row and moves a little: the rest has begun.
    func resting(on source: Source = .extensionYouTube, x: Double = 1000, since s: Double = 0) -> PeekState {
        var state = PeekState()
        state.pointer(on: source, at: p(x), now: at(s))
        state.pointer(on: source, at: p(x + 2), now: at(s))
        return state
    }

    /// Open on the YouTube row, the panel placed to the left.
    func opened() -> PeekState {
        var state = resting()
        state.tick(now: at(0.3))
        state.placed(on: .left)
        return state
    }

    @Test func opensAfterAShortRestThatBeganWithMovement() {
        var state = resting()
        state.tick(now: at(0.29))
        #expect(state.open == nil && state.deadline == at(0.3))
        state.tick(now: at(0.3))
        #expect(state.open == .extensionYouTube)
    }

    @Test func aRowSlidingUnderAStillPointerNeverOpens() {
        var state = PeekState()
        // The list moved (or the menu opened with ⌘.) under the pointer: the same point.
        state.pointer(on: .extensionYouTube, at: p(1000), now: at(0))
        state.pointer(on: .extensionYouTube, at: p(1000), now: at(0.1))
        state.tick(now: at(5))
        #expect(state.open == nil && state.deadline == nil)
        // Then it moves: the rest begins.
        state.pointer(on: .extensionYouTube, at: p(1001), now: at(6))
        state.tick(now: at(6.3))
        #expect(state.open == .extensionYouTube)
    }

    @Test func staysInThePanelAndClosesShortlyAfterLeavingBoth() {
        var state = opened()
        state.pointer(on: nil, at: p(1010, 400), now: at(1))      // off the row, not toward the panel
        #expect(state.deadline == at(1.2))
        state.panelHover(true, now: at(1.1))
        state.tick(now: at(5))
        #expect(state.open == .extensionYouTube && state.deadline == nil)
        state.panelHover(false, now: at(6))
        state.pointerLeftRows(now: at(6))
        state.tick(now: at(6.19))
        #expect(state.open == .extensionYouTube)
        state.tick(now: at(6.2))
        #expect(state.open == nil)
    }

    @Test func headingForThePanelAcrossAnotherRowKeepsIt() {
        var state = opened()                                        // panel on the left
        // Down-left across the X row, toward the panel, for longer than a rest.
        var x = 1000.0
        for i in 1...8 {
            x -= 10
            state.pointer(on: .extensionX, at: p(x, 500 - Double(i) * 4), now: at(1 + Double(i) * 0.1))
            state.tick(now: at(1 + Double(i) * 0.1))
        }
        #expect(state.open == .extensionYouTube)
        state.panelHover(true, now: at(1.9))
        state.tick(now: at(3))
        #expect(state.open == .extensionYouTube)
    }

    @Test func restingOnTheOtherRowTakesOver() {
        var state = opened()
        state.pointer(on: .extensionX, at: p(1000, 470), now: at(1))
        state.pointer(on: .extensionX, at: p(1001, 470), now: at(1))   // away from the panel's side
        state.tick(now: at(1.2))
        #expect(state.open == nil)                                  // left the YouTube row: closed
        state.tick(now: at(1.3))
        #expect(state.open == .extensionX)
    }

    @Test func aClickClosesItAndBlocksItUntilTheRowIsLeft() {
        var state = opened()
        state.rowClicked()
        #expect(state.open == nil)
        state.pointer(on: .extensionYouTube, at: p(1003), now: at(1))
        state.tick(now: at(9))
        #expect(state.open == nil)
        // Left the row and came back: it may open again.
        state.pointer(on: nil, at: p(1003, 300), now: at(10))
        state.pointer(on: .extensionYouTube, at: p(1003), now: at(11))
        state.pointer(on: .extensionYouTube, at: p(1004), now: at(11))
        state.tick(now: at(11.3))
        #expect(state.open == .extensionYouTube)
    }

    @Test func dragsCloseItAndNothingOpensDuringOne() {
        var state = opened()
        state.dragChanged(true)
        #expect(state.open == nil)
        state.pointer(on: .extensionX, at: p(900), now: at(1))
        state.pointer(on: .extensionX, at: p(901), now: at(1))
        state.tick(now: at(5))
        #expect(state.open == nil)
        state.dragChanged(false)
        state.tick(now: at(6))
        #expect(state.open == .extensionX)
    }

    @Test func leavingTheListOrClosingTheMenuStartsAgain() {
        for leave in [{ (s: inout PeekState) in s.listLeft() }, { (s: inout PeekState) in s.menuClosed() }] {
            var state = opened()
            state.rowClicked()
            leave(&state)
            #expect(state.open == nil && state.deadline == nil)
            // Back on the list with the pointer still on the row: nothing until it moves.
            state.pointer(on: .extensionYouTube, at: p(1002), now: at(5))
            state.tick(now: at(9))
            #expect(state.open == nil)
            // The click block is gone too.
            state.pointer(on: .extensionYouTube, at: p(1003), now: at(10))
            state.tick(now: at(10.3))
            #expect(state.open == .extensionYouTube)
        }
    }

    @Test func movingAgainOnTheRowReopensAfterADrag() {
        var state = opened()
        state.dragChanged(true)
        state.dragChanged(false)
        #expect(state.open == nil)
        state.pointer(on: .extensionYouTube, at: p(1005), now: at(2))
        state.tick(now: at(2.3))
        #expect(state.open == .extensionYouTube)
    }

    @Test func aPanelClosedUnderThePointerDoesNotHoldTheNextOne() {
        var state = opened()
        state.panelHover(true, now: at(1))
        state.emptied(.extensionYouTube)            // closed while the pointer was in it
        state.pointer(on: .extensionX, at: p(900), now: at(2))
        state.pointer(on: .extensionX, at: p(901), now: at(2))
        state.tick(now: at(2.3))
        #expect(state.open == .extensionX)
        state.pointerLeftRows(now: at(3))
        state.tick(now: at(3.2))
        #expect(state.open == nil)
    }

    @Test func nothingLeftClosesIt() {
        var state = opened()
        state.emptied(.extensionX)
        #expect(state.open == .extensionYouTube)
        state.emptied(.extensionYouTube)
        #expect(state.open == nil)
    }

    // MARK: Placement

    let visible = PeekRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func goesLeftOfTheMenuWhenThereIsRoomElseRight() {
        let menu = PeekRect(x: 1000, y: 200, width: 340, height: 600)
        let row = PeekRect(x: 1000, y: 300, width: 340, height: 30)
        let left = peekFrame(menu: menu, row: row, visible: visible, width: 280, height: 200)
        #expect(left.side == .left && left.frame == PeekRect(x: 720, y: 130, width: 280, height: 200))
        let nearEdge = PeekRect(x: 100, y: 200, width: 340, height: 600)
        let right = peekFrame(menu: nearEdge, row: PeekRect(x: 100, y: 300, width: 340, height: 30),
                              visible: visible, width: 280, height: 200)
        #expect(right.side == .right && right.frame.minX == 440)
        // Exactly enough room on the left still goes left, flush.
        let exact = peekFrame(menu: PeekRect(x: 280, y: 200, width: 340, height: 600), row: row,
                              visible: visible, width: 280, height: 200)
        #expect(exact.side == .left && exact.frame.minX == 0)
    }

    @Test func movesUpToStayOnScreen() {
        let menu = PeekRect(x: 1000, y: 0, width: 340, height: 800)
        let low = peekFrame(menu: menu, row: PeekRect(x: 1000, y: 20, width: 340, height: 30),
                            visible: visible, width: 280, height: 300)
        #expect(low.frame.minY == 0 && low.frame.height == 300)
        let tall = peekFrame(menu: menu, row: PeekRect(x: 1000, y: 800, width: 340, height: 30),
                             visible: PeekRect(x: 0, y: 0, width: 1440, height: 200), width: 280, height: 900)
        #expect(tall.frame.height == 200 && tall.frame.minY == 0)
    }
}
