import Foundation
import ZIPFoundation

public enum ZIPImportError: Error {
    case invalidArchive
    case unsafeEntry
    case archiveTooLarge
    case duplicateFile(String)
}

public struct ZIPExtractionService: Sendable {
    public let maxArchiveBytes: Int64 = 50_000_000
    public let maxExpandedBytes: Int64 = 100_000_000
    public let maxEntryBytes: Int64 = 30_000_000
    public init() {}

    /// Reads only the seven known CSV files; never writes ZIP paths to disk.
    public func readCSV(at url: URL) throws -> [String: Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(maxArchiveBytes) else { throw ZIPImportError.archiveTooLarge }
        let archive = try Archive(url: url, accessMode: .read)
        let allowed: Set<String> = ["steps.csv", "calories.csv", "heart_rate.csv", "hrv.csv", "blood_oxygen.csv", "sleep.csv", "skin_temperature.csv"]
        var result: [String: Data] = [:]
        var expanded: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !entry.path.contains("\\") else { throw ZIPImportError.unsafeEntry }
            guard entry.type == .file, let filename = parts.last.map(String.init), allowed.contains(filename) else { continue }
            guard result[filename] == nil else { throw ZIPImportError.duplicateFile(filename) }
            guard entry.uncompressedSize <= UInt64(maxEntryBytes),
                  entry.uncompressedSize <= UInt64(maxExpandedBytes) - expanded else { throw ZIPImportError.archiveTooLarge }
            expanded += entry.uncompressedSize
            var bytes = Data()
            _ = try archive.extract(entry, bufferSize: 16_384) { chunk in
                try Task.checkCancellation()
                guard bytes.count + chunk.count <= maxEntryBytes else { throw ZIPImportError.archiveTooLarge }
                bytes.append(chunk)
            }
            result[filename] = bytes
        }
        return result
    }
}
