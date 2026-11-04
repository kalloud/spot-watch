import CoreImage
import CoreML
import Foundation

enum Source: String, CaseIterable, Identifiable {
    case camera = "Camera", testImage = "bus.jpg"
    var id: String { rawValue }
}

enum Compute: String, CaseIterable, Identifiable {
    case gpu = "GPU", cpu = "CPU"
    var id: String { rawValue }
    var units: MLComputeUnits { self == .gpu ? .cpuAndGPU : .cpuOnly }
}

/// The weights and arithmetic of the Core ML export. On the 6s, FP16 ran
/// 640 in about 320 ms against 550 ms for FP32 (first runs, N0).
enum Precision: String, CaseIterable, Identifiable {
    case fp16 = "FP16", fp32 = "FP32"
    var id: String { rawValue }
}

/// Frames in, detections out, off the main thread. Checks run one at a time on
/// the detect queue, at most once per interval, on the newest frame. Each check
/// looks at one view per active spot (the web app's per-spot views), or at
/// the whole frame when no spot is active.
final class Pipeline {
    struct Options: Equatable {
        var mode = ViewMode.each320
        var intervalMs = 1500.0
        var minScore = 0.2
        var source = Source.camera
        var paused = false
        var shape = ""                      // the frame shape `spots` were picked for
        var spots: [Int: FracRect] = [:]    // active spots by index (0-based)
    }

    struct Run {
        let side: Int
        let inferMs: Double
        let first: Bool                     // first run since the model loaded
    }

    struct CheckResult {
        let started: Date
        let source: Source
        let shape: String
        let spots: [Int: FracRect]
        let frameWidth: Double
        let frameHeight: Double
        let views: [FracRect]
        let detections: [Detection]         // frame pixels, de-duplicated
        let thumbs: [Int: [Float]]          // each active spot's thumbnail from this frame
        let runs: [Run]
        let prepMs: Double                  // cutting views into inputs, and the thumbnails
        let totalMs: Double
    }

    enum Event {
        case modelLoading(Int)
        case modelLoaded(Int, loadMs: Double, spec: String)
        case modelFailed(Int, String)
        case check(CheckResult)
        case checkFailed(String)
        case frameShape(Int, Int)
        case testImageFailed(String)
    }

    let camera = Camera()
    /// Called on background queues.
    var onEvent: ((Event) -> Void)?

    private let detectQueue = DispatchQueue(label: "spotwatch.detect", qos: .userInitiated)
    private let tickQueue = DispatchQueue(label: "spotwatch.tick")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timer: DispatchSourceTimer?

    // Guarded by `lock`.
    private let lock = NSLock()
    private var options = Options()
    private var busy = false
    private var nextDue = 0.0
    private var frameTimes: [Double] = []
    private var lastFrameAt: Double?
    private var lastShape: (Int, Int)?

    // Detect queue only.
    private var models: [Int: YOLOModel] = [:]
    private var ranSinceLoad: Set<Int> = []

    // Tick queue only.
    private var reportedNoTestImage = false
    private lazy var testImage: CIImage? = {
        guard let url = Bundle.main.url(forResource: "bus", withExtension: "jpg") else { return nil }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }()

