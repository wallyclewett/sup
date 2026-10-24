import CoreBluetooth

/// The bytes a Desky desk (Jiecang controller + Desky Bluetooth adaptor) understands.
///
/// Every command we send has this shape:
///
///     F1 F1  <command>  <length>  <data …>  <checksum>  7E
///
/// - `F1 F1` marks the start of a command, `7E` marks the end.
/// - `<length>` is the number of data bytes (often 0).
/// - `<checksum>` is the low byte of (command + length + every data byte).
///
/// The desk answers with reports that start with `F2 F2` instead.
/// This protocol comes from the Desky and Jiecang community, not from Desky.
enum DeskProtocol {
    // The Bluetooth "service" and "characteristics" (think: folder and files) the desk uses.
    static let service = CBUUID(string: "FE60")
    static let writeCharacteristic = CBUUID(string: "FE61")   // we write commands here
    static let notifyCharacteristic = CBUUID(string: "FE62")  // the desk sends reports here

    // MARK: Commands

    /// "Move to preset 1 … 4", using the heights saved in the desk itself.
    static func moveToPreset(_ preset: Int) -> Data? {
        let commands: [Int: UInt8] = [1: 0x05, 2: 0x06, 3: 0x27, 4: 0x28]
        guard let command = commands[preset] else { return nil }
        return packet(command)
    }

    /// "Tell me your height". The desk answers with a height report.
    static let askHeight = packet(0x07)

    /// "Move to this height". The height is sent in millimetres as two bytes, high byte first.
    static func moveTo(cm: Double) -> Data {
        let mm = Int((cm * 10).rounded())
        return packet(0x1B, data: [UInt8(mm >> 8), UInt8(mm & 0xFF)])
    }

    private static func packet(_ command: UInt8, data: [UInt8] = []) -> Data {
        let body = [command, UInt8(data.count)] + data
        let checksum = UInt8(body.reduce(0) { $0 + Int($1) } & 0xFF)
        return Data([0xF1, 0xF1] + body + [checksum, 0x7E])
    }

    // MARK: Reports

    /// What a report from the desk means.
    enum Report {
        /// The desk's current height. Sent after `askHeight`, and many times while it moves.
        case height(cm: Double)
        /// The height saved in one of the desk's own presets.
        case presetHeight(preset: Int, cm: Double)
    }

    /// Reads a report: `F2 F2 <type> <length> <mm high> <mm low> …`.
    /// Type 01 = current height; types 25 to 28 = preset 1 to 4 height.
    /// Returns nil for reports we do not use.
    static func parse(_ data: Data) -> Report? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] == 0xF2, bytes[1] == 0xF2 else { return nil }
        let cm = Double(Int(bytes[4]) << 8 | Int(bytes[5])) / 10
        switch bytes[2] {
        case 0x01: return .height(cm: cm)
        case 0x25...0x28: return .presetHeight(preset: Int(bytes[2]) - 0x24, cm: cm)
        default: return nil
        }
    }
}
