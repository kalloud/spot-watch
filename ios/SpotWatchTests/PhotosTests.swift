import XCTest
@testable import SpotWatch

final class PhotosTests: XCTestCase {
    /// 2026-11-04 08:25:38 local time, wherever the tests run.
    private let t = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 8, minute: 25, second: 38))!

    func testDueOnARowOrAfterTheGap() {
        XCTAssertTrue(PhotoPlan.due(rowsLogged: false, last: nil, now: t))
        XCTAssertTrue(PhotoPlan.due(rowsLogged: true, last: t, now: t))
        XCTAssertFalse(PhotoPlan.due(rowsLogged: false, last: t, now: t + PhotoPlan.every - 1))
        XCTAssertTrue(PhotoPlan.due(rowsLogged: false, last: t, now: t + PhotoPlan.every))
    }

    func testNames() {
        XCTAssertEqual(PhotoPlan.fileName(t), "spotwatch-20261104-082538.jpg")
        XCTAssertEqual(PhotoPlan.fileName(t, copy: 2), "spotwatch-20261104-082538-2.jpg")
        XCTAssertEqual(PhotoPlan.zipName(t), "spotwatch-photos-20261104-0825.zip")
    }

    func testExcessDropsTheOldest() {
        let names = [PhotoPlan.fileName(t + 60), PhotoPlan.fileName(t), PhotoPlan.fileName(t + 120)]
        XCTAssertEqual(PhotoPlan.excess(names, keep: 2), [PhotoPlan.fileName(t)])
        XCTAssertEqual(PhotoPlan.excess(names, keep: 3), [])
        XCTAssertEqual(PhotoPlan.excess(names, keep: 0).count, 3)
    }

    func testCaption() {
        let row = EventRow(time: t, spot: 3, event: "vacant", coverage: 0, hunting: false, detail: "change 23.4")
        XCTAssertEqual(PhotoPlan.caption(time: t, setup: "Each 320", rows: [row], spots: ["Spot 3 vacant · 0%"]),
                       ["2026-11-04 08:25:38 · Each 320", "Spot 3 vacant · 0% · change 23.4", "Spot 3 vacant · 0%"])
        XCTAssertEqual(PhotoPlan.caption(time: t, setup: "Each 320", rows: [], spots: [])[1], "No event (a photo every 5 min)")
    }
}
