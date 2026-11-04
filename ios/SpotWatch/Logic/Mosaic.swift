import Foundation

// How a check's views go into the detector and how its boxes come back,
// ported from the web app's mosaicLayout and detectViews. Foundation only.

/// One view placed in a square detector input. `s*` is the view in frame
/// pixels, `t*`/`d*` where it sits in the input (top-left origin), and `k`
/// input pixels per frame pixel.
struct Tile: Equatable {
    let sx: Double, sy: Double, sw: Double, sh: Double
    let k: Double
    let tx: Double, ty: Double, dw: Double, dh: Double
}

/// All views tiled into one 640 input (as in the web app), or one run per
/// view at 320 or 640.
enum ViewMode: String, CaseIterable, Identifiable {
    case mosaic640 = "Mosaic 640", each320 = "Each 320", each640 = "Each 640"

    var id: String { rawValue }
    var side: Int { self == .each320 ? 320 : 640 }
    var perView: Bool { self != .mosaic640 }
}

enum Mosaic {
    /// Lays the views out on a side×side input: one view fills it, more share
    /// a grid (2×2 for up to four). Each view is scaled to fit its tile,
    /// keeping its shape, so a small spot is enlarged.
    static func layout(_ views: [FracRect], frameWidth vw: Double, frameHeight vh: Double, side: Double) -> [Tile] {
        let grid = Int(Double(views.count).squareRoot().rounded(.up))
        let tile = side / Double(max(1, grid))
        return views.enumerated().map { i, v in
            let sx = (v.x * vw).rounded(), sy = (v.y * vh).rounded()
            let sw = max(1, (v.w * vw).rounded()), sh = max(1, (v.h * vh).rounded())
            let k = min(tile / sw, tile / sh)
            return Tile(sx: sx, sy: sy, sw: sw, sh: sh, k: k,
                        tx: Double(i % grid) * tile, ty: Double(i / grid) * tile,
                        dw: max(1, (sw * k).rounded()), dh: max(1, (sh * k).rounded()))
        }
    }

    /// The detector runs for a check, each the tiles of one input.
    static func inputs(_ views: [FracRect], frameWidth: Double, frameHeight: Double, mode: ViewMode) -> [[Tile]] {
        let side = Double(mode.side)
        if mode.perView {
            return views.map { layout([$0], frameWidth: frameWidth, frameHeight: frameHeight, side: side) }
        }
        return [layout(views, frameWidth: frameWidth, frameHeight: frameHeight, side: side)]
    }

    /// Detections in input pixels to frame pixels. Each box belongs to the
    /// tile its centre falls in and is clipped to it; a box centred on the
    /// padding is dropped.
    static func mapBack(_ found: [Detection], tiles: [Tile]) -> [Detection] {
        found.compactMap { d in
            let b = d.box
            let cx = b.x + b.w / 2, cy = b.y + b.h / 2
            guard let t = tiles.first(where: { cx >= $0.tx && cx < $0.tx + $0.dw && cy >= $0.ty && cy < $0.ty + $0.dh })
            else { return nil }
            let x0 = max(b.x, t.tx), y0 = max(b.y, t.ty)
            let x1 = min(b.x + b.w, t.tx + t.dw), y1 = min(b.y + b.h, t.ty + t.dh)
            return d.with(box: Box(x: t.sx + (x0 - t.tx) / t.k, y: t.sy + (y0 - t.ty) / t.k,
                                   w: (x1 - x0) / t.k, h: (y1 - y0) / t.k))
        }
    }
}
