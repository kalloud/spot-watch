import Foundation

// Hunting, alerts, the control topic and the Camera stopped watchdog: the
// web app's hunting and alert code wired to Logic/Hunt.swift and
// Logic/Alerts.swift. The topic names stay out of the status rows, the log
// and the report: anyone who knows a topic can read it.
extension AppModel {
    static let controlShown = 20
    static let cameraDeadS = 10.0       // seconds without a frame, while the app is active, before "Camera stopped"

    struct ControlLine {
        let at: Date
        let lagS: Int?
        let text: String
    }

    // MARK: - Start

    func startAlerts() {
        let d = UserDefaults.standard
        alertTopic = d.string(forKey: "sw.alertTopic").flatMap { Ntfy.validTopic($0) ? $0 : nil } ?? ""
        controlTopic = d.string(forKey: "sw.controlTopic").flatMap { Ntfy.validTopic($0) ? $0 : nil } ?? ""
        if let data = d.data(forKey: "sw.hunt") {
            do {
                hunting.state = try JSONDecoder().decode(HuntState.self, from: data)
            } catch {
                fail("hunt", "Could not read the saved hunt (\(error.localizedDescription)); hunting is off")
            }
        }
        hunting.power = d.string(forKey: "sw.power").flatMap(Power.init) ?? .unknown
        hunting.settings = cfg.huntSettings
        set("alerts", alertTopic.isEmpty ? .warn : .idle, alertTopic.isEmpty ? "No alert topic: set it in Settings" : "No alert sent yet")
        control.onEvent = { [weak self] e in
            DispatchQueue.main.async { self?.handleControl(e) }
        }
        connectControl()
        huntTick()
    }

    func connectControl() {
        if controlTopic.isEmpty {
            set("control", .warn, "No control topic: set it in Settings")
            control.connect(topic: nil, lastId: nil)
        } else {
            control.connect(topic: controlTopic, lastId: UserDefaults.standard.string(forKey: "sw.controlLastId"))
        }
    }

    /// Saves the topics typed in Settings; returns the ones that were invalid (and left unchanged).
    @discardableResult
    func applyTopics(alert: String, control new: String) -> Set<String> {
        var bad: Set<String> = []
        let a = alert.trimmingCharacters(in: .whitespaces), c = new.trimmingCharacters(in: .whitespaces)
        if a != alertTopic {
            if Ntfy.validTopic(a) {
                alertTopic = a
                UserDefaults.standard.set(a, forKey: "sw.alertTopic")
                addLog("topics", "Alert topic changed and saved")
                set("alerts", .idle, "Topic changed · no alert sent yet")
            } else {
                bad.insert("alertTopic")
            }
        }
        if c != controlTopic {
            if Ntfy.validTopic(c) {
                controlTopic = c
                UserDefaults.standard.set(c, forKey: "sw.controlTopic")
                UserDefaults.standard.removeObject(forKey: "sw.controlLastId")      // ids belong to the old topic
                controlSeen = []
                controlLines = []
                addLog("topics", "Control topic changed and saved")
                connectControl()
            } else {
                bad.insert("controlTopic")
            }
        }
        return bad
    }

    // MARK: - Hunting

    /// Full speed while hunting or while the battery is high; otherwise the eco interval.
    var checkIntervalMs: Double { hunting.fullSpeed ? cfg.interval : cfg.ecoInterval }

    /// `at` is when the command was sent.
    func handleCommand(_ text: String, at: Date) {
        run(hunting.handle(text, at: at, now: Date()))
    }

    func toggleHunt() {
        addLog("hunt", "Button: " + (hunting.state.on ? "hunt off" : "hunt on"))
        handleCommand(hunting.state.on ? "hunt off" : "hunt on", at: Date())
    }

    /// Settings changed: new quiet hours or timeout may end the hunt now.
    func huntSettingsChanged() {
        hunting.settings = cfg.huntSettings
        huntTick()
    }

    /// The timeout, quiet hours and the export reminder, every `Hunting.tickEvery` s.
    func huntTick() {
        let now = Date()
        lastHuntTick = now
        run(hunting.tick(now: now))
        exportReminder(now)
    }

    private func run(_ effects: [HuntEffect]) {
        for e in effects {
            switch e {
            case .row(let event, let detail):
                logEvent(nil, event, coverage: nil, detail: detail)
            case .alert(let type, let title, let body):
                Task { await self.sendAlert(type, title: title, body: body) }
            case .note(let msg):
                addLog("hunt", msg)
            }
        }
        saveHunt()
        renderHunt()
        pushOptions()
    }

