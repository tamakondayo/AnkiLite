import UIKit

/// Lightweight wrapper around UIKit's feedback generators so views can stay
/// decoupled from UIKit imports.
enum Haptics {

    /// User tapped a non-destructive primary action (e.g. flipping the card).
    static func tap(enabled: Bool = true) {
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred()
    }

    /// User committed an answer (Again/Hard/Good/Easy).
    static func answer(enabled: Bool = true) {
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    /// Success outcome (import complete, session finished).
    static func success(enabled: Bool = true) {
        guard enabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    /// Failure outcome (import failed).
    static func error(enabled: Bool = true) {
        guard enabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }
}
