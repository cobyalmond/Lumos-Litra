import Foundation
import IOKit
import IOKit.hid

// Listens for interrupt-driven input reports from Litra lights via IOHIDManager.
// Physical button presses generate interrupt IN reports — this is where they land.
//
// If the DEXT driver (AppleUserHIDDevice) registers a matchable HID service, this
// fires when buttons are pressed. If it doesn't, the device matching callback will
// simply never fire (no error — just silence).
final class LitraHIDMonitor {
    typealias ReportHandler = ([UInt8]) -> Void

    private let manager: IOHIDManager
    private let handler: ReportHandler

    init(handler: @escaping ReportHandler) {
        self.handler = handler
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))

        let matchingDicts = LitraDevice.specs.keys.map { pid in
            [kIOHIDVendorIDKey: LitraDevice.vendorID, kIOHIDProductIDKey: pid] as NSDictionary
        } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts)

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, result, _, device in
            guard result == kIOReturnSuccess else { return }
            let vid = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
            print("[LitraHIDMonitor] Device matched vid=0x\(String(format: "%04x", vid)) pid=0x\(String(format: "%04x", pid))")
        }, nil)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, _, _, reportID, report, len in
            guard let ctx, result == kIOReturnSuccess, len > 0 else { return }
            let monitor = Unmanaged<LitraHIDMonitor>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(len)))
            monitor.handler(bytes)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let kr = IOHIDManagerOpen(manager, IOOptionBits(0))
        print("[LitraHIDMonitor] Open: \(kr == kIOReturnSuccess ? "success" : "failed (kr=\(kr))")")
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(0))
    }
}
