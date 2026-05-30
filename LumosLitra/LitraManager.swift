import IOKit
import IOUSBHost
import Combine
import CoreLocation

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

    @Published private(set) var devices: [any LitraDeviceProtocol] = []
    @Published var isOn: Bool = false
    @Published var brightness: Double = 0.5
    @Published var temperature: Int = 4000

    @Published var syncEnabled: Bool = true {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: "syncEnabled") }
    }

    @Published var cameraAutoOn: Bool = false {
        didSet {
            UserDefaults.standard.set(cameraAutoOn, forKey: "cameraAutoOn")
            cameraAutoOn ? cameraMonitor?.start() : cameraMonitor?.stop()
        }
    }

    @Published var circadianEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(circadianEnabled, forKey: "circadianEnabled")
            circadianEnabled ? startCircadian() : stopCircadian()
        }
    }
    @Published private(set) var solarAltitude: Double = 0

    #if DEBUG
    private let isPreview = CommandLine.arguments.contains("--preview")
    #endif

    private var notificationPort: IONotificationPortRef?
    private var notificationSource: CFRunLoopSource?
    private var connectIterator: io_iterator_t = 0
    private var disconnectIterator: io_iterator_t = 0
    private var circadianTimer: Timer?
    private var hidMonitor: LitraHIDMonitor?
    private var cameraMonitor: CameraMonitor?
    private var cameraActivatedLights = false
    private var coreLocationManager: CLLocationManager?
    private var locationDelegate: LocationDelegate?

    // Serial queue for USB transfers — keeps synchronous sends off the main thread.
    private let usbQueue = DispatchQueue(label: "com.cobyalmond.LumosLitra.usb", qos: .userInitiated)
    private var brightnessTimer: Timer?
    private var temperatureTimer: Timer?
    private var lastBrightnessSent: Date = .distantPast
    private var lastTemperatureSent: Date = .distantPast

    init() {
        // Load persisted state before discovering devices so newly connected
        // lights are initialized to the correct values immediately.
        let d = UserDefaults.standard
        isOn              = d.bool(forKey: "isOn")
        brightness        = d.object(forKey: "brightness")   as? Double ?? 0.5
        temperature       = d.object(forKey: "temperature")  as? Int    ?? 4000
        circadianEnabled  = d.bool(forKey: "circadianEnabled")
        syncEnabled       = d.object(forKey: "syncEnabled")  as? Bool   ?? true
        cameraAutoOn      = d.bool(forKey: "cameraAutoOn")

        #if DEBUG
        if isPreview {
            let spec = LitraDevice.specs[0xC901]!
            devices = [MockLitraDevice(spec: spec, id: 1), MockLitraDevice(spec: spec, id: 2)]
        } else {
            setupNotifications()
            hidMonitor    = LitraHIDMonitor { [weak self] bytes in self?.handleHIDReport(bytes) }
            cameraMonitor = CameraMonitor { [weak self] active in self?.handleCameraState(active) }
        }
        #else
        setupNotifications()
        hidMonitor    = LitraHIDMonitor { [weak self] bytes in self?.handleHIDReport(bytes) }
        cameraMonitor = CameraMonitor { [weak self] active in self?.handleCameraState(active) }
        #endif

        // didSet doesn't fire during init, so start manually if needed.
        if circadianEnabled { startCircadian() }
        if cameraAutoOn     { cameraMonitor?.start() }
        requestLocationIfNeeded()
    }

    #if DEBUG
    init(mockDevices: [any LitraDeviceProtocol]) {
        devices = mockDevices
    }
    #endif

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
        if !on { cameraActivatedLights = false }
        isOn = on
        UserDefaults.standard.set(on, forKey: "isOn")
        for device in devices {
            do { try device.setPower(on) }
            catch { print("[LitraManager] setPower error: \(error)") }
        }
    }

    // MARK: - Camera auto-on

    private func handleCameraState(_ active: Bool) {
        guard cameraAutoOn else { return }
        if active {
            guard !isOn else { return }
            cameraActivatedLights = true
            setOn(true)
            for device in devices {
                let span = device.spec.maxBrightness - device.spec.minBrightness
                try? device.setBrightness(device.spec.minBrightness + Int(brightness * Double(span)))
                try? device.setTemperature(temperature)
            }
            print("[LitraManager] Camera active — lights on")
        } else {
            guard cameraActivatedLights else { return }
            cameraActivatedLights = false
            setOn(false)
            print("[LitraManager] Camera inactive — lights off")
        }
    }

    func setBrightness(_ fraction: Double) {
        brightness = fraction
        brightnessTimer?.invalidate()
        let elapsed = Date().timeIntervalSince(lastBrightnessSent)
        let snapshot = devices
        let queue = usbQueue
        let send = {
            self.lastBrightnessSent = Date()
            UserDefaults.standard.set(fraction, forKey: "brightness")
            queue.async {
                for device in snapshot {
                    let span = device.spec.maxBrightness - device.spec.minBrightness
                    try? device.setBrightness(device.spec.minBrightness + Int(fraction * Double(span)))
                }
            }
        }
        if elapsed >= 0.04 {
            send()
        } else {
            brightnessTimer = .scheduledTimer(withTimeInterval: 0.04 - elapsed, repeats: false) { [weak self] _ in
                guard self != nil else { return }
                send()
            }
        }
    }

    func setTemperature(_ kelvin: Int) {
        temperature = kelvin
        temperatureTimer?.invalidate()
        let elapsed = Date().timeIntervalSince(lastTemperatureSent)
        let snapshot = devices
        let queue = usbQueue
        let send = {
            self.lastTemperatureSent = Date()
            UserDefaults.standard.set(kelvin, forKey: "temperature")
            queue.async {
                for device in snapshot { try? device.setTemperature(kelvin) }
            }
        }
        if elapsed >= 0.04 {
            send()
        } else {
            temperatureTimer = .scheduledTimer(withTimeInterval: 0.04 - elapsed, repeats: false) { [weak self] _ in
                guard self != nil else { return }
                send()
            }
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
        let (lat, lon) = circadianCoordinates()
        let alt     = SunPosition.altitude(latitude: lat, longitude: lon)
        let rising  = SunPosition.isRising(latitude: lat, longitude: lon)
        solarAltitude = alt
        setTemperature(SunPosition.kelvin(for: alt, isMorning: rising))
    }

    // Uses CoreLocation-saved coordinates when available; falls back to timezone estimate.
    private func circadianCoordinates() -> (lat: Double, lon: Double) {
        let d = UserDefaults.standard
        if let lat = d.object(forKey: "savedLatitude")  as? Double,
           let lon = d.object(forKey: "savedLongitude") as? Double {
            return (lat, lon)
        }
        return timeZoneCoordinates()
    }

    // Requests a one-time location fix. Result is saved to UserDefaults and
    // used for all future circadian calculations. Never asks again once saved.
    private func requestLocationIfNeeded() {
        guard UserDefaults.standard.object(forKey: "savedLatitude") == nil else { return }
        let delegate = LocationDelegate()
        let mgr = CLLocationManager()
        mgr.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        mgr.delegate = delegate

        delegate.onLocation = { [weak self] coord in
            DispatchQueue.main.async {
                UserDefaults.standard.set(coord.latitude,  forKey: "savedLatitude")
                UserDefaults.standard.set(coord.longitude, forKey: "savedLongitude")
                self?.coreLocationManager = nil
                self?.locationDelegate    = nil
                if self?.circadianEnabled == true { self?.applyCircadian() }
                print("[LitraManager] Location saved: \(coord.latitude), \(coord.longitude)")
            }
        }
        delegate.onFailure = { [weak self] in
            DispatchQueue.main.async {
                self?.coreLocationManager = nil
                self?.locationDelegate    = nil
                print("[LitraManager] Location unavailable — using timezone estimate")
            }
        }

        coreLocationManager = mgr
        locationDelegate    = delegate
        mgr.requestWhenInUseAuthorization()
    }

    // Derives approximate coordinates from the system timezone.
    // Used when CoreLocation permission is denied or not yet determined.
    // Specific IANA IDs take priority; prefix-based fallback covers unknown zones.
    private func timeZoneCoordinates() -> (lat: Double, lon: Double) {
        let tz = TimeZone.current
        let id = tz.identifier

        let known: [String: (Double, Double)] = [
            // United States
            "America/New_York":             (40.71, -74.01),
            "America/Chicago":              (41.85, -87.65),
            "America/Denver":               (39.74, -104.98),
            "America/Los_Angeles":          (34.05, -118.24),
            "America/Phoenix":              (33.45, -112.07),
            "America/Anchorage":            (61.22, -149.90),
            "America/Honolulu":             (21.31, -157.80),
            "Pacific/Honolulu":             (21.31, -157.80),
            "America/Detroit":              (42.33, -83.05),
            "America/Indiana/Indianapolis": (39.77, -86.16),
            "America/Boise":                (43.62, -116.20),
            // Canada
            "America/Toronto":              (43.65, -79.38),
            "America/Vancouver":            (49.25, -123.12),
            "America/Calgary":              (51.05, -114.07),
            "America/Winnipeg":             (49.90, -97.14),
            "America/Halifax":              (44.65, -63.57),
            // Europe
            "Europe/London":                (51.51,  -0.13),
            "Europe/Dublin":                (53.33,  -6.25),
            "Europe/Lisbon":                (38.72,  -9.14),
            "Europe/Madrid":                (40.42,  -3.70),
            "Europe/Paris":                 (48.85,   2.35),
            "Europe/Brussels":              (50.85,   4.35),
            "Europe/Amsterdam":             (52.37,   4.90),
            "Europe/Berlin":                (52.52,  13.40),
            "Europe/Zurich":                (47.38,   8.54),
            "Europe/Vienna":                (48.21,  16.37),
            "Europe/Prague":                (50.09,  14.44),
            "Europe/Warsaw":                (52.23,  21.01),
            "Europe/Rome":                  (41.90,  12.50),
            "Europe/Athens":                (37.98,  23.73),
            "Europe/Stockholm":             (59.33,  18.07),
            "Europe/Oslo":                  (59.91,  10.75),
            "Europe/Copenhagen":            (55.68,  12.57),
            "Europe/Helsinki":              (60.17,  24.94),
            "Europe/Istanbul":              (41.01,  28.95),
            "Europe/Moscow":                (55.75,  37.62),
            "Europe/Kyiv":                  (50.45,  30.52),
            // Asia
            "Asia/Tokyo":                   (35.69, 139.69),
            "Asia/Seoul":                   (37.57, 126.98),
            "Asia/Shanghai":                (31.23, 121.47),
            "Asia/Hong_Kong":               (22.33, 114.17),
            "Asia/Taipei":                  (25.05, 121.53),
            "Asia/Singapore":               ( 1.35, 103.82),
            "Asia/Kuala_Lumpur":            ( 3.15, 101.70),
            "Asia/Bangkok":                 (13.75, 100.50),
            "Asia/Jakarta":                 (-6.21, 106.85),
            "Asia/Kolkata":                 (22.57,  88.36),
            "Asia/Mumbai":                  (19.08,  72.88),
            "Asia/Karachi":                 (24.86,  67.01),
            "Asia/Dubai":                   (25.20,  55.27),
            "Asia/Tehran":                  (35.69,  51.42),
            "Asia/Dhaka":                   (23.72,  90.41),
            // Australia & Pacific
            "Australia/Sydney":             (-33.87, 151.21),
            "Australia/Melbourne":          (-37.81, 144.96),
            "Australia/Brisbane":           (-27.47, 153.03),
            "Australia/Perth":              (-31.95, 115.86),
            "Australia/Adelaide":           (-34.93, 138.60),
            "Australia/Darwin":             (-12.46, 130.84),
            "Pacific/Auckland":             (-36.87, 174.77),
            // Africa
            "Africa/Johannesburg":          (-26.20,  28.04),
            "Africa/Cairo":                 ( 30.04,  31.24),
            "Africa/Lagos":                 (  6.52,   3.38),
            "Africa/Nairobi":               ( -1.29,  36.82),
            "Africa/Casablanca":            ( 33.59,  -7.62),
        ]
        if let (lat, lon) = known[id] { return (lat, lon) }

        // Last resort: longitude from UTC offset, rough latitude from region prefix.
        let lon = Double(tz.secondsFromGMT()) / 3600.0 * 15.0
        let lat: Double
        switch true {
        case id.hasPrefix("America/"), id.hasPrefix("US/"), id.hasPrefix("Canada/"): lat = 40.0
        case id.hasPrefix("Europe/"):                                                 lat = 50.0
        case id.hasPrefix("Australia/"):                                              lat = -33.0
        case id.hasPrefix("Asia/"):                                                   lat = 35.0
        case id.hasPrefix("Pacific/"):                                                lat = 0.0
        case id.hasPrefix("Africa/"):                                                 lat = 5.0
        default:                                                                      lat = 40.0
        }
        return (lat, lon)
    }

    // MARK: - Hardware sync

    func handleHIDReport(_ bytes: [UInt8]) {
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
        #if DEBUG
        guard !isPreview else { return }
        #endif
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

// MARK: - Location delegate

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocationCoordinate2D) -> Void)?
    var onFailure: (() -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.first?.coordinate else { return }
        onLocation?(coord)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationDelegate] \(error)")
        onFailure?()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            onFailure?()
        default:
            break
        }
    }
}
