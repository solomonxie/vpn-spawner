import SwiftUI

struct ContentView: View {
    @StateObject private var manager = SessionManager()

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        if let session = manager.currentSession {
                            SessionCardView(manager: manager, session: session)
                        } else {
                            LaunchCardView(manager: manager)
                        }
                    }
                    .padding()
                }
                .navigationTitle("VPN Spawner")
                .refreshable {
                    await manager.reconcileSession()
                }
            }
            .tabItem {
                Label("Session", systemImage: "bolt.shield")
            }

            HistoryView(manager: manager)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
