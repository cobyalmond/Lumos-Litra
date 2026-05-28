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

private struct MenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .frame(width: 18, alignment: .center)
            configuration.title
        }
    }
}

private struct HoverRow<Content: View>: View {
    @State private var isHovered = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovered ? 0.06 : 0))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
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

            HoverRow {
                HStack(spacing: 8) {
                    Label("Launch at Login", systemImage: "power")
                        .font(.body)
                        .labelStyle(MenuLabelStyle())
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .allowsHitTesting(false)
                }
            }
            .onTapGesture {
                let next = !launchAtLogin
                do {
                    if next { try SMAppService.mainApp.register() }
                    else    { try SMAppService.mainApp.unregister() }
                    launchAtLogin = next
                } catch {
                    print("[LumosLitra] Launch at login: \(error)")
                }
            }
            .padding(.top, 3)

            Divider()
                .padding(.horizontal, 16)

            HoverRow {
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.rectangle")
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .center)
                            Text("Quit LumosLitra")
                        }
                        Spacer()
                        Text("⌘Q")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .font(.body)
            }
            .padding(.bottom, 3)
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
                .font(.body)
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

            HStack {
                Text("Status")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("\(litra.devices.count) light\(litra.devices.count == 1 ? "" : "s") connected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // Brightness
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Brightness", systemImage: "sun.max")
                        .font(.body)
                        .labelStyle(MenuLabelStyle())
                    Spacer()
                    let totalLumens = litra.devices.reduce(0) { sum, device in
                        sum + device.spec.minBrightness + Int(litra.brightness * Double(device.spec.maxBrightness - device.spec.minBrightness))
                    }
                    Text("\(totalLumens) lumens")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

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
                        .font(.body)
                        .labelStyle(MenuLabelStyle())
                        .foregroundStyle(litra.circadianEnabled ? .secondary : .primary)
                    Spacer()
                    Text("\(litra.temperature)K")
                        .font(.callout)
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
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            // Circadian toggle
            HoverRow {
                HStack(spacing: 8) {
                    Label("Circadian Mode", systemImage: "sun.and.horizon")
                        .font(.body)
                        .labelStyle(MenuLabelStyle())
                    Spacer()
                    if litra.circadianEnabled {
                        Text("\(litra.solarAltitude >= 0 ? "+" : "")\(Int(litra.solarAltitude))°")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Toggle("", isOn: Binding(
                        get: { litra.circadianEnabled },
                        set: { litra.circadianEnabled = $0 }
                    ))
                    .labelsHidden()
                    .allowsHitTesting(false)
                }
            }
            .onTapGesture { litra.circadianEnabled.toggle() }
            .padding(.horizontal, -16)

            // Camera auto-on
            HoverRow {
                HStack(spacing: 8) {
                    Label("Camera auto-on", systemImage: "video")
                        .font(.body)
                        .labelStyle(MenuLabelStyle())
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { litra.cameraAutoOn },
                        set: { litra.cameraAutoOn = $0 }
                    ))
                    .labelsHidden()
                    .allowsHitTesting(false)
                }
            }
            .onTapGesture { litra.cameraAutoOn.toggle() }
            .padding(.horizontal, -16)

            // Sync toggle — only relevant with multiple lights
            if litra.devices.count > 1 {
                HoverRow {
                    HStack(spacing: 8) {
                        Label("Button sync", systemImage: "arrow.left.arrow.right")
                            .font(.body)
                            .labelStyle(MenuLabelStyle())
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { litra.syncEnabled },
                            set: { litra.syncEnabled = $0 }
                        ))
                        .labelsHidden()
                        .allowsHitTesting(false)
                    }
                }
                .onTapGesture { litra.syncEnabled.toggle() }
                .padding(.horizontal, -16)
            }

        }
        .padding(16)
    }
}
