import Foundation

public enum CSVError: Error, Equatable {
    case unterminatedQuote
    case inconsistentColumns(row: Int)
    case invalidEncoding
    case duplicateHeader
}

public struct CSVParseResult: Sendable {
    public let rows: [[String: String]]
    public let recordNumbers: [Int]
    /// One-based record numbers, including the header as record 1.
    public let rejectedRecords: [Int]
}

public struct CSVParsingService: Sendable {
    public init() {}

    /// RFC 4180 style parser. Keeps embedded commas, quotes and line breaks inside quoted fields.
    public func parse(_ data: Data) throws -> [[String: String]] {
        let (records, unterminated) = try tokenize(data)
        if unterminated { throw CSVError.unterminatedQuote }
        guard let header = records.first else { return [] }
        try validateHeader(header)
        return try records.dropFirst().enumerated().map { offset, fields in
            guard fields.count == header.count else { throw CSVError.inconsistentColumns(row: offset + 2) }
            return Dictionary(uniqueKeysWithValues: zip(header, fields))
        }
    }

    /// Preserves valid records around incomplete or malformed records without guessing missing fields.
    public func parseRecovering(_ data: Data) throws -> CSVParseResult {
        let (records, unterminated) = try tokenize(data)
        guard let header = records.first else {
            return CSVParseResult(rows: [], recordNumbers: [], rejectedRecords: unterminated ? [1] : [])
        }
        try validateHeader(header)
        var rows: [[String: String]] = []
        var recordNumbers: [Int] = []
        var rejected: [Int] = []
        for (offset, fields) in records.dropFirst().enumerated() {
            if fields.count == header.count {
                rows.append(Dictionary(uniqueKeysWithValues: zip(header, fields)))
                recordNumbers.append(offset + 2)
            } else {
                rejected.append(offset + 2)
            }
        }
        if unterminated { rejected.append(records.count + 1) }
        return CSVParseResult(rows: rows, recordNumbers: recordNumbers, rejectedRecords: rejected)
    }

    private func validateHeader(_ header: [String]) throws {
        guard Set(header).count == header.count else { throw CSVError.duplicateHeader }
    }

    private func tokenize(_ data: Data) throws -> ([[String]], Bool) {
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
        if quoted { return (records, true) }
        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            records.append(row)
        }
        return (records, false)
    }
}
