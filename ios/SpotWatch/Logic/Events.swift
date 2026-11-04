import Foundation

// Event log rows and their CSV, ported from the web app (logEvent,
// eventText, csvField, eventCsv). Foundation only.

/// One row of the event log. The CSV columns are the web app's:
/// time,spot,event,coverage_pct,hunting,detail.
struct EventRow: Equatable {
    let time: Date
    let spot: Int?          // 1-based; nil for whole-app rows such as `start`
    let event: String
    let coverage: Int?      // percent
    let hunting: Bool
    let detail: String
}

enum EventFormat {
    static let header = "time,spot,event,coverage_pct,hunting,detail"

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// "2026-11-04T05:12:03.481Z", as JavaScript's toISOString.
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
    static func date(iso s: String) -> Date? { isoFormatter.date(from: s) }

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func fields(_ r: EventRow) -> [String] {
        [iso(r.time), r.spot.map(String.init) ?? "", r.event, r.coverage.map(String.init) ?? "", r.hunting ? "1" : "0", r.detail]
    }

    static func csv(_ rows: [EventRow]) -> String {
        ([header] + rows.map { fields($0).map(csvField).joined(separator: ",") }).joined(separator: "\n") + "\n"
    }

    /// "Spot 1 occupied · 45% · change 12.3"
    static func text(_ r: EventRow) -> String {
        (r.spot.map { "Spot \($0) " } ?? "") + r.event + (r.coverage.map { " · \($0)%" } ?? "")
            + (r.detail.isEmpty ? "" : " · " + r.detail)
    }

    /// "11-04 00:12:03", local time.
    static func stamp(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute, .second], from: d)
        return String(format: "%02d-%02d %02d:%02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// One row as a JSON array line, the web app's row format:
    /// [time, spot or "", event, coverage or "", hunting 0/1, detail].
    static func jsonLine(_ r: EventRow) -> String {
        let a: [Any] = [iso(r.time), r.spot.map { $0 as Any } ?? "", r.event, r.coverage.map { $0 as Any } ?? "",
                        r.hunting ? 1 : 0, r.detail]
        let data = (try? JSONSerialization.data(withJSONObject: a)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func row(jsonLine line: Substring) -> EventRow? {
        guard let a = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any], a.count == 6,
              let t = a[0] as? String, let time = date(iso: t), let event = a[2] as? String,
              let hunting = a[4] as? Int, let detail = a[5] as? String else { return nil }
        return EventRow(time: time, spot: a[1] as? Int, event: event, coverage: a[3] as? Int,
                        hunting: hunting == 1, detail: detail)
    }

    /// "spotwatch-log-20261104-0012.csv"
    static func csvName(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "spotwatch-log-%04d%02d%02d-%02d%02d.csv", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
