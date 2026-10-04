import Foundation

/// One Heart Rate Measurement (GATT 0x2A37) notification. Port of `hrmon.ble.parse_hr_measurement`.
public struct HeartRateSample: Equatable, Sendable {
    public let heartRate: Int
    /// nil when the sensor does not report skin-contact support.
    public let skinContact: Bool?
    public let energyExpendedKJ: Int?
    /// RR intervals in milliseconds (1/1024 s units on the wire).
    public let rrIntervalsMs: [Double]
    public let raw: [UInt8]

    public var flags: UInt8 { raw[0] }

    public init(heartRate: Int, skinContact: Bool?, energyExpendedKJ: Int?, rrIntervalsMs: [Double], raw: [UInt8]) {
        self.heartRate = heartRate
        self.skinContact = skinContact
        self.energyExpendedKJ = energyExpendedKJ
        self.rrIntervalsMs = rrIntervalsMs
        self.raw = raw
    }

    public enum ParseError: Error, Equatable { case tooShort }

    /// Decode per the Bluetooth Heart Rate Service spec.
    /// flags bit0: HR is uint16 (else uint8); bit1: contact detected; bit2: contact supported;
    /// bit3: energy expended uint16 present; bit4: one or more RR intervals (uint16, 1/1024 s).
    public static func parse(_ data: Data) throws -> HeartRateSample {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw ParseError.tooShort }
        let flags = bytes[0]
        var i = 1
        let hr: Int
        if flags & 0x01 != 0 {
            hr = bytes.count >= 3 ? Int(bytes[1]) | Int(bytes[2]) << 8 : Int(bytes[1])
            i = 3
        } else {
            hr = Int(bytes[1])
            i = 2
        }
        let contact: Bool? = flags & 0x04 != 0 ? (flags & 0x02 != 0) : nil
        var energy: Int?
        if flags & 0x08 != 0, i + 1 < bytes.count {
            energy = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < bytes.count {
                let units = Int(bytes[i]) | Int(bytes[i + 1]) << 8
                rr.append(Double(units) * 1000.0 / 1024.0)
                i += 2
            }
        }
        return HeartRateSample(heartRate: hr, skinContact: contact, energyExpendedKJ: energy, rrIntervalsMs: rr, raw: bytes)
    }
}
