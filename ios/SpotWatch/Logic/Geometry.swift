import Foundation

// Spots and the detector's views of them, ported from the web app
// (spotViews, shapeOf, overlapArea, iou, dedupe). Foundation only.

/// A rectangle as fractions (0–1) of the frame, top-left origin.
struct FracRect: Equatable, Codable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let full = FracRect(x: 0, y: 0, w: 1, h: 1)

    func pixels(width: Double, height: Double) -> Box {
        Box(x: x * width, y: y * height, w: w * width, h: h * height)
    }

    /// "x 12%, y 40%, w 20%, h 15%"
    var text: String {
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        return "x \(pct(x)), y \(pct(y)), w \(pct(w)), h \(pct(h))"
    }
}

/// A hand-drawn parking spot, as fractions of the frame, with the frame shape
/// it was drawn on. The same fractions point at another part of the street on
/// another shape, so a spot only applies while the frame has its shape.
struct Spot: Equatable, Codable {
    var rect: FracRect
    var shape: String

    var isValid: Bool {
        let r = rect
        return [r.x, r.y, r.w, r.h].allSatisfy { $0.isFinite } && r.x >= 0 && r.y >= 0 && r.w > 0 && r.h > 0
            && r.x + r.w <= 1.0001 && r.y + r.h <= 1.0001 && !shape.isEmpty
    }

    var text: String { "\(rect.text), \(shape)" }
}

enum Geometry {
    static let cropMargin = 0.5        // margin around each spot's view, as a share of the spot's size
    static let cropMinMargin = 0.05    // ...but at least this share of the frame
    static let duplicateIoU = 0.5      // the same object seen twice is kept once
    static let minSpotSide = 0.02      // a drawn box narrower or shorter than this is a stray tap

    /// Where the frame comes from plus its aspect, e.g. "landscape right 4:3".
    /// The label names the mount (the interface orientation) or the test image,
    /// since a phone turned the other way round sees the street upside down.
    static func shape(width: Double, height: Double, label: String) -> String {
        let r = max(width, height) / max(1, min(width, height))
        let ratio = abs(r - 16.0 / 9) < 0.05 ? "16:9" : abs(r - 4.0 / 3) < 0.05 ? "4:3" : String(format: "%.2f", r)
        return "\(label) \(width >= height ? "" : "portrait ")\(ratio)"
    }

    /// The detector's view of each spot: the spot plus a margin of `cropMargin`
    /// of its size on each side (at least `cropMinMargin` of the frame),
    /// clipped to the frame. The whole frame when no spot is active.
    static func views(_ spots: [FracRect]) -> [FracRect] {
        let views = spots.map { s -> FracRect in
            let mx = max(cropMargin * s.w, cropMinMargin), my = max(cropMargin * s.h, cropMinMargin)
            let x0 = max(0, s.x - mx), y0 = max(0, s.y - my)
            let x1 = min(1, s.x + s.w + mx), y1 = min(1, s.y + s.h + my)
            return FracRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        }
        return views.isEmpty ? [.full] : views
    }

    static func overlapArea(_ a: Box, _ b: Box) -> Double {
        let ow = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
        let oh = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
        return ow > 0 && oh > 0 ? ow * oh : 0
    }

    static func iou(_ a: Box, _ b: Box) -> Double {
        let inter = overlapArea(a, b)
        let union = a.area + b.area - inter
        return union > 0 ? inter / union : 0
    }

    /// Keeps the best of each group of same-class boxes overlapping by more
    /// than `duplicateIoU`: neighbouring views overlap, and the end-to-end head
    /// can return one object twice.
    static func dedupe(_ dets: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for d in dets.sorted(by: { $0.score > $1.score }) where
            !kept.contains(where: { $0.classIndex == d.classIndex && iou($0.box, d.box) > duplicateIoU }) {
            kept.append(d)
        }
        return kept
    }
}
