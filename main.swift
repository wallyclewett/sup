// Sup (stand-up paddle, "SUP"): a menu bar app that reminds you to stand at 10 minutes to the hour
// and moves the Desky desk to a preset over Bluetooth Low Energy.
// Right click the paddle icon to switch between stand (preset 2) and sit (preset 1).
// It also logs how long you stand and sit each day, from the desk height.

import AppKit
import Combine
import CoreBluetooth
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Desk

/// Talks to the desk. Same protocol as ~/desk-control/desk.py.
final class Desk: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = Desk()

    private let deskID = UUID(uuidString: "460B96C5-5D9B-376D-CD8F-32E6CFB85A6D")!
    private let serviceUUID = CBUUID(string: "FE60")
    private let writeUUID = CBUUID(string: "FE61")
    private let notifyUUID = CBUUID(string: "FE62")
    private let presetCodes: [Int: UInt8] = [1: 0x05, 2: 0x06, 3: 0x27, 4: 0x28]
    private let heightCode: UInt8 = 0x07

    @Published var status = "Idle"
    @Published var height = "Unknown"
    @Published var heightCm: Double?

    /// Height of each preset in cm. The desk may report them (F2 F2 25..28),
    /// and the app also learns each one when a preset move stops.
    @Published private(set) var presetHeights: [Int: Double] = {
        var heights: [Int: Double] = [:]
        for preset in 1...4 {
            let saved = UserDefaults.standard.double(forKey: "presetHeight\(preset)")
            if saved > 0 { heights[preset] = saved }
        }
        return heights
    }()
    private var movingToPreset: Int?
    private var settleWork: DispatchWorkItem?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pendingPacket: Data?
    private var pendingIsMove = false
    private var disconnectWork: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        // Read the height each time the menu opens
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshHeight()
        }
    }

    /// The last preset sent, so a right click can switch between stand (2) and sit (1).
    @Published private(set) var lastPreset = UserDefaults.standard.integer(forKey: "lastPreset")

    /// Sit if the desk is up, stand if it is down. Uses the height when known, else the last preset.
    func toggleStandSit() {
        if let cm = heightCm {
            goTo(preset: cm >= Tracker.standingFromCm ? 1 : 2)
        } else {
            goTo(preset: lastPreset == 2 ? 1 : 2)
        }
    }

    /// Move to a height in cm. F1 F1 1B 02 <mm high> <mm low> <checksum> 7E
    func goTo(cm: Double) {
        movingToPreset = nil
        let mm = Int((cm * 10).rounded())
        let body: [UInt8] = [0x1B, 0x02, UInt8(mm >> 8), UInt8(mm & 0xFF)]
        let checksum = UInt8(body.reduce(0) { $0 + Int($1) } & 0xFF)
        pendingPacket = Data([0xF1, 0xF1] + body + [checksum, 0x7E])
        pendingIsMove = true
        connect()
    }

    // F1 F1 <command> <length 0> <checksum> 7E
    private func packet(_ code: UInt8) -> Data {
        Data([0xF1, 0xF1, code, 0x00, code, 0x7E])
    }

    /// Move to a preset: to the height set in Settings if there is one, else the desk's own preset.
    func goTo(preset: Int) {
        guard let code = presetCodes[preset] else { return }
        lastPreset = preset
        UserDefaults.standard.set(preset, forKey: "lastPreset")
        if let cm = Presets.customHeight(preset) {
            goTo(cm: cm)
            return
        }
        movingToPreset = preset
        pendingPacket = packet(code)
        pendingIsMove = true
        connect()
    }

    /// Ask the desk for its height. Skipped while connected: the desk already sends it then.
    func refreshHeight() {
        guard central.state == .poweredOn, pendingPacket == nil, peripheral?.state != .connected else { return }
        pendingPacket = packet(heightCode)
        pendingIsMove = false
        connect()
    }

    private func connect() {
        guard central.state == .poweredOn else {
            status = "Waiting for Bluetooth"
            return  // centralManagerDidUpdateState calls connect() when ready
        }
        if let peripheral = peripheral, peripheral.state == .connected, writeChar != nil {
            sendPending()
        } else if let known = central.retrievePeripherals(withIdentifiers: [deskID]).first {
            peripheral = known
            known.delegate = self
            if pendingIsMove { status = "Connecting" }
            central.connect(known)
        } else {
            if pendingIsMove { status = "Searching" }
            central.scanForPeripherals(withServices: [serviceUUID])
        }
    }

    // The desk ignores the first few sends while it wakes up, so a move is sent 5 times.
    private func sendPending() {
        guard let packet = pendingPacket, let peripheral = peripheral, let char = writeChar else { return }
        pendingPacket = nil
        for i in 0..<(pendingIsMove ? 5 : 1) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) {
                peripheral.writeValue(packet, for: char, type: .withResponse)
            }
        }
        if pendingIsMove { status = "Moving" }

        // Let go of the desk after a while so the phone app can still connect
        disconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let p = self.peripheral else { return }
            self.central.cancelPeripheralConnection(p)
        }
        disconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (pendingIsMove ? 20 : 3), execute: work)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if pendingPacket != nil { connect() } else { refreshHeight() }
        case .unauthorized:
            status = "No Bluetooth permission"
        default:
            status = "Bluetooth off"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier == deskID || peripheral.name == "WallyDesk" else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "Connecting"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Could not connect"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeChar = nil
        if ["Moving", "Connecting", "Searching"].contains(status) { status = "Idle" }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == writeUUID { writeChar = char }
            if char.uuid == notifyUUID { peripheral.setNotifyValue(true, for: char) }
        }
        sendPending()
    }

    // Height report: F2 F2 01 03 <high> <low> ... in millimetres
    // Reports: F2 F2 <type> <length> <high> <low> ... in millimetres.
    // Type 01 = current height, 25 to 28 = preset 1 to 4 height.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, data.count >= 6, data[0] == 0xF2, data[1] == 0xF2 else { return }
        let cm = Double(Int(data[4]) << 8 | Int(data[5])) / 10
        switch data[2] {
        case 0x01:
            heightCm = cm
            height = String(format: "%.1f cm", cm)
            learnPresetHeight()
        case 0x25...0x28:
            savePresetHeight(Int(data[2]) - 0x24, cm)
        default:
            break
        }
    }

    /// After a preset move, save the height once it has not changed for 2 seconds.
    private func learnPresetHeight() {
        guard let preset = movingToPreset else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let cm = self.heightCm, self.movingToPreset == preset else { return }
            self.movingToPreset = nil
            self.savePresetHeight(preset, cm)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func savePresetHeight(_ preset: Int, _ cm: Double) {
        guard (1...4).contains(preset), cm > 40, cm < 150 else { return }
        presetHeights[preset] = cm
        UserDefaults.standard.set(cm, forKey: "presetHeight\(preset)")
    }
}

