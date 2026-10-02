import SwiftUI

@main
struct VPNSpawnerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { DispatchQueue.main.async { KeyboardDismissTap.shared.install() } }
        }
    }
}
