import IOKit
import IOUSBHost
import Combine

// Discovery strategy:
//   IOServiceAddMatchingNotification cannot see Litra devices because their
//   IOUSBHostDevice nodes carry IOServiceDEXTEntitlements, which blocks matching
//   APIs for apps without the driverkit.transport.usb entitlement.
//
//   Instead: watch for ANY IOUSBHostDevice connect/disconnect as a trigger, then
//   scan the IOUSB registry plane directly with IORegistryCreateIterator. Direct
//   iteration bypasses the matching restrictions — this is how `ioreg -p IOUSB`
//   finds them.
final class LitraManager: ObservableObject {

    @Published private(set) var devices: [LitraDevice] = []
    @Published var isOn: Bool = false
    @Published var brightness: Double = 0.5
    @Published var temperature: Int = 4000

    @Published var syncEnabled: Bool = true {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: "syncEnabled") }
    }

    @Published var circadianEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(circadianEnabled, forKey: "circadianEnabled")
            circadianEnabled ? startCircadian() : stopCircadian()
        }
    }
    @Published private(set) var solarAltitude: Double = 0

    private var notificationPort: IONotificationPortRef?
    private var notificationSource: CFRunLoopSource?
    private var connectIterator: io_iterator_t = 0
    private var disconnectIterator: io_iterator_t = 0
    private var circadianTimer: Timer?
    private var hidMonitor: LitraHIDMonitor?

    init() {
        // Load persisted state before discovering devices so newly connected
        // lights are initialized to the correct values immediately.
        let d = UserDefaults.standard
        isOn              = d.bool(forKey: "isOn")
        brightness        = d.object(forKey: "brightness")   as? Double ?? 0.5
        temperature       = d.object(forKey: "temperature")  as? Int    ?? 4000
        circadianEnabled  = d.bool(forKey: "circadianEnabled")
        syncEnabled       = d.object(forKey: "syncEnabled")  as? Bool   ?? true

        setupNotifications()
        hidMonitor = LitraHIDMonitor { [weak self] bytes in self?.handleHIDReport(bytes) }

        // didSet doesn't fire during init, so start circadian manually if needed.
        if circadianEnabled { startCircadian() }
    }

    deinit {
        circadianTimer?.invalidate()
        if connectIterator != 0    { IOObjectRelease(connectIterator) }
        if disconnectIterator != 0 { IOObjectRelease(disconnectIterator) }
        if let src = notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        if let port = notificationPort { IONotificationPortDestroy(port) }
    }

    // MARK: - Public interface

    func setOn(_ on: Bool) {
        isOn = on
        UserDefaults.standard.set(on, forKey: "isOn")
        for device in devices {
            do { try device.setPower(on) }
            catch { print("[LitraManager] setPower error: \(error)") }
        }
    }

    func setBrightness(_ fraction: Double) {
        brightness = fraction
        UserDefaults.standard.set(fraction, forKey: "brightness")
        for device in devices {
            let span = device.spec.maxBrightness - device.spec.minBrightness
            let lumens = device.spec.minBrightness + Int(fraction * Double(span))
            do { try device.setBrightness(lumens) }
            catch { print("[LitraManager] setBrightness error: \(error)") }
        }
    }

    func setTemperature(_ kelvin: Int) {
        temperature = kelvin
        UserDefaults.standard.set(kelvin, forKey: "temperature")
        for device in devices {
            do { try device.setTemperature(kelvin) }
            catch { print("[LitraManager] setTemperature error: \(error)") }
        }
    }

    // MARK: - Circadian mode

    private func startCircadian() {
        applyCircadian()
        circadianTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.applyCircadian()
        }
    }

    private func stopCircadian() {
        circadianTimer?.invalidate()
        circadianTimer = nil
    }

    private func applyCircadian() {
        let (lat, lon) = timeZoneCoordinates()
        let alt = SunPosition.altitude(latitude: lat, longitude: lon)
        solarAltitude = alt
        setTemperature(SunPosition.kelvin(for: alt))
    }

    // Derives approximate latitude and longitude from the system timezone.
    // Longitude: timezone UTC offset × 15° (exact for standard meridians, within
    // ~30–45 min for zones that don't sit on their meridian).
    // Latitude: rough regional default from the IANA timezone prefix.
    private func timeZoneCoordinates() -> (lat: Double, lon: Double) {
        let tz  = TimeZone.current
        let lon = Double(tz.secondsFromGMT()) / 3600.0 * 15.0

        let id  = tz.identifier
        let lat: Double
        switch true {
        case id.hasPrefix("America/"), id.hasPrefix("US/"), id.hasPrefix("Canada/"):
            lat = 40.0
        case id.hasPrefix("Europe/"):
            lat = 50.0
        case id.hasPrefix("Australia/"):
            lat = -33.0
        case id.hasPrefix("Asia/"):
            lat = 35.0
        case id.hasPrefix("Pacific/"):
            lat = 0.0
        case id.hasPrefix("Africa/"):
            lat = 5.0
        default:
            lat = 40.0
        }
        return (lat, lon)
    }

    // MARK: - Hardware sync

    private func handleHIDReport(_ bytes: [UInt8]) {
        guard bytes.count >= 6, bytes[0] == 0x11, bytes[1] == 0xff else { return }
        switch bytes[3] {
        case 0x00:
            let on = bytes[4] == 0x01
            guard isOn != on else { return }
            isOn = on
            UserDefaults.standard.set(on, forKey: "isOn")
            if syncEnabled {
                for device in devices {
                    try? device.setPower(on)
                    if on {
                        let span = device.spec.maxBrightness - device.spec.minBrightness
                        try? device.setBrightness(device.spec.minBrightness + Int(brightness * Double(span)))
                        try? device.setTemperature(temperature)
                    }
                }
            }
            print("[LitraManager] Physical button: power \(on ? "on" : "off")")
        case 0x10:
            let lumens = Int(bytes[4]) << 8 | Int(bytes[5])
            guard let spec = devices.first?.spec else { return }
            let fraction = Swift.max(0.0, Swift.min(1.0,
                Double(lumens - spec.minBrightness) / Double(spec.maxBrightness - spec.minBrightness)))
            guard abs(brightness - fraction) > 0.001 else { return }
            brightness = fraction
            UserDefaults.standard.set(fraction, forKey: "brightness")
            if syncEnabled {
                for device in devices {
                    let span = device.spec.maxBrightness - device.spec.minBrightness
                    try? device.setBrightness(device.spec.minBrightness + Int(fraction * Double(span)))
                }
            }
            print("[LitraManager] Physical button: brightness \(lumens) lm → \(Int(fraction * 100))%")
        case 0x20:
            let kelvin = Swift.max(2700, Swift.min(6500, (Int(bytes[4]) << 8 | Int(bytes[5])) / 100 * 100))
            guard temperature != kelvin else { return }
            if circadianEnabled { circadianEnabled = false }
            temperature = kelvin
            UserDefaults.standard.set(kelvin, forKey: "temperature")
            if syncEnabled {
                for device in devices { try? device.setTemperature(kelvin) }
            }
            print("[LitraManager] Physical button: temperature \(kelvin)K")
        case 0x9c, 0x8e:
            break // command-echo noise, ignore
        default:
            break
        }
    }

    // MARK: - Notification setup

    private func setupNotifications() {
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notificationPort else {
            print("[LitraManager] IONotificationPortCreate failed")
            return
        }

        let src = IONotificationPortGetRunLoopSource(port).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        notificationSource = src

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let cr = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"),
            onDeviceConnected, ctx, &connectIterator)
        print("[LitraManager] Connect notification result: \(cr)")
        if cr == kIOReturnSuccess { drainAndReconcile(connectIterator) }

        let dr = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            onDeviceDisconnected, ctx, &disconnectIterator)
        print("[LitraManager] Disconnect notification result: \(dr)")
        if dr == kIOReturnSuccess { drainAndReconcile(disconnectIterator) }
    }

    // MARK: - Notification drain

    fileprivate func drainAndReconcile(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
        reconcileDeviceList()
    }

    // MARK: - Device reconciliation

    private func reconcileDeviceList() {
        struct FoundDevice {
            let entryID: UInt64
            let spec: LitraDevice.Spec
            let service: io_service_t
        }

        var iter: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, "IOUSB",
                                       IOOptionBits(kIORegistryIterateRecursively),
                                       &iter) == kIOReturnSuccess else {
            print("[LitraManager] IORegistryCreateIterator failed")
            return
        }
        defer { IOObjectRelease(iter) }

        var found: [FoundDevice] = []
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            if let vid = ioRegistryInt(svc, "idVendor"), vid == LitraDevice.vendorID,
               let pid = ioRegistryInt(svc, "idProduct"), let spec = LitraDevice.specs[pid] {
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(svc, &entryID)
                IOObjectRetain(svc)
                found.append(FoundDevice(entryID: entryID, spec: spec, service: svc))
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        defer { found.forEach { IOObjectRelease($0.service) } }

        let presentIDs = Set(found.map { $0.entryID })

        let before = devices.count
        devices.removeAll { !presentIDs.contains($0.usbDeviceEntryID) }
        if devices.count < before {
            print("[LitraManager] \(before - devices.count) device(s) removed — total: \(devices.count)")
        }

        for f in found where !devices.contains(where: { $0.usbDeviceEntryID == f.entryID }) {
            do {
                let usbDevice = try IOUSBHostDevice(
                    __ioService: f.service, options: [], queue: nil, interestHandler: nil)
                let light = LitraDevice(usbDevice: usbDevice, usbDeviceEntryID: f.entryID, spec: f.spec)
                devices.append(light)
                if devices.count > 1 { syncEnabled = true }
                print("[LitraManager] Device added — total: \(devices.count)")
                try? light.setPower(isOn)
                if isOn {
                    let span = f.spec.maxBrightness - f.spec.minBrightness
                    try? light.setBrightness(f.spec.minBrightness + Int(brightness * Double(span)))
                    try? light.setTemperature(temperature)
                }
            } catch {
                print("[LitraManager] IOUSBHostDevice init failed: \(error)")
            }
        }
    }
}

private func ioRegistryInt(_ service: io_service_t, _ key: String) -> Int? {
    let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
    return (ref?.takeRetainedValue() as? NSNumber)?.intValue
}

// MARK: - C callbacks

private let onDeviceConnected: IOServiceMatchingCallback = { context, iterator in
    guard let context else { return }
    Unmanaged<LitraManager>.fromOpaque(context).takeUnretainedValue().drainAndReconcile(iterator)
}

private let onDeviceDisconnected: IOServiceMatchingCallback = { context, iterator in
    guard let context else { return }
    Unmanaged<LitraManager>.fromOpaque(context).takeUnretainedValue().drainAndReconcile(iterator)
}
