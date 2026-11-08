import Foundation
import CryptoKit

public enum MeasurementKind: String, CaseIterable, Sendable, Codable {
    case steps, calories, heartRate, hrv, oxygen, sleep, skinTemperature
}

public enum ImportValidation: String, Sendable, Codable {
    case eligible, ambiguousSemantics, malformed, implausible, duplicate, conflict
}

public struct HealthMeasurement: Sendable, Codable, Identifiable {
    public let id: String
    public let kind: MeasurementKind
    public let timestamp: Date
    public let originalTimestamp: String
    public let source: String
    public let value: Decimal?
    public let components: [String: Decimal]
    public let originalUnit: String?
    public let canonicalUnit: String?
    public let statistic: String?
    public let intervalEnd: Date?
    public let sleepStage: Int?
    public let sessionEnd: Date?
    public let provenance: String
    public var validation: ImportValidation
}

public struct ParsedDataset: Sendable {
    public let measurements: [HealthMeasurement]
    public let warnings: [String]
    public let archiveHash: String
}

public struct EvenDataParser: Sendable {
    private enum SleepParseError: Error { case invalidSession }
    private let csv = CSVParsingService()
    private let zip = ZIPExtractionService()
    public init() {}

    public func parseArchive(at url: URL) throws -> ParsedDataset {
        let contents = try zip.readCSV(at: url)
        var measurements: [HealthMeasurement] = []
        var warnings: [String] = []
        for (filename, kind) in fileKinds {
            guard let data = contents[filename] else { warnings.append("File mancante: \(filename)"); continue }
            let rows = try csv.parse(data)
            for (index, row) in rows.enumerated() {
                if kind == .sleep {
                    do { measurements += try parseSleep(row) }
                    catch { warnings.append("sleep.csv: sessione non valida alla riga \(index + 2)") }
                    continue
                }
                guard let time = row["timestamp"], let date = Self.parseDate(time) else {
                    warnings.append("\(filename): riga \(index + 2) con timestamp non valido")
                    continue
                }
                let source = row["source"] ?? "unknown"
                let statistic = row["ty"]
                let value = row["value"].flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
                let components: [String: Decimal] = kind == .calories
                    ? Dictionary(uniqueKeysWithValues: ["resting", "active"].compactMap { key in
                        row[key].flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }.map { (key, $0) }
                    }) : [:]
                var validation: ImportValidation = .ambiguousSemantics
                if kind != .sleep && value == nil { validation = .malformed }
                if kind == .calories && ["resting", "active"].contains(where: { key in
                    guard let text = row[key], !text.isEmpty else { return false }
                    return components[key] == nil
                }) { validation = .malformed }
                if let value, value < 0 { validation = .implausible }
                if kind == .oxygen, let value, (value < 0 || value > 100) { validation = .implausible }
                if kind == .heartRate, let value, (value < 20 || value > 250) { validation = .implausible }
                let end = row["end_ts"].flatMap(Self.parseDate)
                let identity = [kind.rawValue, String(date.timeIntervalSince1970), statistic ?? "", row["start_ts"] ?? "", row["end_ts"] ?? ""].joined(separator: "|")
                let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                measurements.append(.init(id: id, kind: kind, timestamp: date, originalTimestamp: time, source: source, value: value, components: components, originalUnit: nil, canonicalUnit: nil, statistic: statistic, intervalEnd: end, sleepStage: nil, sessionEnd: nil, provenance: filename, validation: validation))
            }
        }
        return .init(measurements: MeasurementDeduplicator().resolve(measurements), warnings: warnings, archiveHash: try hashFile(url))
    }

    public static func parseDate(_ input: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: input) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: input)
    }

    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Stage: Decodable { let type: Int; let half_minutes: Int }

    private func parseSleep(_ row: [String: String]) throws -> [HealthMeasurement] {
        guard let startText = row["start_ts"], let endText = row["end_ts"],
              let start = Self.parseDate(startText), let end = Self.parseDate(endText), end > start,
              let json = row["stages"]?.data(using: .utf8),
              let stages = try? JSONDecoder().decode([Stage].self, from: json), !stages.isEmpty else { throw SleepParseError.invalidSession }
        var sums = [0, 0, 0, 0]
        var elapsed = 0
        for stage in stages {
            guard (0...3).contains(stage.type), stage.half_minutes > 0, stage.half_minutes < 2_880 else { throw SleepParseError.invalidSession }
            let seconds = stage.half_minutes * 30
            sums[stage.type] += seconds
            elapsed += seconds
        }
        guard abs(end.timeIntervalSince(start) - Double(elapsed)) < 1 else { throw SleepParseError.invalidSession }
        for (code, key) in ["wake_time", "rem_time", "light_time", "deep_time"].enumerated() {
            guard let value = row[key].flatMap(Double.init), abs(value - Double(sums[code])) < 1 else { throw SleepParseError.invalidSession }
        }
        guard let total = row["total_time"].flatMap(Double.init), abs(total - Double(elapsed - sums[0])) < 1 else { throw SleepParseError.invalidSession }
        var cursor = start
        let source = row["source"] ?? "unknown"
        return stages.enumerated().map { index, stage in
            let stageStart = cursor
            cursor = cursor.addingTimeInterval(Double(stage.half_minutes * 30))
            let key = "sleep|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(index)"
            let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return HealthMeasurement(id: id, kind: .sleep, timestamp: stageStart, originalTimestamp: startText, source: source, value: nil, components: [:], originalUnit: "half_minutes", canonicalUnit: "seconds", statistic: nil, intervalEnd: cursor, sleepStage: stage.type, sessionEnd: end, provenance: "sleep.csv", validation: .eligible)
        }
    }

    private let fileKinds: [(String, MeasurementKind)] = [
        ("steps.csv", .steps), ("calories.csv", .calories), ("heart_rate.csv", .heartRate),
        ("hrv.csv", .hrv), ("blood_oxygen.csv", .oxygen), ("sleep.csv", .sleep),
        ("skin_temperature.csv", .skinTemperature)
    ]
}

public struct MeasurementDeduplicator: Sendable {
    public init() {}

    public func resolve(_ input: [HealthMeasurement]) -> [HealthMeasurement] {
        var seen: [String: HealthMeasurement] = [:]
        let sessions = Array(Set(input.compactMap { item -> SleepInterval? in
            guard item.kind == .sleep, let end = item.sessionEnd, let start = EvenDataParser.parseDate(item.originalTimestamp) else { return nil }
            return SleepInterval(start: start, end: end)
        })).sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var overlapping = Set<SleepInterval>()
        var latest: SleepInterval?
        for session in sessions {
            if let current = latest {
                if session.start < current.end {
                    overlapping.insert(current)
                    overlapping.insert(session)
                }
                if session.end > current.end { latest = session }
            } else {
                latest = session
            }
        }
        return input.map { item in
            var result = item
            if let previous = seen[item.id] {
                result.validation = previous.value == item.value && previous.intervalEnd == item.intervalEnd && previous.sleepStage == item.sleepStage ? .duplicate : .conflict
            } else { seen[item.id] = item }
            if item.kind == .sleep, let end = item.sessionEnd, let start = EvenDataParser.parseDate(item.originalTimestamp), overlapping.contains(SleepInterval(start: start, end: end)) {
                result.validation = .conflict
            }
            return result
        }
    }

    private struct SleepInterval: Hashable {
        let start: Date
        let end: Date
    }
}
