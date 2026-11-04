import XCTest
@testable import SpotWatch

final class SpotLogicTests: XCTestCase {
    let s = SpotSettings()                       // occThresh 0.35, confirmN 3, hintN 2, changeMin 10
    let spot = Box(x: 100, y: 100, w: 100, h: 100)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let carThumb: [Float] = [40, -40, 40, -40]
    let emptyThumb: [Float] = [0, 0, 0, 0]       // differs from carThumb by 40

    func reading(_ coverage: Double, person: Double = 0) -> Reading {
        Reading(coverage: coverage, person: person > 0, personScore: person)
    }

    /// Feeds readings one second apart and returns all events.
    @discardableResult
    func feed(_ t: inout SpotTrack, _ readings: [Reading], thumb: [Float]? = nil, settings: SpotSettings? = nil) -> [SpotEvent] {
        var all: [SpotEvent] = []
        for (i, r) in readings.enumerated() {
            all += SpotLogic.update(&t, r, thumb: { thumb }, settings ?? s, now: now.addingTimeInterval(Double(i)))
        }
        return all
    }

    // MARK: Readings

    func testCoverageIsTheLargestVehicleOverlap() {
        let r = SpotLogic.read(spot, [car(150, 100, 100, 100), car(100, 100, 25, 100)], s)
        XCTAssertEqual(r.coverage, 0.5, accuracy: 1e-9)
        XCTAssertFalse(r.person)
    }

    func testPersonNeedsPersonMinScoreAndTheMargin() {
        XCTAssertFalse(SpotLogic.read(spot, [person(210, 100, 20, 50, score: 0.39)], s).person)
        // 35 px margin: a person starting 30 px right of the spot is near, at 40 px isn't.
        XCTAssertTrue(SpotLogic.read(spot, [person(230, 100, 20, 50)], s).person)
        XCTAssertFalse(SpotLogic.read(spot, [person(240, 100, 20, 50)], s).person)
        XCTAssertEqual(SpotLogic.read(spot, [person(230, 100, 20, 50, score: 0.6)], s).personScore, 0.6)
    }

    // MARK: State machine

