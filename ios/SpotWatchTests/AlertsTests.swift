import XCTest
@testable import SpotWatch

final class AlertsTests: XCTestCase {
    func testPrioritiesAndTagsMatchTheWebApp() {
        let expected: [AlertType: (Int, String)] = [
            .test: (3, "test_tube"), .free: (5, "rotating_light"), .headsup: (4, "eyes"), .camera: (3, "warning"),
            .hunt: (2, "white_check_mark"), .export: (1, "floppy_disk"), .power: (1, "battery")
        ]
        for t in AlertType.allCases {
            XCTAssertEqual(t.priority, expected[t]?.0, t.rawValue)
            XCTAssertEqual(t.tags, expected[t]?.1, t.rawValue)
        }
    }

    func testPublishURLUsesQueryParams() {
        XCTAssertEqual(Ntfy.publishURL(topic: "spotwatch-abc", title: "Spot 1 is FREE", priority: 5, tags: "rotating_light")?.absoluteString,
                       "https://ntfy.sh/spotwatch-abc?title=Spot%201%20is%20FREE&priority=5&tags=rotating_light")
        XCTAssertEqual(Ntfy.publishURL(topic: "t", title: "[test] Hunting on until 13:00", priority: 2, tags: nil)?.absoluteString,
                       "https://ntfy.sh/t?title=%5Btest%5D%20Hunting%20on%20until%2013%3A00&priority=2")
        XCTAssertEqual(Ntfy.publishURL(topic: "t", title: nil, priority: nil, tags: nil)?.absoluteString, "https://ntfy.sh/t")
        XCTAssertEqual(Ntfy.encode("a–b & c=d"), "a%E2%80%93b%20%26%20c%3Dd")
    }

    func testTopics() {
        XCTAssertTrue(Ntfy.validTopic("spotwatch-k3x9q2m7"))
        XCTAssertTrue(Ntfy.validTopic("A_b-9"))
        XCTAssertFalse(Ntfy.validTopic(""))
        XCTAssertFalse(Ntfy.validTopic("has space"))
        XCTAssertFalse(Ntfy.validTopic("café"))
        XCTAssertFalse(Ntfy.validTopic(String(repeating: "a", count: 65)))
    }

    func testStreamURL() {
        XCTAssertEqual(Ntfy.streamURL(topic: "ctl", since: "Ab12cd")?.absoluteString, "https://ntfy.sh/ctl/json?since=Ab12cd")
        XCTAssertEqual(Ntfy.streamURL(topic: "ctl", since: nil)?.absoluteString, "https://ntfy.sh/ctl/json")
        XCTAssertEqual(Ntfy.streamURL(topic: "ctl", since: "bad id!")?.absoluteString, "https://ntfy.sh/ctl/json")
    }

    func testControlMessages() {
        let m = ControlMessage.parse(#"{"id":"x1Y2","time":1793770323,"event":"message","topic":"ctl","message":"hunt on"}"#)
        XCTAssertEqual(m, ControlMessage(id: "x1Y2", time: Date(timeIntervalSince1970: 1_793_770_323), event: "message",
                                         message: "hunt on", title: ""))
        XCTAssertEqual(ControlMessage.parse(#"{"id":"k","time":1,"event":"keepalive","topic":"ctl"}"#)?.event, "keepalive")
        XCTAssertNil(ControlMessage.parse("not json"))
    }

    func testFreeRules() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SpotAlerts.freeSkip(hunting: false, last: nil, now: now, cooldownMin: 2), "not hunting")
        XCTAssertNil(SpotAlerts.freeSkip(hunting: true, last: nil, now: now, cooldownMin: 2))
        XCTAssertEqual(SpotAlerts.freeSkip(hunting: true, last: now - 119, now: now, cooldownMin: 2), "cooldown")
        XCTAssertNil(SpotAlerts.freeSkip(hunting: true, last: now - 120, now: now, cooldownMin: 2))
    }

    func testHeadsUpRules() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func skip(since: TimeInterval, last: TimeInterval?, hunting: Bool = true) -> String? {
            SpotAlerts.headsupSkip(hunting: hunting, occupiedSince: now - since, last: last.map { now - $0 }, now: now,
                                   graceMin: 2, cooldownMin: 3)
        }
        XCTAssertEqual(skip(since: 600, last: nil, hunting: false), "not hunting")
        XCTAssertEqual(skip(since: 60, last: nil), "arrival grace")
        XCTAssertNil(skip(since: 120, last: nil))
        XCTAssertEqual(skip(since: 600, last: 100), "cooldown")
        XCTAssertNil(skip(since: 600, last: 180))
    }

    func testAlertText() {
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 8, minute: 25, second: 38))!
        XCTAssertEqual(SpotAlerts.freeTitle(3), "Spot 3 is FREE")
        XCTAssertEqual(SpotAlerts.freeBody(3, at: t, occupiedSince: t - 3600),
                       "Spot 3 went vacant at 08:25:38; it had been occupied since 07:25:38.")
        XCTAssertEqual(SpotAlerts.freeBody(3, at: t, occupiedSince: nil), "Spot 3 went vacant at 08:25:38.")
        XCTAssertEqual(SpotAlerts.headsupBody(1, at: t), "Someone is at the parked car in spot 1 (08:25:38).")
    }
}
