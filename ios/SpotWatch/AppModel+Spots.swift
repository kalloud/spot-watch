import SwiftUI
import UIKit

// Spots, their states, the event log, settings and the export: the web app's
// spot code wired to the pure logic in Logic/.
extension AppModel {
    // MARK: - Frame shape

    /// The mount (interface orientation) or the test image, as in a spot's shape.
    var shapeLabel: String {
        source == .testImage ? "bus.jpg" : (orientation?.text ?? "landscape")
    }

    var currentShape: String? {
        frameDims.map { Geometry.shape(width: Double($0.width), height: Double($0.height), label: shapeLabel) }
    }

    func isActive(_ i: Int) -> Bool {
        guard let s = spots[i], let shape = currentShape else { return false }
        return s.shape == shape
    }

    var activeSpots: [Int: FracRect] {
        var out: [Int: FracRect] = [:]
        for i in spots.indices where isActive(i) { out[i] = spots[i]!.rect }
        return out
    }

    /// A new frame shape (the phone turned round, or the source changed)
    /// resets every spot to unknown without a log row, so it can't look like a departure.
    func shapeMaybeChanged() {
        let shape = currentShape
        guard shape != lastShape else { return }
        if lastShape != nil, let shape = shape { addLog("spots", "Frame shape is now \(shape)") }
        lastShape = shape
        tracks = Array(repeating: SpotTrack(), count: AppModel.spotCount)
        if drawingSpot != nil {
            drawHint = "The frame changed mid-drag. Try again."
        }
        renderSpotsStatus()
        pushOptions()
    }

    // MARK: - Spots

    func loadSpots() {
        guard let data = UserDefaults.standard.data(forKey: "sw.spots") else { return }
        do {
            let saved = try JSONDecoder().decode([Spot?].self, from: data)
            for i in spots.indices where i < saved.count {
                if let s = saved[i] {
                    if s.isValid { spots[i] = s } else { addLog("spots", "Saved spot \(i + 1) is invalid, ignored") }
                }
            }
        } catch {
            fail("spots", "Could not read the saved spots (\(error.localizedDescription)); they're ignored")
        }
    }

