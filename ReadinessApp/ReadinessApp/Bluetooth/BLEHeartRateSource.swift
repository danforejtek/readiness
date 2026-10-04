import CoreBluetooth
import Foundation
import HRVCore

/// The real band over CoreBluetooth: scans for the Heart Rate Service, prefers the band used last time,
/// subscribes to Heart Rate Measurement, reads the battery, and reconnects (with the measurement clock paused)
/// if the link drops. One measurement = one source instance; `stop()` disconnects so a watch or another app
/// can use the band afterwards (the band accepts a single central at a time).
// All state is touched on the main queue (CoreBluetooth delegate queue), so the cross-task capture is safe.
final class BLEHeartRateSource: NSObject, HeartRateSource, @unchecked Sendable {
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")

    /// How long to look for a band before giving up with help text.
    var scanTimeout: TimeInterval = 30
    /// How long a dropped connection may stay down before the measurement fails.
    var reconnectTimeout: TimeInterval = 60
    /// Grace period during which an unknown band is ignored in favour of the remembered one.
    var preferSavedFor: TimeInterval = 4

    let displayName = "Bluetooth band"
    let clockRate: Double = 1

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var candidate: CBPeripheral?
    private var continuation: AsyncStream<HeartRateEvent>.Continuation?
    private var battery: Int?
    private var connectedOnce = false
    private var stopped = false
    private var scanStarted: Date?
    private var scanTimer: DispatchWorkItem?
    private var reconnectTimer: DispatchWorkItem?

