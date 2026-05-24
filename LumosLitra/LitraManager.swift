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

    private var notificationPort: IONotificationPortRef?
    private var notificationSource: CFRunLoopSource?
    private var connectIterator: io_iterator_t = 0
    private var disconnectIterator: io_iterator_t = 0

    init() {
        setupNotifications()
    }

    deinit {
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
        for device in devices {
            do { try device.setPower(on) }
            catch { print("[LitraManager] setPower error: \(error)") }
        }
    }

    func setBrightness(_ fraction: Double) {
        brightness = fraction
        for device in devices {
            let span = device.spec.maxBrightness - device.spec.minBrightness
            let lumens = device.spec.minBrightness + Int(fraction * Double(span))
            do { try device.setBrightness(lumens) }
            catch { print("[LitraManager] setBrightness error: \(error)") }
        }
    }

    func setTemperature(_ kelvin: Int) {
        temperature = kelvin
        for device in devices {
            do { try device.setTemperature(kelvin) }
            catch { print("[LitraManager] setTemperature error: \(error)") }
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

    // Drains the iterator (required by IOKit to arm future notifications),
    // then reconciles the tracked device list against the live IOUSB registry.
    fileprivate func drainAndReconcile(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
        reconcileDeviceList()
    }

    // MARK: - Device reconciliation

    // Single-pass scan of the IOUSB registry plane. Adds newly found Litra
    // devices and removes ones that have disappeared.
    private func reconcileDeviceList() {
        struct FoundDevice {
            let entryID: UInt64
            let spec: LitraDevice.Spec
            let service: io_service_t  // +1 retain; released after use
        }

        var iter: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, "IOUSB",
                                       IOOptionBits(kIORegistryIterateRecursively),
                                       &iter) == kIOReturnSuccess else {
            print("[LitraManager] IORegistryCreateIterator failed")
            return
        }
        defer { IOObjectRelease(iter) }

        // Walk every node in the IOUSB plane tree, collect matching Litra devices.
        // Note: IOUSBHostInterface children are inaccessible (DEXT entitlements block
        // child enumeration), so we use the interface number from the Spec instead.
        var found: [FoundDevice] = []
        var svc = IOIteratorNext(iter)
        while svc != 0 {
            if let vid = ioRegistryInt(svc, "idVendor"), vid == LitraDevice.vendorID,
               let pid = ioRegistryInt(svc, "idProduct"), let spec = LitraDevice.specs[pid] {
                var entryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(svc, &entryID)
                IOObjectRetain(svc)  // keep alive past the IOObjectRelease below
                found.append(FoundDevice(entryID: entryID, spec: spec, service: svc))
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        defer { found.forEach { IOObjectRelease($0.service) } }

        let presentIDs = Set(found.map { $0.entryID })

        // Remove devices that are no longer in the registry.
        let before = devices.count
        devices.removeAll { !presentIDs.contains($0.usbDeviceEntryID) }
        if devices.count < before {
            print("[LitraManager] \(before - devices.count) device(s) removed — total: \(devices.count)")
        }

        // Open and add any devices not yet tracked.
        for f in found where !devices.contains(where: { $0.usbDeviceEntryID == f.entryID }) {
            do {
                let usbDevice = try IOUSBHostDevice(
                    __ioService: f.service, options: [], queue: nil, interestHandler: nil)
                let light = LitraDevice(usbDevice: usbDevice, usbDeviceEntryID: f.entryID, spec: f.spec)
                devices.append(light)
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
