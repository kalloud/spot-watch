import XCTest
@testable import SpotWatch

final class EventsTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_793_770_323.5)     // 2026-11-04T05:32:03.500Z

    func testIsoMatchesJavaScript() {
        XCTAssertEqual(EventFormat.iso(t), "2026-11-04T05:32:03.500Z")
    }

    func testCsvQuoting() {
        XCTAssertEqual(EventFormat.csvField("plain"), "plain")
        XCTAssertEqual(EventFormat.csvField("change 12.3, 2 so far"), "\"change 12.3, 2 so far\"")
        XCTAssertEqual(EventFormat.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(EventFormat.csvField("two\nlines"), "\"two\nlines\"")
    }

    func testCsvHasTheWebColumns() {
        let rows = [EventRow(time: t, spot: nil, event: "start", coverage: nil, hunting: false, detail: ""),
                    EventRow(time: t, spot: 2, event: "vacant", coverage: 3, hunting: true, detail: "change 41.0")]
        XCTAssertEqual(EventFormat.csv(rows),
                       "time,spot,event,coverage_pct,hunting,detail\n" +
                       "2026-11-04T05:32:03.500Z,,start,,0,\n" +
                       "2026-11-04T05:32:03.500Z,2,vacant,3,1,change 41.0\n")
    }

    func testJsonLinesRoundTrip() {
        let rows = [EventRow(time: t, spot: 1, event: "person_near", coverage: 45, hunting: false, detail: "person 81%, \"x\""),
                    EventRow(time: t, spot: nil, event: "start", coverage: nil, hunting: true, detail: "")]
        for r in rows {
            XCTAssertEqual(EventFormat.row(jsonLine: Substring(EventFormat.jsonLine(r))), r)
        }
        XCTAssertNil(EventFormat.row(jsonLine: "not json"))
    }

    func testEventText() {
        XCTAssertEqual(EventFormat.text(EventRow(time: t, spot: 1, event: "occupied", coverage: 45, hunting: false, detail: "")),
                       "Spot 1 occupied · 45%")
        XCTAssertEqual(EventFormat.text(EventRow(time: t, spot: nil, event: "start", coverage: nil, hunting: false, detail: "")),
                       "start")
    }
}

final class ConfigTests: XCTestCase {
    func testDefaultsMatchTheSettingsTable() {
        let c = Config()
        for d in Settings.all { XCTAssertEqual(c[keyPath: d.path], d.def, d.key) }
        XCTAssertEqual(c.spotSettings, SpotSettings())
    }

    func testParse() {
        let occ = Settings.all.first { $0.key == "occThresh" }!
        XCTAssertEqual(occ.parse("0,4"), 0.4)
        XCTAssertEqual(occ.parse(" 0.5 "), 0.5)
        XCTAssertNil(occ.parse("0.99"))
        XCTAssertNil(occ.parse(""))
        XCTAssertNil(occ.parse("abc"))
        let n = Settings.all.first { $0.key == "confirmN" }!
        XCTAssertEqual(n.parse("3.6"), 4)
    }
}
