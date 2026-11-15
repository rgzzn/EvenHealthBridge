import Foundation

/// Stable source metadata extracted by a HealthKit adapter before it reaches the domain layer.
public struct ReferenceSourceIdentity: Sendable, Hashable {
    public let productType: String?
    public let sourceName: String

    public init(productType: String?, sourceName: String) {
        self.productType = productType
        self.sourceName = sourceName
    }
}

/// A conservative definition of one reference wearable.
///
/// Product type is preferred because a source name is user-visible, localized, and mutable. The name
/// marker only supports historical samples for which HealthKit did not save a product type.
public struct ReferenceSourceDefinition: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let productTypePrefix: String
    public let historicalSourceNameMarker: String
    /// A person-selected source uses the complete product type reported by HealthKit. It must not
    /// widen into another device just because their product type shares a textual prefix.
    public let requiresExactProductType: Bool

    public init(
        id: String,
        displayName: String,
        productTypePrefix: String,
        historicalSourceNameMarker: String,
        requiresExactProductType: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.productTypePrefix = productTypePrefix
        self.historicalSourceNameMarker = historicalSourceNameMarker
        self.requiresExactProductType = requiresExactProductType
    }

    public func matches(_ identity: ReferenceSourceIdentity) -> Bool {
        if let productType = identity.productType {
            let actual = productType.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = productTypePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !actual.isEmpty, !expected.isEmpty else { return false }
            if requiresExactProductType {
                return actual.caseInsensitiveCompare(expected) == .orderedSame
            }
            return actual.lowercased().hasPrefix(expected.lowercased())
        }

        guard !historicalSourceNameMarker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return identity.sourceName.localizedCaseInsensitiveContains(historicalSourceNameMarker)
    }

    public static let appleWatch = Self(
        id: "apple-watch",
        displayName: "Apple Watch",
        productTypePrefix: "watch",
        historicalSourceNameMarker: "apple watch"
    )

    /// Builds a temporary, exact definition from a source selected in the local study UI.
    /// Product type remains the preferred identity; the source name is used only for older
    /// HealthKit samples where the product type is unavailable.
    public static func discovered(_ identity: ReferenceSourceIdentity) -> Self? {
        let sourceName = identity.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceName.isEmpty else { return nil }
        let productType = identity.productType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableProductType = productType?.isEmpty == false ? productType! : nil
        let id = ["discovered-source", usableProductType ?? "historical", sourceName].joined(separator: "|")
        return Self(
            id: id,
            displayName: sourceName,
            productTypePrefix: usableProductType ?? "",
            historicalSourceNameMarker: sourceName,
            requiresExactProductType: usableProductType != nil
        )
    }
}

/// Compatibility facade for the current Apple Watch UI.
public enum AppleWatchSourceClassifier: Sendable {
    public static func isAppleWatch(productType: String?, sourceName: String) -> Bool {
        ReferenceSourceDefinition.appleWatch.matches(.init(productType: productType, sourceName: sourceName))
    }
}

/// Stable metric keys shared by local coverage studies, regardless of the reference wearable.
public enum SourceCoverageMetric: String, CaseIterable, Sendable, Identifiable {
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
}

/// Source metadata observed while scanning a selected local HealthKit study window.
/// It deliberately contains no measurement value or timestamp.
public struct ReferenceSourceObservation: Sendable, Hashable {
    public let identity: ReferenceSourceIdentity
    public let metric: SourceCoverageMetric

    public init(identity: ReferenceSourceIdentity, metric: SourceCoverageMetric) {
        self.identity = identity
        self.metric = metric
    }
}

/// A temporary summary used to let the person choose a useful comparison source.
/// This is not persisted and cannot change any HealthKit import decision.
public struct ReferenceSourceAvailability: Sendable, Identifiable {
    public let source: ReferenceSourceDefinition
    public let sampleCounts: [SourceCoverageMetric: Int]

