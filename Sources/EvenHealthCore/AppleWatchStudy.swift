import Foundation

/// Categories read from Apple Health only to evaluate the meaning of an Even export.
/// A study never changes a HealthKit record and never makes a category importable.
public enum AppleWatchStudyMetric: String, CaseIterable, Sendable, Identifiable {
    case steps
    case activeEnergy
    case heartRate
    case hrv
    case oxygen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .steps: String(localized: "Passi")
        case .activeEnergy: String(localized: "Calorie attive")
        case .heartRate: String(localized: "Frequenza cardiaca")
        case .hrv: String(localized: "Variabilita cardiaca")
        case .oxygen: String(localized: "Ossigenazione")
        }
    }

    /// This is a matching tolerance for a study, not an asserted sensor sampling interval.
    var matchingTolerance: TimeInterval {
        switch self {
        case .steps, .activeEnergy, .heartRate: 15 * 60
        case .hrv, .oxygen: 70 * 60
        }
    }

    var requiresAverageStatistic: Bool {
        switch self {
        case .heartRate, .hrv, .oxygen: true
        case .steps, .activeEnergy: false
        }
    }

    var supportsNumericDifference: Bool {
        switch self {
        case .heartRate, .hrv, .oxygen: true
        case .steps, .activeEnergy: false
        }
    }
}

public struct AppleWatchReferenceSample: Sendable, Hashable {
    public let metric: AppleWatchStudyMetric
    public let timestamp: Date
    public let value: Double

    public init(metric: AppleWatchStudyMetric, timestamp: Date, value: Double) {
        self.metric = metric
        self.timestamp = timestamp
        self.value = value
    }
}

public struct AppleWatchMetricStudyResult: Sendable, Identifiable {
    public let metric: AppleWatchStudyMetric
    public let evenRecordsInRange: Int
    public let comparableEvenRecords: Int
    public let appleWatchRecords: Int
    public let matchedRecords: Int
    public let unmatchedEvenRecords: Int
    public let medianAbsoluteDifference: Double?

    public var id: AppleWatchStudyMetric { metric }

    public var coverage: Double? {
        guard comparableEvenRecords > 0 else { return nil }
        return Double(matchedRecords) / Double(comparableEvenRecords)
    }
}

public struct AppleWatchStudyReport: Sendable {
    public let interval: DateInterval
    public let results: [AppleWatchMetricStudyResult]

    public init(interval: DateInterval, results: [AppleWatchMetricStudyResult]) {
        self.interval = interval
        self.results = results
    }
}

/// Pure domain logic for a local, read-only Apple Watch comparison.
public struct AppleWatchStudyEngine: Sendable {
    public init() {}

    public func study(
        measurements: [HealthMeasurement],
        references: [AppleWatchReferenceSample],
        interval: DateInterval
    ) -> AppleWatchStudyReport {
        let results = AppleWatchStudyMetric.allCases.map { metric in
            makeResult(metric: metric, measurements: measurements, references: references, interval: interval)
        }
        return AppleWatchStudyReport(interval: interval, results: results)
    }

    private func makeResult(
        metric: AppleWatchStudyMetric,
        measurements: [HealthMeasurement],
        references: [AppleWatchReferenceSample],
        interval: DateInterval
    ) -> AppleWatchMetricStudyResult {
        let allEven = measurements.filter {
            $0.kind == measurementKind(for: metric) && interval.contains($0.timestamp)
        }
        let candidates = allEven.compactMap { item -> TimedValue? in
            guard item.validation != .duplicate,
                  item.validation != .malformed,
                  item.validation != .implausible,
                  item.validation != .conflict,
                  let value = comparableValue(for: item, metric: metric) else { return nil }
            return TimedValue(timestamp: item.timestamp, value: value)
        }
        let appleWatch = references
            .filter { $0.metric == metric && interval.contains($0.timestamp) }
            .map { TimedValue(timestamp: $0.timestamp, value: $0.value) }
            .sorted { $0.timestamp < $1.timestamp }
        let pairings = pair(candidates.sorted { $0.timestamp < $1.timestamp }, with: appleWatch, tolerance: metric.matchingTolerance)
        let differences: [Double] = metric.supportsNumericDifference
            ? pairings.map { abs($0.even.value - $0.reference.value) }
            : []
        return AppleWatchMetricStudyResult(
            metric: metric,
            evenRecordsInRange: allEven.count,
            comparableEvenRecords: candidates.count,
            appleWatchRecords: appleWatch.count,
            matchedRecords: pairings.count,
            unmatchedEvenRecords: candidates.count - pairings.count,
            medianAbsoluteDifference: median(differences)
        )
    }

    private func measurementKind(for metric: AppleWatchStudyMetric) -> MeasurementKind {
        switch metric {
        case .steps: .steps
        case .activeEnergy: .calories
        case .heartRate: .heartRate
        case .hrv: .hrv
        case .oxygen: .oxygen
        }
    }

    private func comparableValue(for item: HealthMeasurement, metric: AppleWatchStudyMetric) -> Double? {
        if metric.requiresAverageStatistic,
           item.statistic?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "avg" {
            return nil
        }
        let decimal: Decimal?
        switch metric {
        case .activeEnergy: decimal = item.components["active"]
        default: decimal = item.value
        }
        guard let decimal else { return nil }
        return NSDecimalNumber(decimal: decimal).doubleValue
    }

    private func pair(_ even: [TimedValue], with references: [TimedValue], tolerance: TimeInterval) -> [Pairing] {
        var unused = Set(references.indices)
        var output: [Pairing] = []
        for item in even {
            let closest = unused.min { left, right in
                abs(references[left].timestamp.timeIntervalSince(item.timestamp)) <
                abs(references[right].timestamp.timeIntervalSince(item.timestamp))
            }
            guard let closest,
                  abs(references[closest].timestamp.timeIntervalSince(item.timestamp)) <= tolerance else { continue }
            unused.remove(closest)
            output.append(Pairing(even: item, reference: references[closest]))
        }
        return output
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
        return sorted[middle]
    }

    private struct TimedValue: Sendable {
        let timestamp: Date
        let value: Double
    }

    private struct Pairing: Sendable {
        let even: TimedValue
        let reference: TimedValue
    }
}
