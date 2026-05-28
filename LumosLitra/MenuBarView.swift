import SwiftUI
import ServiceManagement

private struct GradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let stops: [Gradient.Stop]
    var disabled: Bool = false

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let usableWidth = geo.size.width - thumbSize
            let fraction = ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)

            ZStack(alignment: .leading) {
                LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                    .frame(height: trackHeight)
                    .clipShape(Capsule())
                    .padding(.horizontal, thumbSize / 2)
                    .opacity(disabled ? 0.4 : 1)

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: fraction * Double(usableWidth))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard !disabled else { return }
                        let raw = (Double(drag.location.x) - Double(thumbSize) / 2) / Double(usableWidth)
                        var v = range.lowerBound + raw.clamped(to: 0...1) * (range.upperBound - range.lowerBound)
                        if let step { v = (v / step).rounded() * step }
                        value = v.clamped(to: range)
                    }
            )
        }
        .frame(height: thumbSize)
    }
}

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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if litra.devices.isEmpty {
                noLightsView
            } else {
                controlsView
            }

            Divider()

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else       { try SMAppService.mainApp.unregister() }
                    } catch {
                        print("[LumosLitra] Launch at login: \(error)")
                        launchAtLogin = !enabled  // revert on failure
                    }
                }

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 6)

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

                GradientSlider(
                    value: Binding(
                        get: { litra.brightness },
                        set: { litra.setBrightness($0) }
                    ),
                    range: 0...1,
                    stops: [
                        .init(color: Color(white: 0.08), location: 0),
                        .init(color: .white, location: 1)
                    ]
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

                GradientSlider(
                    value: Binding(
                        get: { Double(litra.temperature) },
                        set: { litra.setTemperature(Int($0)) }
                    ),
                    range: 2700...6500,
                    step: 100,
                    stops: [2700, 3300, 4000, 4800, 5600, 6500].map { k in
                        .init(color: .kelvin(k), location: Double(k - 2700) / Double(6500 - 2700))
                    },
                    disabled: litra.circadianEnabled
                )

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

            // Camera auto-on
            HStack(spacing: 8) {
                Label("Camera auto-on", systemImage: "camera")
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { litra.cameraAutoOn },
                    set: { litra.cameraAutoOn = $0 }
                ))
                .labelsHidden()
            }

            // Sync toggle — only relevant with multiple lights
            if litra.devices.count > 1 {
                HStack(spacing: 8) {
                    Label("Button sync", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { litra.syncEnabled },
                        set: { litra.syncEnabled = $0 }
                    ))
                    .labelsHidden()
                }
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