    private func saveHunt() {
        let d = UserDefaults.standard
        do {
            d.set(try JSONEncoder().encode(hunting.state), forKey: "sw.hunt")
        } catch {
            fail("hunt", "Could not save the hunt: \(error.localizedDescription)")
        }
        d.set(hunting.power.rawValue, forKey: "sw.power")
    }

    func renderHunt() {
        let s = hunting.state
        let last = s.lastCommand.map { c in " · last command \"\(c)\"" + (s.lastCommandAt.map { " at \(EventFormat.stamp($0))" } ?? "") } ?? ""
        let mode = " · checks: \(hunting.modeText)" + (hunting.power != .unknown ? " · battery \(hunting.power.rawValue)" : "")
        if s.on {
            let e = hunting.end(now: Date())
            set("hunting", .ok, "On until \(hunting.hm(e.at)) (\(e.why))" + mode + last)
        } else {
            set("hunting", .idle, "Off" + mode + last)
        }
    }

    private func exportReminder(_ now: Date) {
        let d = UserDefaults.standard
        let lastExport = d.object(forKey: "sw.lastExport") as? Double
        let lastReminder = d.object(forKey: "sw.lastReminder") as? Double
        guard hunting.exportReminderDue(now: now, lastExport: lastExport.map(Date.init(timeIntervalSince1970:)),
                                        firstRow: store?.rows.first?.time,
                                        lastReminder: lastReminder.map(Date.init(timeIntervalSince1970:))) else { return }
        d.set(now.timeIntervalSince1970, forKey: "sw.lastReminder")
        let rows = store?.rows.count ?? 0
        let last = lastExport.map { EventFormat.stamp(Date(timeIntervalSince1970: $0)) } ?? "never"
        Task {
            await sendAlert(.export, title: "Export the Spot Watch log",
                            body: "\(rows) rows; last export \(last). Open Spot Watch and tap Export CSV + photos.")
        }
    }

    // MARK: - Spot alerts

    /// Occupied → vacant (after the departure check). FREE goes out while
    /// hunting, at most once per spot per FREE cooldown.
    func spotFreed(_ i: Int, coverage: Double, occupiedSince: Date?) {
        guard hunting.state.on else { return }
        let now = Date()
        if SpotAlerts.freeSkip(hunting: true, last: alertTimes[i].free, now: now, cooldownMin: cfg.freeCooldown) != nil {
            addLog("alert", "Spot \(i + 1) FREE not sent: cooldown")
            return
        }
        alertTimes[i].free = now
        Task {
            let ok = await sendAlert(.free, title: SpotAlerts.freeTitle(i + 1),
                                     body: SpotAlerts.freeBody(i + 1, at: now, occupiedSince: occupiedSince))
            logEvent(i, "alert_free", coverage: coverage, detail: ok ? "sent" : "not sent")
        }
    }

    /// A person-near visit at an occupied spot. The heads-up goes out while
    /// hunting, except during the arrival grace and the heads-up cooldown.
    func personNear(_ i: Int, coverage: Double, score: Double, occupiedSince: Date?) {
        let now = Date()
        let on = hunting.state.on
        let skip = SpotAlerts.headsupSkip(hunting: on, occupiedSince: occupiedSince, last: alertTimes[i].headsup, now: now,
                                          graceMin: cfg.arrivalGrace, cooldownMin: cfg.headsupCooldown)
        logEvent(i, "person_near", coverage: coverage,
                 detail: "person \(Int((score * 100).rounded()))%" + (on && skip != nil ? ", no alert: \(skip!)" : ""))
        guard skip == nil else { return }
        alertTimes[i].headsup = now
        Task {
            let ok = await sendAlert(.headsup, title: SpotAlerts.headsupTitle(i + 1), body: SpotAlerts.headsupBody(i + 1, at: now))
            logEvent(i, "alert_headsup", coverage: coverage, detail: ok ? "sent" : "not sent")
        }
    }

    // MARK: - Sending

