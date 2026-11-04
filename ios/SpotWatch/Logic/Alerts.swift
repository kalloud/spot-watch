import Foundation

// Alert types, the ntfy publish URL, control-topic messages and the per-spot
// alert rules, ported from the web app (ALERT_TYPES, publish, subscribe,
// onSpotFreed, onPersonNear). Foundation only.

/// Every alert has its type's priority and tag, so Ahmed's ntfy subscriptions
/// and Shortcuts keep working. The titles are the web app's.
enum AlertType: String, CaseIterable, Identifiable {
    case test, free, headsup, camera, hunt, export, power
    var id: String { rawValue }

    var label: String {
        switch self {
        case .test: return "Plain test"
        case .free: return "Spot FREE"
        case .headsup: return "Heads up"
        case .camera: return "Camera stopped"
        case .hunt: return "Hunting on/off"
        case .export: return "Export reminder"
        case .power: return "Power mode"
        }
    }

    var priority: Int {
        switch self {
        case .free: return 5
        case .headsup: return 4
        case .test, .camera: return 3
        case .hunt: return 2
        case .export, .power: return 1
        }
    }

    var tags: String {
        switch self {
        case .test: return "test_tube"
        case .free: return "rotating_light"
        case .headsup: return "eyes"
        case .camera: return "warning"
        case .hunt: return "white_check_mark"
        case .export: return "floppy_disk"
        case .power: return "battery"
        }
    }

    /// The title a preview is sent with, after "[test] ".
    var sample: String {
        switch self {
        case .test: return "Spot Watch test"
        case .free: return "Spot 1 is FREE"
        case .headsup: return "Heads up: spot 1"
        case .camera: return "Camera stopped"
        case .hunt: return "Hunting on until 22:00"
        case .export: return "Export the Spot Watch log"
        case .power: return "Battery low: eco when not hunting"
        }
    }
}

enum Ntfy {
    static let base = "https://ntfy.sh"
    static let retryAfter: TimeInterval = 10        // a failed alert is tried once more after this
    static let publishTimeout: TimeInterval = 15

    /// Long and random is safest: anyone who knows a public topic can read it.
    static func validTopic(_ t: String) -> Bool {
        (1...64).contains(t.count) && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// JavaScript's encodeURIComponent: everything but A–Z a–z 0–9 - _ . ! ~ * ' ( ) is escaped.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// `https://ntfy.sh/<topic>?title=…&priority=…&tags=…`: options as query
    /// params, never headers, as in the web app.
    static func publishURL(topic: String, title: String?, priority: Int?, tags: String?) -> URL? {
        var qs: [String] = []
        if let t = title, !t.isEmpty { qs.append("title=" + encode(t)) }
        if let p = priority { qs.append("priority=\(p)") }
        if let t = tags, !t.isEmpty { qs.append("tags=" + encode(t)) }
        return URL(string: base + "/" + encode(topic) + (qs.isEmpty ? "" : "?" + qs.joined(separator: "&")))
    }

    /// The control topic's JSON stream, from just after the last message
    /// handled (ntfy keeps messages for 12 h), or new messages only.
    static func streamURL(topic: String, since lastId: String?) -> URL? {
        let since = lastId.flatMap { id in
            id.count <= 32 && !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? "?since=" + id : nil
        } ?? ""
        return URL(string: base + "/" + encode(topic) + "/json" + since)
    }
}

/// One line of ntfy's JSON stream.
struct ControlMessage: Equatable {
    let id: String?
    let time: Date?             // when it was sent
    let event: String           // "open", "keepalive" or "message"
    let message: String
    let title: String

    static func parse(_ line: Substring) -> ControlMessage? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return ControlMessage(id: o["id"] as? String,
                              time: (o["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                              event: o["event"] as? String ?? "message",
                              message: o["message"] as? String ?? "",
                              title: o["title"] as? String ?? "")
    }
}

/// When each spot last alerted, for the cooldowns. They survive redrawing a spot.
struct AlertTimes: Equatable {
    var free: Date?
    var headsup: Date?
}

enum SpotAlerts {
    /// Why a FREE goes out or not: nil to send it. Not hunting sends nothing and logs nothing.
    static func freeSkip(hunting: Bool, last: Date?, now: Date, cooldownMin: Double) -> String? {
        if !hunting { return "not hunting" }
        if let l = last, now.timeIntervalSince(l) < cooldownMin * 60 { return "cooldown" }
        return nil
    }

    /// Why a heads-up goes out or not: nil to send it. The arrival grace is the
    /// driver who just parked getting out.
    static func headsupSkip(hunting: Bool, occupiedSince: Date?, last: Date?, now: Date,
                            graceMin: Double, cooldownMin: Double) -> String? {
        if !hunting { return "not hunting" }
        if let s = occupiedSince, now.timeIntervalSince(s) < graceMin * 60 { return "arrival grace" }
        if let l = last, now.timeIntervalSince(l) < cooldownMin * 60 { return "cooldown" }
        return nil
    }

    static func freeTitle(_ spot: Int) -> String { "Spot \(spot) is FREE" }

    static func freeBody(_ spot: Int, at: Date, occupiedSince: Date?) -> String {
        "Spot \(spot) went vacant at \(Format.clock(at))" + (occupiedSince.map { "; it had been occupied since \(Format.clock($0))" } ?? "") + "."
    }

    static func headsupTitle(_ spot: Int) -> String { "Heads up: spot \(spot)" }

    static func headsupBody(_ spot: Int, at: Date) -> String {
        "Someone is at the parked car in spot \(spot) (\(Format.clock(at)))."
    }
}
