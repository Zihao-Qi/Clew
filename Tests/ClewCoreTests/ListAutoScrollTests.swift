import ClewCore
import Testing

/// Autoscroll while dragging in a long list (user, 2026-11-18).
@Suite struct ListAutoScrollTests {
    let view = (minY: 100.0, maxY: 500.0)

    @Test func scrollsOnlyInTheEdgeBands() {
        #expect(ListAutoScroll.step(pointerY: 300, viewport: view) == 0)
        #expect(ListAutoScroll.step(pointerY: 128.5, viewport: view) == 0)            // just inside
        #expect(ListAutoScroll.step(pointerY: 120, viewport: view) < 0)               // top band: up
        #expect(ListAutoScroll.step(pointerY: 480, viewport: view) > 0)               // bottom band: down
    }

    @Test func fasterTowardTheEdgeAndFastestPastIt() {
        let inner = ListAutoScroll.step(pointerY: 476, viewport: view)
        let outer = ListAutoScroll.step(pointerY: 495, viewport: view)
        #expect(inner >= 1 && outer > inner)
        // Just inside the band it still moves, at its slowest (a point a tick).
        #expect(ListAutoScroll.step(pointerY: 472.5, viewport: view) == 1)
        #expect(ListAutoScroll.step(pointerY: 520, viewport: view) == ListAutoScroll.maxStep)
        #expect(ListAutoScroll.step(pointerY: 60, viewport: view) == -ListAutoScroll.maxStep)
    }

    @Test func aTinyViewportDoesNotScroll() {
        #expect(ListAutoScroll.step(pointerY: 101, viewport: (minY: 100, maxY: 150)) == 0)
    }

    @Test func offsetsStayInTheContent() {
        #expect(ListAutoScroll.clamp(-5, maxOffset: 300) == 0)
        #expect(ListAutoScroll.clamp(120, maxOffset: 300) == 120)
        #expect(ListAutoScroll.clamp(400, maxOffset: 300) == 300)
        #expect(ListAutoScroll.clamp(10, maxOffset: -4) == 0)
    }
}
