import AppKit
import AVFoundation
import UniformTypeIdentifiers
import EventKit

// MARK: - Model

struct Meeting: Codable {
    let id: UUID
    var name: String
    var hour: Int
    var minute: Int
    var weekdays: [Int]      // 1=Sun 2=Mon 3=Tue 4=Wed 5=Thu 6=Fri 7=Sat
    var repeatsWeekly: Bool

    var displayTime: String { String(format: "%02d:%02d", hour, minute) }

    var weekdayLabel: String {
        let s = weekdays.sorted()
        if s == [2,3,4,5,6] { return "Mon–Fri" }
        if s == [1,2,3,4,5,6,7] { return "Every day" }
        let short = ["Su","Mo","Tu","We","Th","Fr","Sa"]
        return s.map { short[$0 - 1] }.joined(separator: " ")
    }

    func nextOccurrence(after now: Date = Date()) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        let cal = Calendar.current
        for offset in 0...13 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            let wd = cal.component(.weekday, from: day)
            guard weekdays.contains(wd) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = hour; c.minute = minute; c.second = 0
            guard let t = cal.date(from: c) else { continue }
            if t > now { return t }
        }
        return nil
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var ticker: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var audioDuration: Int = 14   // seconds — auto-detected from file
    private var meetings: [Meeting] = []
    private var blinkOn = false
    private var audioTriggeredFor: Set<UUID> = []

    private let eventStore = EKEventStore()
    private var calendarSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "NewsTimer.calendarSyncEnabled")
    private var calendarAutoRefreshEnabled: Bool = UserDefaults.standard.bool(forKey: "NewsTimer.calendarAutoRefreshEnabled")
    private var lastCalendarSync: Date? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadMeetings()
        loadAudio()
        setupStatusItem()
        if calendarSyncEnabled {
            syncFromCalendarAction()
        }
        if calendarAutoRefreshEnabled {
            scheduleCalendarAutoRefresh()
        }
        startTicker()
    }

    // MARK: - Audio

    private func loadAudio() {
        // 1. User-picked file (saved in App Support)
        if let saved = UserDefaults.standard.string(forKey: "NewsTimer.audioPath") {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: saved) {
                initPlayer(url: url); return
            }
        }
        // 2. Bundled default
        if let url = Bundle.main.url(forResource: "countdown", withExtension: "mp3") {
            initPlayer(url: url); return
        }
        let path = Bundle.main.bundlePath + "/Contents/Resources/countdown.mp3"
        if FileManager.default.fileExists(atPath: path) {
            initPlayer(url: URL(fileURLWithPath: path))
        }
    }

    private func initPlayer(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioDuration = max(1, Int(ceil(audioPlayer!.duration)))
            NSLog("Audio loaded: \(url.lastPathComponent), duration: \(audioDuration)s")
        } catch { NSLog("AVAudioPlayer: \(error)") }
    }

    private func playAudio() {
        guard let p = audioPlayer else { return }
        p.stop(); p.currentTime = 0; p.play()
    }

    private func playAudioIfNeeded(for meeting: Meeting, secondsUntil: Int) {
        guard secondsUntil <= audioDuration else { return }
        guard !audioTriggeredFor.contains(meeting.id) else { return }
        audioTriggeredFor.insert(meeting.id)
        playAudio()
    }

    @objc private func chooseAudioAction() {
        statusItem.menu?.cancelTracking()

        let panel = NSOpenPanel()
        panel.message = "Choose your countdown audio file"
        panel.prompt = "Use this file"
        panel.allowedContentTypes = [UTType.audio, UTType.mp3]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let src = panel.url else { return }

        // Copy to Application Support so it survives moves/deletes
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("NewsTimer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("audio.\(src.pathExtension)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            let err = NSAlert()
            err.messageText = "Could not copy file"
            err.informativeText = error.localizedDescription
            err.runModal()
            return
        }

        UserDefaults.standard.set(dest.path, forKey: "NewsTimer.audioPath")
        audioTriggeredFor.removeAll()
        initPlayer(url: dest)
        buildMenu()

        let info = NSAlert()
        info.messageText = "Audio updated"
        info.informativeText = "\(src.lastPathComponent)\nDuration: \(audioDuration)s — will play \(audioDuration)s before each meeting."
        info.runModal()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.masksToBounds = true
        showCollapsed(button)
        buildMenu()
        tick()
    }

    private func showCollapsed(_ button: NSStatusBarButton) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        button.image = NSImage(systemSymbolName: "calendar.badge.clock",
                               accessibilityDescription: "Meetings")?.withSymbolConfiguration(cfg)
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.layer?.backgroundColor = CGColor.clear
    }

    private func showText(_ button: NSStatusBarButton, text: String, bg: NSColor, fg: NSColor) {
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: fg,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        ])
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            button.layer?.backgroundColor = bg == .clear ? CGColor.clear : bg.cgColor
        }
    }

    // MARK: - Tick

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    private func tick() {
        let now = Date()
        guard let button = statusItem.button else { return }

        // Auto-remove expired one-time meetings (passed > 5 min ago)
        let cal = Calendar.current
        let before = meetings.count
        meetings.removeAll { m in
            guard !m.repeatsWeekly else { return false }
            let wd = cal.component(.weekday, from: now)
            guard m.weekdays.contains(wd) else { return false }
            var c = cal.dateComponents([.year, .month, .day], from: now)
            c.hour = m.hour; c.minute = m.minute; c.second = 0
            guard let t = cal.date(from: c) else { return false }
            return now.timeIntervalSince(t) > 300
        }
        if meetings.count != before { saveMeetings(); buildMenu() }

        // Find next upcoming meeting
        guard let (meeting, nextTime) = meetings
            .compactMap({ m -> (Meeting, Date)? in
                guard let d = m.nextOccurrence(after: now) else { return nil }
                return (m, d)
            })
            .sorted(by: { $0.1 < $1.1 })
            .first
        else {
            showCollapsed(button)
            return
        }

        let secs = Int(nextTime.timeIntervalSinceNow)

        // Live (within 5 min after start)
        if secs < 0 && secs > -300 {
            audioTriggeredFor.remove(meeting.id)
            showText(button, text: "((·)) \(meeting.name) is live!", bg: .systemGreen, fg: .white)
            return
        }

        // Ended or far future → collapse
        if secs < 0 || secs / 60 >= 15 {
            showCollapsed(button)
            return
        }

        // Countdown text
        let m = secs / 60, s = secs % 60
        let countStr = m > 0 ? "\(m):\(String(format: "%02d", s))" : "0:\(String(format: "%02d", s))"
        let label = "((·)) \(meeting.name) in \(countStr)"

        playAudioIfNeeded(for: meeting, secondsUntil: secs)

        if secs <= audioDuration {
            blinkOn.toggle()
            showText(button, text: label,
                     bg: blinkOn ? .systemRed : .clear,
                     fg: blinkOn ? .white : .labelColor)
        } else if secs <= 60 {
            showText(button, text: label, bg: NSColor.systemOrange.withAlphaComponent(0.25), fg: .labelColor)
        } else {
            showText(button, text: label, bg: .clear, fg: .labelColor)
        }
    }

    private var calendarRefreshTimer: Timer?

    private func scheduleCalendarAutoRefresh(intervalMinutes: Int = 5) {
        calendarRefreshTimer?.invalidate()
        let interval = TimeInterval(intervalMinutes * 60)
        calendarRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performAutoCalendarRefresh()
        }
        RunLoop.main.add(calendarRefreshTimer!, forMode: .common)
        // Kick off an immediate refresh if we haven't yet this session
        performAutoCalendarRefresh()
    }

    private func performAutoCalendarRefresh() {
        guard calendarAutoRefreshEnabled else { return }
        // Throttle: avoid syncing more often than every 60 seconds
        if let last = lastCalendarSync, Date().timeIntervalSince(last) < 60 { return }
        lastCalendarSync = Date()
        syncFromCalendarAction()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Meetings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if meetings.isEmpty {
            let e = NSMenuItem(title: "No meetings yet", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        } else {
            for m in meetings.sorted(by: { $0.hour * 60 + $0.minute < $1.hour * 60 + $1.minute }) {
                let icon = m.repeatsWeekly ? "↻" : "1×"
                let item = NSMenuItem(
                    title: "  \(m.name)  \(m.displayTime)  [\(m.weekdayLabel)] \(icon)   ✕",
                    action: #selector(removeMeetingAction(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = m.id.uuidString
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let add = NSMenuItem(title: "Add Meeting…", action: #selector(addMeetingAction), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)

        menu.addItem(.separator())

        let audioLabel: String = {
            let name = UserDefaults.standard.string(forKey: "NewsTimer.audioPath")
                .flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "default"
            return "Audio: \(name) (\(audioDuration)s)"
        }()
        let audioInfo = NSMenuItem(title: audioLabel, action: nil, keyEquivalent: "")
        audioInfo.isEnabled = false
        menu.addItem(audioInfo)

        let choose = NSMenuItem(title: "Choose Audio File…", action: #selector(chooseAudioAction), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        let test = NSMenuItem(title: "Test Audio ▶", action: #selector(testAudioAction), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)

        let stop = NSMenuItem(title: "Stop Music ◼", action: #selector(stopAudioAction), keyEquivalent: "s")
        stop.target = self
        menu.addItem(stop)

        menu.addItem(.separator())

        let calHeader = NSMenuItem(title: "Calendar", action: nil, keyEquivalent: "")
        calHeader.isEnabled = false
        menu.addItem(calHeader)

        let syncNow = NSMenuItem(title: "Sync from Calendar…", action: #selector(syncFromCalendarAction), keyEquivalent: "r")
        syncNow.target = self
        menu.addItem(syncNow)

        let autoSync = NSMenuItem(title: "Auto-sync on launch", action: #selector(toggleCalendarAutoSync(_:)), keyEquivalent: "")
        autoSync.target = self
        autoSync.state = calendarSyncEnabled ? .on : .off
        menu.addItem(autoSync)

        let autoRefresh = NSMenuItem(title: "Auto-refresh every 5 min", action: #selector(toggleCalendarAutoRefresh(_:)), keyEquivalent: "")
        autoRefresh.target = self
        autoRefresh.state = calendarAutoRefreshEnabled ? .on : .off
        menu.addItem(autoRefresh)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func addMeetingAction() {
        statusItem.menu?.cancelTracking()

        let alert = NSAlert()
        alert.messageText = "Add Meeting"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 138))

        // Name row
        let nameLbl = NSTextField(labelWithString: "Name:")
        nameLbl.frame = NSRect(x: 0, y: 112, width: 55, height: 20)
        let nameField = NSTextField(frame: NSRect(x: 60, y: 110, width: 270, height: 24))
        nameField.placeholderString = "e.g. Team sync"

        // Time row
        let timeLbl = NSTextField(labelWithString: "Time:")
        timeLbl.frame = NSRect(x: 0, y: 80, width: 55, height: 20)
        let timeField = NSTextField(frame: NSRect(x: 60, y: 78, width: 270, height: 24))
        timeField.placeholderString = "HH:MM  (24h, e.g. 14:30)"

        // Days row — Calendar weekday: 2=Mon 3=Tue 4=Wed 5=Thu 6=Fri 7=Sat 1=Sun
        let daysLbl = NSTextField(labelWithString: "Days:")
        daysLbl.frame = NSRect(x: 0, y: 48, width: 55, height: 20)

        let dayLabels  = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        let dayWDNums  = [2, 3, 4, 5, 6, 7, 1]
        var dayButtons = [NSButton]()

        for (i, label) in dayLabels.enumerated() {
            let btn = NSButton(frame: NSRect(x: 60 + i * 38, y: 44, width: 34, height: 26))
            btn.title = label
            btn.setButtonType(.pushOnPushOff)
            btn.bezelStyle = .rounded
            btn.tag = dayWDNums[i]
            btn.state = i < 5 ? .on : .off  // Mon-Fri on by default
            dayButtons.append(btn)
        }

        // Repeat checkbox
        let repeatChk = NSButton(checkboxWithTitle: "Repeat weekly", target: nil, action: nil)
        repeatChk.frame = NSRect(x: 60, y: 10, width: 200, height: 24)
        repeatChk.state = .on

        container.addSubview(nameLbl)
        container.addSubview(nameField)
        container.addSubview(timeLbl)
        container.addSubview(timeField)
        container.addSubview(daysLbl)
        dayButtons.forEach { container.addSubview($0) }
        container.addSubview(repeatChk)

        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name      = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let timeStr   = timeField.stringValue.trimmingCharacters(in: .whitespaces)
        let parts     = timeStr.split(separator: ":").compactMap { Int($0) }
        let selDays   = dayButtons.filter { $0.state == .on }.map { $0.tag }

        guard !name.isEmpty,
              parts.count == 2,
              (0...23).contains(parts[0]),
              (0...59).contains(parts[1]),
              !selDays.isEmpty else {
            let err = NSAlert()
            err.messageText = "Invalid input"
            err.informativeText = "Fill in name, valid time (HH:MM), and at least one day."
            err.runModal()
            return
        }

        meetings.append(Meeting(
            id: UUID(), name: name,
            hour: parts[0], minute: parts[1],
            weekdays: selDays,
            repeatsWeekly: repeatChk.state == .on
        ))
        saveMeetings()
        buildMenu()
        tick()
    }

    @objc private func removeMeetingAction(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String,
              let id = UUID(uuidString: s) else { return }
        meetings.removeAll { $0.id == id }
        audioTriggeredFor.remove(id)
        saveMeetings()
        buildMenu()
        tick()
    }

    @objc private func testAudioAction() {
        statusItem.menu?.cancelTracking()
        playAudio()
    }

    @objc private func stopAudioAction() {
        audioPlayer?.stop()
    }

    // MARK: - Persistence

    private func loadMeetings() {
        guard let data = UserDefaults.standard.data(forKey: "BBCMeetingTimer.meetings"),
              let saved = try? JSONDecoder().decode([Meeting].self, from: data) else { return }
        meetings = saved
    }

    private func saveMeetings() {
        if let data = try? JSONEncoder().encode(meetings) {
            UserDefaults.standard.set(data, forKey: "BBCMeetingTimer.meetings")
        }
    }

    // MARK: - Calendar Sync

    private func requestCalendarAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            completion(true)
        case .writeOnly:
            // Write-only access is insufficient for reading events
            completion(false)
        case .notDetermined:
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToEvents { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func fetchUpcomingCalendarMeetings(hoursAhead: Int = 12) -> [Meeting] {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: hoursAhead, to: now) else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-60), end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        var result: [Meeting] = []
        for ev in events {
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute, .weekday], from: ev.startDate)
            guard let hour = comps.hour, let minute = comps.minute, let wd = comps.weekday else { continue }

            // Determine if the event is repeating weekly (simple heuristic using recurrenceRules)
            let repeatsWeekly = ev.recurrenceRules?.contains(where: { rule in
                rule.frequency == .weekly
            }) ?? false

            let meeting = Meeting(
                id: ev.eventIdentifier.data(using: .utf8).map { UUID(uuid: uuidFromStringData($0)) } ?? UUID(),
                name: ev.title,
                hour: hour,
                minute: minute,
                weekdays: [wd],
                repeatsWeekly: repeatsWeekly
            )
            result.append(meeting)
        }
        return result
    }

    private func uuidFromStringData(_ data: Data) -> uuid_t {
        // Create a stable 16-byte value from eventIdentifier bytes using a simple rolling hash
        var hash = [UInt8](repeating: 0, count: 16)
        var a: UInt32 = 5381
        var b: UInt32 = 52711
        for byte in data {
            a = ((a << 5) &+ a) &+ UInt32(byte) // a = a*33 + byte
            b = ((b << 6) &+ (b << 16) &- b) &+ UInt32(byte) // b = b*65599 - b + byte
        }
        // Spread into 16 bytes deterministically
        for i in 0..<16 {
            let v = (i % 2 == 0) ? (a &+ UInt32(i * 17)) : (b &+ UInt32(i * 31))
            hash[i] = UInt8(truncatingIfNeeded: v >> 8) &+ UInt8(truncatingIfNeeded: v)
        }
        return (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15])
    }

    @objc private func syncFromCalendarAction() {
        statusItem.menu?.cancelTracking()
        requestCalendarAccessIfNeeded { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                let alert = NSAlert()
                alert.messageText = "Calendar access required"
                alert.informativeText = "Please grant Calendar permission in System Settings → Privacy & Security → Calendars."
                alert.runModal()
                return
            }

            let now = Date()
            let imported = self.fetchUpcomingCalendarMeetings(hoursAhead: 24)

            // Merge: replace non-repeating one-time meetings that came from calendar within range
            // For simplicity, we clear non-repeating future meetings and replace with imported ones.
            self.meetings.removeAll { m in
                guard !m.repeatsWeekly else { return false }
                guard let next = m.nextOccurrence(after: now) else { return true }
                return next > now
            }
            self.meetings.append(contentsOf: imported)
            self.lastCalendarSync = Date()
            self.saveMeetings()
            self.buildMenu()
            self.tick()
        }
    }

    @objc private func toggleCalendarAutoSync(_ sender: NSMenuItem) {
        calendarSyncEnabled.toggle()
        UserDefaults.standard.set(calendarSyncEnabled, forKey: "NewsTimer.calendarSyncEnabled")
        sender.state = calendarSyncEnabled ? .on : .off
        if calendarSyncEnabled {
            syncFromCalendarAction()
        }
    }

    @objc private func toggleCalendarAutoRefresh(_ sender: NSMenuItem) {
        calendarAutoRefreshEnabled.toggle()
        UserDefaults.standard.set(calendarAutoRefreshEnabled, forKey: "NewsTimer.calendarAutoRefreshEnabled")
        sender.state = calendarAutoRefreshEnabled ? .on : .off
        if calendarAutoRefreshEnabled {
            scheduleCalendarAutoRefresh()
        } else {
            calendarRefreshTimer?.invalidate()
            calendarRefreshTimer = nil
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