    public var id: String { source.id }
    public var metrics: [SourceCoverageMetric] {
        SourceCoverageMetric.allCases.filter { sampleCounts[$0, default: 0] > 0 }
    }
    public var totalSamples: Int { sampleCounts.values.reduce(0, +) }

    public init(source: ReferenceSourceDefinition, sampleCounts: [SourceCoverageMetric: Int]) {
        self.source = source
        self.sampleCounts = sampleCounts
    }

    public static func summarize(_ observations: [ReferenceSourceObservation]) -> [Self] {
        var countsBySource: [ReferenceSourceDefinition: [SourceCoverageMetric: Int]] = [:]
        for observation in observations {
            let source: ReferenceSourceDefinition?
            if ReferenceSourceDefinition.appleWatch.matches(observation.identity) {
                source = .appleWatch
            } else {
                source = .discovered(observation.identity)
            }
            guard let source else { continue }
            var metricCounts = countsBySource[source, default: [:]]
            metricCounts[observation.metric, default: 0] += 1
            countsBySource[source] = metricCounts
        }
        return countsBySource.map { Self(source: $0.key, sampleCounts: $0.value) }.sorted {
            $0.source.displayName.localizedCaseInsensitiveCompare($1.source.displayName) == .orderedAscending
        }
    }
}

/// Health import remains disabled for every contract until its semantics and interval are verified.
public enum SourceCoverageWriteStatus: String, Sendable {
    case blockedByUnknownInterval
    case blockedByUnknownMetric
    case blockedByUnverifiedSemantics
}

public enum SourceCoverageComparisonMode: String, Sendable {
    /// Indicates temporal presence only. It must not be interpreted as a numeric comparison or a gap to fill.
    case temporalPresence
    /// A descriptive difference for research. It never determines HealthKit eligibility.
    case descriptiveNumericDifference
}

/// Declarative, conservative rules for one metric. These rules are local evidence rules, not import rules.
public struct SourceCoverageMetricContract: Sendable {
    public let metric: SourceCoverageMetric
    public let measurementKind: MeasurementKind
    public let matchingTolerance: TimeInterval
    public let comparisonMode: SourceCoverageComparisonMode
    public let requiresAverageStatistic: Bool
    public let writeStatus: SourceCoverageWriteStatus

    public init(
        metric: SourceCoverageMetric,
        measurementKind: MeasurementKind,
        matchingTolerance: TimeInterval,
        comparisonMode: SourceCoverageComparisonMode,
        requiresAverageStatistic: Bool,
        writeStatus: SourceCoverageWriteStatus
    ) {
        self.metric = metric
        self.measurementKind = measurementKind
        self.matchingTolerance = matchingTolerance
        self.comparisonMode = comparisonMode
        self.requiresAverageStatistic = requiresAverageStatistic
        self.writeStatus = writeStatus
    }

    public static let standard: [SourceCoverageMetricContract] = [
        .init(metric: .steps, measurementKind: .steps, matchingTolerance: 15 * 60,
              comparisonMode: .temporalPresence, requiresAverageStatistic: false,
              writeStatus: .blockedByUnknownInterval),
        .init(metric: .activeEnergy, measurementKind: .calories, matchingTolerance: 15 * 60,
              comparisonMode: .temporalPresence, requiresAverageStatistic: false,
              writeStatus: .blockedByUnknownInterval),
        .init(metric: .heartRate, measurementKind: .heartRate, matchingTolerance: 15 * 60,
              comparisonMode: .descriptiveNumericDifference, requiresAverageStatistic: true,
              writeStatus: .blockedByUnknownInterval),
        .init(metric: .hrv, measurementKind: .hrv, matchingTolerance: 70 * 60,
              comparisonMode: .temporalPresence, requiresAverageStatistic: true,
              writeStatus: .blockedByUnknownMetric),
        .init(metric: .oxygen, measurementKind: .oxygen, matchingTolerance: 70 * 60,
              comparisonMode: .descriptiveNumericDifference, requiresAverageStatistic: true,
              writeStatus: .blockedByUnverifiedSemantics)
    ]
}

