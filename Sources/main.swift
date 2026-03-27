import AppKit
import AVFoundation

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
    private var meetings: [Meeting] = []
    private var blinkOn = false
    private var audioTriggeredFor: Set<UUID> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadMeetings()
        loadAudio()
        setupStatusItem()
        startTicker()
    }

    // MARK: - Audio

    private func loadAudio() {
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
        } catch { NSLog("AVAudioPlayer: \(error)") }
    }

    private func playAudio() {
        guard let p = audioPlayer else { return }
        p.stop(); p.currentTime = 0; p.play()
    }

    private func playAudioIfNeeded(for meeting: Meeting, secondsUntil: Int) {
        guard secondsUntil <= 14 else { return }
        guard !audioTriggeredFor.contains(meeting.id) else { return }
        audioTriggeredFor.insert(meeting.id)
        playAudio()
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

        if secs <= 14 {
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

        let test = NSMenuItem(title: "Test Audio ▶", action: #selector(testAudioAction), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)

        let stop = NSMenuItem(title: "Stop Music ◼", action: #selector(stopAudioAction), keyEquivalent: "s")
        stop.target = self
        menu.addItem(stop)

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
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
