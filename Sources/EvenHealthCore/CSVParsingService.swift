import Foundation

public enum CSVError: Error, Equatable {
    case unterminatedQuote
    case malformedQuote(row: Int)
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
        var header: [String]?
        var rows: [[String: String]] = []
        var firstInvalid: CSVError?
        let unfinished = try visitRecords(data) { number, fields, valid in
            if !valid {
                if firstInvalid == nil { firstInvalid = .malformedQuote(row: number) }
                return
            }
            if let header {
                if fields.count == header.count {
                    rows.append(Dictionary(uniqueKeysWithValues: zip(header, fields)))
                } else if firstInvalid == nil {
                    firstInvalid = .inconsistentColumns(row: number)
                }
            } else {
                try validateHeader(fields)
                header = fields
            }
        }
        if unfinished != nil { throw CSVError.unterminatedQuote }
        if let firstInvalid { throw firstInvalid }
        return rows
    }

    /// Preserves valid records around incomplete or malformed records without guessing missing fields.
    public func parseRecovering(_ data: Data) throws -> CSVParseResult {
        var rows: [[String: String]] = []
        var recordNumbers: [Int] = []
        var rejected: [Int] = []
        try forEachRowRecovering(data, onRejected: { rejected.append($0) }) { number, row in
            rows.append(row)
            recordNumbers.append(number)
        }
        return CSVParseResult(rows: rows, recordNumbers: recordNumbers, rejectedRecords: rejected)
    }

    /// Visits one CSV row at a time. Callers can retain only normalized measurements and bounded diagnostics.
    public func forEachRowRecovering(_ data: Data, onRejected: (Int) throws -> Void,
                                     onRow: (Int, [String: String]) throws -> Void) throws {
        var header: [String]?
        let unfinished = try visitRecords(data) { number, fields, valid in
            guard valid else {
                if header == nil { throw CSVError.malformedQuote(row: number) }
                try onRejected(number)
                return
            }
            if let header {
                if fields.count == header.count {
                    try onRow(number, Dictionary(uniqueKeysWithValues: zip(header, fields)))
                } else {
                    try onRejected(number)
                }
            } else {
                try validateHeader(fields)
                header = fields
            }
        }
        if let unfinished { try onRejected(unfinished) }
    }

    private func validateHeader(_ header: [String]) throws {
        guard Set(header).count == header.count else { throw CSVError.duplicateHeader }
    }

    /// Returns the number of an incomplete final record, if a quote remains open at EOF.
    private func visitRecords(_ data: Data, _ onRecord: (Int, [String], Bool) throws -> Void) throws -> Int? {
        guard var input = String(data: data, encoding: .utf8) else { throw CSVError.invalidEncoding }
        // Swift treats CRLF as one Character; normalize it before scanning by Character.
        input = input.replacingOccurrences(of: "\r\n", with: "\n")
        var index = input.startIndex
        if index < input.endIndex && input[index] == "\u{FEFF}" { index = input.index(after: index) }
        var recordNumber = 1
        var row: [String] = []
        var field = ""
        var quoted = false
        var afterQuote = false
        var valid = true
        var scanned = 0
        while index < input.endIndex {
            if scanned.isMultiple(of: 16_384) { try Task.checkCancellation() }
            scanned += 1
            let ch = input[index]
            let next = input.index(after: index)
            if quoted {
                if ch == "\"" {
                    if next < input.endIndex && input[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                        afterQuote = true
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"" where field.isEmpty && !afterQuote: quoted = true
                case "\"": valid = false
                case ",":
                    row.append(field)
                    field = ""
                    afterQuote = false
                case "\n":
                    row.append(field)
                    try onRecord(recordNumber, row, valid)
                    recordNumber += 1
                    row.removeAll(keepingCapacity: true)
                    field.removeAll(keepingCapacity: true)
                    afterQuote = false
                    valid = true
                case "\r": break
                default:
                    if afterQuote { valid = false }
                    field.append(ch)
                }
            }
            index = input.index(after: index)
        }
        if quoted { return recordNumber }
        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            try onRecord(recordNumber, row, valid)
        }
        return nil
    }
}