// MARK: - Away

/// Tells you when you are away from the Mac: screen locked, screen saver on, or Mac asleep.
/// The three are tracked apart, because the screen saver can stop while the screen is still locked.
final class AwayWatcher {
    static let shared = AwayWatcher()

    private var locked = false
    private var screenSaver = false
    private var asleep = false
    private var wasAway = false
    private var onChange: (Bool) -> Void = { _ in }

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        let system = DistributedNotificationCenter.default()
        let events: [(String, (AwayWatcher) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.locked = true }),
            ("com.apple.screenIsUnlocked", { $0.locked = false }),
            ("com.apple.screensaver.didstart", { $0.screenSaver = true }),
            ("com.apple.screensaver.didstop", { $0.screenSaver = false }),
        ]
        for (name, change) in events {
            system.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                change(self)
                self.check()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.check()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            self?.check()
        }
    }

    private func check() {
        let away = locked || screenSaver || asleep
        if away != wasAway {
            wasAway = away
            onChange(away)
        }
    }
}

// MARK: - Tracker

/// Counts the time you stand and sit each day, while you are at the Mac.
/// Standing = desk at 80 cm or higher. The desk height is read every 2 minutes,
/// and live while the desk moves. Locked, screen saver and sleep time is not counted.
/// Totals are kept per day in ~/desk-control/standup_log.json (seconds).
/// Each time in one position is also logged in ~/desk-control/standup_sessions.csv.
final class Tracker: ObservableObject {
    static let shared = Tracker()

