import SwiftUI

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
            // Power toggle
            HStack {
                Label("Lights", systemImage: litra.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { litra.isOn },
                    set: { litra.setOn($0) }
                ))
                .labelsHidden()
            }

            Divider()

            // Brightness — always enabled so you can set a level before turning on
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

            // Color temperature — disabled only when circadian is driving it
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

            // Circadian toggle — always enabled so you can arm it before turning on
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
