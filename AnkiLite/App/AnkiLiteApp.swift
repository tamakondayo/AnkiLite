import SwiftUI
import UIKit

@main
struct AnkiLiteApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var importBus = IncomingImportBus()

    init() {
        Self.applyGlobalAppearance()
    }

    /// iOS 26 doesn't let SwiftUI's `.background()` paint past the
    /// horizontal safe-area gutters on its own — the system fills those
    /// strips with the window's UIKit background, which defaults to black.
    /// We override the window background here, plus the navigation bar
    /// and any scroll view background, so the whole surface stays one
    /// consistent colour.
    private static func applyGlobalAppearance() {
        let bg = UIColor(Theme.background)

        // The window itself (kills the side gutters).
        UIWindow.appearance().backgroundColor = bg

        // Navigation bar — opaque so iOS 26's translucent material
        // doesn't blend in the system colour.
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().compactScrollEdgeAppearance = nav

        // Lists / Forms come with their own backing UIScrollView, which
        // can also show through if we don't make it transparent.
        UIScrollView.appearance().backgroundColor = .clear
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
    }

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
                    // Cold-launch sweep for orphan scratch HTML files
                    // that a crashed previous session may have left behind.
                    MediaManager.shared.sweepScratchFiles()
                    // Boot AdMob (ATT prompt + first interstitial preload).
                    AdsManager.shared.start()
                }
        }
    }
}

/// Top-level container. Currently the deck list is the sole root; a tab bar
/// can be added here as more sections (browser, stats) graduate from P1.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            // Paint the entire window — including the horizontal safe areas
            // around the dynamic island / home indicator — so iOS 26's
            // default system background doesn't show through as black bands
            // on either side of the navigation content.
            Theme.background
                .ignoresSafeArea(.all, edges: .all)
            DeckListView(settings: settings)
        }
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
