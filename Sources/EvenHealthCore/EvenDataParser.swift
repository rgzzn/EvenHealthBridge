import Foundation
import CryptoKit

public enum MeasurementKind: String, CaseIterable, Sendable, Codable {
    case steps, calories, heartRate, hrv, oxygen, sleep, skinTemperature
}

public enum ImportValidation: String, Sendable, Codable {
    case eligible, ambiguousSemantics, malformed, implausible, duplicate, conflict
}

public enum EvenParserError: LocalizedError, Equatable {
    case tooManyMeasurements(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyMeasurements(let limit):
            String(localized: "L'archivio contiene più di \(limit) misurazioni. Importazione interrotta per proteggere la memoria del dispositivo.")
        }
    }
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

    public init(id: String, kind: MeasurementKind, timestamp: Date, originalTimestamp: String,
                source: String, value: Decimal?, components: [String: Decimal], originalUnit: String?,
                canonicalUnit: String?, statistic: String?, intervalEnd: Date?, sleepStage: Int?,
                sessionEnd: Date?, provenance: String, validation: ImportValidation) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.originalTimestamp = originalTimestamp
        self.source = source
        self.value = value
        self.components = components
        self.originalUnit = originalUnit
        self.canonicalUnit = canonicalUnit
        self.statistic = statistic
        self.intervalEnd = intervalEnd
        self.sleepStage = sleepStage
        self.sessionEnd = sessionEnd
        self.provenance = provenance
        self.validation = validation
    }
}

public struct ParsedDataset: Sendable {
    public let measurements: [HealthMeasurement]
    public let warnings: [String]
    public let archiveHash: String

    public init(measurements: [HealthMeasurement], warnings: [String], archiveHash: String) {
        self.measurements = measurements
        self.warnings = warnings
        self.archiveHash = archiveHash
    }
}

public struct EvenDataParser: Sendable {
    private enum SleepParseError: Error { case invalidSession }
    private let csv = CSVParsingService()
    private let zip = ZIPExtractionService()
    public let maxMeasurements: Int
    public init(maxMeasurements: Int = 100_000) { self.maxMeasurements = max(1, maxMeasurements) }

    public func parseArchive(at url: URL) throws -> ParsedDataset {
        var measurements: [HealthMeasurement] = []
        var warnings: [String] = []
        var omittedWarnings = 0
        func addWarning(_ message: String) {
            if warnings.count < 100 { warnings.append(message) }
            else { omittedWarnings += 1 }
        }
        let kindsByFilename = Dictionary(uniqueKeysWithValues: fileKinds)
        let seen = try zip.forEachCSV(at: url) { filename, data in
            try Task.checkCancellation()
            guard let kind = kindsByFilename[filename] else { return }
            do {
                try csv.forEachRowRecovering(data, onRejected: { number in
                    addWarning(String(localized: "\(filename): record CSV \(number) scartato"))
                }) { recordNumber, row in
                    if recordNumber.isMultiple(of: 256) { try Task.checkCancellation() }
                    if kind == .sleep {
                        let stages: [HealthMeasurement]
                        do { stages = try parseSleep(row) }
                        catch {
                            addWarning(String(localized: "sleep.csv: sessione non valida nel record \(recordNumber)"))
                            return
                        }
                        guard stages.count <= maxMeasurements - measurements.count else {
                            throw EvenParserError.tooManyMeasurements(limit: maxMeasurements)
                        }
                        measurements += stages
                        return
                    }
                    guard let time = row["timestamp"], let date = Self.parseDate(time) else {
                        addWarning(String(localized: "\(filename): record \(recordNumber) con timestamp non valido"))
                        return
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
                    guard measurements.count < maxMeasurements else {
                        throw EvenParserError.tooManyMeasurements(limit: maxMeasurements)
                    }
                    measurements.append(.init(id: id, kind: kind, timestamp: date, originalTimestamp: time, source: source, value: value, components: components, originalUnit: nil, canonicalUnit: nil, statistic: statistic, intervalEnd: end, sleepStage: nil, sessionEnd: nil, provenance: filename, validation: validation))
                }
            } catch is CSVError {
                addWarning(String(localized: "\(filename): intestazione o codifica CSV non valida"))
            }
        }
        for (filename, _) in fileKinds where !seen.contains(filename) {
            addWarning(String(localized: "File mancante: \(filename)"))
        }
        if omittedWarnings > 0 { warnings.append(String(localized: "Altri \(omittedWarnings) avvisi omessi; controlla la qualità dell'archivio.")) }
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
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
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
            guard elapsed <= 86_400 - seconds else { throw SleepParseError.invalidSession }
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
        var observedComponents: [String: [String: Decimal]] = [:]
        var conflictingIDs = Set<String>()
        for item in input {
            if let previous = seen[item.id] {
                if !sameMeasurement(previous, item) { conflictingIDs.insert(item.id) }
                for (key, value) in item.components {
                    if let observed = observedComponents[item.id]?[key], observed != value {
                        conflictingIDs.insert(item.id)
                    } else {
                        observedComponents[item.id, default: [:]][key] = value
                    }
                }
            } else {
                seen[item.id] = item
                observedComponents[item.id] = item.components
            }
        }
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
        var shapes: [SleepInterval: [String: [SleepStageShape]]] = [:]
        var shapesByID: [String: Set<SleepStageShape>] = [:]
        var sessionByID: [String: SleepInterval] = [:]
        for item in input where item.kind == .sleep {
            guard let end = item.sessionEnd, let start = EvenDataParser.parseDate(item.originalTimestamp),
                  let stageEnd = item.intervalEnd, let stage = item.sleepStage else { continue }
            let session = SleepInterval(start: start, end: end)
            let shape = SleepStageShape(start: item.timestamp, end: stageEnd, stage: stage)
            shapes[session, default: [:]][item.source, default: []].append(shape)
            shapesByID[item.id, default: []].insert(shape)
            sessionByID[item.id] = session
        }
        var disagreements = Set(shapes.compactMap { session, bySource -> SleepInterval? in
            let sequences = bySource.values.map { stages in
                Array(Set(stages)).sorted { $0.start < $1.start }
            }
            return Set(sequences).count > 1 ? session : nil
        })
        for (id, variants) in shapesByID where variants.count > 1 {
            if let session = sessionByID[id] { disagreements.insert(session) }
        }
        var repeated = Set<String>()
        return input.map { item in
            var result = item
            if conflictingIDs.contains(item.id) { result.validation = .conflict }
            else if !repeated.insert(item.id).inserted { result.validation = .duplicate }
            if item.kind == .sleep, let end = item.sessionEnd, let start = EvenDataParser.parseDate(item.originalTimestamp) {
                let session = SleepInterval(start: start, end: end)
                if overlapping.contains(session) || disagreements.contains(session) { result.validation = .conflict }
            }
            return result
        }
    }

    private func sameMeasurement(_ lhs: HealthMeasurement, _ rhs: HealthMeasurement) -> Bool {
        lhs.kind == rhs.kind && lhs.timestamp == rhs.timestamp && lhs.value == rhs.value &&
        lhs.originalUnit == rhs.originalUnit &&
        lhs.canonicalUnit == rhs.canonicalUnit && lhs.statistic == rhs.statistic &&
        lhs.intervalEnd == rhs.intervalEnd && lhs.sleepStage == rhs.sleepStage &&
        lhs.sessionEnd == rhs.sessionEnd && lhs.provenance == rhs.provenance
    }

    private struct SleepInterval: Hashable {
        let start: Date
        let end: Date
    }

    private struct SleepStageShape: Hashable {
        let start: Date
        let end: Date
        let stage: Int
    }
}