    func start(_ options: Options, compute: Compute, precision: Precision) {
        lock.lock()
        self.options = options
        lock.unlock()
        camera.onFrame = { [weak self] pb in self?.cameraFrame(pb) }
        if options.source == .camera { camera.start() }
        loadModels(compute, precision)
        let t = DispatchSource.makeTimerSource(queue: tickQueue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func update(_ new: Options) {
        lock.lock()
        let old = options
        options = new
        if new.intervalMs != old.intervalMs || new.paused != old.paused { nextDue = 0 }
        lock.unlock()
        if new.source != old.source {
            if new.source == .camera { camera.start() } else { camera.stop() }
        }
    }

    func loadModels(_ compute: Compute, _ precision: Precision) {
        detectQueue.async {
            self.models = [:]
            self.ranSinceLoad = []
            for side in [640, 320] {
                self.onEvent?(.modelLoading(side))
                do {
                    let m = try YOLOModel(side: side, precision: precision, computeUnits: compute.units)
                    self.models[side] = m
                    self.onEvent?(.modelLoaded(side, loadMs: m.loadMs, spec: m.specText))
                } catch {
                    self.onEvent?(.modelFailed(side, error.localizedDescription))
                }
            }
        }
    }

    /// Camera frames per second over the last 5 s, and seconds since the last frame.
    func frameRate() -> (fps: Double?, age: Double?) {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let recent = frameTimes.filter { now - $0 <= 5 }
        let fps = recent.count >= 2 ? Double(recent.count - 1) / (recent.last! - recent.first!) : nil
        return (fps, lastFrameAt.map { now - $0 })
    }

    // MARK: - Frames

    private func cameraFrame(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastFrameAt = now
        frameTimes.append(now)
        if frameTimes.count > 60 { frameTimes.removeFirst(frameTimes.count - 60) }
        let shapeChanged = lastShape.map { $0 != (w, h) } ?? true
        lastShape = (w, h)
        let wanted = options.source == .camera
        lock.unlock()
        if shapeChanged { onEvent?(.frameShape(w, h)) }
        if wanted { offer(CIImage(cvPixelBuffer: pb), source: .camera) }
    }

    private func tick() {
        lock.lock()
        let wanted = options.source == .testImage
        lock.unlock()
        guard wanted else { return }
        guard let image = testImage else {
            if !reportedNoTestImage { onEvent?(.testImageFailed("bus.jpg is missing from the app bundle.")) }
            reportedNoTestImage = true
            return
        }
        offer(image, source: .testImage)
    }

    private func offer(_ frame: CIImage, source: Source) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard !options.paused, !busy, now >= nextDue else {
            lock.unlock()
            return
        }
        busy = true
        nextDue = now + options.intervalMs / 1000
        let opts = options
        lock.unlock()
        detectQueue.async {
            self.check(frame, opts, source: source)
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
        }
    }

    // MARK: - Checks (detect queue)

    private func check(_ frame: CIImage, _ o: Options, source: Source) {
        guard let model = models[o.mode.side] else { return }
        let started = Date()
        let t0 = CFAbsoluteTimeGetCurrent()
        let fw = Double(frame.extent.width), fh = Double(frame.extent.height)
        let order = o.spots.keys.sorted()
        let views = Geometry.views(order.map { o.spots[$0]! })
        do {
            var found: [Detection] = []
            var runs: [Run] = []
            var prepMs = 0.0
            for tiles in Mosaic.inputs(views, frameWidth: fw, frameHeight: fh, mode: o.mode) {
                let run = try model.run(Composer.input(frame, tiles: tiles, side: model.side), context: context)
                let dets = YOLO26.detections(rows: run.rows, side: Double(model.side), minScore: o.minScore)
                found += Mosaic.mapBack(dets, tiles: tiles)
                prepMs += run.prepMs
                runs.append(Run(side: model.side, inferMs: run.inferMs, first: !ranSinceLoad.contains(model.side)))
                ranSinceLoad.insert(model.side)
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            var thumbs: [Int: [Float]] = [:]
            for i in order {
                thumbs[i] = Composer.thumbnail(frame, spot: o.spots[i]!.pixels(width: fw, height: fh), context: context)
            }
            prepMs += (CFAbsoluteTimeGetCurrent() - t1) * 1000
            onEvent?(.check(CheckResult(started: started, source: source, shape: o.shape, spots: o.spots,
                                        frameWidth: fw, frameHeight: fh, views: views,
                                        detections: Geometry.dedupe(found), thumbs: thumbs, runs: runs, prepMs: prepMs,
                                        totalMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)))
        } catch {
            onEvent?(.checkFailed("YOLO26n \(model.side): \(error.localizedDescription)"))
        }
    }
}
