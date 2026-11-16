import Foundation
import Testing
@testable import EvenHealthCore

@Test func appleWatchSourceClassifierUsesProductTypeBeforeTheSourceDisplayName() {
    #expect(AppleWatchSourceClassifier.isAppleWatch(productType: "watch7,20", sourceName: "Other wearable") == true)
    #expect(AppleWatchSourceClassifier.isAppleWatch(productType: "ring1", sourceName: "Apple Watch") == false)
}

@Test func appleWatchSourceClassifierUsesOnlyANarrowHistoricalFallback() {
    #expect(AppleWatchSourceClassifier.isAppleWatch(productType: nil, sourceName: "Luca's Apple Watch") == true)
    #expect(AppleWatchSourceClassifier.isAppleWatch(productType: "  ", sourceName: "Luca's Apple Watch") == true)
    #expect(AppleWatchSourceClassifier.isAppleWatch(productType: nil, sourceName: "Watch export") == false)
}

@Test func referenceSourceDefinitionsCanUseTheirOwnProductTypeAndHistoricalMarker() {
    let futureWearable = ReferenceSourceDefinition(
        id: "future-wearable",
        displayName: "Future wearable",
        productTypePrefix: "future",
        historicalSourceNameMarker: "future wearable"
    )

    #expect(futureWearable.matches(.init(productType: "future1,1", sourceName: "Other source")) == true)
    #expect(futureWearable.matches(.init(productType: nil, sourceName: "Future Wearable")) == true)
    #expect(futureWearable.matches(.init(productType: "watch7,20", sourceName: "Future Wearable")) == false)
}

@Test func discoveredSourceUsesAnExactProductTypeBeforeItsHistoricalNameFallback() {
    let identity = ReferenceSourceIdentity(productType: "ring1,2", sourceName: "Example Ring")
    let discovered = try! #require(ReferenceSourceDefinition.discovered(identity))

    #expect(discovered.matches(.init(productType: "ring1,2", sourceName: "Another source")) == true)
    #expect(discovered.matches(.init(productType: "ring1,3", sourceName: "Example Ring")) == false)
    #expect(discovered.matches(.init(productType: nil, sourceName: "Example Ring export")) == true)
}

@Test func sourceAvailabilityGroupsMetricsWithoutRetainingMeasurements() {
    let observations = [
        ReferenceSourceObservation(
            identity: .init(productType: "watch7,20", sourceName: "Luca's Apple Watch"),
            metric: .steps
        ),
        ReferenceSourceObservation(
            identity: .init(productType: "watch7,20", sourceName: "Luca's Apple Watch"),
            metric: .heartRate
        ),
        ReferenceSourceObservation(
            identity: .init(productType: "ring1,2", sourceName: "Example Ring"),
            metric: .oxygen
        ),
        ReferenceSourceObservation(
            identity: .init(productType: "ring1,3", sourceName: "Example Ring"),
            metric: .oxygen
        )
    ]

    let availability = ReferenceSourceAvailability.summarize(observations)
    let watch = availability.first { $0.source == .appleWatch }
    let ringOne = availability.first { $0.source.productTypePrefix == "ring1,2" }
    let ringTwo = availability.first { $0.source.productTypePrefix == "ring1,3" }

    #expect(watch?.metrics == [.steps, .heartRate])
    #expect(watch?.totalSamples == 2)
    #expect(ringOne?.metrics == [.oxygen])
    #expect(ringTwo?.metrics == [.oxygen])
}

@Test func referenceSampleRetainsOnlyAValidSourceInterval() {
    let start = Date(timeIntervalSince1970: 1_700_600_000)
    let timed = SourceCoverageReferenceSample(
        metric: .steps,
        timestamp: start,
        intervalEnd: start.addingTimeInterval(15 * 60),
        value: 20
    )
    let instantaneous = SourceCoverageReferenceSample(
        metric: .heartRate,
        timestamp: start,
        intervalEnd: start,
        value: 70
    )

    #expect(timed.interval?.start == start)
    #expect(timed.interval?.end == start.addingTimeInterval(15 * 60))
    #expect(instantaneous.interval == nil)
}

