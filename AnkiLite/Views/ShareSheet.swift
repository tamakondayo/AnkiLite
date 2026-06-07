import SwiftUI
import UIKit

/// Identifiable wrapper for a URL so `sheet(item:)` can drive presentation.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Bridges `UIActivityViewController` into SwiftUI for the standard iOS
/// share sheet (save to Files, AirDrop, send by mail, etc.).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