    static let standingFromCm = 80.0  // sit preset is 63 cm, lowest stand is higher
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("desk-control/standup_log.json")

    @Published private(set) var days: [String: [String: Double]] = [:]  // "2026-10-24": ["standing": s, "sitting": s]
    private(set) var standing: Bool?
    /// When you moved into the current position (or came back to the Mac). Nil while away.
    @Published private(set) var positionSince: Date?
    private let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("desk-control/standup_sessions.csv")
    private var away = false
    private var lastCredit = Date()
    private var watch: AnyCancellable?
    private var timer: Timer?

    init() {
        if let data = try? Data(contentsOf: logURL),
           let saved = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            days = saved
        }
    }

    func start() {
        watch = Desk.shared.$heightCm.receive(on: DispatchQueue.main).sink { [weak self] cm in
            guard let self = self, let cm = cm else { return }
            let nowStanding = cm >= Tracker.standingFromCm
            guard nowStanding != self.standing else { return }
            self.credit()
            self.endSession()
            self.standing = nowStanding
            self.positionSince = self.away ? nil : Date()
        }
        AwayWatcher.shared.start { [weak self] away in
            guard let self = self else { return }
            self.credit()
            if away { self.endSession() }
            self.away = away
            self.positionSince = away || self.standing == nil ? nil : Date()
            if !away { Desk.shared.refreshHeight() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.credit()
            if self?.away == false { Desk.shared.refreshHeight() }
        }
    }

    /// Write the time in the current position to the sessions log.
    /// One line: start, end, position, minutes.
    private func endSession() {
        guard let since = positionSince, let standing = standing else { return }
        positionSince = nil
        let minutes = Date().timeIntervalSince(since) / 60
        guard minutes >= 0.5 else { return }
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        let line = "\(format.string(from: since)),\(format.string(from: Date())),"
            + "\(standing ? "standing" : "sitting"),\(String(format: "%.1f", minutes))\n"
        if !FileManager.default.fileExists(atPath: sessionsURL.path) {
            try? "start,end,position,minutes\n".write(to: sessionsURL, atomically: true, encoding: .utf8)
        }
        if let file = try? FileHandle(forWritingTo: sessionsURL) {
            file.seekToEndOfFile()
            file.write(line.data(using: .utf8)!)
            try? file.close()
        }
    }

    /// "Standing for 12m 5s", or nil when the position is not known or you are away.
    func positionTimer() -> String? {
        guard let since = positionSince, let standing = standing else { return nil }
        let seconds = Int(Date().timeIntervalSince(since))
        let time = seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m"
                                   : "\(seconds / 60)m \(seconds % 60)s"
        return "\(standing ? "Standing" : "Sitting") for \(time)"
    }

    /// Add the time since the last credit to the current position, then save.
    private func credit() {
        let now = Date()
        defer { lastCredit = now }
        guard !away, let standing = standing else { return }
        let seconds = now.timeIntervalSince(lastCredit)
        guard seconds > 0, seconds < 600 else { return }  // skip gaps, for example after the app was not running
        let key = Tracker.dayKey(now)
        days[key, default: [:]][standing ? "standing" : "sitting", default: 0] += seconds
        try? JSONEncoder().encode(days).write(to: logURL)
    }

    /// Totals for a day, including the time since the last credit.
    func totals(for date: Date = Date()) -> (standing: Double, sitting: Double) {
        if Calendar.current.isDateInToday(date) { credit() }
        let day = days[Tracker.dayKey(date)] ?? [:]
        return (day["standing"] ?? 0, day["sitting"] ?? 0)
    }

    static func dayKey(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// "Standing 1h 5m, sitting 3h 40m (23%)"
    static func summary(_ totals: (standing: Double, sitting: Double)) -> String {
        let all = totals.standing + totals.sitting
        let percent = all > 0 ? Int((totals.standing / all * 100).rounded()) : 0
        return "Standing \(duration(totals.standing)), sitting \(duration(totals.sitting)) (\(percent)%)"
    }
}

// MARK: - Reminder

/// Two hourly popups, only inside your hours:
/// at :50 "Time to stand up" (its button moves the desk to the stand preset),
/// at :00 "Time to sit down" (its button moves the desk to the sit preset).
/// The app checks the clock itself every 20 seconds, so it can skip times outside your hours.
final class Reminder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Reminder()

    enum Kind: String {
        case stand, sit
    }

    private let center = UNUserNotificationCenter.current()
    private let store = UserDefaults.standard
    private var timer: Timer?
    private var lastShown = ""  // "2026-10-24 15:50", so each time shows only once

    @Published var standEnabled: Bool { didSet { store.set(standEnabled, forKey: "remindersEnabled") } }
    @Published var standPreset: Int { didSet { store.set(standPreset, forKey: "standPreset") } }
    @Published var sitEnabled: Bool { didSet { store.set(sitEnabled, forKey: "sitReminderEnabled") } }
    @Published var sitPreset: Int { didSet { store.set(sitPreset, forKey: "sitPreset") } }
    @Published var startHour: Int { didSet { store.set(startHour, forKey: "reminderStartHour") } }
    @Published var endHour: Int { didSet { store.set(endHour, forKey: "reminderEndHour") } }
    @Published var weekdaysOnly: Bool { didSet { store.set(weekdaysOnly, forKey: "reminderWeekdaysOnly") } }

    /// False when notifications for Sup are turned off in System Settings.
    @Published private(set) var allowed = true

    override init() {
        standEnabled = store.object(forKey: "remindersEnabled") as? Bool ?? true
        standPreset = store.object(forKey: "standPreset") as? Int ?? 2
        sitEnabled = store.object(forKey: "sitReminderEnabled") as? Bool ?? false
        sitPreset = store.object(forKey: "sitPreset") as? Int ?? 1
        startHour = store.object(forKey: "reminderStartHour") as? Int ?? 9
        endHour = store.object(forKey: "reminderEndHour") as? Int ?? 17
        weekdaysOnly = store.object(forKey: "reminderWeekdaysOnly") as? Bool ?? true
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "STAND", actions: [UNNotificationAction(identifier: "STAND_UP", title: "Stand up")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "SIT", actions: [UNNotificationAction(identifier: "SIT_DOWN", title: "Sit down")],
                                   intentIdentifiers: []),
        ])
        center.removePendingNotificationRequests(withIdentifiers: ["stand"])  // the old fixed :50 timetable
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.checkAllowed() }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkAllowed() {
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
            DispatchQueue.main.async { self.allowed = allowed }
        }
    }

    /// The reminder due at this minute, if any.
    /// Stand at :50 from the start hour; sit at :00 up to and including the end hour.
    func due(at date: Date) -> Kind? {
        let parts = Calendar.current.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return nil }
        if weekdaysOnly && (weekday == 1 || weekday == 7) { return nil }  // Sunday, Saturday
        if minute == 50 && standEnabled && hour >= startHour && hour < endHour { return .stand }
        if minute == 0 && sitEnabled && hour > startHour && hour <= endHour { return .sit }
        return nil
    }

    /// The next time this reminder will show, within the next 8 days.
    func next(_ kind: Kind) -> Date? {
        let calendar = Calendar.current
        guard let thisHour = calendar.dateInterval(of: .hour, for: Date())?.start else { return nil }
        for hours in 0..<(8 * 24) {
            let hourStart = thisHour.addingTimeInterval(Double(hours) * 3600)
            let time = hourStart.addingTimeInterval(kind == .stand ? 50 * 60 : 0)
            if time > Date() && due(at: time) == kind { return time }
        }
        return nil
    }

    func test(_ kind: Kind) {
        show(kind)
    }

    private func tick() {
        let now = Date()
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let key = format.string(from: now)
        guard key != lastShown, let kind = due(at: now) else { return }
        lastShown = key
        show(kind)
    }

    private func show(_ kind: Kind, after seconds: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        if kind == .stand {
            content.title = "Time to stand up"
            content.body = "Click Stand up to move the desk to \(Presets.name(standPreset))."
            content.categoryIdentifier = "STAND"
        } else {
            content.title = "Time to sit down"
            content.body = "Click Sit down to move the desk to \(Presets.name(sitPreset))."
            content.categoryIdentifier = "SIT"
        }
        content.sound = .default
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        center.add(UNNotificationRequest(identifier: "\(kind.rawValue)-\(UUID().uuidString)", content: content, trigger: trigger))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case "STAND_UP": Desk.shared.goTo(preset: self.standPreset)
            case "SIT_DOWN": Desk.shared.goTo(preset: self.sitPreset)
            default: break
            }
        }
        completionHandler()
    }
}

