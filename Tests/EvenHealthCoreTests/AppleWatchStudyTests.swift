import Foundation
import Testing
@testable import EvenHealthCore

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

private func measurement(
    kind: MeasurementKind,
    timestamp: Date,
    value: Decimal,
    statistic: String? = nil,
    components: [String: Decimal] = [:],
    validation: ImportValidation = .ambiguousSemantics
) -> HealthMeasurement {
    HealthMeasurement(
        id: UUID().uuidString, kind: kind, timestamp: timestamp,
        originalTimestamp: timestamp.ISO8601Format(), source: "R1", value: value,
        components: components, originalUnit: nil, canonicalUnit: nil, statistic: statistic,
        intervalEnd: nil, sleepStage: nil, sessionEnd: nil, provenance: "fixture.csv", validation: validation
    )
}
