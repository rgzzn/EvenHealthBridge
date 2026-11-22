import Testing
@testable import EvenHealthCore

@Test func onlyValidatedSleepIsEligibleForAutomaticHealthWriting() {
    for kind in MeasurementKind.allCases {
        let readiness = HealthImportReadiness.current(for: kind)
        #expect(readiness.permitsAutomaticHealthWrite == (kind == .sleep))
    }
}

@Test func eachUnvalidatedCategoryKeepsItsSpecificEvidenceRequirement() {
    #expect(HealthImportReadiness.current(for: .steps) == .requiresStepIntervalAndSemantics)
    #expect(HealthImportReadiness.current(for: .calories) == .requiresCalorieSemanticsAndInterval)
    #expect(HealthImportReadiness.current(for: .heartRate) == .requiresHeartRateAggregationInterval)
    #expect(HealthImportReadiness.current(for: .hrv) == .requiresConfirmedHRVMetric)
    #expect(HealthImportReadiness.current(for: .oxygen) == .requiresOxygenSemanticsAndInterval)
    #expect(HealthImportReadiness.current(for: .skinTemperature) == .requiresReadOnlyTemperatureTrendStudy)
}