@Test func studyRequestsOnlyMetricTypesPresentInItsSelectedWindow() {
    let origin = Date(timeIntervalSince1970: 1_700_700_000)
    let steps = measurement(kind: .steps, timestamp: origin, value: 120)
    let heartRate = measurement(kind: .heartRate, timestamp: origin.addingTimeInterval(60), value: 70, statistic: "avg")
    let oxygenOutsideWindow = measurement(kind: .oxygen, timestamp: origin.addingTimeInterval(120), value: 98, statistic: "avg")
    let interval = DateInterval(start: origin, end: origin.addingTimeInterval(120))

    let metrics = AppleWatchStudyEngine().metricsForStudy(
        measurements: [steps, heartRate, oxygenOutsideWindow], interval: interval
    )

    #expect(metrics == [.steps, .heartRate])
}

@Test func studyUsesOnlyAverageHeartRateAndPairsEachWatchSampleOnce() {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    let average = measurement(kind: .heartRate, timestamp: origin, value: 70, statistic: "avg")
    let minimum = measurement(kind: .heartRate, timestamp: origin, value: 55, statistic: "min")
    let laterAverage = measurement(kind: .heartRate, timestamp: origin.addingTimeInterval(60), value: 73, statistic: "avg")
    let reference = AppleWatchReferenceSample(metric: .heartRate, timestamp: origin.addingTimeInterval(30), value: 72)

    let report = AppleWatchStudyEngine().study(
        measurements: [average, minimum, laterAverage], references: [reference],
        interval: DateInterval(start: origin.addingTimeInterval(-1), end: origin.addingTimeInterval(120))
    )
    let result = report.results.first { $0.metric == .heartRate }

    #expect(result?.evenRecordsInRange == 3)
    #expect(result?.comparableEvenRecords == 2)
    #expect(result?.matchedRecords == 1)
    #expect(result?.unmatchedEvenRecords == 1)
    #expect(result?.medianAbsoluteDifference == 2)
    #expect(report.referenceRecordCount == 1)
}

@Test func studyUsesActiveCaloriesAndExcludesDuplicateRows() {
    let origin = Date(timeIntervalSince1970: 1_700_100_000)
    let usable = measurement(kind: .calories, timestamp: origin, value: 14, components: ["active": 9])
    let duplicate = measurement(kind: .calories, timestamp: origin.addingTimeInterval(60), value: 20, components: ["active": 12], validation: .duplicate)
    let reference = AppleWatchReferenceSample(metric: .activeEnergy, timestamp: origin, value: 8)
    let report = AppleWatchStudyEngine().study(
        measurements: [usable, duplicate], references: [reference],
        interval: DateInterval(start: origin.addingTimeInterval(-1), end: origin.addingTimeInterval(120))
    )
    let result = report.results.first { $0.metric == .activeEnergy }

    #expect(result?.evenRecordsInRange == 2)
    #expect(result?.comparableEvenRecords == 1)
    #expect(result?.matchedRecords == 1)
    #expect(result?.medianAbsoluteDifference == nil)
}

@Test func coverageMatchingMaximizesPairsInsteadOfTakingTheNearestFirstReference() {
    let origin = Date(timeIntervalSince1970: 1_700_200_000)
    let first = measurement(id: "even-first", kind: .heartRate, timestamp: origin, value: 70, statistic: "avg")
    let second = measurement(id: "even-second", kind: .heartRate, timestamp: origin.addingTimeInterval(10 * 60), value: 74, statistic: "avg")
    let earlierReference = AppleWatchReferenceSample(id: "watch-earlier", metric: .heartRate, timestamp: origin.addingTimeInterval(-5 * 60), value: 71)
    let laterReference = AppleWatchReferenceSample(id: "watch-later", metric: .heartRate, timestamp: origin.addingTimeInterval(4 * 60), value: 75)

    let result = AppleWatchStudyEngine().study(
        measurements: [second, first], references: [laterReference, earlierReference],
        interval: DateInterval(start: origin.addingTimeInterval(-10 * 60), end: origin.addingTimeInterval(20 * 60))
    ).results.first { $0.metric == .heartRate }

    #expect(result?.matchedRecords == 2)
    #expect(result?.unmatchedEvenRecords == 0)
    #expect(result?.unmatchedReferenceRecords == 0)
}

