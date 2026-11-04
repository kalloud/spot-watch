import Foundation

// Photos of checked frames (PhotoStore): one for every check that logged a
// row, and one every few minutes, with the spots and detections drawn on.
extension AppModel {
    func openPhotos() {
        let p = PhotoStore(directory: PhotoStore.defaultDirectory())
        p.onStatus = { [weak self] s in
            DispatchQueue.main.async { self?.photoStatus(s) }
        }
        photos = p
        set("photos", .idle, "None yet")
        p.refresh()
    }

    private func photoStatus(_ s: PhotoStore.Status) {
        var detail = s.count == 0 ? "None yet" : "\(s.count) photos · " + String(format: "%.1f MB", s.megabytes)
        if let t = s.last { detail += " · last \(Format.clock(t))" }
        if let f = s.failure {
            set("photos", .fail, f + " · " + detail)
            fail("photos", f)
        } else {
            set("photos", s.count == 0 ? .idle : .ok, detail)
        }
    }

    /// Saves a photo of this check's frame when the check logged a row, or
    /// when the last photo is `PhotoPlan.every` old.
    func photoIfDue(_ r: Pipeline.CheckResult) {
        guard let p = photos, PhotoPlan.due(rowsLogged: !checkRows.isEmpty, last: lastPhotoAt, now: r.started) else { return }
        lastPhotoAt = r.started
        var marks: [PhotoStore.SpotMark] = []
        var states: [String] = []
        for (i, rect) in r.spots.sorted(by: { $0.key < $1.key }) where spots[i]?.rect == rect {
            let t = tracks[i]
            let pct = t.coverage.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            marks.append(PhotoStore.SpotMark(rect: rect.pixels(width: r.frameWidth, height: r.frameHeight),
                                             label: "\(i + 1) · \(t.state.rawValue)\(pct)" + (t.person ? " · person" : ""),
                                             state: t.state))
            states.append("Spot \(i + 1) \(t.state.rawValue)\(pct)")
        }
        let caption = PhotoPlan.caption(time: r.started, setup: "\(viewMode.rawValue) · \(buildLabel)",
                                        rows: checkRows, spots: states)
        let shot = PhotoStore.Shot(frame: r.frame, time: r.started, caption: caption, spots: marks, detections: r.detections)
        if !p.save(shot) { addLog("photos", "Skipped a photo: the last ones are still being written") }
    }
}
