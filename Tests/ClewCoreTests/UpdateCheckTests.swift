import ClewCore
import Foundation
import Testing

/// SPEC 2026-11-13, "About and updates": versions, when a check is due, the dot.
@Suite struct UpdateCheckTests {
    func v(_ s: String) -> AppVersion { AppVersion(running: s)! }

    @Test func tagsAreVAndNumbersAndTheRunningVersionIsNumbers() {
        #expect(AppVersion(tag: "v1.5.1")?.parts == [1, 5, 1])
        #expect(AppVersion(tag: "1.5.1") == nil)
        #expect(AppVersion(tag: "v1.5.1-beta") == nil)
        #expect(AppVersion(tag: "v1..2") == nil)
        #expect(AppVersion(tag: "v") == nil)
        #expect(AppVersion(tag: "v１.5") == nil)                  // full-width digit
        #expect(AppVersion(tag: "v+1.5") == nil && AppVersion(tag: "v1.-5") == nil)   // Int() takes signs
        #expect(AppVersion(running: "1.5.0")?.tag == "v1.5.0")
        #expect(AppVersion(running: "v1.5.0") == nil)
    }

    @Test func versionsCompareByNumberPartByPart() {
        #expect(v("1.10.0") > v("1.9.2"))
        #expect(v("2") > v("1.99.99"))
        #expect(v("1.5") == v("1.5.0"))
        #expect(!(v("1.5") < v("1.5.0")) && !(v("1.5.0") < v("1.5")))
        #expect(v("1.5.0.1") > v("1.5"))
    }

    @Test func dueAfterADayOrWhenTheClockWentBack() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(UpdateCheck.isDue(lastAttempt: nil, now: now))
        #expect(!UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(-24 * 3600 + 1), now: now))
        #expect(UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(-24 * 3600), now: now))
        #expect(UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(60), now: now))
        #expect(!UpdateCheck.isDue(lastAttempt: now, now: now))
    }

    @Test func theDotShowsANewerReleaseUntilAboutShowedIt() {
        let running = v("1.5.0")
        #expect(UpdateCheck.showsDot(running: running, latest: v("1.5.1"), seen: nil))
        #expect(!UpdateCheck.showsDot(running: running, latest: v("1.5.1"), seen: v("1.5.1")))
        // A still newer one brings it back.
        #expect(UpdateCheck.showsDot(running: running, latest: v("1.6.0"), seen: v("1.5.1")))
        // After upgrading, the known release is not newer: no dot.
        #expect(!UpdateCheck.showsDot(running: v("1.5.1"), latest: v("1.5.1"), seen: nil))
        #expect(!UpdateCheck.showsDot(running: v("1.6.0"), latest: v("1.5.1"), seen: nil))
        #expect(!UpdateCheck.showsDot(running: running, latest: nil, seen: nil))
        #expect(UpdateCheck.available(running: running, latest: v("1.5.1")) == v("1.5.1"))
        #expect(UpdateCheck.available(running: running, latest: v("1.5")) == nil)
    }

    // MARK: The state across checks

    let t = Date(timeIntervalSince1970: 3_000_000)

    @Test func automaticChecksNeedTheSwitchAndADayAfterAnyAttempt() {
        var state = UpdateState()
        #expect(!state.automaticCheckDue(now: t))                 // off by default
        state.isOn = true
        #expect(state.automaticCheckDue(now: t))
        state.began(now: t)
        _ = state.finished(tag: nil, now: t, running: v("1.5.0"), aboutShowing: false)
        // A failed attempt still waits a day.
        #expect(!state.automaticCheckDue(now: t.addingTimeInterval(3600)))
        #expect(state.automaticCheckDue(now: t.addingTimeInterval(24 * 3600)))
    }

    @Test func aCheckThatWorkedRemembersTheReleaseAndAFailedOneChangesNothing() {
        var state = UpdateState(isOn: true)
        state.began(now: t)
        #expect(state.finished(tag: "v1.5.1", now: t, running: v("1.5.0"), aboutShowing: false) == .available(v("1.5.1")))
        #expect(state.lastSuccess == t && state.available(running: v("1.5.0")) == v("1.5.1"))
        #expect(state.showsDot(running: v("1.5.0")))
        let later = t.addingTimeInterval(90_000)
        state.began(now: later)
        #expect(state.finished(tag: nil, now: later, running: v("1.5.0"), aboutShowing: false) == .failed)
        #expect(state.finished(tag: "1.6.0", now: later, running: v("1.5.0"), aboutShowing: false) == .failed)
        // Still known, still shown; "Last checked" stays at the check that worked.
        #expect(state.lastSuccess == t && state.lastAttempt == later)
        #expect(state.available(running: v("1.5.0")) == v("1.5.1"))
        #expect(state.finished(tag: "v1.5.0", now: later, running: v("1.5.0"), aboutShowing: false) == .upToDate)
    }

    @Test func aboutClearsTheDotWhenShownOrShowingAsTheReleaseIsFound() {
        var state = UpdateState(isOn: true)
        _ = state.finished(tag: "v1.5.1", now: t, running: v("1.5.0"), aboutShowing: false)
        state.aboutShown(running: v("1.5.0"))
        #expect(!state.showsDot(running: v("1.5.0")) && state.seen == v("1.5.1"))
        // Found while About is on screen: never dotted.
        _ = state.finished(tag: "v1.6.0", now: t, running: v("1.5.0"), aboutShowing: true)
        #expect(!state.showsDot(running: v("1.5.0")) && state.seen == v("1.6.0"))
        // Not showing: a newer one brings the dot back.
        _ = state.finished(tag: "v1.7.0", now: t, running: v("1.5.0"), aboutShowing: false)
        #expect(state.showsDot(running: v("1.5.0")))
        // Nothing newer to show: About leaves `seen` alone.
        var fresh = UpdateState()
        fresh.aboutShown(running: v("1.5.0"))
        #expect(fresh.seen == nil)
    }
}