    private func saveSpots() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(spots), forKey: "sw.spots")
        } catch {
            fail("spots", "Could not save the spots: \(error.localizedDescription)")
        }
    }

    var canDraw: Bool { currentShape != nil && drawingSpot == nil }

    func startDrawing(_ i: Int) {
        guard canDraw else { return }
        drawingSpot = i
        drawHint = "Drag a box over spot \(i + 1)."
        if source == .camera { pipeline.camera.setFocusLocked(false) }
    }

    func cancelDrawing() {
        drawingSpot = nil
        drawHint = "Cancelled."
        lockFocusSoon()
    }

    /// Saves the box dragged for the spot being drawn, as fractions of the frame.
    func finishDrawing(_ r: FracRect) {
        guard let i = drawingSpot, let shape = currentShape else { return }
        if r.w < Geometry.minSpotSide || r.h < Geometry.minSpotSide {
            drawHint = "Too small, not saved. Drag a bigger box over spot \(i + 1)."
            addLog("spots", "Box for spot \(i + 1) too small, ignored")
            return
        }
        func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        let spot = Spot(rect: FracRect(x: round4(r.x), y: round4(r.y), w: round4(r.w), h: round4(r.h)), shape: shape)
        spots[i] = spot
        tracks[i] = SpotTrack()
        saveSpots()
        addLog("spots", "Spot \(i + 1) saved: \(spot.text)")
        drawingSpot = nil
        drawHint = "Spot \(i + 1) saved."
        renderSpotsStatus()
        pushOptions()
        lockFocusSoon()
    }

    func renderSpotsStatus() {
        guard let shape = currentShape else {
            set("spots", .idle, spots.contains(where: { $0 != nil }) ? "Waiting for a frame" : "No spot drawn yet")
            return
        }
        var hiddenIn: String?
        var active = 0
        let parts = spots.indices.map { i -> String in
            guard let s = spots[i] else { return "Spot \(i + 1) not set" }
            if s.shape != shape {
                hiddenIn = s.shape
                return "Spot \(i + 1) hidden"
            }
            active += 1
            return "Spot \(i + 1) set"
        }
        var text = parts.joined(separator: " · ")
        if let h = hiddenIn {
            text = "Drawn on a \(h) frame, the frame is now \(shape). Turn the phone back, switch the source back, or redraw. (\(text))"
        }
        if active == 0 { text += " · Detecting on the full frame, states paused." }
        set("spots", hiddenIn != nil ? .warn : spots.allSatisfy({ $0 != nil }) ? .ok : .idle, text)
    }

    // MARK: - Readings and states

    /// Feeds each active spot this check's reading. A check made for another
    /// frame shape, or before a spot was redrawn, gives that spot no reading.
    func updateSpots(_ r: Pipeline.CheckResult) {
        guard r.shape == currentShape,
              Geometry.shape(width: r.frameWidth, height: r.frameHeight, label: shapeLabel) == currentShape else { return }
        let settings = cfg.spotSettings
        for (i, rect) in r.spots.sorted(by: { $0.key < $1.key }) where spots[i]?.rect == rect {
            let reading = SpotLogic.read(rect.pixels(width: r.frameWidth, height: r.frameHeight), r.detections, settings)
            let events = SpotLogic.update(&tracks[i], reading, thumb: { r.thumbs[i] }, settings, now: Date())
            for e in events { record(e, spot: i) }
        }
    }

    private func record(_ e: SpotEvent, spot i: Int) {
        switch e {
        case .changed(let state, let coverage, let change):
            logEvent(i, state.rawValue, coverage: coverage, detail: change.map { String(format: "change %.1f", $0) } ?? "")
        case .freed(let coverage, let occupiedSince):
            spotFreed(i, coverage: coverage, occupiedSince: occupiedSince)
        case .vacantRejected(let coverage, let change, let count, let logRow):
            let detail = String(format: "change %.1f < %@", change, SettingDef.text(cfg.changeMin))
            if logRow {
                logEvent(i, "vacant_rejected", coverage: coverage, detail: detail + (count > 1 ? ", \(count) so far" : ""))
            } else {
                addLog("spots", "Spot \(i + 1) vacant rejected: \(detail) (\(count))")
            }
        case .personNear(let coverage, let score, let occupiedSince):
            personNear(i, coverage: coverage, score: score, occupiedSince: occupiedSince)
        }
    }

    // MARK: - Event log

    func openEventLog() {
        let s = EventStore(directory: EventStore.defaultDirectory())
        store = s
        if let f = s.failure { fail("events", f) }
        if s.skippedLines > 0 { addLog("events", "Skipped \(s.skippedLines) unreadable line(s) in the event log") }
        recentEvents = Array(s.rows.suffix(AppModel.eventsShown))
        renderEventsStatus()
    }

    /// Appends a row: spot is 0-based (nil for whole-app rows).
    func logEvent(_ spot: Int?, _ event: String, coverage: Double?, detail: String) {
        guard let s = store else { return }
        let row = EventRow(time: Date(), spot: spot.map { $0 + 1 }, event: event,
                           coverage: coverage.map { Int(($0 * 100).rounded()) }, hunting: hunting.state.on, detail: detail)
        s.append(row)
        if let f = s.failure { fail("events", f) }
        checkRows.append(row)
        recentEvents.append(row)
        if recentEvents.count > AppModel.eventsShown { recentEvents.removeFirst(recentEvents.count - AppModel.eventsShown) }
        addLog("event", EventFormat.text(row))
        renderEventsStatus()
    }

    func renderEventsStatus() {
        guard let s = store else { return }
        let detail = "\(s.rows.count) rows" + (s.lastWrite.map { " · last write \(Format.clock($0))" } ?? "")
        set("events", s.failure != nil ? .fail : s.rows.isEmpty ? .idle : .ok, s.failure.map { detail + " · " + $0 } ?? detail)
    }

    /// The CSV and a zip of the photos, through the share sheet.
    func exportLog() {
        prepareExport { [weak self] files, what in self?.share(files, what: what) }
    }

    /// Writes the CSV and zips the photos (off the main thread), then hands
    /// over the files and a description such as "24 rows and 37 photos". A
    /// failed zip still hands over the CSV.
    func prepareExport(_ done: @escaping ([URL], String) -> Void) {
        guard let s = store, !exporting else { return }
        let csv: URL
        do {
            csv = try s.exportCSV()
        } catch {
            exportResult = "Export failed: \(error.localizedDescription)"
            fail("events", exportResult)
            return
        }
        let rows = "\(s.rows.count) rows"
        guard let p = photos else { return done([csv], rows) }
        exporting = true
        exportResult = "Zipping the photos…"
        p.zip(named: PhotoPlan.zipName(Date())) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.exporting = false
                self.exportResult = ""
                switch result {
                case .success(let zip?):
                    done([csv, zip.url], "\(rows) and \(zip.count) photos")
                case .success(nil):
                    done([csv], rows)
                case .failure(let error):
                    self.fail("photos", "Could not zip the photos (\(error.localizedDescription)); sharing the CSV alone")
                    done([csv], rows)
                }
            }
        }
    }

    /// The share sheet (AirDrop, Files…) for the exported files.
    private func share(_ files: [URL], what: String) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            exportResult = "Could not open the share sheet."
            fail("events", exportResult)
            return
        }
        while let next = top.presentedViewController { top = next }
        let name = files[0].lastPathComponent
        let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil)
        sheet.completionWithItemsHandler = { [weak self] activity, completed, _, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    self.exportResult = "Export failed: \(error.localizedDescription)"
                    self.fail("events", self.exportResult)
                } else if completed {
                    self.exportResult = "\(Format.clock()): shared \(name) (\(what))" +
                        (activity.map { " via \($0.rawValue.components(separatedBy: ".").last ?? $0.rawValue)" } ?? "")
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "sw.lastExport")
                    self.addLog("events", self.exportResult)
                } else {
                    self.exportResult = "Export cancelled."
                }
            }
        }
        top.present(sheet, animated: true)
        exportResult = "Sharing \(name) (\(what))…"
    }

    // MARK: - Settings

    func loadSettings() {
        let d = UserDefaults.standard
        var c = Config()
        for def in Settings.all {
            guard let raw = d.string(forKey: "sw.cfg." + def.key) else { continue }
            if let v = def.parse(raw) { c[keyPath: def.path] = v } else { addLog("settings", "Saved \(def.label) is invalid, using the default") }
        }
        cfg = c
    }

    /// Applies the typed values; returns the keys that were invalid (and left unchanged).
    @discardableResult
    func applySettings(_ typed: [String: String]) -> Set<String> {
        var bad: Set<String> = []
        var c = cfg
        for def in Settings.all {
            guard let raw = typed[def.key] else { continue }
            guard let v = def.parse(raw) else {
                bad.insert(def.key)
                continue
            }
            if v != c[keyPath: def.path] {
                c[keyPath: def.path] = v
                UserDefaults.standard.set(SettingDef.text(v), forKey: "sw.cfg." + def.key)
                addLog("settings", "\(def.label) = \(SettingDef.text(v))")
            }
        }
        cfg = c
        huntSettingsChanged()
        pushOptions()
        return bad
    }
}
