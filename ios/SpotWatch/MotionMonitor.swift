import CoreMotion

/// Feeds the motion sensor (10 samples a second) to MotionGuard and reports
/// when the phone starts moving and when it has settled again.
final class MotionMonitor {
    enum Event {
        case started
        case settled
        case failed(String)
    }

    /// Called on the motion queue.
    var onEvent: ((Event) -> Void)?
    var available: Bool { manager.isDeviceMotionAvailable }

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "spotwatch.motion"
        return q
    }()
    private var motionGuard = MotionGuard()     // motion queue only

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, error in
            guard let self = self else { return }
            if let error = error {
                self.onEvent?(.failed(error.localizedDescription))
                return
            }
            guard let m = m else { return }
            let r = m.rotationRate
            switch self.motionGuard.add(t: m.timestamp, gravity: [m.gravity.x, m.gravity.y, m.gravity.z],
                                        rotation: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()) {
            case .started: self.onEvent?(.started)
            case .settled: self.onEvent?(.settled)
            case .none: break
            }
        }
    }
}
