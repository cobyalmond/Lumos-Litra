import Foundation

// NOAA solar position algorithm.
// Returns solar altitude (elevation) in degrees above the horizon.
// Positive = sun is up, negative = sun is below horizon.
enum SunPosition {
    static func altitude(latitude: Double, longitude: Double, date: Date = .now) -> Double {
        let jd  = julianDay(date)
        let jc  = (jd - 2451545.0) / 36525.0  // Julian century from J2000.0

        // Geometric mean longitude and anomaly of the sun
        let l0 = (280.46646 + jc * (36000.76983 + jc * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let m  = 357.52911 + jc * (35999.05029 - 0.0001537 * jc)

        // Equation of center
        let mr = rad(m)
        let c  = sin(mr)     * (1.914602 - jc * (0.004817 + 0.000014 * jc))
               + sin(2 * mr) * (0.019993 - 0.000101 * jc)
               + sin(3 * mr) * 0.000289

        // Apparent sun longitude (corrected for aberration)
        let omega  = 125.04 - 1934.136 * jc
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(rad(omega))

        // Obliquity of the ecliptic (corrected)
        let eps0 = 23.0 + (26.0 + (21.448 - jc * (46.8150 + jc * (0.00059 - jc * 0.001813))) / 60) / 60
        let eps  = eps0 + 0.00256 * cos(rad(omega))

        // Sun's declination
        let decl = deg(asin(sin(rad(eps)) * sin(rad(lambda))))

        // Equation of time (minutes) — using Earth orbital eccentricity ≈ 0.0167
        let e    = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)
        let y    = tan(rad(eps / 2))
        let y2   = y * y
        let l0r  = rad(l0)
        let eot  = deg(4 * (y2 * sin(2 * l0r)
                   - 2 * e * sin(mr)
                   + 4 * e * y2 * sin(mr) * cos(2 * l0r)
                   - 0.5 * y2 * y2 * sin(4 * l0r)
                   - 1.25 * e * e * sin(2 * mr)))

        // True solar time (minutes since midnight UTC, adjusted for longitude)
        let utcMinutes = utcMinuteOfDay(date)
        var tst = (utcMinutes + eot + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if tst < 0 { tst += 1440 }

        // Hour angle (degrees, negative = before solar noon)
        var ha = tst / 4.0 - 180.0
        if ha < -180 { ha += 360 }

        // Solar altitude = arcsin(sin φ sin δ + cos φ cos δ cos H)
        let sinAlt = sin(rad(latitude)) * sin(rad(decl))
                   + cos(rad(latitude)) * cos(rad(decl)) * cos(rad(ha))
        return deg(asin(max(-1, min(1, sinAlt))))
    }
}

// MARK: - Circadian mapping

extension SunPosition {
    // Maps solar altitude to a color temperature.
    //   altitude ≤   0°  →  2700 K (warm; sun at or below horizon)
    //   altitude ≥  30°  →  5500 K (cool; sun well overhead)
    static func kelvin(for altitude: Double) -> Int {
        let t = (altitude / 30.0).clamped(to: 0...1)
        let raw = 2700.0 + t * 2800.0
        return Int((raw / 100).rounded()) * 100
    }
}

// MARK: - Private helpers

private func julianDay(_ date: Date) -> Double {
    // Reduce date to UTC components
    var cal  = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    var y = Double(comps.year!), m = Double(comps.month!)
    let d = Double(comps.day!)
    let h = Double(comps.hour!) + Double(comps.minute!) / 60 + Double(comps.second!) / 3600
    if m <= 2 { y -= 1; m += 12 }
    let A = floor(y / 100)
    let B = 2 - A + floor(A / 4)
    return floor(365.25 * (y + 4716)) + floor(30.6001 * (m + 1)) + d + h / 24 + B - 1524.5
}

private func utcMinuteOfDay(_ date: Date) -> Double {
    var cal  = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let comps = cal.dateComponents([.hour, .minute, .second], from: date)
    return Double(comps.hour!) * 60 + Double(comps.minute!) + Double(comps.second!) / 60
}

private func rad(_ d: Double) -> Double { d * .pi / 180 }
private func deg(_ r: Double) -> Double { r * 180 / .pi }

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { max(r.lowerBound, min(r.upperBound, self)) }
}
