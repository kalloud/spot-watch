import Foundation

// Pure timing and formatting helpers. Foundation only.

/// Run times for one model, with the first run kept apart: it includes
/// Core ML's one-time setup, so it would skew the average (as in the web app).
struct TimingStats: Equatable {
    private(set) var first: Double?
    private(set) var last: Double?
    private(set) var count = 0
    private(set) var sum = 0.0
    private(set) var min = Double.infinity
    private(set) var max = 0.0

    mutating func add(_ ms: Double) {
        last = ms
        if first == nil {
            first = ms
            return
        }
        count += 1
        sum += ms
        min = Swift.min(min, ms)
        max = Swift.max(max, ms)
    }

    var average: Double? { count > 0 ? sum / Double(count) : nil }

    /// "212 ms over 40 (first excluded)", or "–".
    var averageText: String {
        guard let a = average else { return "–" }
        return "\(Format.ms(a)) over \(count) (first excluded)"
    }

    var minMaxText: String { count > 0 ? "\(Format.ms(min)) / \(Format.ms(max))" : "–" }
}

/// Share of wall time spent inside checks over the last few checks, like the
/// web app's "detector busy".
struct BusyTracker {
    private(set) var checks: [(start: Double, duration: Double)] = []
    let keep: Int

    init(keep: Int = 20) { self.keep = keep }

    /// `start` and `duration` in seconds.
    mutating func add(start: Double, duration: Double) {
        checks.append((start, duration))
        if checks.count > keep { checks.removeFirst(checks.count - keep) }
    }

    /// Percent busy from the first kept check's start to the last one's end.
    var percent: Int? {
        guard checks.count >= 2, let first = checks.first, let last = checks.last else { return nil }
        let span = last.start + last.duration - first.start
        guard span > 0 else { return nil }
        let busy = checks.reduce(0) { $0 + $1.duration }
        return Int((busy / span * 100).rounded())
    }
}

enum Format {
    static func ms(_ ms: Double?) -> String {
        guard let ms = ms, ms.isFinite else { return "–" }
        return ms >= 10_000 ? String(format: "%.1f s", ms / 1000) : "\(Int(ms.rounded())) ms"
    }

    static func clock(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
