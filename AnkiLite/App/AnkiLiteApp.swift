import SwiftUI

@main
struct AnkiLiteApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var importBus = IncomingImportBus()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(importBus)
                .environment(\.locale, settings.locale)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(Theme.accent)
                .onOpenURL { url in
                    importBus.receive(url: url)
                }
                .task {
                    // Daily backup check (no-op if last backup is fresh).
                    BackupManager.shared.runIfDue(iCloudEnabled: settings.iCloudBackup)
                }
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

/// Broadcasts incoming apkg URLs (Open-in, AirDrop, Files) to whatever
/// view wants to drive the import flow.
final class IncomingImportBus: ObservableObject {
    /// The next URL waiting to be imported. Set by `receive(url:)`, cleared
    /// once the importer picks it up.
    @Published var pendingURL: URL?

    /// Stage an apkg URL. Copies it into the temp directory first so we
    /// keep access after the security-scoped resource is released.
    func receive(url: URL) {
        guard url.pathExtension.lowercased() == "apkg" else { return }
        if let copied = try? FileHelper.copyToTemporary(url) {
            pendingURL = copied
        } else {
            pendingURL = url
        }
    }
}
