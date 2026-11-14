import Foundation
import Testing
@testable import EvenHealthCore

@Test func overlayPlannerNeverAdmitsAnUnvalidatedCategory() {
    let planner = ConservativeOverlayPlanner()
    let start = Date(timeIntervalSince1970: 1_700_700_000)
    let heartRate = measurement(id: "heart-rate", kind: .heartRate, start: start, end: start.addingTimeInterval(60))

    let plan = planner.plan(measurements: [heartRate], existingCoverage: [])

    #expect(plan.candidates.isEmpty)
    #expect(plan.exclusions == [.init(measurementID: "heart-rate", reason: .notEligibleForAutomaticWriting(.requiresHeartRateAggregationInterval))])
}

@Test func overlayPlannerAcceptsOnlyAWholeEligibleUncoveredInterval() {
    let planner = ConservativeOverlayPlanner()
    let start = Date(timeIntervalSince1970: 1_700_710_000)
    let uncovered = measurement(id: "uncovered", kind: .sleep, start: start, end: start.addingTimeInterval(60))
    let covered = measurement(id: "covered", kind: .sleep, start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))
    let coverage = ExistingHealthCoverage(kind: .sleep, interval: DateInterval(start: start.addingTimeInterval(90), end: start.addingTimeInterval(150)))

    let plan = planner.plan(measurements: [covered, uncovered], existingCoverage: [coverage])

    #expect(plan.candidates.map(\.id) == ["uncovered"])
    #expect(plan.exclusions == [.init(measurementID: "covered", reason: .overlapsExistingCoverage)])
}

@Test func overlayPlannerUsesEndExclusiveIntervalsAndNeverSplitsOverlappingEvenSamples() {
    let planner = ConservativeOverlayPlanner()
    let start = Date(timeIntervalSince1970: 1_700_720_000)
    let first = measurement(id: "first", kind: .sleep, start: start, end: start.addingTimeInterval(60))
    let touching = measurement(id: "touching", kind: .sleep, start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))
    let overlapping = measurement(id: "overlapping", kind: .sleep, start: start.addingTimeInterval(30), end: start.addingTimeInterval(90))

    let plan = planner.plan(measurements: [overlapping, touching, first], existingCoverage: [])

    #expect(plan.candidates.map(\.id) == ["first", "touching"])
    #expect(plan.exclusions == [.init(measurementID: "overlapping", reason: .overlapsAnotherEvenMeasurement)])
}

private func measurement(id: String, kind: MeasurementKind, start: Date, end: Date) -> HealthMeasurement {
    .init(
        id: id,
        kind: kind,
        timestamp: start,
        originalTimestamp: "",
        source: "fixture",
        value: 1,
        components: [:],
        originalUnit: nil,
        canonicalUnit: nil,
        statistic: nil,
        intervalEnd: end,
        sleepStage: nil,
        sessionEnd: end,
        provenance: "fixture",
        validation: .eligible
    )
}
