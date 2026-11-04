import AVFoundation
import SwiftUI
import UIKit

let buildLabel = "N0 · 2026-11-03 · 1"

/// Everything the screen shows, and the report. Lives on the main thread; the
/// pipeline's events hop here.
@MainActor
final class AppModel: ObservableObject {
    enum RowState { case idle, busy, ok, warn, fail }

    struct StatusRow: Identifiable {
        let id: String
        let label: String
        var state = RowState.idle
        var detail = ""
    }

    struct LogEntry {
        var time: String
        let stage: String
        let msg: String
        var count = 1
        var line: String { "\(time) [\(stage)] \(msg)" + (count > 1 ? " (×\(count))" : "") }
    }

    struct ErrorEntry: Identifiable {
        let id = UUID()
        let time: String
        let msg: String
    }

    struct ModelTiming {
        var loadMs: Double?
        var spec = ""
        var infer = TimingStats()
        var prep = TimingStats()
        var lastDetections = ""
    }

    static let logMax = 50
    static let errorsMax = 50
    static let noFramesWarnS = 5.0

    @Published private(set) var rows: [StatusRow] = [
        StatusRow(id: "camera", label: "Camera"),
        StatusRow(id: "640", label: "YOLO26n 640"),
        StatusRow(id: "320", label: "YOLO26n 320"),
        StatusRow(id: "check", label: "Checks"),
        StatusRow(id: "device", label: "Device"),
        StatusRow(id: "app", label: "App")
    ]
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var errors: [ErrorEntry] = []
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var frameSize = CGSize(width: 4, height: 3)
    @Published private(set) var lastSide: Int?
    @Published private(set) var lastCheckAt: Date?
    @Published private(set) var timing: [Int: ModelTiming] = [640: ModelTiming(), 320: ModelTiming()]
    @Published private(set) var busy = BusyTracker()
    @Published private(set) var checksOK = 0
    @Published private(set) var checksFailed = 0
    @Published private(set) var cpu: Double?
    @Published private(set) var cpuAvg: Double?
    @Published private(set) var memoryMB: Double?
    @Published private(set) var headroomMB: Double?
    @Published private(set) var thermal = DeviceInfo.thermalText()
    @Published private(set) var battery = "–"
    @Published private(set) var fps: Double?
    @Published private(set) var cameraRunning = false
    @Published private(set) var orientation: AVCaptureVideoOrientation?
    @Published var copyResult = ""

    @Published var mode: ModelMode { didSet { optionsChanged("Models", mode.rawValue) } }
    @Published var pace: Pace { didSet { optionsChanged("Pace", pace.rawValue) } }
    @Published var source: Source { didSet { sourceChanged() } }
    @Published var paused = false { didSet { optionsChanged("Detection", paused ? "paused" : "resumed") } }
    @Published var compute: Compute { didSet { modelsChanged("Compute", compute.units.text) } }
    @Published var precision: Precision { didSet { modelsChanged("Precision", precision.rawValue) } }

    let testImage: UIImage? = Bundle.main.url(forResource: "bus", withExtension: "jpg").flatMap { UIImage(contentsOfFile: $0.path) }
    var session: AVCaptureSession { pipeline.camera.session }

    private let pipeline = Pipeline()
    private let started = Date()
    private var cpuSamples: [Double] = []
    private var lastBatteryLevel: Float?
    private var lastBatteryState: UIDevice.BatteryState?
    private var noFramesReported = false
    private var droppedTotal = 0
    private var lastDropReason = ""
    private var startedPipeline = false

    init() {
        let d = UserDefaults.standard
        mode = d.string(forKey: "sw.mode").flatMap(ModelMode.init) ?? .both
        pace = d.string(forKey: "sw.pace").flatMap(Pace.init) ?? .interval
        compute = d.string(forKey: "sw.compute").flatMap(Compute.init) ?? .gpu
        precision = d.string(forKey: "sw.precision").flatMap(Precision.init) ?? .fp16
        #if targetEnvironment(simulator)
        source = .testImage                       // the Simulator has no camera
        #else
        source = d.string(forKey: "sw.source").flatMap(Source.init) ?? .camera
        #endif
    }

    var frameAspect: CGFloat { frameSize.height > 0 ? frameSize.width / frameSize.height : 4 / 3 }

    private var options: Pipeline.Options {
        Pipeline.Options(mode: mode, pace: pace, source: source, paused: paused)
    }

    // MARK: - Start

