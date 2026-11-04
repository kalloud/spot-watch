import Foundation

/// When the app saves a photo of the checked frame, and what it calls it.
/// The photos (PhotoStore) let a test be checked against the street
/// afterwards: one for every check that logged a row, and one every few
/// minutes regardless, which shows a car the app missed without an event.
/// Foundation only.
enum PhotoPlan {
    static let every: TimeInterval = 300    // seconds between photos when nothing is logged
    static let maxPhotos = 400              // the oldest go first; the Photos status row shows the space used

    static func due(rowsLogged: Bool, last: Date?, now: Date) -> Bool {
        rowsLogged || last.map { now.timeIntervalSince($0) >= every } ?? true
    }

    /// "spotwatch-20261104-082538.jpg", local time, so the names sort in time
    /// order; another photo in the same second gets "-2", "-3"…
    static func fileName(_ d: Date, copy: Int = 1) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "spotwatch-%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0) + (copy > 1 ? "-\(copy)" : "") + ".jpg"
    }

    /// "spotwatch-photos-20261104-0826.zip"
    static func zipName(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "spotwatch-photos-%04d%02d%02d-%02d%02d.zip", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0)
    }

    /// The names to delete so that only the newest `keep` remain.
    static func excess(_ names: [String], keep: Int) -> [String] {
        let sorted = names.sorted()
        return Array(sorted.prefix(max(0, sorted.count - keep)))
    }

    /// The caption burned into a photo: when and how it was taken, the rows
    /// this check logged (or why else it was taken), then each spot's state.
    static func caption(time: Date, setup: String, rows: [EventRow], spots: [String]) -> [String] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time)
        let when = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                          c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        var lines = [when + " · " + setup]
        lines += rows.isEmpty ? ["No event (a photo every \(Int(every / 60)) min)"] : rows.map(EventFormat.text)
        if !spots.isEmpty { lines.append(spots.joined(separator: " · ")) }
        return lines
    }
}
