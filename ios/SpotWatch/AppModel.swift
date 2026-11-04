import AVFoundation
import SwiftUI
import UIKit

let buildLabel = "N1 · 2026-11-04 · 3"

/// Everything the screen shows, and the report. Lives on the main thread; the
/// pipeline's events hop here. Spots, the event log and settings are in
/// AppModel+Spots.swift, photos in AppModel+Photos.swift, the report in
/// AppModel+Report.swift.
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
    }

    static let spotCount = 3
    static let logMax = 50
    static let errorsMax = 50
    static let eventsShown = 50
    static let noFramesWarnS = 5.0
    static let focusLockDelay: UInt64 = 2_000_000_000   // ns after the camera starts or a spot is saved

    @Published var rows: [StatusRow] = [
        StatusRow(id: "camera", label: "Camera"),
        StatusRow(id: "640", label: "YOLO26n 640"),
        StatusRow(id: "320", label: "YOLO26n 320"),
        StatusRow(id: "check", label: "Checks"),
        StatusRow(id: "spots", label: "Spots"),
        StatusRow(id: "events", label: "Events"),
        StatusRow(id: "photos", label: "Photos"),
        StatusRow(id: "device", label: "Device"),
        StatusRow(id: "app", label: "App")
    ]
    @Published var log: [LogEntry] = []
    @Published var errors: [ErrorEntry] = []
    @Published var detections: [Detection] = []
    @Published var views: [FracRect] = []                 // the last check's views; empty for the full frame
    @Published var frameSize = CGSize(width: 4, height: 3)
    @Published var lastCheckAt: Date?
    @Published var timing: [Int: ModelTiming] = [640: ModelTiming(), 320: ModelTiming()]
    @Published var checkStats = TimingStats()
    @Published var prepStats = TimingStats()
    @Published var busy = BusyTracker()
    @Published var checksOK = 0
    @Published var checksFailed = 0
    @Published var cpu: Double?
    @Published var cpuAvg: Double?
    @Published var memoryMB: Double?
    @Published var headroomMB: Double?
    @Published var thermal = DeviceInfo.thermalText()
    @Published var battery = "–"
    @Published var fps: Double?
    @Published var cameraRunning = false
    @Published var orientation: AVCaptureVideoOrientation?
    @Published var copyResult = ""
    @Published var exportResult = ""
    @Published var exporting = false

    // Spots and the event log (AppModel+Spots.swift).
    @Published var spots: [Spot?] = Array(repeating: nil, count: AppModel.spotCount)
    @Published var tracks: [SpotTrack] = Array(repeating: SpotTrack(), count: AppModel.spotCount)
    @Published var drawingSpot: Int?
    @Published var drawHint = ""
    @Published var recentEvents: [EventRow] = []
    @Published var showSettings = false
    @Published var cfg = Config()

    @Published var viewMode: ViewMode { didSet { optionsChanged("Views", viewMode.rawValue) } }
    @Published var source: Source { didSet { sourceChanged() } }
    @Published var paused = false { didSet { optionsChanged("Detection", paused ? "paused" : "resumed") } }
    @Published var compute: Compute { didSet { modelsChanged("Compute", compute.units.text) } }
    @Published var precision: Precision { didSet { modelsChanged("Precision", precision.rawValue) } }
    @Published var showBoxes: Bool { didSet { optionsChanged("Detection boxes", showBoxes ? "on" : "off") } }

    let testImage: UIImage? = Bundle.main.url(forResource: "bus", withExtension: "jpg").flatMap { UIImage(contentsOfFile: $0.path) }
    var session: AVCaptureSession { pipeline.camera.session }

    let pipeline = Pipeline()
    let started = Date()
    var store: EventStore?
    var photos: PhotoStore?
    var lastPhotoAt: Date?
    /// Rows logged by the check being handled, for its photo.
    var checkRows: [EventRow] = []
    /// The frame's pixel size for the current source, once known.
    var frameDims: CGSize?
    var lastShape: String?
    var cpuSamples: [Double] = []
    var lastBatteryLevel: Float?
    var lastBatteryState: UIDevice.BatteryState?
    var noFramesReported = false
    var droppedTotal = 0
    var lastDropReason = ""
    var focusText = "–"
    var startedPipeline = false

    init() {
        let d = UserDefaults.standard
        viewMode = d.string(forKey: "sw.viewMode").flatMap(ViewMode.init) ?? .each320
        compute = d.string(forKey: "sw.compute").flatMap(Compute.init) ?? .gpu
        precision = d.string(forKey: "sw.precision").flatMap(Precision.init) ?? .fp16
        showBoxes = d.object(forKey: "sw.showBoxes") as? Bool ?? true
        #if targetEnvironment(simulator)
        source = .testImage                       // the Simulator has no camera
        #else
        source = d.string(forKey: "sw.source").flatMap(Source.init) ?? .camera
        #endif
        if source == .testImage, let img = testImage { frameDims = img.size }
    }

    var frameAspect: CGFloat { frameSize.height > 0 ? frameSize.width / frameSize.height : 4 / 3 }

    var options: Pipeline.Options {
        Pipeline.Options(mode: viewMode, intervalMs: cfg.interval, minScore: cfg.minScore, source: source,
                         paused: paused, shape: currentShape ?? "", spots: activeSpots)
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
        loadSettings()
        loadSpots()
        openEventLog()
        openPhotos()
        lastShape = currentShape
        renderSpotsStatus()
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
        // `… -exportAfter 30` zips the export and prints its files, without the share sheet.
        let exportAfter = UserDefaults.standard.double(forKey: "exportAfter")
        if exportAfter > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(exportAfter * 1_000_000_000))
                self?.prepareExport { files, what in print("EXPORT \(what): " + files.map(\.path).joined(separator: " ")) }
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
        shapeMaybeChanged()
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

    // MARK: - Options

    func saveOptions() {
        let d = UserDefaults.standard
        d.set(viewMode.rawValue, forKey: "sw.viewMode")
        d.set(source.rawValue, forKey: "sw.source")
        d.set(compute.rawValue, forKey: "sw.compute")
        d.set(precision.rawValue, forKey: "sw.precision")
        d.set(showBoxes, forKey: "sw.showBoxes")
    }

    func pushOptions() {
        if startedPipeline { pipeline.update(options) }
    }

    private func optionsChanged(_ what: String, _ value: String) {
        saveOptions()
        addLog("settings", "\(what): \(value)")
        pushOptions()
    }

    private func sourceChanged() {
        detections = []
        views = []
        if source == .testImage {
            cameraRunning = false
            set("camera", .idle, "Off (source is bus.jpg)")
            frameDims = testImage?.size
            if let s = frameDims { frameSize = s }
        } else {
            set("camera", .busy, "Starting…")
            frameDims = nil
            frameSize = CGSize(width: 4, height: 3)
        }
        optionsChanged("Source", source.rawValue)
        shapeMaybeChanged()
    }

    /// Compute units and precision need the models loaded again, and new timings.
    private func modelsChanged(_ what: String, _ value: String) {
        optionsChanged(what, value)
        guard startedPipeline else { return }
        resetTimings()
        pipeline.loadModels(compute, precision)
    }

    func resetTimings() {
        timing = [640: ModelTiming(), 320: ModelTiming()]
        checkStats = TimingStats()
        prepStats = TimingStats()
        busy = BusyTracker()
    }

    var modelText: String { "\(precision.rawValue) · \(compute.units.text)" }

    // MARK: - Pipeline events

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
            checkDone(r)
        case .checkFailed(let msg):
            checksFailed += 1
            set("check", .fail, msg)
            fail("check", msg)
        case .frameShape(let w, let h):
            addLog("camera", "Frames are \(w)×\(h)")
            if source == .camera {
                frameDims = CGSize(width: w, height: h)
                shapeMaybeChanged()
            }
        case .testImageFailed(let msg):
            fail("source", msg)
            source = .camera
        }
    }

    private func checkDone(_ r: Pipeline.CheckResult) {
        checksOK += 1
        for run in r.runs {
            timing[run.side]?.infer.add(run.inferMs)
            if run.first { addLog("check", "First \(run.side) run: \(Format.ms(run.inferMs))") }
        }
        checkStats.add(r.totalMs)
        prepStats.add(r.prepMs)
        busy.add(start: r.started.timeIntervalSinceReferenceDate, duration: r.totalMs / 1000)
        detections = r.detections
        views = r.views == [.full] ? [] : r.views
        frameSize = CGSize(width: r.frameWidth, height: r.frameHeight)
        lastCheckAt = r.started
        let runs = r.runs.count == 1 ? "1 run" : "\(r.runs.count) runs"
        set("check", .ok, "\(Format.clock(r.started)) · \(Format.ms(r.totalMs)) · \(viewMode.rawValue), \(runs) · \(YOLO26.summarize(r.detections))")
        checkRows = []
        updateSpots(r)
        photoIfDue(r)
    }

    private func handleCamera(_ e: Camera.Event) {
        switch e {
        case .started(let format):
            cameraRunning = true
            noFramesReported = false
            set("camera", .ok, format)
            addLog("camera", "Started: \(format)")
            addLog("camera", "4:3 formats: \(pipeline.camera.formatsOnOffer.joined(separator: "; "))")
            logEvent(nil, "start", coverage: nil, detail: "")
            lockFocusSoon()
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
        case .focus(let text):
            focusText = text
            addLog("camera", "Focus \(text)")
        }
    }

    /// Locks focus a moment after the camera starts or a spot is saved, once
    /// any spot is drawn, so autofocus can't drift (at night especially).
    func lockFocusSoon() {
        guard source == .camera, spots.contains(where: { $0 != nil }) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.focusLockDelay)
            guard let self = self, self.drawingSpot == nil, self.source == .camera else { return }
            self.pipeline.camera.setFocusLocked(true)
        }
    }

    // MARK: - Device readings (every second)

    func sampleDevice() {
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

    func set(_ id: String, _ state: RowState, _ detail: String) {
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

    func fail(_ stage: String, _ msg: String) {
        errors.append(ErrorEntry(time: Format.clock(), msg: "[\(stage)] \(msg)"))
        if errors.count > AppModel.errorsMax { errors.removeFirst(errors.count - AppModel.errorsMax) }
        addLog("error", "[\(stage)] \(msg)")
    }

    func clearErrors() { errors = [] }
}
