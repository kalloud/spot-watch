import Foundation

// Per-spot readings and the state machine, ported from the web app's
// readSpot, updateSpot, spotThumb and thumbDiff. Foundation only.

struct SpotSettings: Equatable {
    var occThresh = 0.35
    var confirmN = 3
    var hintN = 2
    var personMargin = 0.35
    var personMinScore = 0.4
    var changeMin = 10.0            // 0 turns the departure check off

    static let holdFactor = 0.5     // an occupied spot stays occupied down to this share of occThresh
    static let snapshotEvery = 10   // occupied readings between snapshot refreshes
}

/// One check's verdict on one spot.
struct Reading: Equatable {
    var coverage: Double            // largest share of the spot covered by one vehicle box
    var person: Bool                // a person box overlaps the spot plus the person margin
    var personScore: Double
}

enum SpotState: String {
    case unknown, occupied, vacant
}

/// Live state of one spot. Reset (without a log row) when the spot is
/// redrawn or the frame shape changes, so neither can look like a departure.
struct SpotTrack: Equatable {
    var state = SpotState.unknown
    var since: Date?
    var occRun = 0
    var vacRun = 0
    var coverage: Double?
    var person = false
    var personRun = 0
    var clearRun = 0
    var personVisit = false
    var snap: [Float]?
    var snapAge = 0
    var rejects = 0
}

enum SpotEvent: Equatable {
    /// A state change, logged as an `occupied` or `vacant` row. `change` is
    /// the departure check's value when it ran.
    case changed(SpotState, coverage: Double, change: Double?)
    /// Occupied → vacant: what the FREE alert fires on (N2). Never from unknown.
    case freed(coverage: Double, occupiedSince: Date?)
    /// A departure held back because the spot still looks like its snapshot:
    /// the detector only lost the car. `logRow` is true for the first of each 20.
    case vacantRejected(coverage: Double, change: Double, count: Int, logRow: Bool)
    /// The start of a person-near visit at an occupied spot: the heads-up trigger (N2).
    case personNear(coverage: Double, score: Double, occupiedSince: Date?)
}

enum SpotLogic {
    static let thumbWidth = 32

    /// Coverage and person-near for one spot (in frame pixels). Cars count from
    /// the detector's minScore; people need `personMinScore`.
    static func read(_ spot: Box, _ dets: [Detection], _ s: SpotSettings) -> Reading {
        let mx = spot.w * s.personMargin, my = spot.h * s.personMargin
        let near = Box(x: spot.x - mx, y: spot.y - my, w: spot.w + 2 * mx, h: spot.h + 2 * my)
        var coverage = 0.0, personScore = 0.0
        for d in dets {
            if d.isVehicle {
                coverage = max(coverage, Geometry.overlapArea(spot, d.box) / spot.area)
            } else if d.isPerson && d.score >= s.personMinScore && Geometry.overlapArea(near, d.box) > 0 {
                personScore = max(personScore, d.score)
            }
        }
        return Reading(coverage: coverage, person: personScore > 0, personScore: personScore)
    }

