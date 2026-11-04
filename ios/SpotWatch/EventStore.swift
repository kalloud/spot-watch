import Foundation

/// The event log on disk: one JSON row per line (the web app's row format) in
/// Application Support, so it survives restarts and reinstalls. Capped at
/// `maxRows`, dropping the oldest first. Main thread only; events are rare.
final class EventStore {
    static let maxRows = 20_000
    static let compactSlack = 1_000         // rows past the cap before the file is rewritten

    private(set) var rows: [EventRow] = []
    private(set) var lastWrite: Date?
    /// The last failure, for the Events status row; nil while writing works.
    private(set) var failure: String?
    private(set) var skippedLines = 0
    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("events.jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.split(separator: "\n") {
                    if let r = EventFormat.row(jsonLine: line) { rows.append(r) } else { skippedLines += 1 }
                }
            }
            if rows.count > EventStore.maxRows {
                rows.removeFirst(rows.count - EventStore.maxRows)
                try rewrite()
            }
        } catch {
            failure = "Could not read the event log: \(error.localizedDescription)"
        }
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SpotWatch", isDirectory: true)
    }

    func append(_ r: EventRow) {
        rows.append(r)
        do {
            if rows.count > EventStore.maxRows + EventStore.compactSlack {
                rows.removeFirst(rows.count - EventStore.maxRows)
                try rewrite()
            } else {
                let data = Data((EventFormat.jsonLine(r) + "\n").utf8)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url, options: .atomic)
                } else {
                    // The throwing calls (iOS 13.4+): the old ones raise on a full disk.
                    let h = try FileHandle(forWritingTo: url)
                    defer { try? h.close() }
                    try h.seekToEnd()
                    try h.write(contentsOf: data)
                }
            }
            lastWrite = Date()
            failure = nil
        } catch {
            failure = "Event not saved: \(error.localizedDescription)"
        }
    }

    private func rewrite() throws {
        let text = rows.map(EventFormat.jsonLine).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Writes the CSV to a temporary file named for now, for the share sheet.
    func exportCSV(now: Date = Date()) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(EventFormat.csvName(now))
        try Data(EventFormat.csv(rows).utf8).write(to: file, options: .atomic)
        return file
    }
}
