import CoreImage
import UIKit

/// Photos of checked frames with the spots and detections drawn on, in
/// `Application Support/SpotWatch/photos` next to the event log, newest
/// `PhotoPlan.maxPhotos` kept. Drawing, writing and zipping run on the photo
/// queue, so a camera frame is held only until its photo is written.
final class PhotoStore {
    struct SpotMark {
        let rect: Box                   // frame pixels
        let label: String
        let state: SpotState
    }

    struct Shot {
        let frame: CIImage
        let time: Date
        let caption: [String]
        let spots: [SpotMark]
        let detections: [Detection]
    }

    struct Status {
        let count: Int
        let megabytes: Double
        let last: Date?
        let failure: String?
    }

    enum PhotoError: LocalizedError {
        case render
        var errorDescription: String? { "Core Image could not render the frame" }
    }

    static let width: CGFloat = 1280
    static let quality: CGFloat = 0.5
    static let maxWaiting = 2           // photos queued and not yet written; more are skipped

    // The overlay's colours.
    private static let vehicle = UIColor(red: 1, green: 0.62, blue: 0.11, alpha: 1)
    private static let person = UIColor(red: 0.18, green: 0.77, blue: 0.95, alpha: 1)
    private static let other = UIColor(red: 0.6, green: 0.64, blue: 0.7, alpha: 1)
    private static func color(_ s: SpotState) -> UIColor {
        switch s {
        case .occupied: return UIColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 1)
        case .vacant: return UIColor(red: 0.25, green: 0.73, blue: 0.31, alpha: 1)
        case .unknown: return UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)
        }
    }
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    let directory: URL
    /// Called on the photo queue after each save or failure, and on `refresh`.
    var onStatus: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "spotwatch.photos", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let format: UIGraphicsImageRendererFormat
    private let lock = NSLock()
    private var waiting = 0             // guarded by `lock`
    private var last: Date?             // photo queue only

    /// Make it on the main thread: the renderer format reads the screen.
    init(directory: URL) {
        self.directory = directory
        format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
    }

    static func defaultDirectory() -> URL {
        EventStore.defaultDirectory().appendingPathComponent("photos", isDirectory: true)
    }

    /// Reports what is already on disk.
    func refresh() {
        queue.async { self.report(failure: nil) }
    }

    /// Queues a photo; false when too many are still waiting to be written.
    func save(_ shot: Shot) -> Bool {
        lock.lock()
        guard waiting < PhotoStore.maxWaiting else {
            lock.unlock()
            return false
        }
        waiting += 1
        lock.unlock()
        queue.async {
            defer {
                self.lock.lock()
                self.waiting -= 1
                self.lock.unlock()
            }
            do {
                let data = try self.render(shot)
                let fm = FileManager.default
                try fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
                var copy = 1
                var url = self.directory.appendingPathComponent(PhotoPlan.fileName(shot.time))
                while fm.fileExists(atPath: url.path) {
                    copy += 1
                    url = self.directory.appendingPathComponent(PhotoPlan.fileName(shot.time, copy: copy))
                }
                try data.write(to: url, options: .atomic)
                self.last = shot.time
                for name in PhotoPlan.excess(self.names(), keep: PhotoPlan.maxPhotos) {
                    try fm.removeItem(at: self.directory.appendingPathComponent(name))
                }
                self.report(failure: nil)
            } catch {
                self.report(failure: "Photo not saved: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Zips every photo into a temporary file called `name`, for the share
    /// sheet: the file and the photo count, or nil when there are no photos.
    func zip(named name: String, completion: @escaping (Result<(url: URL, count: Int)?, Error>) -> Void) {
        queue.async {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            // Earlier exports' zips are large: only the newest is kept.
            for old in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where old.hasPrefix("spotwatch-photos-") {
                try? fm.removeItem(at: tmp.appendingPathComponent(old))
            }
            let count = self.names().count
            guard count > 0 else { return completion(.success(nil)) }
            let dst = tmp.appendingPathComponent(name)
            var coordinatorError: NSError?
            var moveError: Error?
            // Reading a folder "for uploading" hands over a zip of it, so no zip library is needed.
            NSFileCoordinator().coordinate(readingItemAt: self.directory, options: .forUploading,
                                           error: &coordinatorError) { zipped in
                do { try fm.moveItem(at: zipped, to: dst) } catch { moveError = error }
            }
            if let e = coordinatorError ?? moveError {
                completion(.failure(e))
            } else {
                completion(.success((dst, count)))
            }
        }
    }

    // MARK: - Photo queue

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".jpg") }
    }

    private func report(failure: String?) {
        var bytes = 0
        let names = self.names()
        for n in names {
            let v = try? directory.appendingPathComponent(n).resourceValues(forKeys: [.fileSizeKey])
            bytes += v?.fileSize ?? 0
        }
        onStatus?(Status(count: names.count, megabytes: Double(bytes) / 1_048_576, last: last, failure: failure))
    }

    private func render(_ s: Shot) throws -> Data {
        let e = s.frame.extent
        let k = PhotoStore.width / e.width
        let size = CGSize(width: PhotoStore.width, height: (e.height * k).rounded())
        let scaled = s.frame
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size),
                                             format: .RGBA8, colorSpace: PhotoStore.sRGB) else { throw PhotoError.render }
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: PhotoStore.quality) { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            func scaledRect(_ b: Box) -> CGRect { CGRect(x: b.x * k, y: b.y * k, width: b.w * k, height: b.h * k) }

            let small = UIFont.systemFont(ofSize: 15, weight: .semibold)
            for d in s.detections {
                let r = scaledRect(d.box)
                let c = d.isVehicle ? PhotoStore.vehicle : d.isPerson ? PhotoStore.person : PhotoStore.other
                c.setStroke()
                let path = UIBezierPath(rect: r)
                path.lineWidth = 2
                path.stroke()
                tag("\(d.className) \(Int((d.score * 100).rounded()))%", at: r.origin, font: small, color: c,
                    above: true, width: size.width)
            }

            let big = UIFont.systemFont(ofSize: 20, weight: .bold)
            for m in s.spots {
                let r = scaledRect(m.rect)
                let c = PhotoStore.color(m.state)
                c.withAlphaComponent(0.15).setFill()
                UIBezierPath(rect: r).fill()
                c.setStroke()
                let path = UIBezierPath(rect: r)
                path.lineWidth = 3
                path.stroke()
                tag(m.label, at: r.origin, font: big, color: .white, above: false, width: size.width)
            }

            let line = UIFont.systemFont(ofSize: 18, weight: .regular)
            let first = UIFont.systemFont(ofSize: 18, weight: .bold)
            let band = CGRect(x: 0, y: 0, width: size.width, height: CGFloat(s.caption.count) * line.lineHeight + 12)
            UIColor.black.withAlphaComponent(0.6).setFill()
            UIBezierPath(rect: band).fill()
            for (i, text) in s.caption.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 10, y: 6 + CGFloat(i) * line.lineHeight),
                                        withAttributes: [.font: i == 0 ? first : line, .foregroundColor: UIColor.white])
            }
        }
    }

    /// A label on a dark tag at a box's top-left corner: above the box, or inside it.
    private func tag(_ text: String, at p: CGPoint, font: UIFont, color: UIColor, above: Bool, width: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        var r = CGRect(x: p.x, y: p.y, width: size.width + 8, height: size.height + 4)
        if above && p.y >= r.height { r.origin.y = p.y - r.height }
        r.origin.x = max(0, min(r.origin.x, width - r.width))
        UIColor.black.withAlphaComponent(0.65).setFill()
        UIBezierPath(rect: r).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 4, y: r.minY + 2), withAttributes: attrs)
    }
}
