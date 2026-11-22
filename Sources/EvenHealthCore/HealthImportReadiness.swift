import Foundation

/// The current, conservative import decision for a category in an Even export.
///
/// This is deliberately separate from parser validation: a row can be syntactically valid while
/// its biomedical meaning or measurement interval remains insufficiently documented for HealthKit.
public enum HealthImportReadiness: String, Sendable, Codable, CaseIterable {
    case availableForValidatedSleep
    case requiresStepIntervalAndSemantics
    case requiresCalorieSemanticsAndInterval
    case requiresHeartRateAggregationInterval
    case requiresConfirmedHRVMetric
    case requiresOxygenSemanticsAndInterval
    /// Even exports a nightly deviation from its own baseline. Apple’s closest sleep-temperature
    /// type contains absolute wrist temperatures and is read-only, so this category supports a
    /// local temporal study only, never a HealthKit write.
    case requiresReadOnlyTemperatureTrendStudy

    public static func current(for kind: MeasurementKind) -> Self {
        switch kind {
        case .sleep: .availableForValidatedSleep
        case .steps: .requiresStepIntervalAndSemantics
        case .calories: .requiresCalorieSemanticsAndInterval
        case .heartRate: .requiresHeartRateAggregationInterval
        case .hrv: .requiresConfirmedHRVMetric
        case .oxygen: .requiresOxygenSemanticsAndInterval
        case .skinTemperature: .requiresReadOnlyTemperatureTrendStudy
        }
    }

    public var permitsAutomaticHealthWrite: Bool {
        self == .availableForValidatedSleep
    }
}
