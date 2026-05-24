import CoreMediaIO
import Foundation

// Monitors camera in-use state across all system camera devices using
// kCMIODevicePropertyDeviceIsRunningSomewhere, which fires when any app
// (Zoom, FaceTime, Teams, etc.) opens or releases the camera.
//
// Listeners are only registered while active — call start()/stop() to control.
final class CameraMonitor {
    typealias StateHandler = (Bool) -> Void

    private let handler: StateHandler
    private var trackedDeviceIDs: [CMIODeviceID] = []
    private var listening = false

    init(handler: @escaping StateHandler) {
        self.handler = handler
    }

    deinit {
        if listening { removeAllListeners() }
    }

    func start() {
        guard !listening else { return }
        listening = true
        var addr = systemDevicesAddress()
        CMIOObjectAddPropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &addr,
            cmioDeviceListChanged, Unmanaged.passUnretained(self).toOpaque())
        refreshDevices()
    }

    func stop() {
        guard listening else { return }
        removeAllListeners()
    }

    private func removeAllListeners() {
        listening = false
        for id in trackedDeviceIDs {
            var addr = deviceRunningAddress()
            CMIOObjectRemovePropertyListener(id, &addr,
                cmioDeviceStateChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        trackedDeviceIDs = []
        var addr = systemDevicesAddress()
        CMIOObjectRemovePropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &addr,
            cmioDeviceListChanged, Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func refreshDevices() {
        guard listening else { return }
        let newIDs  = allDeviceIDs()
        let added   = newIDs.filter { !trackedDeviceIDs.contains($0) }
        let removed = trackedDeviceIDs.filter { !newIDs.contains($0) }
        for id in removed {
            var addr = deviceRunningAddress()
            CMIOObjectRemovePropertyListener(id, &addr,
                cmioDeviceStateChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        for id in added {
            var addr = deviceRunningAddress()
            CMIOObjectAddPropertyListener(id, &addr,
                cmioDeviceStateChanged, Unmanaged.passUnretained(self).toOpaque())
        }
        trackedDeviceIDs = newIDs
        broadcastState()
    }

    fileprivate func broadcastState() {
        guard listening else { return }
        let active = trackedDeviceIDs.contains { isRunning($0) }
        print("[CameraMonitor] Camera \(active ? "active" : "inactive") (\(trackedDeviceIDs.count) device(s))")
        handler(active)
    }

    private func isRunning(_ id: CMIODeviceID) -> Bool {
        var addr = deviceRunningAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &size, &value)
        return value != 0
    }

    private func allDeviceIDs() -> [CMIODeviceID] {
        var addr = systemDevicesAddress()
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var ids = [CMIODeviceID](repeating: 0, count: count)
        var outSize = dataSize
        CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, dataSize, &outSize, &ids)
        return ids
    }
}

// MARK: - Helpers

private func systemDevicesAddress() -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

private func deviceRunningAddress() -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope:    CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement:  CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

// MARK: - C callbacks (file-scope so pointer identity is stable for add/remove)

private let cmioDeviceListChanged: CMIOObjectPropertyListenerProc = { _, _, _, ctx in
    guard let ctx else { return noErr }
    let monitor = Unmanaged<CameraMonitor>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { monitor.refreshDevices() }
    return noErr
}

private let cmioDeviceStateChanged: CMIOObjectPropertyListenerProc = { _, _, _, ctx in
    guard let ctx else { return noErr }
    let monitor = Unmanaged<CameraMonitor>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { monitor.broadcastState() }
    return noErr
}
