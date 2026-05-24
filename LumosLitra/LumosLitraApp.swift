import SwiftUI

@main
struct LumosLitraApp: App {
    // @StateObject creates the manager once and keeps it alive for the app's lifetime.
    @StateObject private var litra = LitraManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(litra)  // makes `litra` available to all child views
        } label: {
            Image(systemName: "lightbulb.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
