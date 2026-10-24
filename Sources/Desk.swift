import AppKit
import Combine
import CoreBluetooth

/// Which desk to talk to. Change these for your own desk.
enum MyDesk {
    /// The Bluetooth ID macOS gave the desk on this Mac. Lets us reconnect without a scan.
    static let id = UUID(uuidString: "460B96C5-5D9B-376D-CD8F-32E6CFB85A6D")!
    /// The desk's Bluetooth name, used when a scan is needed.
    static let name = "WallyDesk"
}

/// Talks to the desk over Bluetooth Low Energy (BLE).
///
/// How a command gets to the desk:
/// 1. A method like `goTo(preset:)` stores the bytes in `pendingPacket`.
/// 2. `connect()` connects to the desk (or finds it with a scan first).
/// 3. Once connected, macOS calls the delegate methods at the bottom of this file,
///    and `sendPending()` writes the bytes.
/// 4. After a short time we disconnect again, so the Desky phone app can still connect.
///    When the menu opens we stay connected for 30 seconds, so a preset or slider click goes at once.
///
/// `ObservableObject` + `@Published` let the menu redraw when the height or status changes.
final class Desk: NSObject, ObservableObject {
    static let shared = Desk()

    /// What the desk link is doing. The text shows in the menu as "Desk: …".
    enum Status: String {
        case idle = "Idle"
        case waitingForBluetooth = "Waiting for Bluetooth"
        case searching = "Searching"
        case connecting = "Connecting"
        case moving = "Moving"
        case couldNotConnect = "Could not connect"
        case noPermission = "No Bluetooth permission"
        case bluetoothOff = "Bluetooth off"
    }

    @Published private(set) var status = Status.idle
    /// The last height the desk reported, in cm. Nil until the first report.
    @Published private(set) var heightCm: Double?
    /// The height of each of the desk's own presets, in cm (see `learnPresetHeight`).
    @Published private(set) var deskPresetHeights: [Int: Double] = Desk.loadDeskPresetHeights()

    /// The last preset we moved to. Only used to guess stand or sit before the first height report.
    private(set) var lastPreset: Int = saved(Key.lastPreset, or: 0)

    /// True when the desk is at a standing height.
    var isStanding: Bool {
        if let cm = heightCm { return cm >= Presets.standingFromCm }
        return lastPreset == 2
    }

    // Bluetooth objects. `central` is our side of the link, `peripheral` is the desk.
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    /// The command waiting to be sent once we are connected.
    private var pendingPacket: Data?
    /// True when the pending command moves the desk (it is sent 5 times).
    private var pendingIsMove = false
    /// How long to stay connected after the pending command is sent.
    private var pendingStaySeconds: TimeInterval = 3

    private var disconnectTimer: DispatchWorkItem?
    /// When the link will be closed. Used so a short wait never cuts a longer one.
    private var disconnectAt = Date.distantPast
    private var settleTimer: DispatchWorkItem?
    /// The desk preset we are moving to, so we can learn its height when the desk stops.
    private var movingToPreset: Int?

