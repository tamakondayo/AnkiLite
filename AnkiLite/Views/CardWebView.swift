import SwiftUI
import WebKit

/// Renders a card's HTML inside a WKWebView.
///
/// Media files cannot be loaded by `loadHTMLString`, so we write a temporary
/// HTML file into a directory that also contains (links to) the media, and
/// load it with `loadFileURL`, granting read access to the media directory.
struct CardWebView: UIViewRepresentable {

    /// Inner rendered HTML (already template-processed).
    let bodyHTML: String
    /// Note type CSS.
    let userCSS: String
    /// Whether to apply the night-mode body class.
    let nightMode: Bool
    /// Base body font size, in CSS pixels.
    let fontSize: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = Self.wrap(body: bodyHTML, userCSS: userCSS, nightMode: nightMode, fontSize: fontSize)
        let mediaDir = MediaManager.shared.mediaDirectory

        // Write the HTML into the media directory so relative media URLs resolve.
        let fileURL = mediaDir.appendingPathComponent("__card_\(context.coordinator.id).html")
        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            webView.loadFileURL(fileURL, allowingReadAccessTo: mediaDir)
        } catch {
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator {
        let id = UUID().uuidString
    }

    // MARK: - HTML wrapping

    /// The whether `userCSS` already styles `.night_mode` itself.
    static func userCSSHandlesNightMode(_ css: String) -> Bool {
        css.contains(".night_mode") || css.contains(".nightMode")
    }

    static func wrap(body: String, userCSS: String, nightMode: Bool, fontSize: Int) -> String {
        let nightClass = nightMode ? "night_mode" : ""
        return """
        <!DOCTYPE html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
        html, body {
          margin: 0;
          padding: 20px 18px;
          min-height: 100%;
          box-sizing: border-box;
        }
        body {
          font-family: -apple-system, "Hiragino Sans", BlinkMacSystemFont, sans-serif;
          font-size: \(fontSize)px;
          line-height: 1.6;
          text-align: center;
          color: #2b2b2b;
          background-color: transparent;
          word-wrap: break-word;
          -webkit-text-size-adjust: 100%;
          -webkit-tap-highlight-color: transparent;
        }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        body.night_mode { color: #ececec; }
        body.night_mode img { opacity: 0.92; }
        .cloze { font-weight: 600; color: #3f6f9d; }
        body.night_mode .cloze { color: #7fa8d0; }
        hr { border: none; border-top: 1px solid rgba(128,128,128,0.25); margin: 22px 0; }
        audio { width: 100%; max-width: 320px; margin: 10px 0; }
        a.hint { color: #5b7a9d; text-decoration: none; }
        .missing-media {
          display: inline-block; color: #999;
          border: 1px dashed rgba(128,128,128,0.4);
          padding: 6px 12px; border-radius: 8px;
          font-size: 0.85em;
        }
        /* User CSS */
        \(userCSS)
        </style>
        </head>
        <body class="\(nightClass)">
        \(body)
        </body>
        </html>
        """
    }
}
