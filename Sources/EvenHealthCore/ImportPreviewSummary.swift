import Foundation

public struct CategoryPreviewSummary: Sendable {
    public let kind: MeasurementKind
    public let records: Int
    public let eligible: Int
    public let new: Int
    public let alreadyImported: Int
    public let duplicates: Int
    public let excluded: Int
    public let conflicts: Int
    public let periodStart: Date?
    public let periodEnd: Date?
    public let sources: [String: Int]
    public let reportedUnits: [String]
    public let reportedStatistics: [String]
    public let recordsWithReportedEnd: Int
}

public struct ImportPreviewSummary: Sendable {
    public let categories: [CategoryPreviewSummary]

    public init(measurements: [HealthMeasurement], sleepPlan: SleepImportPlan,
                quantityPlans: [QuantityImportKind: QuantityImportPlan] = [:]) {
        categories = MeasurementKind.allCases.map { kind in
            let items = measurements.filter { $0.kind == kind }
            let crossArchiveConflicts = kind == .sleep ? sleepPlan.conflicts : 0
            let quantityPlan: QuantityImportPlan? = switch kind {
            case .steps: quantityPlans[.steps]
            case .calories: quantityPlans[.activeEnergy]
            default: nil
            }
            return CategoryPreviewSummary(
                kind: kind,
                records: items.count,
                eligible: items.filter { $0.validation == .eligible }.count,
                new: kind == .sleep ? sleepPlan.newSamples.count : quantityPlan?.newSamples.count ?? 0,
                alreadyImported: kind == .sleep ? sleepPlan.alreadyImported : quantityPlan?.alreadyImported ?? 0,
                duplicates: items.filter { $0.validation == .duplicate }.count,
                excluded: items.filter { $0.validation != .eligible && $0.validation != .duplicate }.count + crossArchiveConflicts + (quantityPlan?.conflicts ?? 0),
                conflicts: items.filter { $0.validation == .conflict }.count + crossArchiveConflicts + (quantityPlan?.conflicts ?? 0),
                periodStart: items.map(\.timestamp).min(),
                periodEnd: items.map { $0.intervalEnd ?? $0.timestamp }.max(),
                sources: Dictionary(items.map { ($0.source, 1) }, uniquingKeysWith: +),
                reportedUnits: Array(Set(items.compactMap(\.originalUnit))).sorted(),
                reportedStatistics: Array(Set(items.compactMap(\.statistic))).sorted(),
                recordsWithReportedEnd: items.filter { $0.intervalEnd != nil }.count
            )
        }
    }
}
