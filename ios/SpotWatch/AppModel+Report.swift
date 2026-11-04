import UIKit

// The numbers on screen and Copy report. Leaves out anything that names the
// ntfy topics (N2): anyone who knows a topic can read it.
extension AppModel {
    var hudLines: [String] {
        let side = viewMode.side
        let t = timing[side]
        let infer = t?.infer.average.map { "avg \(Format.ms($0))" } ?? "avg –"
        let check = checkStats.average.map { "avg \(Format.ms($0)) (n \(checkStats.count))" } ?? "avg –"
        return [
            "Check: last \(Format.ms(checkStats.last)) · \(check)",
            "\(side) run: last \(Format.ms(t?.infer.last)) · \(infer)",
            "CPU \(cpuText)",
            "Thermal \(thermal) · battery \(battery)",
            "Memory \(memoryText)"
        ]
    }

    var cpuText: String {
        guard let c = cpu else { return "–" }
        return "\(Int(c.rounded()))% (10 s avg \(Int((cpuAvg ?? c).rounded()))%) of \(DeviceInfo.cores * 100)%"
    }

    var memoryText: String {
        guard let m = memoryMB else { return "–" }
        return "\(Int(m.rounded())) MB" + (headroomMB.map { " · \(Int($0.rounded())) MB headroom" } ?? "")
    }

    /// "occupied since 00:12 · 45% · person no · next –"
    func spotLine(_ i: Int) -> String {
        guard let s = spots[i] else { return "not set" }
        guard isActive(i) else { return "hidden (drawn on \(s.shape))" }
        let t = tracks[i]
        return t.state.rawValue + (t.since.map { " since \(Format.clock($0))" } ?? "")
            + (t.coverage.map { " · \(Int(($0 * 100).rounded()))%" } ?? "")
            + (t.coverage != nil ? " · person \(t.person ? "yes" : "no")" : "")
            + " · next \(SpotLogic.runText(t, confirmN: Int(cfg.confirmN)))"
    }

    func statRows() -> [(String, String)] {
        var out: [(String, String)] = [
            ("Views", "\(viewMode.rawValue) · \(modelText) · every \(Format.ms(cfg.interval))"),
            ("Source", source == .camera
                ? "camera · " + (fps.map { String(format: "%.1f fps", $0) } ?? "– fps") + (orientation.map { " · " + $0.text } ?? "")
                : "bus.jpg"),
            ("Frame", "\(Int(frameSize.width))×\(Int(frameSize.height))" + (currentShape.map { " · \($0)" } ?? "")),
            ("Check", checkStats.averageText),
            ("Check min / max", checkStats.minMaxText),
            ("Prep", prepStats.average.map { "avg \(Format.ms($0)) (views and thumbnails)" } ?? "–")
        ]
        for side in [640, 320] {
            guard let t = timing[side], t.loadMs != nil else { continue }
            out.append(("\(side) load / first", "\(Format.ms(t.loadMs)) / \(Format.ms(t.infer.first))"))
            out.append(("\(side) run", t.infer.averageText + (t.infer.count > 0 ? " · \(t.infer.minMaxText)" : "")))
        }
        out.append(("Detector busy", busy.percent.map { "\($0)% (last \(busy.checks.count) checks)" } ?? "–"))
        out.append(("Checks", "\(checksOK) ok · \(checksFailed) failed" + (paused ? " · paused" : "")))
        out.append(("CPU", cpuText))
        out.append(("Memory", memoryText))
        out.append(("Thermal", thermal + " · camera pressure " + pipeline.camera.pressureText))
        out.append(("Battery", battery))
        out.append(("Focus", focusText))
        out.append(("Dropped frames", "\(droppedTotal)" + (lastDropReason.isEmpty ? "" : " (last: \(lastDropReason))")))
        return out
    }

    func buildReport() -> String {
        var lines: [String] = []
        lines.append("Spot Watch iOS report · \(buildLabel)")
        lines.append("Time: \(Date())")
        #if DEBUG
        let config = "Debug"
        #else
        let config = "Release"
        #endif
        lines.append("\(DeviceInfo.model) · iOS \(UIDevice.current.systemVersion) · \(DeviceInfo.cores) cores · \(config) build")
        lines.append("Up \(Int(Date().timeIntervalSince(started) / 60)) min")
        lines.append("")
        lines.append("Status:")
        for r in rows { lines.append("  \(r.label): \(r.state) · \(r.detail)") }
        lines.append("")
        lines.append("Checks:")
        for (k, v) in statRows() { lines.append("  \(k): \(v)") }
        for side in [640, 320] {
            if let t = timing[side], !t.spec.isEmpty { lines.append("  \(side) spec: \(t.spec)") }
        }
        lines.append("  Camera: \(pipeline.camera.formatText.isEmpty ? "not started" : pipeline.camera.formatText)")
        lines.append("  4:3 formats: \(pipeline.camera.formatsOnOffer.joined(separator: "; "))")
        lines.append("")
        lines.append("Spots (frame \(currentShape ?? "unknown")):")
        for i in spots.indices {
            lines.append("  Spot \(i + 1): " + (spots[i].map { "\($0.text) · " } ?? "") + spotLine(i))
        }
        lines.append("  Views: " + (views.isEmpty ? "full frame" : views.map(\.text).joined(separator: " | ")))
        lines.append("Settings: " + Settings.text(cfg))
        lines.append("")
        lines.append("Last detections\(lastCheckAt.map { " (\(Format.clock($0)))" } ?? ""):")
        if detections.isEmpty { lines.append("  none above \(Int((cfg.minScore * 100).rounded()))%") }
        for d in detections {
            let b = d.box
            lines.append("  \(d.className) \(Int((d.score * 100).rounded()))% · x \(Int(b.x)) y \(Int(b.y)) w \(Int(b.w)) h \(Int(b.h))")
        }
        lines.append("")
        lines.append("Events (\(store?.rows.count ?? 0) rows, newest first, last \(AppModel.eventsShown)):")
        for r in recentEvents.reversed() { lines.append("  \(EventFormat.stamp(r.time))  \(EventFormat.text(r))") }
        lines.append("")
        lines.append("Errors (\(errors.count)):")
        for e in errors { lines.append("  \(e.time) \(e.msg)") }
        lines.append("")
        lines.append("Log (newest first):")
        for e in log.reversed() { lines.append("  " + e.line) }
        return lines.joined(separator: "\n")
    }

    func copyReport() {
        let text = buildReport()
        UIPasteboard.general.string = text
        copyResult = UIPasteboard.general.string == text
            ? "Report copied at \(Format.clock()) (\(text.split(separator: "\n").count) lines)."
            : "Could not copy the report."
        if UIPasteboard.general.string != text { fail("report", "The pasteboard did not take the report") }
    }
}
