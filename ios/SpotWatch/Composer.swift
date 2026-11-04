import CoreImage

/// Cuts views out of a frame with Core Image: the detector inputs (the web
/// app's drawMosaic) and the spot thumbnails for the departure check
/// (spotThumb). Rectangles come in frame pixels with a top-left origin.
enum Composer {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    /// A side×side input with each tile's view scaled into its place, on black.
    static func input(_ frame: CIImage, tiles: [Tile], side: Int) -> CIImage {
        let s = CGFloat(side)
        var image = CIImage(color: CIColor.black).cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
        for t in tiles {
            // Core Image's origin is the bottom-left, so the tile's y flips.
            let dst = CGRect(x: t.tx, y: Double(side) - t.ty - t.dh, width: t.dw, height: t.dh)
            image = cut(frame, Box(x: t.sx, y: t.sy, w: t.sw, h: t.sh), into: dst).composited(over: image)
        }
        return image
    }

    /// The spot's grey thumbnail with its mean removed (see SpotLogic.thumbnail).
    static func thumbnail(_ frame: CIImage, spot: Box, context: CIContext) -> [Float] {
        let size = SpotLogic.thumbSize(spotWidth: spot.w, spotHeight: spot.h)
        let rowBytes = size.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * size.height)
        let dst = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.render(cut(frame, spot, into: dst), toBitmap: &bytes, rowBytes: rowBytes, bounds: dst,
                       format: .RGBA8, colorSpace: sRGB)
        return SpotLogic.thumbnail(rgba: bytes, width: size.width, height: size.height, rowBytes: rowBytes)
    }

    /// The part of `frame` under `r` (frame pixels, top-left origin), scaled to fill `dst` (Core Image coordinates).
    private static func cut(_ frame: CIImage, _ r: Box, into dst: CGRect) -> CIImage {
        let e = frame.extent
        let src = CGRect(x: e.minX + r.x, y: e.maxY - r.y - r.h, width: r.w, height: r.h)
        return frame.cropped(to: src).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
            .transformed(by: CGAffineTransform(scaleX: dst.width / src.width, y: dst.height / src.height))
            .transformed(by: CGAffineTransform(translationX: dst.minX, y: dst.minY))
            .cropped(to: dst)
    }
}
