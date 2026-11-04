import Foundation

/// Notices the phone being picked up, tilted or moved, from the motion
/// sensor's gravity direction and rotation rate. While it moves, checks give
/// no reading and the spots reset to unknown, so handling the phone can't
/// look like cars leaving (it did four times on Nov 4, once sending two false
/// FREEs). A phone put back at a new angle becomes the new resting direction
/// once it has held still there. Foundation only.
struct MotionGuard {
    static let rotationMax = 0.3            // rad/s; picking a phone up turns it faster than this
    static let tiltMaxDeg = 2.0             // degrees away from the resting direction
    static let settle: TimeInterval = 5     // seconds still before it counts as settled
    static let follow = 0.02                // how fast the resting direction follows a still phone

    enum Change: Equatable { case none, started, settled }

    private(set) var rest: [Double]?        // gravity as a unit vector
    private(set) var moving = false
    private var lastMotion: TimeInterval = 0
    private var candidate: [Double]?        // a new direction the phone is holding still at
    private var candidateSince: TimeInterval = 0

    /// One sensor sample: `t` in seconds, `gravity` in g, `rotation` in rad/s.
    mutating func add(t: TimeInterval, gravity: [Double], rotation: Double) -> Change {
        guard let u = MotionGuard.unit(gravity) else { return .none }
        guard let r = rest else {
            rest = u
            return .none
        }
        var motion = rotation > MotionGuard.rotationMax
        if motion {
            candidate = nil
        } else if MotionGuard.degrees(u, r) > MotionGuard.tiltMaxDeg {
            // Steady but pointing elsewhere: after `settle` s like this, it's the new resting direction.
            if let c = candidate, MotionGuard.degrees(u, c) <= MotionGuard.tiltMaxDeg / 4 {
                if t - candidateSince >= MotionGuard.settle {
                    rest = u
                    candidate = nil
                } else {
                    motion = true
                }
            } else {
                candidate = u
                candidateSince = t
                motion = true
            }
        } else {
            candidate = nil
            rest = MotionGuard.unit(zip(r, u).map { $0 * (1 - MotionGuard.follow) + $1 * MotionGuard.follow }) ?? r
        }
        if motion {
            lastMotion = t
            if !moving {
                moving = true
                return .started
            }
            return .none
        }
        if moving && t - lastMotion >= MotionGuard.settle {
            moving = false
            return .settled
        }
        return .none
    }

    static func unit(_ v: [Double]) -> [Double]? {
        let n = v.map { $0 * $0 }.reduce(0, +).squareRoot()
        return v.count == 3 && n > 0.1 ? v.map { $0 / n } : nil
    }

    static func degrees(_ a: [Double], _ b: [Double]) -> Double {
        let dot = zip(a, b).map(*).reduce(0, +)
        return acos(max(-1, min(1, dot))) * 180 / .pi
    }
}
