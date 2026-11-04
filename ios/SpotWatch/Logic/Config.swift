import Foundation

// The tuning, hunting and alert settings, with the web app's keys, defaults
// and ranges (PLAN.md's starting parameters). Foundation only. The ntfy
// topics are kept apart (AppModel+Alerts.swift), out of the report.

struct Config: Equatable {
    var interval = 1500.0           // ms between check starts; a check never overlaps the previous one
    var minScore = 0.2
    var personMinScore = 0.4
    var occThresh = 0.35
    var confirmN = 3.0
    var hintN = 2.0
    var personMargin = 0.35
    var huntHours = 3.0
    var quietStart = 21.0           // decimal hours, e.g. 7.5 = 07:30
    var quietEnd = 7.0
    var headsupCooldown = 3.0       // minutes, per spot
    var freeCooldown = 2.0          // minutes, per spot
    var arrivalGrace = 2.0          // minutes after a spot becomes occupied with no heads-up
    var changeMin = 10.0
    var ecoInterval = 10_000.0      // ms between checks when not hunting (and the battery isn't high)

    var spotSettings: SpotSettings {
        SpotSettings(occThresh: occThresh, confirmN: Int(confirmN), hintN: Int(hintN), personMargin: personMargin,
                     personMinScore: personMinScore, changeMin: changeMin)
    }

    var huntSettings: HuntSettings {
        HuntSettings(huntHours: huntHours, quietStart: quietStart, quietEnd: quietEnd, ecoInterval: ecoInterval)
    }
}

struct SettingDef {
    let key: String
    let label: String
    let def: Double
    let min: Double
    let max: Double
    let isInt: Bool
    let path: WritableKeyPath<Config, Double>

    /// The value typed, or nil if it isn't a number in range. Accepts a
    /// decimal comma, which some keypads show.
    func parse(_ raw: String?) -> Double? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."),
              !text.isEmpty, let v = Double(text), v.isFinite, v >= min, v <= max else { return nil }
        return isInt ? v.rounded() : v
    }

    var hint: String { "\(Self.text(min))–\(Self.text(max)) · default \(Self.text(def))" }

    static func text(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}

enum Settings {
    static let all: [SettingDef] = [
        SettingDef(key: "interval", label: "Interval (ms)", def: 1500, min: 500, max: 10000, isInt: true, path: \.interval),
        SettingDef(key: "minScore", label: "minScore", def: 0.2, min: 0.1, max: 0.9, isInt: false, path: \.minScore),
        SettingDef(key: "personMinScore", label: "Person minScore", def: 0.4, min: 0.1, max: 0.95, isInt: false, path: \.personMinScore),
        SettingDef(key: "occThresh", label: "occThresh", def: 0.35, min: 0.05, max: 0.95, isInt: false, path: \.occThresh),
        SettingDef(key: "confirmN", label: "confirmN", def: 3, min: 1, max: 20, isInt: true, path: \.confirmN),
        SettingDef(key: "hintN", label: "hintN", def: 2, min: 1, max: 20, isInt: true, path: \.hintN),
        SettingDef(key: "personMargin", label: "Person margin", def: 0.35, min: 0, max: 2, isInt: false, path: \.personMargin),
        SettingDef(key: "huntHours", label: "Hunt timeout (h)", def: 3, min: 0.05, max: 12, isInt: false, path: \.huntHours),
        SettingDef(key: "quietStart", label: "Quiet from (h)", def: 21, min: 0, max: 23.99, isInt: false, path: \.quietStart),
        SettingDef(key: "quietEnd", label: "Quiet until (h)", def: 7, min: 0, max: 23.99, isInt: false, path: \.quietEnd),
        SettingDef(key: "headsupCooldown", label: "Heads-up cooldown (min)", def: 3, min: 0, max: 60, isInt: false, path: \.headsupCooldown),
        SettingDef(key: "freeCooldown", label: "FREE cooldown (min)", def: 2, min: 0, max: 60, isInt: false, path: \.freeCooldown),
        SettingDef(key: "arrivalGrace", label: "Arrival grace (min)", def: 2, min: 0, max: 30, isInt: false, path: \.arrivalGrace),
        SettingDef(key: "changeMin", label: "Departure change min", def: 10, min: 0, max: 100, isInt: false, path: \.changeMin),
        SettingDef(key: "ecoInterval", label: "Eco interval (ms)", def: 10000, min: 1500, max: 60000, isInt: true, path: \.ecoInterval)
    ]

    /// "interval 1500, minScore 0.2, …" for the report.
    static func text(_ c: Config) -> String {
        all.map { "\($0.key) \(SettingDef.text(c[keyPath: $0.path]))" }.joined(separator: ", ")
    }
}
