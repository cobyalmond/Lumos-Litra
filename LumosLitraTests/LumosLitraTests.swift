import XCTest
@testable import LumosLitra

// MARK: - SunPosition

final class SunPositionTests: XCTestCase {

    // MARK: kelvin — evening (default)

    func testKelvinAtOrBelowHorizon() {
        // Evening floor is 2700K; anything at or below the horizon holds there.
        XCTAssertEqual(SunPosition.kelvin(for: 0),   2700)
        XCTAssertEqual(SunPosition.kelvin(for: -10), 2700)
        XCTAssertEqual(SunPosition.kelvin(for: -90), 2700)
    }

    func testKelvinAtOrAboveCeiling() {
        // Altitude ≥ 45° is capped at 6500K.
        XCTAssertEqual(SunPosition.kelvin(for: 45), 6500)
        XCTAssertEqual(SunPosition.kelvin(for: 60), 6500)
        XCTAssertEqual(SunPosition.kelvin(for: 90), 6500)
    }

    func testKelvinAt30Degrees() {
        // 30° altitude with pow(0.65) ease-in over 45° range → ~5600K
        XCTAssertEqual(SunPosition.kelvin(for: 30), 5600)
    }

    func testKelvinAt15Degrees() {
        // 15° altitude (1/3 of the 45° range) with ease-in → ~4600K
        XCTAssertEqual(SunPosition.kelvin(for: 15), 4600)
    }

    func testKelvinIsMultipleOf100() {
        for altitude in stride(from: -10.0, through: 50.0, by: 2.5) {
            let k = SunPosition.kelvin(for: altitude)
            XCTAssertEqual(k % 100, 0, "kelvin(\(altitude)) = \(k) is not a multiple of 100")
        }
    }

    func testKelvinRange() {
        for altitude in stride(from: -90.0, through: 90.0, by: 5.0) {
            let k = SunPosition.kelvin(for: altitude)
            XCTAssertGreaterThanOrEqual(k, 2700)
            XCTAssertLessThanOrEqual(k, 6500)
        }
    }

    // MARK: kelvin — morning

    func testKelvinMorningFloor() {
        // Morning floor is 3300K — warm but not as extreme as post-sunset 2700K.
        XCTAssertEqual(SunPosition.kelvin(for:  0, isMorning: true), 3300)
        XCTAssertEqual(SunPosition.kelvin(for: -5, isMorning: true), 3300)
    }

    func testKelvinMorningLessWarmThanEveningAtHorizon() {
        // At the horizon, morning (3300K) is cooler than post-sunset evening (2700K).
        // Higher K = less warm/amber.
        let morning = SunPosition.kelvin(for: 0, isMorning: true)
        let evening = SunPosition.kelvin(for: 0, isMorning: false)
        XCTAssertGreaterThan(morning, evening)
    }

    func testKelvinMorningAndEveningBothReachCeiling() {
        // At or above the altitude ceiling both curves converge to 6500K.
        XCTAssertEqual(SunPosition.kelvin(for: 45, isMorning: true),  6500)
        XCTAssertEqual(SunPosition.kelvin(for: 45, isMorning: false), 6500)
        XCTAssertEqual(SunPosition.kelvin(for: 90, isMorning: true),  6500)
    }

    func testKelvinDefaultIsMorningFalse() {
        // isMorning defaults to false — bare call matches the evening curve.
        for alt in [-10.0, 0.0, 15.0, 45.0] {
            XCTAssertEqual(SunPosition.kelvin(for: alt),
                           SunPosition.kelvin(for: alt, isMorning: false))
        }
    }

    func testKelvinMorningRangeValid() {
        for altitude in stride(from: -90.0, through: 90.0, by: 5.0) {
            let k = SunPosition.kelvin(for: altitude, isMorning: true)
            XCTAssertGreaterThanOrEqual(k, 3300)
            XCTAssertLessThanOrEqual(k, 6500)
        }
    }

    // MARK: isRising

    func testIsRisingBeforeSolarNoon() {
        // 06:00 UTC at longitude 0° → hour angle ≈ –90° → rising.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 6))!
        XCTAssertTrue(SunPosition.isRising(latitude: 40, longitude: 0, date: date))
    }

    func testIsRisingAfterSolarNoon() {
        // 18:00 UTC at longitude 0° → hour angle ≈ +90° → setting.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 18))!
        XCTAssertFalse(SunPosition.isRising(latitude: 40, longitude: 0, date: date))
    }

