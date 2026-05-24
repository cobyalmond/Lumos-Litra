import SwiftUI

@main
struct LumosLitraApp: App {
    @StateObject private var litra = LitraManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(litra)
        } label: {
            // Filled + temperature color = on; outline + default = off
            Image(systemName: litra.isOn ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(litra.isOn ? Color.kelvin(litra.temperature) : .primary)
        }
        .menuBarExtraStyle(.window)
    }
}
