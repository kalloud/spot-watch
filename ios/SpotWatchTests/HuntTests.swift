import XCTest
@testable import SpotWatch

final class HuntTests: XCTestCase {
    /// Local times on Nov 4, 2026 (or the next days), wherever the tests run.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 4) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func hunting() -> Hunting { Hunting() }     // defaults: 3 h, quiet 21:00–07:00, eco 10 s

    func testHuntOnUntilTheTimeout() {
        var h = hunting()
        let fx = h.handle("hunt on", at: at(10), now: at(10))
        XCTAssertTrue(h.state.on)
        XCTAssertEqual(h.state.since, at(10))
        XCTAssertEqual(h.state.until, at(13))
        XCTAssertEqual(h.state.lastCommand, "hunt on")
        XCTAssertEqual(fx, [.row("hunt_on", detail: "started, ends 13:00 (timeout)"),
                            .alert(.hunt, title: "Hunting on until 13:00", body: "The 3 h safety timeout ends it at 13:00.")])
    }

    func testHuntOnUntilQuietHours() {
        var h = hunting()
        let fx = h.handle("hunt on", at: at(19), now: at(19))
        XCTAssertEqual(fx, [.row("hunt_on", detail: "started, ends 21:00 (quiet hours)"),
                            .alert(.hunt, title: "Hunting on until 21:00", body: "Quiet hours start at 21:00.")])
    }

    func testHuntOnRefusedInQuietHoursAcrossMidnight() {
        var h = hunting()
        let refused = HuntEffect.alert(.hunt, title: "Hunt on refused: quiet hours until 07:00",
                                       body: "Quiet hours run 21:00–07:00. They can be changed in Settings.")
        XCTAssertEqual(h.handle("hunt on", at: at(22, 30), now: at(22, 30)), [.note("\"hunt on\" refused: quiet hours"), refused])
        XCTAssertEqual(h.handle("hunt on", at: at(6, day: 5), now: at(6, day: 5)), [.note("\"hunt on\" refused: quiet hours"), refused])
        XCTAssertFalse(h.state.on)
        XCTAssertFalse(h.inQuietHours(at(7)))
        XCTAssertTrue(h.inQuietHours(at(21)))
    }

    func testQuietHoursOffWhenEqual() {
        var h = hunting()
        h.settings.quietStart = 7
        h.settings.quietEnd = 7
        XCTAssertFalse(h.inQuietHours(at(23)))
        _ = h.handle("hunt on", at: at(22), now: at(22))
        XCTAssertEqual(h.end(now: at(22)).why, "timeout")
    }

    func testHuntOffAndAlreadyOff() {
        var h = hunting()
        _ = h.handle("hunt on", at: at(10), now: at(10))
        XCTAssertEqual(h.handle("Hunt Off", at: at(11), now: at(11)),
                       [.row("hunt_off", detail: "manual"),
                        .alert(.hunt, title: "Hunting off (manual)", body: "Spot Watch stopped hunting at 11:00.")])
        XCTAssertFalse(h.state.on)
        XCTAssertEqual(h.handle("hunt off", at: at(11, 5), now: at(11, 5)),
                       [.alert(.hunt, title: "Hunting was already off", body: "Nothing to stop.")])
        XCTAssertEqual(h.handle("hunt off", at: at(11, 5), now: at(11, 30)), [], "a replayed hunt off gets no reply")
    }

    func testExtendKeepsTheStart() {
        var h = hunting()
        _ = h.handle("hunt on", at: at(10), now: at(10))
        let fx = h.handle("  HUNT   on ", at: at(11), now: at(11))
        XCTAssertEqual(h.state.since, at(10))
        XCTAssertEqual(h.state.until, at(14))
        XCTAssertEqual(fx.first, .row("hunt_on", detail: "extended, ends 14:00 (timeout)"))
    }

    func testReplayedHuntOnIsJudgedBySentTime() {
        var h = hunting()
        XCTAssertEqual(h.handle("hunt on", at: at(10), now: at(13, 30)),
                       [.note("\"hunt on\" sent \(EventFormat.stamp(at(10))) had already timed out, ignored")])
        XCTAssertFalse(h.state.on)
        let fx = h.handle("hunt on", at: at(10), now: at(10, 5))
        XCTAssertTrue(h.state.on)
        XCTAssertEqual(h.state.until, at(13), "the timeout runs from when it was sent")
        XCTAssertEqual(fx.first, .row("hunt_on", detail: "started, ends 13:00 (timeout), sent \(Format.clock(at(10)))"))
    }