    /// Sends one alert, trying once more after `Ntfy.retryAfter` if ntfy
    /// doesn't take it. True once ntfy accepted it.
    @discardableResult
    func sendAlert(_ type: AlertType, title: String, body: String) async -> Bool {
        guard !alertTopic.isEmpty else {
            set("alerts", .fail, "\"\(title)\" not sent: no alert topic, set it in Settings")
            fail("alert", "\"\(title)\" not sent: no alert topic")
            return false
        }
        for attempt in 1...2 {
            do {
                _ = try await NtfyPublisher.publish(topic: alertTopic, title: title, priority: type.priority, tags: type.tags, body: body)
                set("alerts", .ok, "Last sent: \"\(title)\" at \(Format.clock())")
                addLog("alert", "Sent \"\(title)\"")
                return true
            } catch {
                addLog("alert", "\"\(title)\" failed on try \(attempt): \(error.localizedDescription)")
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: UInt64(Ntfy.retryAfter * 1_000_000_000))
                } else {
                    set("alerts", .fail, "\"\(title)\" not sent: \(error.localizedDescription)")
                    fail("alert", "\"\(title)\" not sent: \(error.localizedDescription)")
                }
            }
        }
        return false
    }

    /// A preview of one alert type: its real priority and tag, a "[test]" title.
    func sendTest() async {
        let t = testType
        sendingTest = true
        defer { sendingTest = false }
        guard !alertTopic.isEmpty else {
            testResult = "No alert topic: set it in Settings."
            return
        }
        set("alerts", .busy, "Sending a test \"\(t.label)\"…")
        let started = Date()
        do {
            let id = try await NtfyPublisher.publish(topic: alertTopic, title: "[test] " + t.sample, priority: t.priority, tags: t.tags,
                                                     body: "Preview of the \"\(t.label)\" alert, sent \(Format.clock()) (\(buildLabel))")
            let detail = "Test \"\(t.label)\" accepted by ntfy in \(Format.ms(Date().timeIntervalSince(started) * 1000)) · priority \(t.priority)"
                + (id.map { " · id \($0)" } ?? "")
            set("alerts", .ok, detail)
            testResult = "\(Format.clock()): \(detail). Now check the main phone."
            addLog("alert", detail)
        } catch {
            set("alerts", .fail, "Test \"\(t.label)\" failed: \(error.localizedDescription)")
            testResult = "\(Format.clock()): failed: \(error.localizedDescription)"
            fail("alert", "Test \"\(t.label)\" failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Control topic

    private func handleControl(_ e: ControlStream.Event) {
        switch e {
        case .connecting:
            set("control", .busy, "Connecting…")
        case .open:
            set("control", .ok, "Connected · waiting for messages")
            addLog("control", "Connected")
        case .keepalive:
            lastKeepalive = Date()
        case .message(let m):
            if let id = m.id {
                if controlSeen.contains(id) { return }
                controlSeen.append(id)
                if controlSeen.count > 100 { controlSeen.removeFirst(controlSeen.count - 100) }
                UserDefaults.standard.set(id, forKey: "sw.controlLastId")
            }
            let now = Date()
            let lag = m.time.map { max(0, Int(now.timeIntervalSince($0).rounded())) }
            controlLines.insert(ControlLine(at: now, lagS: lag, text: m.message), at: 0)
            if controlLines.count > AppModel.controlShown { controlLines.removeLast(controlLines.count - AppModel.controlShown) }
            let lagText = lag.map { " (~\($0) s after send)" } ?? ""
            set("control", .ok, "Connected · last message \(Format.clock(now))" + lagText)
            addLog("control", "Received: \"\(String(m.message.prefix(80)))\"" + lagText)
            handleCommand(m.message, at: m.time ?? now)
        case .dropped(let why, let wait):
            controlReconnects += 1
            set("control", .warn, "Connection dropped (\(why)) · reconnecting in \(Int(wait)) s")
            addLog("control", "Connection dropped (\(why)), reconnecting in \(Int(wait)) s")
        }
    }

    var controlInfo: String {
        "Reconnects: \(controlReconnects) · last keepalive: " + (lastKeepalive.map { Format.clock($0) } ?? "none yet")
    }

    // MARK: - Camera stopped

    /// Once per outage, sent even when not hunting; then the session restarts.
    func cameraStopped(_ why: String) {
        guard source == .camera, !cameraDown else { return }
        cameraDown = true
        logEvent(nil, "camera_stopped", coverage: nil, detail: why)
        Task {
            await sendAlert(.camera, title: "Camera stopped",
                            body: "Spot Watch lost its camera at \(hunting.hm(Date())) (\(why)). Check the 6s.")
        }
        addLog("camera", "Restarting the camera")
        pipeline.camera.restart()
    }

    /// Every second: no frame for `cameraDeadS` while the app is active means
    /// the camera stopped. Time in the background doesn't count (iOS stops the camera there).
    func cameraWatch(frameAge: Double?) {
        guard source == .camera, appActive else { return }
        let sinceActive = Date().timeIntervalSince(activeSince)
        let age = min(frameAge ?? sinceActive, sinceActive)
        if age > AppModel.cameraDeadS {
            cameraStopped("no frames for \(Int(age)) s")
        } else if cameraDown, let a = frameAge, a < 1 {
            cameraDown = false
            addLog("camera", "Camera is back")
        }
    }
}
