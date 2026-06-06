import SwiftUI

@main
struct AnkiLiteApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Theme.accent)
        }
    }
}

/// Top-level container. Currently the deck list is the sole root; a tab bar
/// can be added here as more sections (browser, stats) graduate from P1.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        DeckListView(settings: settings)
    }
}
