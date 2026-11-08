import Foundation

public enum CSVError: Error, Equatable {
    case unterminatedQuote
    case inconsistentColumns(row: Int)
    case invalidEncoding
}

public struct CSVParsingService: Sendable {
    public init() {}

    /// RFC 4180 style parser. Keeps embedded commas, quotes and line breaks inside quoted fields.
    public func parse(_ data: Data) throws -> [[String: String]] {
        guard var input = String(data: data, encoding: .utf8) else { throw CSVError.invalidEncoding }
        if input.hasPrefix("\u{FEFF}") { input.removeFirst() }
        input = input.replacingOccurrences(of: "\r\n", with: "\n")
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]
            let next = input.index(after: index)
            if quoted {
                if ch == "\"" {
                    if next < input.endIndex && input[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else { quoted = false }
                } else { field.append(ch) }
            } else {
                switch ch {
                case "\"" where field.isEmpty: quoted = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); records.append(row); row = []; field = ""
                case "\r": break
                default: field.append(ch)
                }
            }
            index = input.index(after: index)
        }
        if quoted { throw CSVError.unterminatedQuote }
        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            records.append(row)
        }
        guard let header = records.first else { return [] }
        return try records.dropFirst().enumerated().map { offset, fields in
            guard fields.count == header.count else { throw CSVError.inconsistentColumns(row: offset + 2) }
            return Dictionary(uniqueKeysWithValues: zip(header, fields))
        }
    }
}
