import Foundation

// Hunting mode, ported from the web app (startHunt, endHunt, handleCommand,
// huntTick, setPower, exportReminder). FREE and heads-up alerts fire only
// while hunting. "hunt on" / "hunt off" on the control topic (or the button)
// switch it; the safety timeout or the start of quiet hours end it. Every
// step returns its effects (log rows, alerts, log lines) for the app to carry
// out. Foundation only.

/// Saved across launches, so a restart keeps the hunt.
struct HuntState: Codable, Equatable {
    var on = false
    var since: Date?
    var until: Date?                // the safety timeout
    var lastCommand: String?
    var lastCommandAt: Date?        // when it was sent
}

/// The battery level as last reported by "power low" / "power high" (the
/// 6s's Shortcuts automations). Reading it directly comes in N3.
enum Power: String, Codable {
    case low, high, unknown
}

struct HuntSettings: Equatable {
    var huntHours = 3.0
    var quietStart = 21.0           // decimal hours, local time; equal values turn quiet hours off
    var quietEnd = 7.0
    var ecoInterval = 10_000.0      // ms between checks when not at full speed
}

enum HuntEffect: Equatable {
    case row(String, detail: String)                        // an event-log row with no spot
    case alert(AlertType, title: String, body: String)
    case note(String)                                       // a log line
}

struct Hunting {
    static let lateEnd: TimeInterval = 120          // a hunt end found this long after is reported as late
    static let lateCommand: TimeInterval = 60       // a command older than this gets no reply
    static let tickEvery: TimeInterval = 15         // how often the timeout, quiet hours and export reminder are checked
    static let week: TimeInterval = 7 * 24 * 3600

    var state = HuntState()
    var power = Power.unknown
    var settings = HuntSettings()
    var calendar = Calendar.current

    /// Full speed while hunting, or while the battery is high (to use power up).
    var fullSpeed: Bool { state.on || power == .high }

    var modeText: String {
        fullSpeed ? "full speed" + (state.on ? "" : " (battery high)")
            : "eco, every \(SettingDef.text(settings.ecoInterval / 1000)) s"
    }

    // MARK: - Time

    /// Quiet hours run from quietStart to quietEnd, across midnight when the
    /// start is later than the end.
    func inQuietHours(_ d: Date) -> Bool {
        let s = settings.quietStart, e = settings.quietEnd
        if s == e { return false }
        let c = calendar.dateComponents([.hour, .minute], from: d)
        let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return s < e ? h >= s && h < e : h >= s || h < e
    }

    /// The next time after `d` that the clock reads `hours`.
    func nextAt(_ d: Date, hours: Double) -> Date {
        let midnight = calendar.startOfDay(for: d)
        let minutes = Int(hours.rounded(.down)) * 60 + Int(((hours.truncatingRemainder(dividingBy: 1)) * 60).rounded())
        var t = calendar.date(byAdding: .minute, value: minutes, to: midnight) ?? d
        if t <= d { t = calendar.date(byAdding: .day, value: 1, to: t) ?? t.addingTimeInterval(86_400) }
        return t
    }

    /// When the current hunt ends, and why: the timeout or quiet hours, whichever comes first.
    func end(now: Date) -> (at: Date, why: String) {
        let until = state.until ?? now
        guard settings.quietStart != settings.quietEnd else { return (until, "timeout") }
        let quiet = nextAt(now, hours: settings.quietStart)
        return quiet < until ? (quiet, "quiet hours") : (until, "timeout")
    }

