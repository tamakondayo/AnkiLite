import Foundation
import GoogleMobileAds
import AppTrackingTransparency
import UIKit

/// All AdMob identifiers in one place.
///
/// Debug builds (⌘R from Xcode) always use Google's official TEST unit id —
/// tapping or repeatedly showing your own production ads counts as invalid
/// traffic and can get the AdMob account suspended. Release builds
/// (TestFlight / App Store) serve the production unit.
/// The application id lives in `AnkiLite/Info.plist` (GADApplicationIdentifier).
enum AdConfig {
    #if DEBUG
    /// Google's official interstitial TEST unit id.
    static let interstitialUnitID = "ca-app-pub-3940256099942544/4411468910"
    #else
    /// Production interstitial unit.
    static let interstitialUnitID = "ca-app-pub-3357693184634020/3250049675"
    #endif
    /// Minimum seconds between two interstitials, so finishing several
    /// small decks back-to-back doesn't chain-fire ads.
    static let minimumInterval: TimeInterval = 180
}

/// Loads and presents the deck-completion interstitial.
///
/// Lifecycle: `start()` once at launch (requests App Tracking Transparency,
/// boots the SDK, preloads the first ad). `showInterstitial()` whenever a
/// study session finishes — it no-ops unless an ad is loaded and the
/// cooldown has passed, then reloads for the next opportunity.
@MainActor
final class AdsManager: NSObject, ObservableObject {
    static let shared = AdsManager()

    private var interstitial: GADInterstitialAd?
    private var lastShownAt: Date?
    private var isLoading = false
    private var started = false

    /// Boot the SDK. ATT is requested first so the SDK knows whether the
    /// IDFA is available (the prompt only appears once per install).
    func start() {
        guard !started else { return }
        started = true
        ATTrackingManager.requestTrackingAuthorization { _ in
            Task { @MainActor in
                GADMobileAds.sharedInstance().start { _ in
                    Task { @MainActor in self.loadAd() }
                }
            }
        }
    }

    private func loadAd() {
        guard interstitial == nil, !isLoading else { return }
        isLoading = true
        GADInterstitialAd.load(withAdUnitID: AdConfig.interstitialUnitID,
                               request: GADRequest()) { [weak self] ad, error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                if let ad {
                    ad.fullScreenContentDelegate = self
                    self.interstitial = ad
                } else if error != nil {
                    // Loading fails for benign reasons (no fill, offline).
                    // The next showInterstitial() attempt re-triggers a load.
                }
            }
        }
    }

    /// Present the interstitial if one is ready and the cooldown allows it.
    func showInterstitial() {
        guard started else { return }
        if let last = lastShownAt, Date().timeIntervalSince(last) < AdConfig.minimumInterval {
            return
        }
        guard let ad = interstitial else {
            loadAd() // be ready for the next completion
            return
        }
        guard let root = Self.rootViewController() else { return }
        lastShownAt = Date()
        interstitial = nil
        ad.present(fromRootViewController: root)
    }

    private static func rootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

extension AdsManager: GADFullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        Task { @MainActor in self.loadAd() }
    }

    nonisolated func ad(_ ad: GADFullScreenPresentingAd,
                        didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in
            self.interstitial = nil
            self.loadAd()
        }
    }
}
