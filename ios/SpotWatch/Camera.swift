import AVFoundation
import UIKit

/// The back wide camera at a 4:3 format near 1920×1440 and a fixed frame rate,
/// delivering frames in the interface's landscape orientation.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Event {
        case started(String)            // the chosen format, for the status row
        case failed(String)
        case interrupted(String)
        case interruptionEnded
        case runtimeError(String)
        case stopped
        case focus(String)
    }

    // The 6s has no 1280×960; 1920×1440 gives a far spot more pixels than the
    // web app's 1280×960 (Ahmed's call, N1).
    static let wantedWidth: Int32 = 1920
    static let fps: Double = 5

    let session = AVCaptureSession()
    /// Called on the video queue with each frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on any queue.
    var onEvent: ((Event) -> Void)?

    private let sessionQueue = DispatchQueue(label: "spotwatch.session")
    private let videoQueue = DispatchQueue(label: "spotwatch.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var orientation: AVCaptureVideoOrientation = .landscapeRight
    private var observers: [NSObjectProtocol] = []

    private let dropLock = NSLock()
    private var dropCount = 0
    private var lastDropReason = ""

    /// 4:3 formats on offer, for the report.
    private(set) var formatsOnOffer: [String] = []
    private(set) var formatText = ""

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndRun() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok {
                    self.sessionQueue.async { self.configureAndRun() }
                } else {
                    self.onEvent?(.failed("Camera access denied. Allow it in Settings → Spot Watch → Camera."))
                }
            }
        default:
            onEvent?(.failed("Camera access denied. Allow it in Settings → Spot Watch → Camera."))
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.onEvent?(.stopped)
        }
    }

    func setOrientation(_ o: AVCaptureVideoOrientation) {
        sessionQueue.async {
            self.orientation = o
            self.applyOrientation()
        }
    }

    /// Locks focus where it is, once spots are drawn, so autofocus can't drift
    /// (at night especially); or goes back to continuous autofocus, for drawing.
    func setFocusLocked(_ locked: Bool) {
        sessionQueue.async {
            guard let d = self.device else { return }
            let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
            guard d.isFocusModeSupported(mode), d.focusMode != mode else { return }
            do {
                try d.lockForConfiguration()
                d.focusMode = mode
                d.unlockForConfiguration()
                self.onEvent?(.focus(locked ? String(format: "locked at lens position %.2f", d.lensPosition) : "continuous autofocus"))
            } catch {
                self.onEvent?(.failed("Could not set focus: \(error.localizedDescription)"))
            }
        }
    }

    /// Frames dropped since the last call, and the last reason given.
    func takeDrops() -> (count: Int, reason: String) {
        dropLock.lock()
        defer { dropLock.unlock() }
        let r = (dropCount, lastDropReason)
        dropCount = 0
        return r
    }

    /// The camera's own report of heat or power pressure (iOS may lower the frame rate).
    var pressureText: String {
        guard let d = device else { return "–" }
        let level = d.systemPressureState.level
        switch level {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        case .shutdown: return "shutdown"
        default: return level.rawValue
        }
    }

    // MARK: - Setup (session queue)

    private func configureAndRun() {
        if !configured {
            do {
                try configure()
                configured = true
                observe()
            } catch {
                onEvent?(.failed(error.localizedDescription))
                return
            }
        }
        if !session.isRunning { session.startRunning() }
        if session.isRunning {
            onEvent?(.started(formatText))
        } else {
            onEvent?(.failed("The capture session did not start (no error given)."))
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError("No back camera found (the Simulator has none: use the bus.jpg source).")
        }
        self.device = device
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // The format is picked on the device below; a preset would override it.
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input) else { throw CameraError("Cannot add the camera input.") }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let pixelFormat = output.availableVideoPixelFormatTypes.contains(fullRange) ? fullRange : kCVPixelFormatType_32BGRA
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw CameraError("Cannot add the video output.") }
        session.addOutput(output)

        let fourThree = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * 3 == Int(d.height) * 4
        }
        formatsOnOffer = fourThree.map(Camera.describe)
        guard let format = Camera.pick(fourThree, fps: Camera.fps) else {
            throw CameraError("No 4:3 format supports \(Int(Camera.fps)) fps. Formats: \(formatsOnOffer.joined(separator: ", "))")
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        let range = format.videoSupportedFrameRateRanges.first { $0.minFrameRate <= Camera.fps && Camera.fps <= $0.maxFrameRate }
        let duration = range != nil ? CMTime(value: 1, timescale: CMTimeScale(Camera.fps)) : format.videoSupportedFrameRateRanges[0].minFrameDuration
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()

        applyOrientation()
        let fps = Double(duration.timescale) / Double(duration.value)
        formatText = "\(Camera.describe(format)) at \(String(format: "%g", fps)) fps · \(pixelFormat == fullRange ? "420f" : "BGRA") frames"
    }

    /// The 4:3 format closest to `wantedWidth` that runs at `fps`; on a tie, the
    /// larger one, then full-range video.
    static func pick(_ formats: [AVCaptureDevice.Format], fps: Double) -> AVCaptureDevice.Format? {
        let usable = formats.filter { f in
            f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
        func key(_ f: AVCaptureDevice.Format) -> (Int32, Int32, Int) {
            let w = CMVideoFormatDescriptionGetDimensions(f.formatDescription).width
            let full = CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return (abs(w - wantedWidth), -w, full ? 0 : 1)
        }
        return usable.min { key($0) < key($1) }
    }

    static func describe(_ f: AVCaptureDevice.Format) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let code = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xff) }, encoding: .ascii) ?? "?"
        let rates = f.videoSupportedFrameRateRanges.map { String(format: "%g–%g", $0.minFrameRate, $0.maxFrameRate) }
        return "\(d.width)×\(d.height) \(code) \(rates.joined(separator: ","))fps" + (f.isVideoBinned ? " binned" : "")
    }

    private func applyOrientation() {
        guard let c = output.connection(with: .video) else { return }
        if c.isVideoOrientationSupported { c.videoOrientation = orientation }
        if c.isVideoMirroringSupported { c.isVideoMirrored = false }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] n in
            let e = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.onEvent?(.runtimeError(e.map { "\($0.localizedDescription) (code \($0.code))" } ?? "unknown error"))
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] n in
            let raw = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            self?.onEvent?(.interrupted(Camera.interruptionText(raw)))
        })
        observers.append(nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.onEvent?(.interruptionEnded)
        })
    }

    static func interruptionText(_ raw: Int?) -> String {
        guard let raw = raw, let r = AVCaptureSession.InterruptionReason(rawValue: raw) else { return "reason unknown" }
        switch r {
        case .videoDeviceNotAvailableInBackground: return "app in the background"
        case .audioDeviceInUseByAnotherClient: return "audio in use by another app"
        case .videoDeviceInUseByAnotherClient: return "camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure: return "system pressure (heat)"
        default: return "reason \(raw)"
        }
    }

    // MARK: - Frames (video queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        dropLock.lock()
        dropCount += 1
        lastDropReason = (reason as? String) ?? "unknown"
        dropLock.unlock()
    }
}

struct CameraError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension AVCaptureVideoOrientation {
    init?(_ o: UIInterfaceOrientation) {
        switch o {
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        default: return nil
        }
    }

    var text: String {
        switch self {
        case .landscapeLeft: return "landscape left"
        case .landscapeRight: return "landscape right"
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait upside down"
        @unknown default: return "unknown"
        }
    }
}