// MARK: - Icon

/// Menu bar icon: a tilted SUP paddle (T-grip, shaft, blade), drawn in an 18x18 box.
/// The blade is filled while standing and outlined while sitting.
/// A template image, so macOS colours it for light and dark menu bars.
func paddleIcon(standing: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let tilt = NSAffineTransform()
        tilt.translateX(by: 9, yBy: 9)
        tilt.rotate(byDegrees: -30)
        tilt.translateX(by: -9, yBy: -9)
        tilt.concat()
        NSColor.black.set()
        // T-grip and shaft
        NSBezierPath(roundedRect: NSRect(x: 6.6, y: 16.2, width: 4.8, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
        NSBezierPath(rect: NSRect(x: 8.4, y: 8, width: 1.2, height: 8.6)).fill()
        // Blade: narrow neck, widest near the tip
        let blade = NSBezierPath()
        blade.move(to: NSPoint(x: 9, y: 8.5))
        blade.curve(to: NSPoint(x: 11.4, y: 2), controlPoint1: NSPoint(x: 9.6, y: 6.5), controlPoint2: NSPoint(x: 11.4, y: 4.5))
        blade.curve(to: NSPoint(x: 6.6, y: 2), controlPoint1: NSPoint(x: 11.4, y: 0.2), controlPoint2: NSPoint(x: 6.6, y: 0.2))
        blade.curve(to: NSPoint(x: 9, y: 8.5), controlPoint1: NSPoint(x: 6.6, y: 4.5), controlPoint2: NSPoint(x: 8.4, y: 6.5))
        blade.close()
        blade.lineWidth = 1.3
        blade.stroke()
        if standing { blade.fill() }
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Menu

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

/// A menu item that runs a closure when you click it.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

extension NSMenuItem {
    /// Give the item an SF Symbol icon on the left, like the icons in Magnet's menu.
    func icon(_ symbol: String) -> Self {
        setIcon(symbol)
        return self
    }

    /// macOS 27 hides menu item symbol images unless the item asks to show them.
    func setIcon(_ symbol: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
    }

    /// A bold number as the icon, the full icon size (SF Symbol numbers in circles are too small to read).
    func setNumberIcon(_ number: Int) {
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        icon.isTemplate = true  // macOS colours it like the other icons
        image = icon
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
    }
}

// MARK: - Slider

/// A slider for a menu, like the volume slider in the macOS Sound menu:
/// icon, slider, icon, value. The desk moves only when you let go and the value stops changing.
final class MenuSlider: NSView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Int) -> String
    private let onRelease: (Int) -> Void
    private var releaseCheck: DispatchWorkItem?
    private var lastSent: Int?

    init(min: Int, max: Int, lowIcon: String, highIcon: String,
         format: @escaping (Int) -> String, onRelease: @escaping (Int) -> Void) {
        slider = NSSlider(value: Double(min), minValue: Double(min), maxValue: Double(max), target: nil, action: nil)
        self.format = format
        self.onRelease = onRelease
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 28))
        let low = NSImageView(image: NSImage(systemSymbolName: lowIcon, accessibilityDescription: nil)!)
        let high = NSImageView(image: NSImage(systemSymbolName: highIcon, accessibilityDescription: nil)!)
        low.frame = NSRect(x: 14, y: 6, width: 16, height: 16)
        slider.frame = NSRect(x: 34, y: 4, width: 132, height: 20)
        high.frame = NSRect(x: 170, y: 6, width: 16, height: 16)
        valueLabel.frame = NSRect(x: 188, y: 6, width: 50, height: 16)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        slider.target = self
        slider.action = #selector(moved)
        slider.isContinuous = true
        [low, slider, high, valueLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ value: Int) {
        slider.integerValue = value
        valueLabel.stringValue = format(value)
        lastSent = value
    }

    // Update the label while dragging. Menus do not always report the mouse up,
    // so check every 0.3 s until the button is up, then send the value once.
    @objc private func moved() {
        valueLabel.stringValue = format(slider.integerValue)
        scheduleReleaseCheck()
    }

    private func scheduleReleaseCheck() {
        releaseCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleReleaseCheck()  // still holding the slider
            } else if self.slider.integerValue != self.lastSent {
                self.lastSent = self.slider.integerValue
                self.onRelease(self.slider.integerValue)
            }
        }
        releaseCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }
}

