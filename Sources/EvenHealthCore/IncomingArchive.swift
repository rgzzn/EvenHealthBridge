import Foundation

/// A validated file URL delivered by Files, Open In, or a future Share extension.
/// Archive contents remain untrusted and are validated again by `ZIPExtractionService`.
public struct IncomingArchive: Sendable, Equatable {
    public let url: URL

    public init?(url: URL) {
        guard url.isFileURL,
              url.pathExtension.localizedCaseInsensitiveCompare("zip") == .orderedSame else {
            return nil
        }
        self.url = url
    }
}
