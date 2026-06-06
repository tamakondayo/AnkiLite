import Foundation

/// Manages media files (images, audio) extracted from apkg packages.
///
/// Anki stores media inside the package as numbered files (`0`, `1`, ...)
/// with a `media` JSON manifest mapping those numbers to original file names.
/// We copy them into the app sandbox keyed by their original names.
final class MediaManager {
    static let shared = MediaManager()

    let mediaDirectory: URL

    init(mediaDirectory: URL? = nil) {
        if let mediaDirectory {
            self.mediaDirectory = mediaDirectory
        } else {
            let fm = FileManager.default
            let support = (try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true))
                ?? fm.temporaryDirectory
            self.mediaDirectory = support
                .appendingPathComponent("AnkiLite", isDirectory: true)
                .appendingPathComponent("media", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.mediaDirectory,
                                                 withIntermediateDirectories: true)
    }

    /// Parses the `media` manifest data into a [number: filename] map.
    func parseManifest(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var map: [String: String] = [:]
        for (key, value) in object {
            if let name = value as? String {
                map[key] = name
            }
        }
        return map
    }

    /// Copies media into the sandbox.
    /// - Parameters:
    ///   - manifest: [number: filename] map from `parseManifest`.
    ///   - fileProvider: returns the raw bytes for a given numbered entry.
    func importMedia(manifest: [String: String],
                     fileProvider: (String) -> Data?) {
        for (number, filename) in manifest {
            guard let data = fileProvider(number) else { continue }
            let destination = url(forMediaNamed: filename)
            try? data.write(to: destination)
        }
    }

    /// The on-disk URL for a media file (by its original name).
    func url(forMediaNamed name: String) -> URL {
        // Sanitize to avoid path traversal from malicious manifests.
        let safe = name.replacingOccurrences(of: "/", with: "_")
                       .replacingOccurrences(of: "..", with: "_")
        return mediaDirectory.appendingPathComponent(safe)
    }

    /// Whether a media file exists locally.
    func mediaExists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forMediaNamed: name).path)
    }

    /// Removes all stored media (used when clearing the collection).
    func clearAll() {
        try? FileManager.default.removeItem(at: mediaDirectory)
        try? FileManager.default.createDirectory(at: mediaDirectory,
                                                 withIntermediateDirectories: true)
    }
}