// MARK: - Goal

/// Daily standing goal in minutes, set in Settings. 0 = off.
enum Goal {
    static let choices = [0, 30, 60, 90, 120, 150, 180, 240]

    static var minutes: Int {
        UserDefaults.standard.object(forKey: "standingGoalMinutes") as? Int ?? 120
    }

    static func text(_ minutes: Int) -> String {
        minutes == 0 ? "Off" : Tracker.duration(Double(minutes * 60))
    }
}

/// Menu row: target icon, "Goal: 1h 5m of 2h (54%)", and a progress bar under it.
final class GoalView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 38))
        icon.frame = NSRect(x: 14, y: 18, width: 16, height: 16)
        label.frame = NSRect(x: 36, y: 18, width: 210, height: 16)
        label.textColor = .secondaryLabelColor
        bar.frame = NSRect(x: 36, y: 5, width: 200, height: 10)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        [icon, label, bar].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(standingSeconds: Double, goalMinutes: Int) {
        let goal = Double(goalMinutes * 60)
        let progress = min(standingSeconds / goal, 1)
        bar.doubleValue = progress
        let reached = standingSeconds >= goal
        icon.image = NSImage(systemSymbolName: reached ? "checkmark.seal.fill" : "target", accessibilityDescription: nil)
        icon.contentTintColor = reached ? .systemGreen : .secondaryLabelColor
        let done = Tracker.duration(standingSeconds)
        label.stringValue = reached ? "Goal reached: \(done) of \(Goal.text(goalMinutes))"
                                    : "Goal: \(done) of \(Goal.text(goalMinutes)) (\(Int(progress * 100))%)"
    }
}

