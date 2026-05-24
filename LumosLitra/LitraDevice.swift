import IOKit
import IOUSBHost

// Represents one physical Litra light.
//
// Commands are sent as USB HID SET_REPORT control transfers directly to the
// device's control endpoint (USB endpoint 0). This bypasses the macOS HID
// subsystem entirely, so the app never needs Input Monitoring permission.
final class LitraDevice {

    struct Spec {
        let minBrightness: Int  // lumens
        let maxBrightness: Int  // lumens
        let commandByte: UInt8  // 0x04 for Glow/Beam, 0x06 for Beam LX
        let interfaceNumber: Int // USB HID interface (always 0 for all known Litra models)
    }

    static let specs: [Int: Spec] = [
        0xC900: Spec(minBrightness: 20,  maxBrightness: 250, commandByte: 0x04, interfaceNumber: 0), // Litra Glow
        0xC901: Spec(minBrightness: 30,  maxBrightness: 400, commandByte: 0x04, interfaceNumber: 0), // Litra Beam
        0xB901: Spec(minBrightness: 30,  maxBrightness: 400, commandByte: 0x04, interfaceNumber: 0), // Litra Beam (alt PID)
        0xC903: Spec(minBrightness: 30,  maxBrightness: 400, commandByte: 0x06, interfaceNumber: 0), // Litra Beam LX
    ]

    static let vendorID = 0x046D

    private let usbDevice: IOUSBHostDevice
    private let interfaceNumber: UInt16
    let spec: Spec
    let usbDeviceEntryID: UInt64  // IOUSBHostDevice registryEntryID; stable identity across reconnects

    init(usbDevice: IOUSBHostDevice, usbDeviceEntryID: UInt64, spec: Spec) {
        self.usbDevice = usbDevice
        self.interfaceNumber = UInt16(spec.interfaceNumber)
        self.usbDeviceEntryID = usbDeviceEntryID
        self.spec = spec
    }

    // MARK: - Commands

    func setPower(_ on: Bool) throws {
        try send([0xff, spec.commandByte, 0x1c, on ? 0x01 : 0x00])
    }

    func setBrightness(_ lumens: Int) throws {
        let v = lumens.clamped(to: spec.minBrightness...spec.maxBrightness)
        try send([0xff, spec.commandByte, 0x4c, UInt8(v >> 8), UInt8(v & 0xff)])
    }

    func setTemperature(_ kelvin: Int) throws {
        let v = ((kelvin / 100) * 100).clamped(to: 2700...6500)
        try send([0xff, spec.commandByte, 0x9c, UInt8(v >> 8), UInt8(v & 0xff)])
    }

    // MARK: - Private

    // USB HID SET_REPORT (USB HID spec §7.2.2):
    //   bmRequestType 0x21 = host→device (0), class (01), interface (01)
    //   bRequest      0x09 = SET_REPORT
    //   wValue        0x0211 = report type Output (2), report ID 0x11
    //   wIndex        = interface number of the lighting control interface
    //   data          = 19-byte payload (no report ID prefix — that's in wValue)
    private func send(_ bytes: [UInt8]) throws {
        var payload = [UInt8](repeating: 0, count: 19)
        for (i, b) in bytes.prefix(19).enumerated() { payload[i] = b }

        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x21
        req.bRequest      = 0x09
        req.wValue        = 0x0211
        req.wIndex        = interfaceNumber
        req.wLength       = UInt16(payload.count)

        try autoreleasepool {
            let data = NSMutableData(bytes: payload, length: payload.count)
            var transferred = 0
            try usbDevice.__send(req, data: data, bytesTransferred: &transferred, completionTimeout: 1.0)
        }
    }
}

enum LitraError: Error {
    case interfaceNotFound
    case deviceOpenFailed
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
