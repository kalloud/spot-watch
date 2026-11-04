import XCTest
@testable import SpotWatch

final class MotionTests: XCTestCase {
    /// Gravity for a phone tilted `deg` degrees from lying along -z.
    private func gravity(_ deg: Double) -> [Double] {
        let a = deg * .pi / 180
        return [sin(a), 0, -cos(a)]
    }

    /// Feeds 10 samples a second from `from` to `to` s; returns the changes seen, with their times.
    private func feed(_ g: inout MotionGuard, from: Double, to: Double, deg: Double, rotation: Double = 0.01) -> [(Double, MotionGuard.Change)] {
        var out: [(Double, MotionGuard.Change)] = []
        var t = from
        while t < to - 1e-9 {
            let c = g.add(t: t, gravity: gravity(deg), rotation: rotation)
            if c != .none { out.append((t, c)) }
            t += 0.1
        }
        return out
    }

    func testStillPhoneNeverMoves() {
        var g = MotionGuard()
        XCTAssertTrue(feed(&g, from: 0, to: 60, deg: 0).isEmpty)
        XCTAssertTrue(feed(&g, from: 60, to: 70, deg: 0, rotation: 0.1).isEmpty, "window vibration")
        XCTAssertTrue(feed(&g, from: 70, to: 80, deg: 1).isEmpty, "a small sag")
        XCTAssertFalse(g.moving)
    }

    func testPickupStartsAndSettlesAfterFiveSeconds() {
        var g = MotionGuard()
        _ = feed(&g, from: 0, to: 5, deg: 0)
        let pickup = feed(&g, from: 5, to: 6, deg: 0, rotation: 1.5)
        XCTAssertEqual(pickup.map(\.1), [.started])
        XCTAssertTrue(g.moving)
        let back = feed(&g, from: 6, to: 12, deg: 0)
        XCTAssertEqual(back.map(\.1), [.settled])
        XCTAssertEqual(back.first?.0 ?? 0, 10.9, accuracy: 0.15, "5 s after the last motion at 5.9 s")
        XCTAssertFalse(g.moving)
    }

    func testSlowTiltCountsAsMovingThenBecomesTheNewRest() {
        var g = MotionGuard()
        _ = feed(&g, from: 0, to: 5, deg: 0)
        let tilted = feed(&g, from: 5, to: 30, deg: 6)      // no rotation spike, just a new angle
        XCTAssertEqual(tilted.map(\.1), [.started, .settled])
        XCTAssertEqual(tilted.first?.0 ?? 0, 5, accuracy: 0.05)
        XCTAssertLessThan(MotionGuard.degrees(g.rest!, gravity(6)), 0.5, "held still at 6°, so 6° is the new rest")
        XCTAssertTrue(feed(&g, from: 30, to: 40, deg: 6).isEmpty)
    }

    func testDegrees() {
        XCTAssertEqual(MotionGuard.degrees(gravity(0), gravity(10)), 10, accuracy: 1e-9)
        XCTAssertNil(MotionGuard.unit([0, 0, 0]))
    }
}
