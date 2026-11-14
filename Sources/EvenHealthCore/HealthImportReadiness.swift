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
    case requiresCompatibleTemperatureSemantics

    public static func current(for kind: MeasurementKind) -> Self {
        switch kind {
        case .sleep: .availableForValidatedSleep
        case .steps: .requiresStepIntervalAndSemantics
        case .calories: .requiresCalorieSemanticsAndInterval
        case .heartRate: .requiresHeartRateAggregationInterval
        case .hrv: .requiresConfirmedHRVMetric
        case .oxygen: .requiresOxygenSemanticsAndInterval
        case .skinTemperature: .requiresCompatibleTemperatureSemantics
        }
    }

    public var permitsAutomaticHealthWrite: Bool {
        self == .availableForValidatedSleep
    }
}