    func testConfirmNReadingsInARowChangeTheState() {
        var t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5)])
        XCTAssertEqual(t.state, .unknown)
        XCTAssertEqual(SpotLogic.runText(t, confirmN: 3), "occupied 2/3")
        let e = feed(&t, [reading(0.5)])
        XCTAssertEqual(t.state, .occupied)
        XCTAssertEqual(e, [.changed(.occupied, coverage: 0.5, change: nil)])
    }

    func testAPassingCarDoesNotFlipTheState() {
        var t = SpotTrack()
        feed(&t, [reading(0), reading(0), reading(0)])
        XCTAssertEqual(t.state, .vacant)
        feed(&t, [reading(0.6), reading(0.6), reading(0)])
        XCTAssertEqual(t.state, .vacant)
    }

    func testNeverFreeFromUnknown() {
        var t = SpotTrack()
        let e = feed(&t, [reading(0), reading(0), reading(0)])
        XCTAssertEqual(e, [.changed(.vacant, coverage: 0, change: nil)])
    }

    func testOccupiedHoldsDownToHalfTheThreshold() {
        var t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)])
        feed(&t, [reading(0.2), reading(0.18), reading(0.2), reading(0.18)])   // above 0.175
        XCTAssertEqual(t.state, .occupied)
        XCTAssertEqual(t.vacRun, 0)
    }

    func testDepartureWithoutSnapshotChangeIsRejected() {
        var t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)], thumb: carThumb)
        XCTAssertEqual(t.snap, carThumb)
        // The detector loses the car, but the spot looks the same.
        let e = feed(&t, [reading(0), reading(0), reading(0)], thumb: carThumb)
        XCTAssertEqual(t.state, .occupied)
        XCTAssertEqual(e, [.vacantRejected(coverage: 0, change: 0, count: 1, logRow: true)])
        XCTAssertEqual(t.vacRun, 0)
    }

    func testOnlyTheFirstOfEach20RejectionsIsARow() {
        var t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)], thumb: carThumb)
        var rows = 0
        for _ in 0..<21 {
            for e in feed(&t, [reading(0), reading(0), reading(0)], thumb: carThumb) {
                if case .vacantRejected(_, _, _, let logRow) = e, logRow { rows += 1 }
            }
        }
        XCTAssertEqual(t.rejects, 21)
        XCTAssertEqual(rows, 2)                  // the 1st and the 21st
    }

    func testARealDepartureIsAcceptedAndFrees() {
        var t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)], thumb: carThumb)
        let occupiedSince = t.since
        let e = feed(&t, [reading(0), reading(0), reading(0)], thumb: emptyThumb)
        XCTAssertEqual(t.state, .vacant)
        XCTAssertEqual(e, [.changed(.vacant, coverage: 0, change: 40), .freed(coverage: 0, occupiedSince: occupiedSince)])
    }

    func testChangeMinZeroTurnsTheCheckOff() {
        var t = SpotTrack()
        var off = s
        off.changeMin = 0
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)], thumb: carThumb, settings: off)
        feed(&t, [reading(0), reading(0), reading(0)], thumb: carThumb, settings: off)
        XCTAssertEqual(t.state, .vacant)
    }

    func testThumbnailsOfAnotherSizeDontBlockADeparture() {
        var t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)], thumb: carThumb)
        feed(&t, [reading(0), reading(0), reading(0)], thumb: [0, 0])
        XCTAssertEqual(t.state, .vacant)
    }

    func testTheSnapshotRefreshesEvery10OccupiedReadings() {
        var t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)], thumb: carThumb)
        let later: [Float] = [41, -41, 41, -41]
        feed(&t, Array(repeating: reading(0.5), count: 9), thumb: later)
        XCTAssertEqual(t.snap, carThumb)
        feed(&t, [reading(0.5)], thumb: later)
        XCTAssertEqual(t.snap, later)
    }

    // MARK: Person near

    func testPersonNearOncePerVisitAndOnlyWhileOccupied() {
        var t = SpotTrack()
        // Vacant: a person near logs nothing.
        XCTAssertTrue(feed(&t, [reading(0, person: 0.8), reading(0, person: 0.8), reading(0, person: 0.8)])
            .allSatisfy { if case .personNear = $0 { return false } else { return true } })
        t = SpotTrack()
        feed(&t, [reading(0.5), reading(0.5), reading(0.5)])
        let since = t.since
        let first = feed(&t, [reading(0.5, person: 0.7), reading(0.5, person: 0.8), reading(0.5, person: 0.8)])
        XCTAssertEqual(first, [.personNear(coverage: 0.5, score: 0.8, occupiedSince: since)])
        // One reading without a person doesn't end the visit (hintN 2)...
        XCTAssertTrue(feed(&t, [reading(0.5), reading(0.5, person: 0.8), reading(0.5, person: 0.8)]).isEmpty)
        // ...two do, and the next person starts a new visit.
        feed(&t, [reading(0.5), reading(0.5)])
        XCTAssertEqual(feed(&t, [reading(0.5, person: 0.6), reading(0.5, person: 0.6)]).count, 1)
    }

    // MARK: Thumbnails

    func testThumbnailRemovesTheMeanAndUsesLuma() {
        // Two pixels: black and white (RGBA), 2×1, rows of 8 bytes.
        let g = SpotLogic.thumbnail(rgba: [0, 0, 0, 255, 255, 255, 255, 255], width: 2, height: 1, rowBytes: 8)
        XCTAssertEqual(g[0], -127.5, accuracy: 0.01)
        XCTAssertEqual(g[1], 127.5, accuracy: 0.01)
        // The same picture, brighter overall, gives the same thumbnail.
        let brighter = SpotLogic.thumbnail(rgba: [50, 50, 50, 255, 255, 255, 255, 255], width: 2, height: 1, rowBytes: 8)
        XCTAssertEqual(SpotLogic.thumbDiff(g, brighter)!, 25, accuracy: 0.01)
        XCTAssertEqual(SpotLogic.thumbDiff(g, g), 0)
        XCTAssertNil(SpotLogic.thumbDiff(g, [0]))
    }

    func testThumbSizeKeepsTheSpotShapeWithinLimits() {
        XCTAssertEqual(SpotLogic.thumbSize(spotWidth: 200, spotHeight: 100).height, 16)
        XCTAssertEqual(SpotLogic.thumbSize(spotWidth: 400, spotHeight: 10).height, 4)
        XCTAssertEqual(SpotLogic.thumbSize(spotWidth: 10, spotHeight: 400).height, 48)
    }
}
