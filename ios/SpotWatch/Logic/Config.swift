import Foundation

// The tuning settings, with the web app's keys, defaults and ranges
// (PLAN.md's starting parameters). Foundation only. The hunting, alert and
// eco settings join in N2 and N3.

struct Config: Equatable {
    var interval = 1500.0           // ms between check starts; a check never overlaps the previous one
    var minScore = 0.2
    var personMinScore = 0.4
    var occThresh = 0.35
    var confirmN = 3.0
    var hintN = 2.0
    var personMargin = 0.35
    var changeMin = 10.0

    var spotSettings: SpotSettings {
        SpotSettings(occThresh: occThresh, confirmN: Int(confirmN), hintN: Int(hintN), personMargin: personMargin,
                     personMinScore: personMinScore, changeMin: changeMin)
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
        SettingDef(key: "changeMin", label: "Departure change min", def: 10, min: 0, max: 100, isInt: false, path: \.changeMin)
    ]

    /// "interval 1500, minScore 0.2, …" for the report.
    static func text(_ c: Config) -> String {
        all.map { "\($0.key) \(SettingDef.text(c[keyPath: $0.path]))" }.joined(separator: ", ")
    }
}