    func testIsRisingSymmetricAroundNoon() {
        // Same number of hours before and after solar noon should give opposite results.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let morning   = cal.date(from: DateComponents(year: 2024, month: 6, day: 21, hour:  8))!
        let afternoon = cal.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 16))!
        XCTAssertTrue( SunPosition.isRising(latitude: 40, longitude: 0, date: morning))
        XCTAssertFalse(SunPosition.isRising(latitude: 40, longitude: 0, date: afternoon))
    }

    // MARK: altitude

    func testSummerNoonHigherThanWinterNoon() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let summerNoon = cal.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 12))!
        let winterNoon = cal.date(from: DateComponents(year: 2024, month: 12, day: 21, hour: 12))!
        let summerAlt = SunPosition.altitude(latitude: 40, longitude: 0, date: summerNoon)
        let winterAlt = SunPosition.altitude(latitude: 40, longitude: 0, date: winterNoon)
        XCTAssertGreaterThan(summerAlt, winterAlt)
        XCTAssertGreaterThan(summerAlt, 0, "Sun should be above horizon at noon on summer solstice")
        XCTAssertGreaterThan(winterAlt, 0, "Sun should be above horizon at noon on winter solstice")
    }

    func testMidnightBelowHorizon() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: 0))!
        let alt = SunPosition.altitude(latitude: 40, longitude: 0, date: midnight)
        XCTAssertLessThan(alt, 0, "Sun should be below horizon at midnight UTC at lon 0")
    }

    func testAltitudeBounded() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        for hour in 0..<24 {
            let date = cal.date(from: DateComponents(year: 2024, month: 6, day: 21, hour: hour))!
            let alt = SunPosition.altitude(latitude: 40, longitude: 0, date: date)
            XCTAssertGreaterThanOrEqual(alt, -90)
            XCTAssertLessThanOrEqual(alt, 90)
        }
    }
}

// MARK: - LitraDevice

final class LitraDeviceTests: XCTestCase {

    func testVendorID() {
        XCTAssertEqual(LitraDevice.vendorID, 0x046D)
    }

    func testSpecsContainKnownPIDs() {
        for pid in [0xC900, 0xC901, 0xB901, 0xC903] {
            XCTAssertNotNil(LitraDevice.specs[pid],
                "Missing spec for PID 0x\(String(pid, radix: 16, uppercase: true))")
        }
    }

    func testGlowSpec() {
        let s = LitraDevice.specs[0xC900]!
        XCTAssertEqual(s.minBrightness, 20)
        XCTAssertEqual(s.maxBrightness, 250)
        XCTAssertEqual(s.commandByte, 0x04)
        XCTAssertEqual(s.interfaceNumber, 0)
    }

    func testBeamSpec() {
        let s = LitraDevice.specs[0xC901]!
        XCTAssertEqual(s.minBrightness, 4)
        XCTAssertEqual(s.maxBrightness, 400)
        XCTAssertEqual(s.commandByte, 0x04)
        XCTAssertEqual(s.interfaceNumber, 0)
    }

    func testBeamAltPIDSpec() {
        let s = LitraDevice.specs[0xB901]!
        XCTAssertEqual(s.minBrightness, 4)
        XCTAssertEqual(s.maxBrightness, 400)
        XCTAssertEqual(s.commandByte, 0x04)
        XCTAssertEqual(s.interfaceNumber, 0)
    }

    func testBeamLXSpec() {
        let s = LitraDevice.specs[0xC903]!
        XCTAssertEqual(s.minBrightness, 30)
        XCTAssertEqual(s.maxBrightness, 400)
        XCTAssertEqual(s.commandByte, 0x06)
        XCTAssertEqual(s.interfaceNumber, 0)
    }

    func testMinBrightnessLessThanMax() {
        for (pid, s) in LitraDevice.specs {
            XCTAssertLessThan(s.minBrightness, s.maxBrightness,
                "PID 0x\(String(pid, radix: 16)): min must be < max")
        }
    }
}

// MARK: - LitraManager

final class LitraManagerTests: XCTestCase {

    private var beamSpec: LitraDevice.Spec { LitraDevice.specs[0xC901]! }
    private func makeMock(id: UInt64 = 1) -> MockLitraDevice {
        MockLitraDevice(spec: beamSpec, id: id)
    }

    // MARK: Initial state

    func testInitialStateDefaults() {
        let m = LitraManager(mockDevices: [])
        XCTAssertFalse(m.isOn)
        XCTAssertEqual(m.brightness, 0.5, accuracy: 0.001)
        XCTAssertEqual(m.temperature, 4000)
        XCTAssertTrue(m.syncEnabled)
        XCTAssertFalse(m.circadianEnabled)
        XCTAssertFalse(m.cameraAutoOn)
    }

    func testMockDevicesInjected() {
        let m = LitraManager(mockDevices: [makeMock(id: 1), makeMock(id: 2)])
        XCTAssertEqual(m.devices.count, 2)
    }

    // MARK: State mutations