    func testTickEndsAtTheTimeout() {
        var h = hunting()
        _ = h.handle("hunt on", at: at(10), now: at(10))
        XCTAssertEqual(h.tick(now: at(12, 59)), [])
        XCTAssertEqual(h.tick(now: at(13, 1)),
                       [.row("hunt_off", detail: "timeout"),
                        .alert(.hunt, title: "Hunting off (timeout)", body: "Spot Watch stopped hunting at 13:01.")])
    }

    func testLateTimeoutIsReportedAsLate() {
        var h = hunting()
        _ = h.handle("hunt on", at: at(10), now: at(10))
        XCTAssertEqual(h.tick(now: at(17, 52)),
                       [.row("hunt_off", detail: "timeout, ended \(EventFormat.stamp(at(13)))"),
                        .alert(.hunt, title: "Hunting ended at 13:00 (timeout)",
                               body: "The app wasn't running then, so this is reported late, at 17:52.")])
    }

    func testLateQuietHoursEndOnAnotherDay() {
        var h = hunting()
        _ = h.handle("hunt on", at: at(19, 30), now: at(19, 30))
        let fx = h.tick(now: at(8, day: 5))
        XCTAssertEqual(fx.first, .row("hunt_off", detail: "quiet hours, ended \(EventFormat.stamp(at(21)))"))
        XCTAssertEqual(fx.last, .alert(.hunt, title: "Hunting ended at 11-04 21:00 (quiet hours)",
                                       body: "The app wasn't running then, so this is reported late, at 08:00."))
    }

    func testQuietHoursEditedToCoverNowEndTheHunt() {
        var h = hunting()
        _ = h.handle("hunt on", at: at(10), now: at(10))
        h.settings.quietStart = 9
        h.settings.quietEnd = 12
        XCTAssertEqual(h.tick(now: at(10, 1)).first, .row("hunt_off", detail: "quiet hours"))
    }

    func testPowerCommandsAndEco() {
        var h = hunting()
        XCTAssertFalse(h.fullSpeed)
        XCTAssertEqual(h.modeText, "eco, every 10 s")
        XCTAssertEqual(h.handle("power high", at: at(10), now: at(10)),
                       [.row("power_high", detail: "full speed (battery high)"),
                        .alert(.power, title: "Battery high: full speed", body: "Checks run at full speed to use power.")])
        XCTAssertTrue(h.fullSpeed)
        XCTAssertEqual(h.handle("power low", at: at(10), now: at(10, 5)), [.row("power_low", detail: "eco, every 10 s, sent late")])
        XCTAssertNil(h.state.lastCommand, "power commands aren't hunt commands")
        _ = h.handle("hunt on", at: at(11), now: at(11))
        XCTAssertTrue(h.fullSpeed)
        XCTAssertEqual(h.modeText, "full speed")
    }

    func testNotACommand() {
        var h = hunting()
        XCTAssertEqual(h.handle("hello there", at: at(10), now: at(10)), [.note("Not a command, ignored: \"hello there\"")])
    }

    func testTimeHelpers() {
        let h = hunting()
        XCTAssertEqual(h.nextAt(at(6), hours: 7.5), at(7, 30))
        XCTAssertEqual(h.nextAt(at(8), hours: 7.5), at(7, 30, day: 5))
        XCTAssertEqual(Hunting.hoursText(7.5), "07:30")
        XCTAssertEqual(Hunting.hoursText(21), "21:00")
        XCTAssertEqual(h.whenText(at(9), now: at(10)), "09:00")
    }

    func testExportReminder() {
        let h = hunting()
        let first = at(10, day: 1)
        XCTAssertFalse(h.exportReminderDue(now: at(9, day: 9), lastExport: nil, firstRow: first, lastReminder: nil), "before 10:00")
        XCTAssertTrue(h.exportReminderDue(now: at(10, day: 9), lastExport: nil, firstRow: first, lastReminder: nil))
        XCTAssertFalse(h.exportReminderDue(now: at(10, day: 9), lastExport: at(10, day: 5), firstRow: first, lastReminder: nil))
        XCTAssertFalse(h.exportReminderDue(now: at(10, day: 9), lastExport: nil, firstRow: first, lastReminder: at(10, day: 6)))
        XCTAssertFalse(h.exportReminderDue(now: at(20, day: 9), lastExport: nil, firstRow: first, lastReminder: nil), "after 20:00")
    }
}
