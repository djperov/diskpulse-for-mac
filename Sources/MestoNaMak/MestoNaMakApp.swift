import SwiftUI
import AppKit

@main
struct MestoNaMakApp: App {
    @StateObject private var viewModel = DiskMonitorViewModel()

    init() {
        // Swift Package executables do not always become foreground apps when
        // launched from Xcode. Make the window visible like a normal .app.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("DiskPulse for Mac") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 820, minHeight: 560)
        }
    }
}