@Test func temporalOnlyContractsNeverProduceANumericDifference() {
    let origin = Date(timeIntervalSince1970: 1_700_300_000)
    let hrv = measurement(id: "hrv", kind: .hrv, timestamp: origin, value: 42, statistic: "avg")
    let reference = AppleWatchReferenceSample(id: "watch-hrv", metric: .hrv, timestamp: origin, value: 9)

    let result = AppleWatchStudyEngine().study(
        measurements: [hrv], references: [reference],
        interval: DateInterval(start: origin.addingTimeInterval(-1), end: origin.addingTimeInterval(1))
    ).results.first { $0.metric == .hrv }

    #expect(result?.matchedRecords == 1)
    #expect(result?.medianAbsoluteDifference == nil)
    #expect(result?.contract.comparisonMode == .temporalPresence)
    #expect(result?.contract.writeStatus == .blockedByUnknownMetric)
}

@Test func coverageReportsParserConflictsAndNeverPairsExcludedMeasurements() {
    let origin = Date(timeIntervalSince1970: 1_700_400_000)
    let usable = measurement(id: "usable", kind: .oxygen, timestamp: origin, value: 97, statistic: "avg")
    let conflict = measurement(id: "conflict", kind: .oxygen, timestamp: origin, value: 98, statistic: "avg", validation: .conflict)
    let duplicate = measurement(id: "duplicate", kind: .oxygen, timestamp: origin, value: 99, statistic: "avg", validation: .duplicate)
    let references = [
        AppleWatchReferenceSample(id: "watch-usable", metric: .oxygen, timestamp: origin, value: 97),
        AppleWatchReferenceSample(id: "watch-unused", metric: .oxygen, timestamp: origin.addingTimeInterval(60), value: 98)
    ]

    let result = AppleWatchStudyEngine().study(
        measurements: [usable, conflict, duplicate], references: references,
        interval: DateInterval(start: origin.addingTimeInterval(-1), end: origin.addingTimeInterval(120))
    ).results.first { $0.metric == .oxygen }

    #expect(result?.evenRecordsInRange == 3)
    #expect(result?.comparableEvenRecords == 1)
    #expect(result?.excludedEvenRecords == 2)
    #expect(result?.conflictingEvenRecords == 1)
    #expect(result?.matchedRecords == 1)
    #expect(result?.unmatchedReferenceRecords == 1)
}

@Test func coverageUsesAnEndExclusiveStudyInterval() {
    let origin = Date(timeIntervalSince1970: 1_700_500_000)
    let inside = measurement(id: "inside", kind: .heartRate, timestamp: origin, value: 70, statistic: "avg")
    let atEnd = measurement(id: "at-end", kind: .heartRate, timestamp: origin.addingTimeInterval(60), value: 71, statistic: "avg")
    let reference = AppleWatchReferenceSample(id: "watch", metric: .heartRate, timestamp: origin, value: 70)

    let result = AppleWatchStudyEngine().study(
        measurements: [inside, atEnd], references: [reference],
        interval: DateInterval(start: origin, end: origin.addingTimeInterval(60))
    ).results.first { $0.metric == .heartRate }

    #expect(result?.evenRecordsInRange == 1)
    #expect(result?.matchedRecords == 1)
}

private func measurement(
    id: String = UUID().uuidString,
    kind: MeasurementKind,
    timestamp: Date,
    value: Decimal,
    statistic: String? = nil,
    components: [String: Decimal] = [:],
    validation: ImportValidation = .ambiguousSemantics
) -> HealthMeasurement {
    HealthMeasurement(
        id: id, kind: kind, timestamp: timestamp,
        originalTimestamp: timestamp.ISO8601Format(), source: "R1", value: value,
        components: components, originalUnit: nil, canonicalUnit: nil, statistic: statistic,
        intervalEnd: nil, sleepStage: nil, sessionEnd: nil, provenance: "fixture.csv", validation: validation
    )
}
