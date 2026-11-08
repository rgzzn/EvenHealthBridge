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
}

public struct ImportPreviewSummary: Sendable {
    public let categories: [CategoryPreviewSummary]

    public init(measurements: [HealthMeasurement], sleepPlan: SleepImportPlan) {
        categories = MeasurementKind.allCases.map { kind in
            let items = measurements.filter { $0.kind == kind }
            let crossArchiveConflicts = kind == .sleep ? sleepPlan.conflicts : 0
            return CategoryPreviewSummary(
                kind: kind,
                records: items.count,
                eligible: items.filter { $0.validation == .eligible }.count,
                new: kind == .sleep ? sleepPlan.newSamples.count : 0,
                alreadyImported: kind == .sleep ? sleepPlan.alreadyImported : 0,
                duplicates: items.filter { $0.validation == .duplicate }.count,
                excluded: items.filter { $0.validation != .eligible && $0.validation != .duplicate }.count + crossArchiveConflicts,
                conflicts: items.filter { $0.validation == .conflict }.count + crossArchiveConflicts,
                periodStart: items.map(\.timestamp).min(),
                periodEnd: items.map { $0.intervalEnd ?? $0.timestamp }.max(),
                sources: Dictionary(items.map { ($0.source, 1) }, uniquingKeysWith: +)
            )
        }
    }
}