// MARK: - Presets

/// Preset names and heights you can change in Settings.
/// UserDefaults: presetName1-4 (text), customHeight1-4 (cm as text, empty = use the desk's own preset).
enum Presets {
    static let defaults = [1: "Sit", 2: "Stand", 3: "Preset 3", 4: "Preset 4"]
    static let heightRange = 60.0...125.0  // this desk's own limits

    static func name(_ preset: Int) -> String {
        let saved = UserDefaults.standard.string(forKey: "presetName\(preset)") ?? ""
        return saved.isEmpty ? defaults[preset]! : saved
    }

    /// The height you set for this preset, or nil to use the desk's own preset.
    static func customHeight(_ preset: Int) -> Double? {
        let text = UserDefaults.standard.string(forKey: "customHeight\(preset)") ?? ""
        guard let cm = Double(text.replacingOccurrences(of: ",", with: ".")), heightRange.contains(cm) else { return nil }
        return cm
    }
}

// MARK: - Settings

/// One preset: name, height and a button to use the desk's current height.
struct PresetRow: View {
    let preset: Int
    @AppStorage private var name: String
    @AppStorage private var height: String

    init(preset: Int) {
        self.preset = preset
        _name = AppStorage(wrappedValue: "", "presetName\(preset)")
        _height = AppStorage(wrappedValue: "", "customHeight\(preset)")
    }

