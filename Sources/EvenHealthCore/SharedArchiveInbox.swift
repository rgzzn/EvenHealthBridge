import Foundation

public enum SharedArchiveInboxError: LocalizedError, Sendable, Equatable {
    case unsupportedFile
    case archiveTooLarge
    case invalidInboxFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: String(localized: "Condividi un archivio ZIP Even.")
        case .archiveTooLarge: String(localized: "L'archivio ZIP è troppo grande per essere condiviso.")
        case .invalidInboxFile: String(localized: "L'archivio condiviso non è più disponibile.")
        }
    }
}

/// A narrow, local-only staging folder used by the Share extension and its host app.
/// It holds at most one ZIP, never parses or uploads it, and removes the archive after use.
public struct SharedArchiveFileStore: Sendable {
    public static let defaultMaximumArchiveBytes = 512 * 1024 * 1024

    public let folder: URL
    public let maximumArchiveBytes: Int

    public init(folder: URL, maximumArchiveBytes: Int = defaultMaximumArchiveBytes) {
        self.folder = folder.standardizedFileURL
        self.maximumArchiveBytes = maximumArchiveBytes
    }

    /// Copies a shared ZIP before the source provider revokes its temporary file URL.
    /// A new share replaces any prior unclaimed archive in this app-owned folder.
    public func receive(from source: URL, fileManager: FileManager = .default) throws -> URL {
        guard source.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
            throw SharedArchiveInboxError.unsupportedFile
        }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw SharedArchiveInboxError.unsupportedFile }
        guard let size = values.fileSize, size >= 0, size <= maximumArchiveBytes else {
            throw SharedArchiveInboxError.archiveTooLarge
        }

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".receiving-\(UUID().uuidString)", isDirectory: false)
        let destination = folder.appendingPathComponent("EvenHealthBridge-\(UUID().uuidString).zip", isDirectory: false)
        do {
            try fileManager.copyItem(at: source, to: temporary)
            #if os(iOS) || os(visionOS)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
            #endif
            try fileManager.moveItem(at: temporary, to: destination)
            try discardAll(except: destination, fileManager: fileManager)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    public func discard(_ archive: URL, fileManager: FileManager = .default) throws {
        let resolvedFolder = folder.resolvingSymlinksInPath().path
        let resolvedArchive = archive.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedArchive.deletingLastPathComponent().path == resolvedFolder,
              resolvedArchive.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
            throw SharedArchiveInboxError.invalidInboxFile
        }
        guard fileManager.fileExists(atPath: resolvedArchive.path) else { return }
        try fileManager.removeItem(at: resolvedArchive)
    }

    private func discardAll(except archive: URL, fileManager: FileManager) throws {
        let entries = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for entry in entries where entry.standardizedFileURL != archive.standardizedFileURL {
            try fileManager.removeItem(at: entry)
        }
    }
}

/// Shared App Group coordination. The marker is a filename rather than a path so the host app
/// cannot be directed outside its own inbox folder.
public enum SharedArchiveInbox {
    public static let appGroupIdentifier = "group.com.rgzzn.EvenHealthBridge"
    private static let pendingFilenameKey = "pendingSharedArchiveFilename"

    public static func receive(from source: URL) throws {
        let store = try makeStore()
        let archive = try store.receive(from: source)
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            try? store.discard(archive)
            throw SharedArchiveInboxError.invalidInboxFile
        }
        defaults.set(archive.lastPathComponent, forKey: pendingFilenameKey)
    }

    /// Claims the pending archive exactly once. The caller must discard it after analysis.
    public static func claim() -> URL? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let filename = defaults.string(forKey: pendingFilenameKey),
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              URL(fileURLWithPath: filename).pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame,
              let store = try? makeStore() else { return nil }
        defaults.removeObject(forKey: pendingFilenameKey)
        let archive = store.folder.appendingPathComponent(filename, isDirectory: false)
        return FileManager.default.fileExists(atPath: archive.path) ? archive : nil
    }

    public static func discard(_ archive: URL) {
        try? makeStore().discard(archive)
    }

    private static func makeStore() throws -> SharedArchiveFileStore {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SharedArchiveInboxError.invalidInboxFile
        }
        return SharedArchiveFileStore(folder: container.appendingPathComponent("IncomingArchives", isDirectory: true))
    }
}