    func start() {
        guard !startedPipeline else { return }
        startedPipeline = true
        addLog("app", "Started \(buildLabel) · \(DeviceInfo.model) · iOS \(UIDevice.current.systemVersion)")
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            addLog("app", "Running unit tests: camera and models stay off")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        set("app", .ok, "Active · screen lock off")
        set("camera", source == .camera ? .busy : .idle, source == .camera ? "Starting…" : "Off (source is bus.jpg)")
        set("check", .idle, "Waits for a frame and a model")
        pipeline.onEvent = { [weak self] e in
            DispatchQueue.main.async { self?.handle(e) }
        }
        pipeline.camera.onEvent = { [weak self] e in
            DispatchQueue.main.async { self?.handleCamera(e) }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sampleDevice() }
        }
        pipeline.start(options, compute: compute, precision: precision)
        #if DEBUG
        // `simctl launch --console-pty … -reportAfter 20` prints the report, for Simulator checks.
        let after = UserDefaults.standard.double(forKey: "reportAfter")
        if after > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                if let self = self { print(self.buildReport()) }
            }
        }
        #endif
        Task { @MainActor [weak self] in
            while let self = self {
                self.sampleDevice()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func orientationChanged(_ o: AVCaptureVideoOrientation) {
        guard o != orientation else { return }
        orientation = o
        addLog("camera", "Orientation \(o.text)")
        pipeline.camera.setOrientation(o)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            set("app", .ok, "Active · screen lock off")
            addLog("app", "Active")
        case .inactive:
            set("app", .warn, "Inactive")
            addLog("app", "Inactive")
        case .background:
            set("app", .fail, "In the background: iOS stops the camera")
            addLog("app", "In the background")
        @unknown default:
            break
        }
    }

    // MARK: - Settings

    private func optionsChanged(_ what: String, _ value: String) {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "sw.mode")
        d.set(pace.rawValue, forKey: "sw.pace")
        d.set(source.rawValue, forKey: "sw.source")
        d.set(compute.rawValue, forKey: "sw.compute")
        d.set(precision.rawValue, forKey: "sw.precision")
        addLog("settings", "\(what): \(value)")
        if startedPipeline { pipeline.update(options) }
    }

    private func sourceChanged() {
        detections = []
        lastSide = nil
        if source == .testImage {
            cameraRunning = false
            set("camera", .idle, "Off (source is bus.jpg)")
            if let img = testImage { frameSize = img.size }
        } else {
            set("camera", .busy, "Starting…")
            frameSize = CGSize(width: 4, height: 3)
        }
        optionsChanged("Source", source.rawValue)
    }

    /// Compute units and precision need the models loaded again, and new timings.
    private func modelsChanged(_ what: String, _ value: String) {
        optionsChanged(what, value)
        guard startedPipeline else { return }
        timing = [640: ModelTiming(), 320: ModelTiming()]
        busy = BusyTracker()
        pipeline.loadModels(compute, precision)
    }

    private var modelText: String { "\(precision.rawValue) · \(compute.units.text)" }

    // MARK: - Events

    private func handle(_ e: Pipeline.Event) {
        switch e {
        case .modelLoading(let side):
            set("\(side)", .busy, "Loading (\(modelText))…")
        case .modelLoaded(let side, let ms, let spec):
            timing[side]?.loadMs = ms
            timing[side]?.spec = spec
            set("\(side)", .ok, "Loaded in \(Format.ms(ms)) · \(modelText)")
            addLog("model", "YOLO26n \(side) loaded in \(Format.ms(ms)) · \(spec)")
        case .modelFailed(let side, let msg):
            set("\(side)", .fail, msg)
            fail("model", "YOLO26n \(side): \(msg)")
        case .check(let r):
            guard r.source == source else { return }    // a check from before a source switch
            checksOK += 1
            timing[r.side]?.infer.add(r.inferMs)
            timing[r.side]?.prep.add(r.prepMs)
            timing[r.side]?.lastDetections = YOLO26.summarize(r.detections)
            busy.add(start: r.started.timeIntervalSinceReferenceDate, duration: r.totalMs / 1000)
            detections = r.detections
            frameSize = CGSize(width: r.frameWidth, height: r.frameHeight)
            lastSide = r.side
            lastCheckAt = r.started
            set("check", .ok, "\(r.side) at \(Format.clock(r.started)) · \(Format.ms(r.inferMs)) · \(YOLO26.summarize(r.detections))")
            if r.first {
                addLog("check", "First \(r.side) run: \(Format.ms(r.inferMs)) (prep \(Format.ms(r.prepMs))) · \(YOLO26.summarize(r.detections))")
            }
        case .checkFailed(let side, let msg):
            checksFailed += 1
            set("check", .fail, "\(side): \(msg)")
            fail("check", "YOLO26n \(side): \(msg)")
        case .frameShape(let w, let h):
            addLog("camera", "Frames are \(w)×\(h)" + (w > h ? " (landscape)" : " (portrait)"))
        case .testImageFailed(let msg):
            fail("source", msg)
            source = .camera
        }
    }

    private func handleCamera(_ e: Camera.Event) {
        switch e {
        case .started(let format):
            cameraRunning = true
            noFramesReported = false
            set("camera", .ok, format)
            addLog("camera", "Started: \(format)")
            addLog("camera", "4:3 formats: \(pipeline.camera.formatsOnOffer.joined(separator: "; "))")
        case .failed(let msg):
            cameraRunning = false
            set("camera", .fail, msg)
            fail("camera", msg)
        case .interrupted(let why):
            set("camera", .fail, "Interrupted: \(why)")
            fail("camera", "Interrupted: \(why)")
        case .interruptionEnded:
            set("camera", .ok, pipeline.camera.formatText)
            addLog("camera", "Interruption ended")
        case .runtimeError(let msg):
            cameraRunning = false
            set("camera", .fail, "Runtime error: \(msg)")
            fail("camera", "Runtime error: \(msg)")
        case .stopped:
            cameraRunning = false
            addLog("camera", "Stopped")
        }
    }

    // MARK: - Device readings (every second)

    private func sampleDevice() {
        if let c = DeviceInfo.cpuPercent() {
            cpu = c
            cpuSamples.append(c)
            if cpuSamples.count > 10 { cpuSamples.removeFirst(cpuSamples.count - 10) }
            cpuAvg = cpuSamples.reduce(0, +) / Double(cpuSamples.count)
        }
        memoryMB = DeviceInfo.footprintMB()
        headroomMB = DeviceInfo.headroomMB()

        let t = DeviceInfo.thermalText()
        if t != thermal { addLog("device", "Thermal state \(thermal) → \(t)") }
        thermal = t
        let dev = UIDevice.current
        battery = DeviceInfo.batteryText(level: dev.batteryLevel, state: dev.batteryState)
        if lastBatteryLevel != dev.batteryLevel || lastBatteryState != dev.batteryState {
            if lastBatteryLevel != nil { addLog("device", "Battery \(battery)") }
            lastBatteryLevel = dev.batteryLevel
            lastBatteryState = dev.batteryState
        }
        let hot = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        set("device", hot ? .warn : .ok, "Thermal \(thermal) · battery \(battery)")

        let drops = pipeline.camera.takeDrops()
        if drops.count > 0 {
            droppedTotal += drops.count
            lastDropReason = drops.reason
        }
        let rate = pipeline.frameRate()
        fps = rate.fps
        if source == .camera && cameraRunning {
            if let age = rate.age, age > AppModel.noFramesWarnS {
                set("camera", .warn, "No frame for \(Int(age)) s")
                if !noFramesReported { fail("camera", "No frame for \(Int(age)) s") }
                noFramesReported = true
            } else if noFramesReported, let age = rate.age, age < 1 {
                noFramesReported = false
                set("camera", .ok, pipeline.camera.formatText)
                addLog("camera", "Frames are back")
            }
        }
    }

    // MARK: - Rows, log, errors

    private func set(_ id: String, _ state: RowState, _ detail: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows[i].state != state || rows[i].detail != detail {
            rows[i].state = state
            rows[i].detail = detail
        }
    }

    func addLog(_ stage: String, _ msg: String) {
        let now = Format.clock()
        if let last = log.last, last.stage == stage, last.msg == msg {
            log[log.count - 1].count += 1
            log[log.count - 1].time = now
            return
        }
        log.append(LogEntry(time: now, stage: stage, msg: msg))
        if log.count > AppModel.logMax { log.removeFirst(log.count - AppModel.logMax) }
    }

    private func fail(_ stage: String, _ msg: String) {
        errors.append(ErrorEntry(time: Format.clock(), msg: "[\(stage)] \(msg)"))
        if errors.count > AppModel.errorsMax { errors.removeFirst(errors.count - AppModel.errorsMax) }
        addLog("error", "[\(stage)] \(msg)")
    }

    func clearErrors() { errors = [] }

    // MARK: - Report

    func hudLine(_ side: Int) -> String {
        guard let t = timing[side] else { return "" }
        let avg = t.infer.average.map { "avg \(Format.ms($0)) (n \(t.infer.count))" } ?? "avg –"
        return "\(side): last \(Format.ms(t.infer.last)) · \(avg)"
    }

    var cpuText: String {
        guard let c = cpu else { return "–" }
        return "\(Int(c.rounded()))% (10 s avg \(Int((cpuAvg ?? c).rounded()))%) of \(DeviceInfo.cores * 100)%"
    }

    var memoryText: String {
        guard let m = memoryMB else { return "–" }
        return "\(Int(m.rounded())) MB" + (headroomMB.map { " · \(Int($0.rounded())) MB headroom" } ?? "")
    }

    func statRows() -> [(String, String)] {
        var out: [(String, String)] = [
            ("Models", mode.rawValue + " · pace " + pace.rawValue + " · " + modelText),
            ("Source", source == .camera
                ? "camera · " + (fps.map { String(format: "%.1f fps", $0) } ?? "– fps") + (orientation.map { " · " + $0.text } ?? "")
                : "bus.jpg"),
            ("Frame", "\(Int(frameSize.width))×\(Int(frameSize.height))")
        ]
        for side in [640, 320] {
            guard let t = timing[side] else { continue }
            out.append(("\(side) load / first", "\(Format.ms(t.loadMs)) / \(Format.ms(t.infer.first))"))
            out.append(("\(side) inference", t.infer.averageText))
            out.append(("\(side) min / max", t.infer.minMaxText))
            out.append(("\(side) prep", t.prep.average.map { "avg \(Format.ms($0))" } ?? "–"))
        }
        out.append(("Detector busy", busy.percent.map { "\($0)% (last \(busy.checks.count) checks)" } ?? "–"))
        out.append(("Checks", "\(checksOK) ok · \(checksFailed) failed" + (paused ? " · paused" : "")))
        out.append(("CPU", cpuText))
        out.append(("Memory", memoryText))
        out.append(("Thermal", thermal + " · camera pressure " + pipeline.camera.pressureText))
        out.append(("Battery", battery))
        out.append(("Dropped frames", "\(droppedTotal)" + (lastDropReason.isEmpty ? "" : " (last: \(lastDropReason))")))
        return out
    }

    func buildReport() -> String {
        var lines: [String] = []
        lines.append("Spot Watch iOS report · \(buildLabel)")
        lines.append("Time: \(Date())")
        #if DEBUG
        let config = "Debug"
        #else
        let config = "Release"
        #endif
        lines.append("\(DeviceInfo.model) · iOS \(UIDevice.current.systemVersion) · \(DeviceInfo.cores) cores · \(config) build")
        lines.append("Up \(Int(Date().timeIntervalSince(started) / 60)) min")
        lines.append("")
        lines.append("Status:")
        for r in rows { lines.append("  \(r.label): \(r.state) · \(r.detail)") }
        lines.append("")
        lines.append("Checks:")
        for (k, v) in statRows() { lines.append("  \(k): \(v)") }
        for side in [640, 320] {
            if let t = timing[side], !t.spec.isEmpty {
                lines.append("  \(side) spec: \(t.spec) · last: \(t.lastDetections.isEmpty ? "no run yet" : t.lastDetections)")
            }
        }
        lines.append("  Camera: \(pipeline.camera.formatText.isEmpty ? "not started" : pipeline.camera.formatText)")
        lines.append("  4:3 formats: \(pipeline.camera.formatsOnOffer.joined(separator: "; "))")
        lines.append("")
        lines.append("Last detections (\(lastSide.map { "YOLO26n \($0)" } ?? "none yet")\(lastCheckAt.map { " at " + Format.clock($0) } ?? "")):")
        if detections.isEmpty { lines.append("  none above \(Int(YOLO26.minScore * 100))%") }
        for d in detections {
            let b = d.box
            lines.append("  \(d.className) \(Int((d.score * 100).rounded()))% · x \(Int(b.x)) y \(Int(b.y)) w \(Int(b.w)) h \(Int(b.h))")
        }
        lines.append("")
        lines.append("Errors (\(errors.count)):")
        for e in errors { lines.append("  \(e.time) \(e.msg)") }
        lines.append("")
        lines.append("Log (newest first):")
        for e in log.reversed() { lines.append("  " + e.line) }
        return lines.joined(separator: "\n")
    }

    func copyReport() {
        let text = buildReport()
        UIPasteboard.general.string = text
        copyResult = UIPasteboard.general.string == text
            ? "Report copied at \(Format.clock()) (\(text.split(separator: "\n").count) lines)."
            : "Could not copy the report."
        if UIPasteboard.general.string != text { fail("report", "The pasteboard did not take the report") }
    }
}
