import Foundation
import Testing

@testable import UploadTheFileCore

/// The pending-update state that keeps a scheduled update from taking the focus, and the rule
/// that holds the relaunch while a publish runs.
@Suite("Update reminders")
struct UpdateReminderTests {
    @Test func menuItemSaysCheckWhenNothingIsPending() {
        let pending = PendingUpdate()
        #expect(pending.version == nil)
        #expect(pending.menuTitle == "Check for Updates…")
    }

    @Test func menuItemNamesThePendingVersionUntilItIsCleared() {
        var pending = PendingUpdate()
        pending.record(version: "0.1.3")
        #expect(pending.menuTitle == "Update to 0.1.3…")
        pending.clear()
        #expect(pending.version == nil)
        #expect(pending.menuTitle == "Check for Updates…")
    }

    @Test func aVersionIsNewsOnlyTheFirstTime() {
        var pending = PendingUpdate()
        let first = pending.record(version: "0.1.3")
        let again = pending.record(version: "0.1.3")
        let newer = pending.record(version: "0.1.4")
        #expect(first)
        #expect(!again, "the same version must not notify twice")
        #expect(newer, "a newer version replaces it and is news")
        #expect(pending.menuTitle == "Update to 0.1.4…")
        pending.clear()
        let afterSession = pending.record(version: "0.1.4")
        #expect(afterSession, "after the session ended it is news again")
    }

    @Test func theNotificationNamesTheVersionInPlainWords() {
        let message = PendingUpdate.notification(version: "0.1.3")
        #expect(message.title == "Update available")
        #expect(message.body == "Upload the File 0.1.3 is available.")
        #expect(PendingUpdate.notificationActionKey == "action")
        #expect(PendingUpdate.notificationActionValue == "checkForUpdates")
    }

    // MARK: Relaunch

    @MainActor
    private final class Counter {
        var relaunches = 0
    }

    @MainActor
    @Test func relaunchHappensAtOnceWhenNothingIsRunning() {
        var hold = RelaunchHold()
        let counter = Counter()
        let held = hold.request(isBusy: false) { counter.relaunches += 1 }
        #expect(!held, "Sparkle must be told to relaunch now")
        #expect(!hold.isHolding)
        hold.busyChanged(isBusy: false)
        #expect(counter.relaunches == 0, "the block is Sparkle's to run when it is not held")
    }

    @MainActor
    @Test func relaunchWaitsForAPublishAndRunsOnceWhenItEnds() {
        var hold = RelaunchHold()
        let counter = Counter()
        let held = hold.request(isBusy: true) { counter.relaunches += 1 }
        #expect(held)
        #expect(hold.isHolding)

        hold.busyChanged(isBusy: true)
        #expect(counter.relaunches == 0, "still running: keep waiting")
        #expect(hold.isHolding)

        hold.busyChanged(isBusy: false)
        #expect(counter.relaunches == 1)
        #expect(!hold.isHolding)

        hold.busyChanged(isBusy: false)
        #expect(counter.relaunches == 1, "the relaunch runs once")
    }

    @MainActor
    @Test func aLaterRequestReplacesTheHeldOne() {
        var hold = RelaunchHold()
        let counter = Counter()
        _ = hold.request(isBusy: true) { counter.relaunches += 10 }
        _ = hold.request(isBusy: true) { counter.relaunches += 1 }
        hold.busyChanged(isBusy: false)
        #expect(counter.relaunches == 1)
    }
}