    override init() {
        super.init()
        // Creating the manager starts Bluetooth. Its delegate methods run on the main thread.
        central = CBCentralManager(delegate: self, queue: .main)

        // Each time a menu opens: get a fresh height, and connect now, so a click in the menu is instant.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.getReady()
        }
    }

    // MARK: - Commands

    /// Sit if the desk is up, stand if it is down. This is the right click on the icon.
    func toggleStandSit() {
        goTo(preset: isStanding ? 1 : 2)
    }

    /// Move to a preset: to the height set in Settings if there is one, else to the desk's own preset.
    func goTo(preset: Int) {
        guard let packet = DeskProtocol.moveToPreset(preset) else { return }
        lastPreset = preset
        UserDefaults.standard.set(preset, forKey: Key.lastPreset)

        if let cm = Presets.customHeight(preset) {
            goTo(cm: cm)
        } else {
            movingToPreset = preset
            send(packet, isMove: true, staySeconds: 20)
        }
    }

    /// Move to any height, in cm.
    func goTo(cm: Double) {
        movingToPreset = nil
        send(DeskProtocol.moveTo(cm: cm), isMove: true, staySeconds: 20)
    }

    /// Ask the desk for its height.
    /// Skipped while connected (the desk already sends its height then) or while another command waits.
    func refreshHeight() {
        guard central.state == .poweredOn, pendingPacket == nil, peripheral?.state != .connected else { return }
        send(DeskProtocol.askHeight, isMove: false, staySeconds: 3)
    }

    /// Called when the menu opens. Connects now (reading the height on the way) and stays connected
    /// for 30 seconds, so a preset or slider click does not wait for a new connection.
    func getReady() {
        let readySeconds: TimeInterval = 30
        if peripheral?.state == .connected {
            closeLink(after: readySeconds)  // already connected: just stay longer
        } else if central.state == .poweredOn, pendingPacket == nil {
            send(DeskProtocol.askHeight, isMove: false, staySeconds: readySeconds)
        }
    }

    private func send(_ packet: Data, isMove: Bool, staySeconds: TimeInterval) {
        pendingPacket = packet
        pendingIsMove = isMove
        pendingStaySeconds = staySeconds
        connect()
    }

    // MARK: - Connecting and sending

    private func connect() {
        guard central.state == .poweredOn else {
            status = .waitingForBluetooth
            return  // centralManagerDidUpdateState calls connect() again when Bluetooth is ready
        }
        if let peripheral = peripheral, peripheral.state == .connected, writeCharacteristic != nil {
            sendPending()  // already connected
        } else if let known = central.retrievePeripherals(withIdentifiers: [MyDesk.id]).first {
            // macOS remembers the desk, so we can connect straight away.
            peripheral = known
            known.delegate = self
            if pendingIsMove { status = .connecting }
            central.connect(known)
        } else {
            // Not known yet: scan for devices with the desk's service. See `didDiscover` below.
            if pendingIsMove { status = .searching }
            central.scanForPeripherals(withServices: [DeskProtocol.service])
        }
    }

    /// Writes the pending command, then disconnects after a while.
    private func sendPending() {
        guard let packet = pendingPacket, let peripheral = peripheral, let characteristic = writeCharacteristic else { return }
        pendingPacket = nil

        // The desk ignores the first few writes while it wakes up, so a move is sent 5 times, 0.3 s apart.
        let times = pendingIsMove ? 5 : 1
        for index in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(index)) {
                peripheral.writeValue(packet, for: characteristic, type: .withResponse)
            }
        }
        if pendingIsMove { status = .moving }

        // Stay longer after a move, so we receive the height reports while the desk moves.
        closeLink(after: pendingStaySeconds)
    }

    /// Disconnects after `seconds`, so the Desky phone app can connect again.
    /// If the link is already planned to stay open longer, that longer time is kept.
    private func closeLink(after seconds: TimeInterval) {
        let newTime = Date().addingTimeInterval(seconds)
        guard newTime > disconnectAt else { return }
        disconnectAt = newTime
        disconnectTimer?.cancel()
        let disconnect = DispatchWorkItem { [weak self] in
            guard let self = self, let peripheral = self.peripheral else { return }
            self.central.cancelPeripheralConnection(peripheral)
        }
        disconnectTimer = disconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: disconnect)
    }

    // MARK: - Reports from the desk

    private func handle(_ report: DeskProtocol.Report) {
        switch report {
        case .height(let cm):
            heightCm = cm
            learnPresetHeight()
        case .presetHeight(let preset, let cm):
            saveDeskPresetHeight(preset, cm)
        }
    }

    /// After a move to one of the desk's own presets, save the height once it has stopped changing for 2 seconds.
    /// This is how the menu knows each preset's height.
    private func learnPresetHeight() {
        guard let preset = movingToPreset else { return }
        settleTimer?.cancel()  // still moving: start the 2 seconds again
        let settle = DispatchWorkItem { [weak self] in
            guard let self = self, let cm = self.heightCm, self.movingToPreset == preset else { return }
            self.movingToPreset = nil
            self.saveDeskPresetHeight(preset, cm)
        }
        settleTimer = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: settle)
    }

    private func saveDeskPresetHeight(_ preset: Int, _ cm: Double) {
        guard Presets.all.contains(preset), cm > 40, cm < 150 else { return }  // ignore nonsense values
        deskPresetHeights[preset] = cm
        UserDefaults.standard.set(cm, forKey: Key.deskPresetHeight(preset))
    }

    private static func loadDeskPresetHeights() -> [Int: Double] {
        var heights: [Int: Double] = [:]
        for preset in Presets.all {
            let cm: Double = saved(Key.deskPresetHeight(preset), or: 0)
            if cm > 0 { heights[preset] = cm }
        }
        return heights
    }
}

// MARK: - Bluetooth callbacks

// macOS calls these methods as the connection moves along. They run on the main thread.
extension Desk: CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Bluetooth turned on or off, or the user answered the permission question.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if pendingPacket != nil { connect() } else { refreshHeight() }
        case .unauthorized:
            status = .noPermission
        default:
            status = .bluetoothOff
        }
    }

    /// The scan found a device. Connect if it is our desk.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier == MyDesk.id || peripheral.name == MyDesk.name else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = .connecting
        central.connect(peripheral)
    }

    /// Connected. Next, find the desk's service.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([DeskProtocol.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = .couldNotConnect
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeCharacteristic = nil
        disconnectAt = .distantPast
        if [.moving, .connecting, .searching].contains(status) { status = .idle }
    }

    /// Found the service. Next, find the two characteristics inside it.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == DeskProtocol.service {
            peripheral.discoverCharacteristics([DeskProtocol.writeCharacteristic, DeskProtocol.notifyCharacteristic],
                                               for: service)
        }
    }

    /// Ready: keep the write characteristic, turn on reports, and send the waiting command.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == DeskProtocol.writeCharacteristic { writeCharacteristic = characteristic }
            if characteristic.uuid == DeskProtocol.notifyCharacteristic { peripheral.setNotifyValue(true, for: characteristic) }
        }
        sendPending()
    }

    /// The desk sent a report.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, let report = DeskProtocol.parse(data) else { return }
        handle(report)
    }
}