/// A normalized sample from a reference source. The core does not import HealthKit or identify wearables.
public struct SourceCoverageReferenceSample: Sendable, Hashable {
    public let id: String
    public let metric: SourceCoverageMetric
    public let timestamp: Date
    /// End of the source sample, when the source reports a duration. Instantaneous samples use `nil`.
    public let intervalEnd: Date?
    public let value: Double

    public init(
        id: String? = nil,
        metric: SourceCoverageMetric,
        timestamp: Date,
        intervalEnd: Date? = nil,
        value: Double
    ) {
        self.id = id ?? "\(metric.rawValue)-\(timestamp.timeIntervalSinceReferenceDate)-\(value)"
        self.metric = metric
        self.timestamp = timestamp
        self.intervalEnd = intervalEnd
        self.value = value
    }

    /// A valid half-open interval when the source supplied one; otherwise this is an instantaneous sample.
    public var interval: DateInterval? {
        guard let intervalEnd, intervalEnd > timestamp else { return nil }
        return DateInterval(start: timestamp, end: intervalEnd)
    }
}

public struct SourceCoverageMetricResult: Sendable, Identifiable {
    public let contract: SourceCoverageMetricContract
    public let evenRecordsInRange: Int
    public let comparableEvenRecords: Int
    public let excludedEvenRecords: Int
    public let conflictingEvenRecords: Int
    public let referenceRecords: Int
    public let matchedRecords: Int
    public let unmatchedEvenRecords: Int
    public let unmatchedReferenceRecords: Int
    public let medianAbsoluteDifference: Double?

    public var id: SourceCoverageMetric { contract.metric }
    public var metric: SourceCoverageMetric { contract.metric }

    public var coverage: Double? {
        guard comparableEvenRecords > 0 else { return nil }
        return Double(matchedRecords) / Double(comparableEvenRecords)
    }
}

public struct SourceCoverageReport: Sendable {
    public let interval: DateInterval
    public let results: [SourceCoverageMetricResult]

    /// Total reference samples returned for the selected study interval.
    /// This is a count only; the report never retains HealthKit samples themselves.
    public var referenceRecordCount: Int {
        results.reduce(into: 0) { total, result in
            total += result.referenceRecords
        }
    }

    public init(interval: DateInterval, results: [SourceCoverageMetricResult]) {
        self.interval = interval
        self.results = results
    }
}

/// Pure, local coverage analysis. It never writes HealthKit data and cannot make a metric importable.
public struct SourceCoverageEngine: Sendable {
    private let contracts: [SourceCoverageMetricContract]

    public init(contracts: [SourceCoverageMetricContract] = SourceCoverageMetricContract.standard) {
        self.contracts = contracts
    }

    public func analyze(
        measurements: [HealthMeasurement],
        references: [SourceCoverageReferenceSample],
        interval: DateInterval
    ) -> SourceCoverageReport {
        SourceCoverageReport(
            interval: interval,
            results: contracts.map { contract in
                makeResult(contract: contract, measurements: measurements, references: references, interval: interval)
            }
        )
    }