    /// Feeds one reading to a spot. A spot changes state only after
    /// `confirmN` readings in a row agree; a reading is occupied at
    /// `occThresh`, or, once occupied, down to half of it (hysteresis). A
    /// departure must also change the spot's picture compared with its
    /// snapshot. `thumb` gives the spot's thumbnail from this check's frame.
    /// person_near counts only while occupied, once per visit: a visit starts
    /// after `hintN` readings with a person near and ends after `hintN` without.
    static func update(_ t: inout SpotTrack, _ reading: Reading, thumb: () -> [Float]?,
                       _ s: SpotSettings, now: Date) -> [SpotEvent] {
        var events: [SpotEvent] = []
        t.coverage = reading.coverage
        t.person = reading.person
        let threshold = t.state == .occupied ? s.occThresh * SpotSettings.holdFactor : s.occThresh
        let occupiedReading = reading.coverage >= threshold
        if occupiedReading {
            t.occRun += 1
            t.vacRun = 0
        } else {
            t.vacRun += 1
            t.occRun = 0
        }
        var next: SpotState? = t.occRun >= s.confirmN ? .occupied : t.vacRun >= s.confirmN ? .vacant : nil

        // Departure check: a car that drove away changes the spot's picture; a
        // car the detector merely lost doesn't.
        var change: Double?
        if next == .vacant && t.state == .occupied, let snap = t.snap {
            change = thumbDiff(snap, thumb())
            if let c = change, c < s.changeMin {
                next = nil
                t.vacRun = 0
                t.rejects += 1
                events.append(.vacantRejected(coverage: reading.coverage, change: c, count: t.rejects,
                                              logRow: t.rejects % 20 == 1))
            }
        }

        if let n = next, n != t.state {
            let prev = t.state, prevSince = t.since
            t.state = n
            t.since = now
            events.append(.changed(n, coverage: reading.coverage, change: change))
            if prev == .occupied && n == .vacant {
                events.append(.freed(coverage: reading.coverage, occupiedSince: prevSince))
            }
        }

        // The snapshot is taken while a car is in the spot, and refreshed every
        // `snapshotEvery` occupied readings so slow light changes follow along.
        if t.state == .occupied && occupiedReading {
            if t.snap == nil {
                t.snap = thumb()
                t.snapAge = 0
            } else {
                t.snapAge += 1
                if t.snapAge >= SpotSettings.snapshotEvery {
                    t.snap = thumb()
                    t.snapAge = 0
                }
            }
        }

        if reading.person {
            t.personRun += 1
            t.clearRun = 0
        } else {
            t.clearRun += 1
            t.personRun = 0
        }
        if !t.personVisit && t.state == .occupied && t.personRun >= s.hintN {
            t.personVisit = true
            events.append(.personNear(coverage: reading.coverage, score: reading.personScore, occupiedSince: t.since))
        } else if t.personVisit && t.clearRun >= s.hintN {
            t.personVisit = false
        }
        return events
    }

    /// Thumbnail size for a spot of `w`×`h` frame pixels: 32 wide, 4–48 high.
    static func thumbSize(spotWidth w: Double, spotHeight h: Double) -> (width: Int, height: Int) {
        let height = Int((Double(thumbWidth) * max(1, h.rounded()) / max(1, w.rounded())).rounded())
        return (thumbWidth, min(48, max(4, height)))
    }

    /// A spot's picture as grey levels with their mean removed, so a change
    /// in overall light (exposure, dusk) doesn't count as change. From RGBA bytes.
    static func thumbnail(rgba: [UInt8], width: Int, height: Int, rowBytes: Int) -> [Float] {
        var g = [Float](repeating: 0, count: width * height)
        var mean: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let j = y * rowBytes + x * 4
                let v = 0.299 * Float(rgba[j]) + 0.587 * Float(rgba[j + 1]) + 0.114 * Float(rgba[j + 2])
                g[y * width + x] = v
                mean += v
            }
        }
        mean /= Float(max(1, g.count))
        return g.map { $0 - mean }
    }

    /// Mean absolute difference between two thumbnails (0–255), or nil if
    /// either is missing or they differ in size.
    static func thumbDiff(_ a: [Float]?, _ b: [Float]?) -> Double? {
        guard let a = a, let b = b, a.count == b.count, !a.isEmpty else { return nil }
        var sum: Float = 0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return Double(sum / Float(a.count))
    }

    /// Readings in a row toward a state change, e.g. "vacant 2/3".
    static func runText(_ t: SpotTrack, confirmN: Int) -> String {
        if t.state != .occupied && t.occRun > 0 { return "occupied \(min(t.occRun, confirmN))/\(confirmN)" }
        if t.state != .vacant && t.vacRun > 0 { return "vacant \(min(t.vacRun, confirmN))/\(confirmN)" }
        return "–"
    }
}