    func hm(_ d: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// HH:MM today, or MM-DD HH:MM for another day.
    func whenText(_ d: Date, now: Date) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return hm(d) }
        let c = calendar.dateComponents([.month, .day], from: d)
        return String(format: "%02d-%02d ", c.month ?? 0, c.day ?? 0) + hm(d)
    }

    static func hoursText(_ h: Double) -> String {
        String(format: "%02d:%02d", Int(h.rounded(.down)), Int((h.truncatingRemainder(dividingBy: 1) * 60).rounded()))
    }

    // MARK: - Commands

    /// `at` is when the command was sent, so a command replayed after a
    /// reconnect is judged by its own time, not by when it arrived.
    mutating func handle(_ text: String, at: Date, now: Date) -> [HuntEffect] {
        let cmd = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let late = now.timeIntervalSince(at) > Hunting.lateCommand
        if cmd == "power low" || cmd == "power high" {
            return setPower(cmd == "power low" ? .low : .high, late: late)
        }
        guard cmd == "hunt on" || cmd == "hunt off" else {
            return [.note("Not a command, ignored: \"\(String(text.prefix(40)))\"")]
        }
        state.lastCommand = cmd
        state.lastCommandAt = at
        if cmd == "hunt off" {
            if state.on { return end("manual", at: at, now: now) }
            return late ? [] : [.alert(.hunt, title: "Hunting was already off", body: "Nothing to stop.")]
        }
        if inQuietHours(at) {
            var out: [HuntEffect] = [.note("\"hunt on\" refused: quiet hours")]
            if !late {
                out.append(.alert(.hunt, title: "Hunt on refused: quiet hours until \(hm(nextAt(at, hours: settings.quietEnd)))",
                                  body: "Quiet hours run \(Hunting.hoursText(settings.quietStart))–\(Hunting.hoursText(settings.quietEnd)). They can be changed in Settings."))
            }
            return out
        }
        return start(at: at, now: now, late: late)
    }

    mutating func start(at: Date, now: Date, late: Bool) -> [HuntEffect] {
        let until = at.addingTimeInterval(settings.huntHours * 3600)
        if until <= now {
            return [.note("\"hunt on\" sent \(EventFormat.stamp(at)) had already timed out, ignored")]
        }
        let extended = state.on
        state.on = true
        if !extended { state.since = at }
        state.until = until
        let e = end(now: now)
        let detail = (extended ? "extended" : "started") + ", ends \(hm(e.at)) (\(e.why))" + (late ? ", sent \(Format.clock(at))" : "")
        let body = e.why == "quiet hours" ? "Quiet hours start at \(hm(e.at))."
            : "The \(SettingDef.text(settings.huntHours)) h safety timeout ends it at \(hm(e.at))."
        return [.row("hunt_on", detail: detail), .alert(.hunt, title: "Hunting on until \(hm(e.at))", body: body)]
    }

    /// `at` is when the hunt actually ended. If the app wasn't running then,
    /// the reply says when it ended rather than implying now.
    mutating func end(_ why: String, at: Date, now: Date) -> [HuntEffect] {
        guard state.on else { return [] }
        state.on = false
        state.until = nil
        let late = now.timeIntervalSince(at) > Hunting.lateEnd
        let row = HuntEffect.row("hunt_off", detail: why + (late ? ", ended \(EventFormat.stamp(at))" : ""))
        if late {
            return [row, .alert(.hunt, title: "Hunting ended at \(whenText(at, now: now)) (\(why))",
                                body: "The app wasn't running then, so this is reported late, at \(hm(now)).")]
        }
        return [row, .alert(.hunt, title: "Hunting off (\(why))", body: "Spot Watch stopped hunting at \(hm(now)).")]
    }

    mutating func setPower(_ level: Power, late: Bool) -> [HuntEffect] {
        power = level
        var out: [HuntEffect] = [.row("power_" + level.rawValue, detail: modeText + (late ? ", sent late" : ""))]
        if !late {
            out.append(.alert(.power, title: "Battery \(level.rawValue): " + (fullSpeed ? "full speed" : "eco when not hunting"),
                              body: level == .high ? "Checks run at full speed to use power."
                                : "Checks slow to every \(SettingDef.text(settings.ecoInterval / 1000)) s when not hunting."))
        }
        return out
    }

    /// Ends the hunt at whichever came first: the timeout, or the first
    /// quiet-hours start after it began, using the real time even if the app
    /// was down then. A quiet-hours window edited to cover now ends it straight away.
    mutating func tick(now: Date) -> [HuntEffect] {
        guard state.on else { return [] }
        let quietAt = settings.quietStart == settings.quietEnd ? Date.distantFuture
            : nextAt(state.since ?? now, hours: settings.quietStart)
        let until = state.until ?? now
        if until <= now && until <= quietAt { return end("timeout", at: until, now: now) }
        if quietAt <= now { return end("quiet hours", at: quietAt, now: now) }
        if inQuietHours(now) { return end("quiet hours", at: now, now: now) }
        return []
    }

    /// The weekly nudge to export, between 10:00 and 20:00, so a wiped phone
    /// loses at most a week of log.
    func exportReminderDue(now: Date, lastExport: Date?, firstRow: Date?, lastReminder: Date?) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard hour >= 10 && hour < 20 else { return false }
        let since = max(lastExport ?? .distantPast, firstRow ?? now)
        return now.timeIntervalSince(since) >= Hunting.week
            && now.timeIntervalSince(lastReminder ?? .distantPast) >= Hunting.week
    }
}
