import Foundation

/// The only two quantity categories for which Even Health Bridge has a complete
/// HealthKit writing path. A record still has to satisfy its mapping contract;
/// merely belonging to one of these categories never makes it importable.
public enum QuantityImportKind: String, CaseIterable, Sendable, Codable, Hashable {
    case steps
    case activeEnergy

    public var measurementKind: MeasurementKind {
        switch self {
        case .steps: .steps
        case .activeEnergy: .calories
        }
    }

    public var canonicalUnit: String {
        switch self {
        case .steps: "count"
        case .activeEnergy: "kcal"
        }
    }
}

/// A fully specified interval quantity that can be handed to a HealthKit adapter.
/// The core module deliberately does not import HealthKit so parser and recovery
/// logic remain testable on macOS.
public struct QuantityImportCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: QuantityImportKind
    public let start: Date
    public let end: Date
    public let value: Decimal
    public let unit: String
    public let source: String
    public let parserVersion: Int
    public let mappingVersion: Int

    public init(id: String, kind: QuantityImportKind, start: Date, end: Date,
                value: Decimal, unit: String, source: String,
                parserVersion: Int = 4, mappingVersion: Int = 2) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value
        self.unit = unit
        self.source = source
        self.parserVersion = parserVersion
        self.mappingVersion = mappingVersion
    }
}

public struct ImportedQuantitySample: Sendable, Hashable {
    public let id: String
    public let kind: QuantityImportKind
    public let start: Date
    public let end: Date
    public let value: Decimal
    public let unit: String

    public init(id: String, kind: QuantityImportKind, start: Date, end: Date,
                value: Decimal, unit: String) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value
        self.unit = unit
    }
}

public struct QuantityImportPlan: Sendable {
    public let candidates: [QuantityImportCandidate]
    public let newSamples: [QuantityImportCandidate]
    public let alreadyImported: Int
    public let conflicts: Int

    public init(candidates: [QuantityImportCandidate], newSamples: [QuantityImportCandidate],
                alreadyImported: Int, conflicts: Int) {
        self.candidates = candidates
        self.newSamples = newSamples
        self.alreadyImported = alreadyImported
        self.conflicts = conflicts
    }
}

/// Evidence gate for steps. HealthKit step samples are interval quantities, so a
/// timestamp cadence is never substituted for a declared start and end.
public enum StepMappingContract {
    public static func candidate(for measurement: HealthMeasurement) -> QuantityImportCandidate? {
        guard measurement.kind == .steps,
              measurement.hasExplicitIntervalStart,
              let end = measurement.intervalEnd, end > measurement.timestamp,
              measurement.statistic == nil,
              normalized(measurement.semantics) == "delta",
              isCountUnit(measurement.originalUnit),
              let value = measurement.value,
              isWholePositive(value) else { return nil }
        return .init(id: stableID(for: measurement, kind: .steps), kind: .steps,
                     start: measurement.timestamp, end: end, value: value,
                     unit: QuantityImportKind.steps.canonicalUnit, source: measurement.source)
    }

    public static func canMap(_ measurement: HealthMeasurement) -> Bool {
        candidate(for: measurement) != nil
    }
}

/// Evidence gate for active energy. `value` is deliberately ignored: only an
/// explicitly identified active component can become activeEnergyBurned. Total
/// and resting calories can never pass this contract.
public enum ActiveEnergyMappingContract {
    public static func candidate(for measurement: HealthMeasurement) -> QuantityImportCandidate? {
        guard measurement.kind == .calories,
              measurement.hasExplicitIntervalStart,
              let end = measurement.intervalEnd, end > measurement.timestamp,
              measurement.statistic == nil,
              normalized(measurement.semantics) == "delta",
              isKilocalorieUnit(measurement.originalUnit),
              let active = measurement.components["active"],
              isPositive(active) else { return nil }
        return .init(id: stableID(for: measurement, kind: .activeEnergy), kind: .activeEnergy,
                     start: measurement.timestamp, end: end, value: active,
                     unit: QuantityImportKind.activeEnergy.canonicalUnit, source: measurement.source)
    }

    public static func canMap(_ measurement: HealthMeasurement) -> Bool {
        candidate(for: measurement) != nil
    }
}