    var body: some View {
        Section("Preset \(preset)") {
            TextField("Name", text: $name, prompt: Text(Presets.defaults[preset]!))
            HStack {
                TextField("Height (cm)", text: $height, prompt: Text(deskHeightText))
                Button("Use current height") {
                    if let cm = Desk.shared.heightCm { height = String(format: "%.1f", cm) }
                }
            }
            if !height.isEmpty && Presets.customHeight(preset) == nil {
                Text("Type a height from 60 to 125 cm, or leave it empty.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    // Shown in grey when the box is empty: the desk's own preset is used
    private var deskHeightText: String {
        if let cm = Desk.shared.presetHeights[preset] {
            return String(format: "Desk preset (%.1f)", cm)
        }
        return "Desk preset"
    }
}

/// Open at login, the reminder hours, and the stand-up and sit-down reminders.
struct GeneralSection: View {
    @ObservedObject private var reminder = Reminder.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("standingGoalMinutes") private var goalMinutes = 120

    var body: some View {
        Section("General") {
            Toggle("Open Sup when you log in", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
        }
        Section("Daily standing goal") {
            Picker("Stand for at least", selection: $goalMinutes) {
                ForEach(Goal.choices, id: \.self) { Text(Goal.text($0)).tag($0) }
            }
            Text("The menu shows your progress for today. Days that reach the goal get a ✓ in Last 7 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Section("Reminder hours") {
            Picker("From", selection: $reminder.startHour) {
                ForEach(0..<24, id: \.self) { Text(hourText($0)).tag($0) }
            }
            Picker("To", selection: $reminder.endHour) {
                ForEach(1...24, id: \.self) { Text(hourText($0)).tag($0) }
            }
            Toggle("Weekdays only (Monday to Friday)", isOn: $reminder.weekdaysOnly)
            if reminder.startHour >= reminder.endHour {
                Text("\"From\" must be earlier than \"To\". No reminders will show.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if !reminder.allowed {
                Button("Notifications are off for Sup. Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .foregroundStyle(.red)
            }
        }
        Section("Stand-up reminder") {
            Toggle("Remind me to stand up at 10 minutes to the hour", isOn: $reminder.standEnabled)
            Picker("Stand up moves the desk to", selection: $reminder.standPreset) { presetChoices }
            Text("Shows at :50 (9:50, 10:50 …) inside your hours.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent("Next reminder", value: nextText(.stand, on: reminder.standEnabled))
            Button("Test the stand-up reminder now") { reminder.test(.stand) }
        }
        Section("Sit-down reminder") {
            Toggle("Remind me to sit down on the hour", isOn: $reminder.sitEnabled)
            Picker("Sit down moves the desk to", selection: $reminder.sitPreset) { presetChoices }
            Text("Shows at :00 (10:00, 11:00 …) inside your hours.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent("Next reminder", value: nextText(.sit, on: reminder.sitEnabled))
            Button("Test the sit-down reminder now") { reminder.test(.sit) }
        }
    }

    private var presetChoices: some View {
        ForEach(1...4, id: \.self) { Text("\(Presets.name($0)) (preset \($0))").tag($0) }
    }

    private func hourText(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private func nextText(_ kind: Reminder.Kind, on: Bool) -> String {
        guard on else { return "Off" }
        guard let next = reminder.next(kind) else { return "None in the next 8 days" }
        let day = Calendar.current.isDateInToday(next) ? "" : next.formatted(.dateTime.weekday(.wide)) + " "
        return day + next.formatted(date: .omitted, time: .shortened)
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            GeneralSection()
            ForEach(1...4, id: \.self) { PresetRow(preset: $0) }
            Text("Leave a height empty to use the desk's own preset. A height you type here is used only by this app, "
                 + "not by the buttons on the desk. Right click always moves between preset 1 and preset 2.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)  // a grouped form has no height of its own; it scrolls
    }
}

/// Opens one Settings window and brings it to the front.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.setContentSize(NSSize(width: 440, height: 640))
            Reminder.shared.checkAllowed()
            window.title = "Sup Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App

/// Left click opens the menu. Right click moves the desk: stand if it is down, sit if it is up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let desk = Desk.shared
    private let reminder = Reminder.shared
    private var watch: AnyCancellable?

    private let timerLine = NSMenuItem().icon("timer")
    private let statusLine = NSMenuItem().icon("antenna.radiowaves.left.and.right")
    private let heightLine = NSMenuItem().icon("ruler")
    private let todayLine = NSMenuItem().icon("chart.bar")
    private let goalView = GoalView()
    private let goalItem = NSMenuItem()
    private let historyItem = NSMenuItem(title: "Last 7 days", action: nil, keyEquivalent: "").icon("calendar")
    private let blockedItem = ActionItem("Notifications are off: open Settings") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }.icon("exclamationmark.triangle")
    private let presetItems = (1...4).map { preset in ActionItem("") { Desk.shared.goTo(preset: preset) } }
    private let heightSlider = MenuSlider(min: 60, max: 125, lowIcon: "chair", highIcon: "figure.stand",
                                          format: { "\($0) cm" }) { Desk.shared.goTo(cm: Double($0)) }

    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(timerLine)
        menu.addItem(.separator())
        menu.addItem(statusLine)
        menu.addItem(heightLine)
        menu.addItem(.separator())
        menu.addItem(todayLine)
        goalItem.view = goalView
        menu.addItem(goalItem)
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)
        menu.addItem(.separator())
        let sliderItem = NSMenuItem()
        sliderItem.view = heightSlider
        menu.addItem(sliderItem)
        presetItems.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(blockedItem)
        menu.addItem(ActionItem("Settings…") { SettingsWindow.shared.show() }.icon("gearshape"))
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit") { NSApp.terminate(nil) }.icon("xmark.circle"))
        return menu
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.toolTip = "Sup (right click: stand / sit)"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        Tracker.shared.start()
        watch = desk.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.update() }
        update()
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            desk.toggleStandSit()
        } else {
            reminder.checkAllowed()
            update()
            heightSlider.show(Int((desk.heightCm ?? 100).rounded()))
            // Tick the timer line every second while the menu is open
            let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateTimerLine() }
            RunLoop.main.add(tick, forMode: .common)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)  // returns when the menu closes
            statusItem.menu = nil
            tick.invalidate()
        }
    }

    // Bold and in the normal text colour, so it stands out from the grey info lines
    private func updateTimerLine() {
        let text = Tracker.shared.positionTimer() ?? "Position not known yet"
        timerLine.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    // The blade is filled while the desk is at standing height
    private func update() {
        let standing = desk.heightCm.map { $0 >= Tracker.standingFromCm } ?? (desk.lastPreset == 2)
        statusItem.button?.image = paddleIcon(standing: standing)
        for (index, item) in presetItems.enumerated() {
            let preset = index + 1
            let height = Presets.customHeight(preset) ?? desk.presetHeights[preset]
            let cm = height.map { String(format: " (%.1f cm)", $0) } ?? ""
            item.title = Presets.name(preset) + cm  // the number icon shows which preset it is
            item.setNumberIcon(preset)
        }
        updateTimerLine()
        statusLine.title = "Desk: \(desk.status)"
        heightLine.title = "Height: \(desk.height)"
        let today = Tracker.shared.totals()
        todayLine.title = "Today: " + Tracker.summary(today)
        goalItem.isHidden = Goal.minutes == 0
        if Goal.minutes > 0 {
            goalView.show(standingSeconds: today.standing, goalMinutes: Goal.minutes)
        }
        historyItem.submenu?.removeAllItems()
        let dayName = DateFormatter()
        dayName.dateFormat = "EEE d MMM"
        for back in 1...7 {
            let date = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
            let totals = Tracker.shared.totals(for: date)
            let met = Goal.minutes > 0 && totals.standing >= Double(Goal.minutes * 60) ? " ✓" : ""
            let line = dayName.string(from: date) + ": " + Tracker.summary(totals) + met
            historyItem.submenu?.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        blockedItem.isHidden = reminder.allowed
    }
}

@main
enum Main {
    static let delegate = AppDelegate()

    static func main() {
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
