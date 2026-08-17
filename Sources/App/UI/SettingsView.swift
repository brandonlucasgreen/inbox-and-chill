import SwiftUI

/// Settings shell (M0). Real panes land with their features.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        TabView {
            Form {
                Picker("Menu bar badge", selection: $state.badgeStyle) {
                    Text("High-signal count").tag(BadgeStyle.highSignalCount)
                    Text("Total count").tag(BadgeStyle.totalCount)
                    Text("Dot").tag(BadgeStyle.dot)
                    Text("None").tag(BadgeStyle.none)
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Text("Sources — coming in M1")
                .tabItem { Label("Sources", systemImage: "tray.2") }
        }
        .frame(width: 480, height: 320)
    }
}