public enum QuantityMappingContract {
    public static func validation(for measurement: HealthMeasurement) -> ImportValidation {
        switch measurement.kind {
        case .steps:
            StepMappingContract.canMap(measurement) ? .eligible : .ambiguousSemantics
        case .calories:
            ActiveEnergyMappingContract.canMap(measurement) ? .eligible : .ambiguousSemantics
        default:
            .ambiguousSemantics
        }
    }

    public static func candidate(for measurement: HealthMeasurement) -> QuantityImportCandidate? {
        switch measurement.kind {
        case .steps: StepMappingContract.candidate(for: measurement)
        case .calories: ActiveEnergyMappingContract.candidate(for: measurement)
        default: nil
        }
    }
}

public struct QuantityImportPlanner: Sendable {
    public init() {}

    public func plan(_ measurements: [HealthMeasurement], kind: QuantityImportKind,
                     imported: [ImportedQuantitySample]) -> QuantityImportPlan {
        let candidates = measurements.compactMap { measurement -> QuantityImportCandidate? in
            guard measurement.kind == kind.measurementKind,
                  measurement.validation == .eligible else { return nil }
            return QuantityMappingContract.candidate(for: measurement)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }

        let stored = Dictionary(imported.filter { $0.kind == kind }.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        var newSamples: [QuantityImportCandidate] = []
        var alreadyImported = 0
        var conflicts = 0

        for candidate in candidates {
            guard let existing = stored[candidate.id] else {
                newSamples.append(candidate)
                continue
            }
            if matches(candidate, existing) {
                alreadyImported += 1
            } else {
                conflicts += 1
            }
        }
        return .init(candidates: candidates, newSamples: newSamples,
                     alreadyImported: alreadyImported, conflicts: conflicts)
    }

    private func matches(_ candidate: QuantityImportCandidate, _ stored: ImportedQuantitySample) -> Bool {
        candidate.kind == stored.kind && candidate.start == stored.start && candidate.end == stored.end &&
        candidate.value == stored.value && candidate.unit == stored.unit
    }
}

@MainActor public protocol QuantitySampleWriting {
    func authorize(for kind: QuantityImportKind) async throws
    func alreadySaved(_ sample: QuantityImportCandidate) async throws -> Bool
    func save(_ sample: QuantityImportCandidate) async throws
}

@MainActor public protocol QuantityImportRecording {
    func existingSamples(for kind: QuantityImportKind) throws -> [ImportedQuantitySample]
    func record(_ sample: QuantityImportCandidate) throws
}

/// Reconciles app-owned HealthKit samples before trusting local SwiftData. This
/// recovers a HealthKit save that succeeded just before the app was interrupted.
@MainActor public struct QuantityImportExecutor {
    public init() {}

    @discardableResult
    public func run(_ measurements: [HealthMeasurement], kind: QuantityImportKind,
                    writer: any QuantitySampleWriting, repository: any QuantityImportRecording,
                    progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        let existing = try repository.existingSamples(for: kind)
        let plan = QuantityImportPlanner().plan(measurements, kind: kind, imported: existing)
        guard !plan.candidates.isEmpty else { return 0 }
        try await writer.authorize(for: kind)

        let storedIDs = Set(existing.map(\.id))
        var written = 0
        progress?(0, plan.candidates.count)
        for (index, candidate) in plan.candidates.enumerated() {
            try Task.checkCancellation()
            let saved = try await writer.alreadySaved(candidate)
            try Task.checkCancellation()
            if !saved {
                try await writer.save(candidate)
                written += 1
            }
            if !storedIDs.contains(candidate.id) {
                try repository.record(candidate)
            }
            progress?(index + 1, plan.candidates.count)
        }
        return written
    }
}

private func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
}

private func isCountUnit(_ unit: String?) -> Bool {
    ["count", "counts", "step", "steps"].contains(normalized(unit))
}

private func isKilocalorieUnit(_ unit: String?) -> Bool {
    ["kcal", "kilocalorie", "kilocalories"].contains(normalized(unit))
}

private func isPositive(_ value: Decimal) -> Bool {
    let number = NSDecimalNumber(decimal: value).doubleValue
    return number.isFinite && number > 0
}

private func isWholePositive(_ value: Decimal) -> Bool {
    let number = NSDecimalNumber(decimal: value).doubleValue
    return number.isFinite && number > 0 && number.rounded() == number
}

private func stableID(for measurement: HealthMeasurement, kind: QuantityImportKind) -> String {
    "quantity|\(kind.rawValue)|\(measurement.id)"
}
