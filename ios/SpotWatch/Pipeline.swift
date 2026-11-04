import CoreImage
import CoreML
import Foundation

enum ModelMode: String, CaseIterable, Identifiable {
    case m640 = "640", m320 = "320", both = "Both"
    var id: String { rawValue }
    var sides: [Int] { self == .m640 ? [640] : self == .m320 ? [320] : [640, 320] }
}

enum Pace: String, CaseIterable, Identifiable {
    case interval = "1.5 s", max = "Max"
    var id: String { rawValue }
    /// Start-to-start time between checks; a check never overlaps the previous one.
    var intervalMs: Double { self == .interval ? 1500 : 0 }
}

enum Source: String, CaseIterable, Identifiable {
    case camera = "Camera", testImage = "bus.jpg"
    var id: String { rawValue }
}

enum Compute: String, CaseIterable, Identifiable {
    case gpu = "GPU", cpu = "CPU"
    var id: String { rawValue }
    var units: MLComputeUnits { self == .gpu ? .cpuAndGPU : .cpuOnly }
}

/// The weights and arithmetic of the Core ML export. The A9's GPU runs FP16
/// at about twice the FP32 rate; on bus.jpg the two give the same boxes.
enum Precision: String, CaseIterable, Identifiable {
    case fp16 = "FP16", fp32 = "FP32"
    var id: String { rawValue }
}

/// Frames in, detections out, off the main thread. Checks run one at a time on
/// the detect queue, at most once per interval, on the newest frame.
final class Pipeline {
    struct Options: Equatable {
        var mode = ModelMode.both
        var pace = Pace.interval
        var source = Source.camera
        var paused = false
    }

    struct CheckResult {
        let side: Int
        let first: Bool            // first run since the model loaded
        let started: Date
        let prepMs: Double
        let inferMs: Double
        let totalMs: Double
        let detections: [Detection]
        let frameWidth: Double
        let frameHeight: Double
        let source: Source
    }

    enum Event {
        case modelLoading(Int)
        case modelLoaded(Int, loadMs: Double, spec: String)
        case modelFailed(Int, String)
        case check(CheckResult)
        case checkFailed(Int, String)
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
    private var turn = 0

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
        if new.pace != old.pace || new.paused != old.paused { nextDue = 0 }
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
        nextDue = now + options.pace.intervalMs / 1000
        let sides = options.mode.sides
        lock.unlock()
        detectQueue.async {
            self.check(frame, sides: sides, source: source)
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
        }
    }

    // MARK: - Checks (detect queue)

    private func check(_ frame: CIImage, sides: [Int], source: Source) {
        let ready = sides.filter { models[$0] != nil }
        guard !ready.isEmpty else { return }
        let side = ready[turn % ready.count]
        turn += 1
        guard let model = models[side] else { return }
        let started = Date()
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let run = try model.run(frame, context: context)
            let box = Letterbox(frameWidth: Double(frame.extent.width), frameHeight: Double(frame.extent.height), side: Double(side))
            let dets = YOLO26.detections(rows: run.rows, letterbox: box)
            let first = !ranSinceLoad.contains(side)
            ranSinceLoad.insert(side)
            onEvent?(.check(CheckResult(side: side, first: first, started: started, prepMs: run.prepMs, inferMs: run.inferMs,
                                        totalMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000, detections: dets,
                                        frameWidth: box.frameWidth, frameHeight: box.frameHeight, source: source)))
        } catch {
            onEvent?(.checkFailed(side, error.localizedDescription))
        }
    }
}
