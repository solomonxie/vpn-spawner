import SwiftUI

/// One page: the screen is whatever state the session is in.
struct ContentView: View {
    @StateObject private var manager = SessionManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDataUse = !DataUseView.isAccepted

    var body: some View {
        NavigationStack {
            Group {
                if let session = manager.currentSession {
                    switch session.status {
                    case .ready:
                        ReadyView(manager: manager, session: session)
                    case .stopping:
                        StoppingView(manager: manager, session: session)
                    case .failed:
                        FailedView(manager: manager, session: session)
                    default:
                        ProvisioningView(manager: manager, session: session)
                    }
                } else {
                    IdleView(manager: manager)
                }
            }
            .animation(.default, value: manager.currentSession?.status)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("VPN Spawner")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await manager.resume()
                await manager.reconcileSession()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await manager.resume() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(manager: manager)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .fullScreenCover(isPresented: $showDataUse) {
            NavigationStack {
                DataUseView { showDataUse = false }
            }
            .interactiveDismissDisabled()
        }
    }
}
