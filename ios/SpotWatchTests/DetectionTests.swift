import XCTest
@testable import SpotWatch

final class DetectionTests: XCTestCase {
    // A 1280×960 frame in a 640 input: half scale, 160 px of padding at the bottom.
    let landscape = Letterbox(frameWidth: 1280, frameHeight: 960, side: 640)

    func testScaleFitsTheLongerSide() {
        XCTAssertEqual(landscape.scale, 0.5)
        XCTAssertEqual(Letterbox(frameWidth: 810, frameHeight: 1080, side: 320).scale, 320.0 / 1080)
    }

    func testRowsMapBackToFramePixels() {
        let rows: [Float] = [100, 50, 300, 150, 0.9, 2]
        let d = YOLO26.detections(rows: rows, letterbox: landscape)
        XCTAssertEqual(d, [Detection(classIndex: 2, score: Double(Float(0.9)), box: Box(x: 200, y: 100, w: 400, h: 200))])
        XCTAssertEqual(d.first?.className, "car")
        XCTAssertEqual(d.first?.isVehicle, true)
    }

    func testBoxesInThePaddingAreClippedToTheFrame() {
        // The frame ends at input y 480; a box reaching into the padding stops there.
        let rows: [Float] = [-10, 400, 700, 600, 0.5, 0]
        let d = YOLO26.detections(rows: rows, letterbox: landscape)
        XCTAssertEqual(d.first?.box, Box(x: 0, y: 800, w: 1280, h: 160))
        XCTAssertEqual(d.first?.isPerson, true)
    }

    func testBoxesWhollyInThePaddingAreDropped() {
        let rows: [Float] = [10, 500, 50, 600, 0.8, 2]
        XCTAssertTrue(YOLO26.detections(rows: rows, letterbox: landscape).isEmpty)
    }

    func testLowScoresAreDropped() {
        let rows: [Float] = [0, 0, 10, 10, 0.19, 2,
                             0, 0, 10, 10, 0.2, 7]
        let d = YOLO26.detections(rows: rows, letterbox: landscape)
        XCTAssertEqual(d.map(\.className), ["truck"])
    }

    func testAtMostMaxBoxes() {
        let row: [Float] = [0, 0, 10, 10, 0.9, 0]
        let rows = Array([[Float]](repeating: row, count: 300).joined())
        XCTAssertEqual(YOLO26.detections(rows: rows, letterbox: landscape).count, YOLO26.maxBoxes)
        XCTAssertEqual(YOLO26.detections(rows: rows, letterbox: landscape, maxBoxes: 5).count, 5)
    }

    func testUnknownClassGetsAName() {
        XCTAssertEqual(COCO.classes.count, 80)
        XCTAssertEqual(COCO.name(80), "class 80")
    }

    func testSummary() {
        let car = Detection(classIndex: 2, score: 0.9, box: Box(x: 0, y: 0, w: 1, h: 1))
        let person = Detection(classIndex: 0, score: 0.9, box: Box(x: 0, y: 0, w: 1, h: 1))
        XCTAssertEqual(YOLO26.summarize([car, person, car]), "2 car, 1 person")
        XCTAssertEqual(YOLO26.summarize([]), "Nothing detected")
    }
}

final class TimingTests: XCTestCase {
    func testFirstRunIsKeptApart() {
        var s = TimingStats()
        XCTAssertNil(s.average)
        s.add(5000)
        XCTAssertEqual(s.first, 5000)
        XCTAssertNil(s.average)
        s.add(200)
        s.add(100)
        XCTAssertEqual(s.average, 150)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.min, 100)
        XCTAssertEqual(s.max, 200)
        XCTAssertEqual(s.last, 100)
    }

    func testBusyPercent() {
        var b = BusyTracker(keep: 3)
        b.add(start: 0, duration: 0.5)
        XCTAssertNil(b.percent)
        b.add(start: 1, duration: 0.5)
        XCTAssertEqual(b.percent, 67)       // 1 s busy over 1.5 s
        b.add(start: 2, duration: 1)
        b.add(start: 3, duration: 1)        // drops the first check
        XCTAssertEqual(b.checks.count, 3)
        XCTAssertEqual(b.percent, 83)       // 2.5 s busy over 3 s
    }

    func testFormat() {
        XCTAssertEqual(Format.ms(212.4), "212 ms")
        XCTAssertEqual(Format.ms(12_345), "12.3 s")
        XCTAssertEqual(Format.ms(nil), "–")
    }
}
