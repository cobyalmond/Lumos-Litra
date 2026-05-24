import SwiftUI

// Maps a Kelvin color temperature to an approximate screen color.
// 2700K → rich amber, 4000K → golden yellow, 6500K → near-white
extension Color {
    static func kelvin(_ k: Int) -> Color {
        let t = (Double(k - 2700) / Double(6500 - 2700)).clamped(to: 0...1)
        return Color(hue: 0.09 + t * 0.05,       // amber → warm yellow
                     saturation: 0.9 - t * 0.82,  // rich → near-white
                     brightness: 1.0)
    }
}

private extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { max(r.lowerBound, min(r.upperBound, self)) }
}

struct MenuBarView: View {
    @EnvironmentObject var litra: LitraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if litra.devices.isEmpty {
                noLightsView
            } else {
                controlsView
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    // MARK: - Subviews

    private var noLightsView: some View {
        VStack(spacing: 6) {
            Image(systemName: "lightbulb.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No lights connected")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var controlsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Power toggle — icon and track both reflect temperature when on
            HStack {
                Image(systemName: litra.isOn ? "lightbulb.fill" : "lightbulb")
                    .foregroundStyle(litra.isOn ? Color.kelvin(litra.temperature) : .secondary)
                    .font(.headline)
                Text("Lights")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { litra.isOn },
                    set: { litra.setOn($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Color.kelvin(litra.temperature))
            }

            Divider()

            // Brightness
            VStack(alignment: .leading, spacing: 6) {
                Label("Brightness", systemImage: "sun.max")
                    .font(.subheadline)

                Slider(
                    value: Binding(
                        get: { litra.brightness },
                        set: { litra.setBrightness($0) }
                    ),
                    in: 0...1
                )
            }

            // Color temperature — disabled when circadian is active
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Temperature", systemImage: "thermometer.medium")
                        .font(.subheadline)
                        .foregroundStyle(litra.circadianEnabled ? .secondary : .primary)
                    Spacer()
                    Text("\(litra.temperature)K")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { Double(litra.temperature) },
                        set: { litra.setTemperature(Int($0)) }
                    ),
                    in: 2700...6500,
                    step: 100
                )
                .disabled(litra.circadianEnabled)

                HStack {
                    Text("Warm")
                    Spacer()
                    Text("Cool")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            // Circadian toggle
            HStack(spacing: 8) {
                Label("Circadian", systemImage: "sun.and.horizon")
                    .font(.subheadline)
                Spacer()
                if litra.circadianEnabled {
                    Text("\(litra.solarAltitude >= 0 ? "+" : "")\(Int(litra.solarAltitude))°")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Toggle("", isOn: Binding(
                    get: { litra.circadianEnabled },
                    set: { litra.circadianEnabled = $0 }
                ))
                .labelsHidden()
            }

            // Device count
            Text("\(litra.devices.count) light\(litra.devices.count == 1 ? "" : "s") connected")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
    }
}
