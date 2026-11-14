import Foundation

/// An interval already represented by a HealthKit source. Values are intentionally absent: coverage
/// is enough to decide whether a complete Even sample may be considered for a future mapped import.
public struct ExistingHealthCoverage: Sendable, Hashable {
    public let kind: MeasurementKind
    public let interval: DateInterval

    public init(kind: MeasurementKind, interval: DateInterval) {
        self.kind = kind
        self.interval = interval
    }
}

public enum OverlayExclusionReason: Sendable, Hashable {
    case notEligibleForAutomaticWriting(HealthImportReadiness)
    case invalidMeasurement
    case undocumentedOrInvalidInterval
    case overlapsExistingCoverage
    case overlapsAnotherEvenMeasurement
}

public struct OverlayExclusion: Sendable, Hashable, Identifiable {
    public let measurementID: String
    public let reason: OverlayExclusionReason

    public init(measurementID: String, reason: OverlayExclusionReason) {
        self.measurementID = measurementID
        self.reason = reason
    }

    public var id: String { measurementID }
}

public struct ConservativeOverlayPlan: Sendable {
    public let candidates: [HealthMeasurement]
    public let exclusions: [OverlayExclusion]

    public init(candidates: [HealthMeasurement], exclusions: [OverlayExclusion]) {
        self.candidates = candidates
        self.exclusions = exclusions
    }
}

/// Plans whole-sample overlay candidates without making any HealthKit writes.
///
/// A future category can enter this planner only after `HealthImportReadiness` explicitly permits it.
/// It never interpolates, truncates, or splits a value: any overlap excludes the complete sample.
public struct ConservativeOverlayPlanner: Sendable {
    public init() {}

    public func plan(
        measurements: [HealthMeasurement],
        existingCoverage: [ExistingHealthCoverage]
    ) -> ConservativeOverlayPlan {
        var accepted: [HealthMeasurement] = []
        var exclusions: [OverlayExclusion] = []
        var occupied = existingCoverage

        for measurement in measurements.sorted(by: Self.stableOrder) {
            let readiness = HealthImportReadiness.current(for: measurement.kind)
            guard readiness.permitsAutomaticHealthWrite else {
                exclusions.append(.init(measurementID: measurement.id, reason: .notEligibleForAutomaticWriting(readiness)))
                continue
            }
            guard measurement.validation == .eligible else {
                exclusions.append(.init(measurementID: measurement.id, reason: .invalidMeasurement))
                continue
            }
            guard let interval = validInterval(for: measurement) else {
                exclusions.append(.init(measurementID: measurement.id, reason: .undocumentedOrInvalidInterval))
                continue
            }

            if occupied.contains(where: { $0.kind == measurement.kind && overlaps(interval, $0.interval) }) {
                let reason: OverlayExclusionReason = existingCoverage.contains(where: {
                    $0.kind == measurement.kind && overlaps(interval, $0.interval)
                }) ? .overlapsExistingCoverage : .overlapsAnotherEvenMeasurement
                exclusions.append(.init(measurementID: measurement.id, reason: reason))
                continue
            }

            accepted.append(measurement)
            occupied.append(.init(kind: measurement.kind, interval: interval))
        }

        return .init(candidates: accepted, exclusions: exclusions)
    }

    private static func stableOrder(_ lhs: HealthMeasurement, _ rhs: HealthMeasurement) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id < rhs.id
    }

    private func validInterval(for measurement: HealthMeasurement) -> DateInterval? {
        guard let end = measurement.intervalEnd, end > measurement.timestamp else { return nil }
        return DateInterval(start: measurement.timestamp, end: end)
    }

    private func overlaps(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }
}
