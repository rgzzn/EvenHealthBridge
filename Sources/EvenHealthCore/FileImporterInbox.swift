import Foundation

/// Removes only ZIP copies that iOS placed in this app's `Documents/Inbox`.
/// It never touches the original file selected in Files or any other directory.
public struct FileImporterInbox: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    public static func currentAppInbox(fileManager: FileManager = .default) -> Self? {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return Self(folder: documents.appendingPathComponent("Inbox", isDirectory: true))
    }

    /// Discards older app-owned copies before the next analysis begins.
    /// The current input is excluded until its analysis has finished.
    public func discardCopies(except keptURL: URL? = nil, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: folder.path) else { return }
        let kept = keptURL.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        for candidate in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            guard isOwnedZIP(candidate, fileManager: fileManager) else { continue }
            if let kept, candidate.standardizedFileURL.resolvingSymlinksInPath() == kept { continue }
            try fileManager.removeItem(at: candidate)
        }
    }

    /// Returns false for a URL outside this app's Inbox, leaving it untouched.
    @discardableResult
    public func discardIfOwnedCopy(_ url: URL, fileManager: FileManager = .default) throws -> Bool {
        guard isOwnedZIP(url, fileManager: fileManager) else { return false }
        try fileManager.removeItem(at: url)
        return true
    }

    private func isOwnedZIP(_ url: URL, fileManager: FileManager) -> Bool {
        let resolvedFolder = folder.resolvingSymlinksInPath().path
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedURL.deletingLastPathComponent().path == resolvedFolder,
              resolvedURL.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame,
              fileManager.fileExists(atPath: resolvedURL.path) else { return false }
        return (try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
