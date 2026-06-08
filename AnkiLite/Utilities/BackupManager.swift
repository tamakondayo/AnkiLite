import Foundation
import ZIPFoundation

/// Manages periodic backups of the app's SQLite database and media folder.
///
/// Backups are written as zip archives to the user-visible `Documents/Backups`
/// directory (so they show up in the Files app and can be moved to iCloud
/// Drive). When `iCloudEnabled` is on AND the iCloud container is reachable,
/// each new backup is also copied into the iCloud container.
final class BackupManager {
    static let shared = BackupManager()

    private let fm = FileManager.default
    private let backupSubdir = "Backups"
    private let maxGenerations = 7
    private let lastBackupKey = "lastBackupAt"

    /// All previously written backup URLs in the local Documents folder,
    /// newest first.
    func listBackups() -> [URL] {
        let dir = localBackupsDirectory()
        let urls = (try? fm.contentsOfDirectory(at: dir,
                                                includingPropertiesForKeys: [.creationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "zip" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    /// The timestamp of the most recent successful backup, or nil.
    var lastBackupDate: Date? {
        UserDefaults.standard.object(forKey: lastBackupKey) as? Date
    }

    /// If the last backup is older than 24 hours, run a new one.
    /// The actual work runs on a background queue so a large collection
    /// can't stall app launch.
    func runIfDue(iCloudEnabled: Bool) {
        let last = lastBackupDate ?? .distantPast
        if Date().timeIntervalSince(last) < 24 * 3600 { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.performBackup(iCloudEnabled: iCloudEnabled)
        }
    }

    /// Always run a backup, regardless of the last-backup timestamp.
    @discardableResult
    func performBackup(iCloudEnabled: Bool) throws -> URL {
        let backupsDir = localBackupsDirectory()
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let stamp = Self.timestampFormatter.string(from: Date())
        let outURL = backupsDir.appendingPathComponent("AnkiLite-\(stamp).zip")

        // Source: SQLite + media folder.
        let dbURL = try DatabaseManager.defaultDatabaseURL()
        let mediaDir = MediaManager.shared.mediaDirectory

        // Build the archive in a temp location then move into place atomically.
        let tempURL = fm.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString).zip")
        let archive: Archive
        do {
            archive = try Archive(url: tempURL, accessMode: .create)
        } catch {
            throw NSError(domain: "BackupManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "バックアップアーカイブを作成できませんでした。"
            ])
        }
        if fm.fileExists(atPath: dbURL.path) {
            try archive.addEntry(with: "collection.sqlite",
                                 fileURL: dbURL,
                                 compressionMethod: .deflate)
        }
        if fm.fileExists(atPath: mediaDir.path) {
            let files = (try? fm.contentsOfDirectory(atPath: mediaDir.path)) ?? []
            for file in files {
                // Skip our scratch HTML files.
                if file.hasPrefix("__card_") { continue }
                let fileURL = mediaDir.appendingPathComponent(file)
                try archive.addEntry(with: "media/\(file)",
                                     fileURL: fileURL,
                                     compressionMethod: .deflate)
            }
        }

        try? fm.removeItem(at: outURL)
        try fm.moveItem(at: tempURL, to: outURL)

        // Mirror into iCloud if requested and available.
        if iCloudEnabled, let cloudDir = iCloudBackupsDirectory() {
            try? fm.createDirectory(at: cloudDir, withIntermediateDirectories: true)
            let cloudURL = cloudDir.appendingPathComponent(outURL.lastPathComponent)
            try? fm.removeItem(at: cloudURL)
            try? fm.copyItem(at: outURL, to: cloudURL)
        }

        pruneOld()
        UserDefaults.standard.set(Date(), forKey: lastBackupKey)
        return outURL
    }

    /// Removes backups beyond `maxGenerations`.
    private func pruneOld() {
        let existing = listBackups()
        for old in existing.dropFirst(maxGenerations) {
            try? fm.removeItem(at: old)
        }
    }

    // MARK: - Locations

    /// The user-visible Documents/Backups folder.
    func localBackupsDirectory() -> URL {
        let documents = try? fm.url(for: .documentDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        let base = documents ?? fm.temporaryDirectory
        return base.appendingPathComponent(backupSubdir, isDirectory: true)
    }

    /// The iCloud Drive backups folder, if iCloud is configured for this app.
    /// Nil when the app does not have an iCloud container (e.g. free
    /// Personal Team profiles).
    func iCloudBackupsDirectory() -> URL? {
        guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return nil }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(backupSubdir, isDirectory: true)
    }

    // MARK: - Helpers

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