    func events() -> AsyncStream<HeartRateEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                DispatchQueue.main.async { self?.stop() }
            }
            self.continuation?.yield(.status("Starting Bluetooth…"))
            // Delegate callbacks on the main queue: the measurement session is main-actor bound anyway.
            self.central = CBCentralManager(delegate: self, queue: .main,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        scanTimer?.cancel(); scanTimer = nil
        reconnectTimer?.cancel(); reconnectTimer = nil
        if let central {
            if central.state == .poweredOn {
                central.stopScan()
                if let p = peripheral {
                    if p.state == .connected, let c = measurementCharacteristic(of: p) {
                        p.setNotifyValue(false, for: c)
                    }
                    central.cancelPeripheralConnection(p)
                }
            }
            central.delegate = nil
        }
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Scanning

    private func startScan() {
        guard let central, central.state == .poweredOn, !stopped else { return }
        let savedName = AppSettings.bandName
        if let id = AppSettings.bandIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            // A pending connect to a known peripheral completes as soon as it advertises again,
            // even if it is not yet in range; scanning in parallel catches a replacement band.
            peripheral = known
            known.delegate = self
            central.connect(known)
        }
        scanStarted = Date()
        yield(.status(savedName.map { "Searching for \($0)…" } ?? "Searching for a heart-rate band…"))
        central.scanForPeripherals(withServices: [Self.heartRateService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let timer = DispatchWorkItem { [weak self] in self?.scanTimedOut() }
        scanTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeout, execute: timer)
    }

    private func scanTimedOut() {
        guard !stopped, !connectedOnce else { return }
        fail("""
        No heart-rate band found in \(Int(scanTimeout)) seconds.
        Press the band's button once: it blinks blue while waiting for a connection. \
        Red blinking means the battery is low. If the blue light is steady or not blinking, another app \
        or a watch is already connected to it; disconnect there first (the band takes one connection at a time).
        """)
    }

    private func connect(to p: CBPeripheral) {
        guard let central else { return }
        scanTimer?.cancel(); scanTimer = nil
        central.stopScan()
        if let old = peripheral, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
        peripheral = p
        p.delegate = self
        yield(.status("Found \(p.name ?? "band"), connecting…"))
        central.connect(p)
    }

    // MARK: - Helpers

    private func yield(_ event: HeartRateEvent) { continuation?.yield(event) }

    private func fail(_ message: String) {
        yield(.failed(message))
        stop()
    }

    private func measurementCharacteristic(of p: CBPeripheral) -> CBCharacteristic? {
        p.services?.first { $0.uuid == Self.heartRateService }?
            .characteristics?.first { $0.uuid == Self.heartRateMeasurement }
    }

    private func armReconnectTimeout() {
        reconnectTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.fail("Lost the band for more than \(Int(self.reconnectTimeout)) seconds. Keep the phone within a metre of the band and start again.")
        }
        reconnectTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectTimeout, execute: timer)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEHeartRateSource: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !stopped else { return }
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff:
            fail("Bluetooth is off. Turn it on in Control Centre or Settings and start again.")
        case .unauthorized:
            fail("Readiness is not allowed to use Bluetooth. Allow it in Settings › Privacy & Security › Bluetooth.")
        case .unsupported:
            fail("This device has no Bluetooth LE support.")
        case .resetting, .unknown:
            yield(.status("Waiting for Bluetooth…"))
        @unknown default:
            yield(.status("Waiting for Bluetooth…"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, peripheral?.state != .connected, peripheral?.state != .connecting || peripheral?.identifier == p.identifier else { return }
        let saved = AppSettings.bandIdentifier
        if saved == nil || saved == p.identifier {
            connect(to: p)
            return
        }
        // Another HR sensor: give the remembered band a few seconds before settling for this one.
        candidate = p
        if let started = scanStarted, Date().timeIntervalSince(started) >= preferSavedFor {
            connect(to: p)
        } else {
            yield(.status("Found \(p.name ?? "another sensor"), waiting for \(AppSettings.bandName ?? "your band")…"))
            DispatchQueue.main.asyncAfter(deadline: .now() + preferSavedFor) { [weak self] in
                guard let self, !self.stopped, self.peripheral?.state != .connected, self.peripheral?.state != .connecting,
                      let c = self.candidate else { return }
                self.connect(to: c)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard !stopped else { return }
        scanTimer?.cancel(); scanTimer = nil
        reconnectTimer?.cancel(); reconnectTimer = nil
        central.stopScan()
        AppSettings.bandIdentifier = p.identifier
        AppSettings.bandName = p.name
        yield(.status("Connected, reading services…"))
        p.discoverServices([Self.heartRateService, Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        yield(.status("Connection failed, retrying…"))
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard !stopped else { return }
        yield(.disconnected)
        armReconnectTimeout()
        // Re-issue the connect: it completes when the band advertises again.
        central.connect(p)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEHeartRateSource: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped else { return }
        if let error { fail("Could not read the band's services: \(error.localizedDescription)"); return }
        guard let services = p.services, !services.isEmpty else {
            fail("The band offers no Heart Rate Service. Is this the right sensor?")
            return
        }
        for s in services {
            switch s.uuid {
            case Self.heartRateService: p.discoverCharacteristics([Self.heartRateMeasurement], for: s)
            case Self.batteryService: p.discoverCharacteristics([Self.batteryLevel], for: s)
            default: break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopped, error == nil else { return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.batteryLevel:
                p.readValue(for: c)       // queued before the notify-enable, so the battery is known when we report "connected"
            case Self.heartRateMeasurement:
                p.setNotifyValue(true, for: c)
            default: break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard !stopped, c.uuid == Self.heartRateMeasurement else { return }
        if let error { fail("Could not subscribe to heart-rate data: \(error.localizedDescription)"); return }
        guard c.isNotifying else { return }
        connectedOnce = true
        yield(.connected(device: p.name ?? "Heart-rate band", battery: battery))
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard !stopped, error == nil, let data = c.value else { return }
        switch c.uuid {
        case Self.heartRateMeasurement:
            if let sample = try? HeartRateSample.parse(data) { yield(.sample(sample)) }
        case Self.batteryLevel:
            if let b = data.first { battery = Int(b) }
        default: break
        }
    }
}