    private func makeResult(
        contract: SourceCoverageMetricContract,
        measurements: [HealthMeasurement],
        references: [SourceCoverageReferenceSample],
        interval: DateInterval
    ) -> SourceCoverageMetricResult {
        let allEven = measurements.filter { $0.kind == contract.measurementKind && isInStudyInterval($0.timestamp, interval: interval) }
        let candidates = allEven.compactMap { comparableValue(for: $0, contract: contract) }
        let referenceValues = references
            .filter { $0.metric == contract.metric && isInStudyInterval($0.timestamp, interval: interval) && $0.value.isFinite }
            .map { TimedValue(id: $0.id, timestamp: $0.timestamp, value: $0.value) }
            .sorted(by: TimedValue.order)
        let pairings = pair(candidates.sorted(by: TimedValue.order), with: referenceValues, tolerance: contract.matchingTolerance)
        let differences: [Double]
        switch contract.comparisonMode {
        case .temporalPresence: differences = []
        case .descriptiveNumericDifference: differences = pairings.map { abs($0.even.value - $0.reference.value) }
        }
        return SourceCoverageMetricResult(
            contract: contract,
            evenRecordsInRange: allEven.count,
            comparableEvenRecords: candidates.count,
            excludedEvenRecords: allEven.count - candidates.count,
            conflictingEvenRecords: allEven.filter { $0.validation == .conflict }.count,
            referenceRecords: referenceValues.count,
            matchedRecords: pairings.count,
            unmatchedEvenRecords: candidates.count - pairings.count,
            unmatchedReferenceRecords: referenceValues.count - pairings.count,
            medianAbsoluteDifference: median(differences)
        )
    }

    private func comparableValue(for item: HealthMeasurement, contract: SourceCoverageMetricContract) -> TimedValue? {
        guard item.validation != .duplicate,
              item.validation != .malformed,
              item.validation != .implausible,
              item.validation != .conflict else { return nil }
        if contract.requiresAverageStatistic,
           item.statistic?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "avg" { return nil }
        let decimal: Decimal?
        switch contract.metric {
        case .activeEnergy: decimal = item.components["active"]
        default: decimal = item.value
        }
        guard let decimal else { return nil }
        let value = NSDecimalNumber(decimal: decimal).doubleValue
        guard value.isFinite else { return nil }
        return TimedValue(id: item.id, timestamp: item.timestamp, value: value)
    }

    /// Study windows are half-open: [start, end). Adjacent studies therefore cannot count a boundary sample twice.
    private func isInStudyInterval(_ timestamp: Date, interval: DateInterval) -> Bool {
        timestamp >= interval.start && timestamp < interval.end
    }

    /// Chronological one-to-one matching maximizes the number of pairs under a fixed tolerance.
    /// Stable IDs make equal timestamps deterministic and a reference can never be used twice.
    private func pair(_ even: [TimedValue], with references: [TimedValue], tolerance: TimeInterval) -> [Pairing] {
        var evenIndex = 0
        var referenceIndex = 0
        var output: [Pairing] = []
        while evenIndex < even.count && referenceIndex < references.count {
            let evenValue = even[evenIndex]
            let reference = references[referenceIndex]
            let delta = reference.timestamp.timeIntervalSince(evenValue.timestamp)
            if abs(delta) <= tolerance {
                output.append(Pairing(even: evenValue, reference: reference))
                evenIndex += 1
                referenceIndex += 1
            } else if delta < 0 {
                referenceIndex += 1
            } else {
                evenIndex += 1
            }
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
        let id: String
        let timestamp: Date
        let value: Double

        static func order(_ left: TimedValue, _ right: TimedValue) -> Bool {
            left.timestamp == right.timestamp ? left.id < right.id : left.timestamp < right.timestamp
        }
    }

    private struct Pairing: Sendable {
        let even: TimedValue
        let reference: TimedValue
    }
}

// Compatibility names for the current Apple Watch UI. The domain engine itself is source-neutral.
public typealias AppleWatchStudyMetric = SourceCoverageMetric
public typealias AppleWatchReferenceSample = SourceCoverageReferenceSample
public typealias AppleWatchMetricStudyResult = SourceCoverageMetricResult
public typealias AppleWatchStudyReport = SourceCoverageReport

public struct AppleWatchStudyEngine: Sendable {
    private let coverage: SourceCoverageEngine

    public init(coverage: SourceCoverageEngine = .init()) {
        self.coverage = coverage
    }

    public func study(
        measurements: [HealthMeasurement],
        references: [AppleWatchReferenceSample],
        interval: DateInterval
    ) -> AppleWatchStudyReport {
        coverage.analyze(measurements: measurements, references: references, interval: interval)
    }
}
