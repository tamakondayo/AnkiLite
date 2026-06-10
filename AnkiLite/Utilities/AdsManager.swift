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

    /// Hashed device ids that should always receive test ads, EVEN on the
    /// production unit and WITHOUT ATT/IDFA. The SDK prints each device's
    /// id to the Xcode console on the first request:
    ///   "To get test ads on this device, set ... testDeviceIdentifiers = @[ "XXXX" ]"
    /// Paste that value here.
    static let testDeviceIdentifiers: [String] = []
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
    /// IDFA is available (the prompt only appears once per install, and
    /// only while the app is active).
    func start() {
        guard !started else { return }
        started = true
        let current = ATTrackingManager.trackingAuthorizationStatus
        print("📺 [Ads] start — ATT status before request: \(Self.attLabel(current))")
        ATTrackingManager.requestTrackingAuthorization { status in
            print("📺 [Ads] ATT status after request: \(Self.attLabel(status))")
            Task { @MainActor in
                if !AdConfig.testDeviceIdentifiers.isEmpty {
                    GADMobileAds.sharedInstance().requestConfiguration
                        .testDeviceIdentifiers = AdConfig.testDeviceIdentifiers
                    print("📺 [Ads] using test device ids: \(AdConfig.testDeviceIdentifiers)")
                }
                GADMobileAds.sharedInstance().start { status in
                    let adapters = status.adapterStatusesByClassName
                        .map { "\($0.key)=\($0.value.state == .ready ? "ready" : "not ready")" }
                        .joined(separator: ", ")
                    print("📺 [Ads] SDK started (\(adapters))")
                    Task { @MainActor in self.loadAd() }
                }
            }
        }
    }

    private func loadAd() {
        guard interstitial == nil, !isLoading else { return }
        isLoading = true
        print("📺 [Ads] loading interstitial \(AdConfig.interstitialUnitID)…")
        GADInterstitialAd.load(withAdUnitID: AdConfig.interstitialUnitID,
                               request: GADRequest()) { [weak self] ad, error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                if let ad {
                    print("📺 [Ads] interstitial loaded ✔")
                    ad.fullScreenContentDelegate = self
                    self.interstitial = ad
                } else if let error {
                    // Benign reasons include no fill and offline; the next
                    // showInterstitial() attempt re-triggers a load.
                    print("📺 [Ads] load failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Present the interstitial if one is ready and the cooldown allows it.
    func showInterstitial() {
        guard started else {
            print("📺 [Ads] show skipped — SDK not started")
            return
        }
        if let last = lastShownAt, Date().timeIntervalSince(last) < AdConfig.minimumInterval {
            print("📺 [Ads] show skipped — cooldown (\(Int(Date().timeIntervalSince(last)))s since last)")
            return
        }
        guard let ad = interstitial else {
            print("📺 [Ads] show skipped — no ad loaded yet, requesting one")
            loadAd() // be ready for the next completion
            return
        }
        guard let root = Self.rootViewController() else {
            print("📺 [Ads] show skipped — no root view controller")
            return
        }
        print("📺 [Ads] presenting interstitial")
        lastShownAt = Date()
        interstitial = nil
        ad.present(fromRootViewController: root)
    }

    private static func attLabel(_ s: ATTrackingManager.AuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(s.rawValue))"
        }
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
