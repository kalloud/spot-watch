import XCTest
@testable import SpotWatch

func car(_ x: Double, _ y: Double, _ w: Double, _ h: Double, score: Double = 0.9) -> Detection {
    Detection(classIndex: 2, score: score, box: Box(x: x, y: y, w: w, h: h))
}

func person(_ x: Double, _ y: Double, _ w: Double, _ h: Double, score: Double = 0.9) -> Detection {
    Detection(classIndex: 0, score: score, box: Box(x: x, y: y, w: w, h: h))
}

final class GeometryTests: XCTestCase {
    func testShape() {
        XCTAssertEqual(Geometry.shape(width: 1920, height: 1440, label: "landscape right"), "landscape right 4:3")
        XCTAssertEqual(Geometry.shape(width: 1280, height: 720, label: "landscape left"), "landscape left 16:9")
        XCTAssertEqual(Geometry.shape(width: 810, height: 1080, label: "bus.jpg"), "bus.jpg portrait 4:3")
    }

    func testViewAddsHalfTheSpotOnEachSide() {
        let v = Geometry.views([FracRect(x: 0.4, y: 0.4, w: 0.2, h: 0.2)])
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(v[0].w, 0.4, accuracy: 1e-9)
    }

    func testSmallSpotGetsTheMinimumMarginAndEdgesClip() {
        // A 4% spot gets 5% of the frame each side (not 2%); at the left edge it clips to 0.
        let v = Geometry.views([FracRect(x: 0.01, y: 0.5, w: 0.04, h: 0.04)])[0]
        XCTAssertEqual(v.x, 0, accuracy: 1e-9)
        XCTAssertEqual(v.w, 0.10, accuracy: 1e-9)      // 0 to 0.01 + 0.04 + 0.05
        XCTAssertEqual(v.y, 0.45, accuracy: 1e-9)
        XCTAssertEqual(v.h, 0.14, accuracy: 1e-9)
    }

    func testNoSpotsMeansTheWholeFrame() {
        XCTAssertEqual(Geometry.views([]), [.full])
    }

    func testOverlapAndIoU() {
        let a = Box(x: 0, y: 0, w: 10, h: 10), b = Box(x: 5, y: 0, w: 10, h: 10)
        XCTAssertEqual(Geometry.overlapArea(a, b), 50)
        XCTAssertEqual(Geometry.iou(a, b), 50.0 / 150, accuracy: 1e-9)
        XCTAssertEqual(Geometry.overlapArea(a, Box(x: 10, y: 0, w: 5, h: 5)), 0)
    }

    func testDedupeKeepsTheBestOfEachDuplicate() {
        let kept = Geometry.dedupe([car(0, 0, 10, 10, score: 0.5), car(1, 0, 10, 10, score: 0.8),
                                    person(0, 0, 10, 10, score: 0.4), car(50, 50, 10, 10, score: 0.3)])
        XCTAssertEqual(kept.map(\.score), [0.8, 0.4, 0.3])
    }

    func testSpotValidity() {
        XCTAssertTrue(Spot(rect: FracRect(x: 0.8, y: 0, w: 0.2, h: 1), shape: "landscape right 4:3").isValid)
        XCTAssertFalse(Spot(rect: FracRect(x: 0.9, y: 0, w: 0.2, h: 0.1), shape: "landscape right 4:3").isValid)
        XCTAssertFalse(Spot(rect: FracRect(x: 0.1, y: 0.1, w: 0, h: 0.1), shape: "landscape right 4:3").isValid)
    }
}

final class MosaicTests: XCTestCase {
    func testOneViewFillsTheInputLikeALetterbox() {
        let t = Mosaic.layout([.full], frameWidth: 1920, frameHeight: 1440, side: 640)
        XCTAssertEqual(t, [Tile(sx: 0, sy: 0, sw: 1920, sh: 1440, k: 1.0 / 3, tx: 0, ty: 0, dw: 640, dh: 480)])
    }

    func testThreeViewsShareA2x2Grid() {
        let views = [FracRect(x: 0, y: 0, w: 0.5, h: 0.5), FracRect(x: 0.5, y: 0, w: 0.25, h: 0.5),
                     FracRect(x: 0.5, y: 0.5, w: 0.5, h: 0.25)]
        let t = Mosaic.layout(views, frameWidth: 1000, frameHeight: 1000, side: 640)
        XCTAssertEqual(t.map(\.tx), [0, 320, 0])
        XCTAssertEqual(t.map(\.ty), [0, 0, 320])
        XCTAssertEqual(t[0].k, 0.64, accuracy: 1e-9)         // 500 px into 320
        XCTAssertEqual(t[1].dw, 160)                         // 250×500 fits as 160×320
        XCTAssertEqual(t[1].dh, 320)
        XCTAssertEqual(t[2].dw, 320)
        XCTAssertEqual(t[2].dh, 160)
    }

    func testBoxesMapBackToFramePixels() {
        let tiles = Mosaic.layout([FracRect(x: 0.5, y: 0.5, w: 0.25, h: 0.25)], frameWidth: 1920, frameHeight: 1440, side: 640)
        // The view is 480×360 at (960, 720), scaled by 4/3 into 640×480.
        let mapped = Mosaic.mapBack([car(64, 48, 128, 96)], tiles: tiles)
        XCTAssertEqual(mapped.first!.box.x, 1008, accuracy: 1e-6)
        XCTAssertEqual(mapped.first!.box.y, 756, accuracy: 1e-6)
        XCTAssertEqual(mapped.first!.box.w, 96, accuracy: 1e-6)
        XCTAssertEqual(mapped.first!.box.h, 72, accuracy: 1e-6)
    }

    func testABoxIsClippedToItsTileAndPaddingIsIgnored() {
        let views = [FracRect(x: 0, y: 0, w: 0.5, h: 0.5), FracRect(x: 0.5, y: 0, w: 0.5, h: 0.5)]
        let tiles = Mosaic.layout(views, frameWidth: 1000, frameHeight: 1000, side: 640)
        // Centred in tile 0 (0–320), spilling 40 px into tile 1: cut at 320.
        let spill = Mosaic.mapBack([car(200, 100, 160, 50)], tiles: tiles)
        XCTAssertEqual(spill.first!.box.w, 120 / 0.64, accuracy: 1e-6)
        // Centred in the empty lower half of the grid: dropped.
        XCTAssertTrue(Mosaic.mapBack([car(100, 400, 50, 50)], tiles: tiles).isEmpty)
    }

    func testPerViewModesGiveOneInputPerView() {
        let views = Geometry.views([FracRect(x: 0.1, y: 0.1, w: 0.1, h: 0.1), FracRect(x: 0.6, y: 0.6, w: 0.1, h: 0.1)])
        let each = Mosaic.inputs(views, frameWidth: 1920, frameHeight: 1440, mode: .each320)
        XCTAssertEqual(each.count, 2)
        XCTAssertEqual(each[0].count, 1)
        XCTAssertEqual(max(each[0][0].dw, each[0][0].dh), 320)
        XCTAssertEqual(Mosaic.inputs(views, frameWidth: 1920, frameHeight: 1440, mode: .mosaic640).map(\.count), [2])
    }
}