    func testSetOn() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.setOn(true)
        XCTAssertTrue(m.isOn)
        m.setOn(false)
        XCTAssertFalse(m.isOn)
    }

    func testSetBrightnessUpdatesState() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.setBrightness(0.75)
        XCTAssertEqual(m.brightness, 0.75, accuracy: 0.001)
    }

    func testSetTemperatureUpdatesState() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.setTemperature(3200)
        XCTAssertEqual(m.temperature, 3200)
    }

    // MARK: HID power reports

    func testHIDPowerOn() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.handleHIDReport([0x11, 0xff, 0x04, 0x00, 0x01, 0x00])
        XCTAssertTrue(m.isOn)
    }

    func testHIDPowerOff() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.setOn(true)
        m.handleHIDReport([0x11, 0xff, 0x04, 0x00, 0x00, 0x00])
        XCTAssertFalse(m.isOn)
    }

    func testHIDPowerNoChangeWhenAlreadyOff() {
        let m = LitraManager(mockDevices: [makeMock()])
        XCTAssertFalse(m.isOn)
        m.handleHIDReport([0x11, 0xff, 0x04, 0x00, 0x00, 0x00])
        XCTAssertFalse(m.isOn)
    }

    // MARK: HID brightness reports

    func testHIDBrightness() {
        let m = LitraManager(mockDevices: [makeMock()])
        // 200 lumens with Beam spec (min=4, max=400) → fraction = 196/396
        let lumens = 200
        m.handleHIDReport([0x11, 0xff, 0x04, 0x10, UInt8(lumens >> 8), UInt8(lumens & 0xff)])
        let expected = Double(lumens - beamSpec.minBrightness) / Double(beamSpec.maxBrightness - beamSpec.minBrightness)
        XCTAssertEqual(m.brightness, expected, accuracy: 0.001)
    }

    func testHIDBrightnessNoDeviceIsIgnored() {
        let m = LitraManager(mockDevices: [])
        let before = m.brightness
        m.handleHIDReport([0x11, 0xff, 0x04, 0x10, 0x00, 0xC8])
        XCTAssertEqual(m.brightness, before, accuracy: 0.001)
    }

    func testHIDBrightnessNoChangeWhenSameFraction() {
        let m = LitraManager(mockDevices: [makeMock()])
        let lumens = 200
        let fraction = Double(lumens - beamSpec.minBrightness) / Double(beamSpec.maxBrightness - beamSpec.minBrightness)
        m.setBrightness(fraction)
        let snapshot = m.brightness
        m.handleHIDReport([0x11, 0xff, 0x04, 0x10, UInt8(lumens >> 8), UInt8(lumens & 0xff)])
        XCTAssertEqual(m.brightness, snapshot, accuracy: 0.0001)
    }

    // MARK: HID temperature reports

    func testHIDTemperature() {
        let m = LitraManager(mockDevices: [makeMock()])
        // 4800K: high=0x12, low=0xC0 (4800 = 0x12C0)
        m.handleHIDReport([0x11, 0xff, 0x04, 0x20, 0x12, 0xC0])
        XCTAssertEqual(m.temperature, 4800)
    }

    func testHIDTemperatureNoChangeWhenSame() {
        let m = LitraManager(mockDevices: [makeMock()])
        // Default temperature is 4000K (0x0FA0)
        m.handleHIDReport([0x11, 0xff, 0x04, 0x20, 0x0F, 0xA0])
        XCTAssertEqual(m.temperature, 4000)
    }

    func testHIDTemperatureClampsToMinimum() {
        let m = LitraManager(mockDevices: [makeMock()])
        // 1000K → clamped to 2700K
        m.handleHIDReport([0x11, 0xff, 0x04, 0x20, 0x03, 0xE8])
        XCTAssertEqual(m.temperature, 2700)
    }

    func testHIDTemperatureClampsToMaximum() {
        let m = LitraManager(mockDevices: [makeMock()])
        // 9000K → clamped to 6500K
        m.handleHIDReport([0x11, 0xff, 0x04, 0x20, 0x23, 0x28])
        XCTAssertEqual(m.temperature, 6500)
    }

    func testHIDTemperatureDisablesCircadianWhenEnabled() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.circadianEnabled = true
        XCTAssertTrue(m.circadianEnabled)
        // 6500K differs from the default temperature (4000K), so the physical-button
        // change is detected and circadian mode is disabled.
        m.handleHIDReport([0x11, 0xff, 0x04, 0x20, 0x19, 0x64])
        XCTAssertFalse(m.circadianEnabled)
    }

    // MARK: HID noise / malformed

    func testHIDCommandEchoNoiseSilentlyIgnored() {
        let m = LitraManager(mockDevices: [makeMock()])
        let before = (m.isOn, m.brightness, m.temperature)
        m.handleHIDReport([0x11, 0xff, 0x04, 0x9c, 0x00, 0x00])
        m.handleHIDReport([0x11, 0xff, 0x04, 0x8e, 0x0A, 0x8C])
        XCTAssertEqual(m.isOn, before.0)
        XCTAssertEqual(m.brightness, before.1, accuracy: 0.001)
        XCTAssertEqual(m.temperature, before.2)
    }

    func testHIDWrongFirstByteIgnored() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.handleHIDReport([0x00, 0xff, 0x04, 0x00, 0x01, 0x00])
        XCTAssertFalse(m.isOn)
    }

    func testHIDWrongSecondByteIgnored() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.handleHIDReport([0x11, 0x00, 0x04, 0x00, 0x01, 0x00])
        XCTAssertFalse(m.isOn)
    }

    func testHIDTooShortIgnored() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.handleHIDReport([0x11, 0xff, 0x04, 0x00, 0x01]) // 5 bytes, needs 6
        XCTAssertFalse(m.isOn)
    }

    func testHIDEmptyIgnored() {
        let m = LitraManager(mockDevices: [makeMock()])
        m.handleHIDReport([])
        XCTAssertFalse(m.isOn)
    }
}
