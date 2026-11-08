import Foundation
import Testing
@testable import EvenHealthCore

@Test func quotedCSVAndEmbeddedJSON() throws {
    let data = Data("name,payload\r\n\"a,b\",\"{\"\"type\"\":1}\"\r\n".utf8)
    let rows = try CSVParsingService().parse(data)
    #expect(rows.count == 1)
    #expect(rows.first?["name"] == "a,b")
    #expect(rows.first?["payload"] == "{\"type\":1}")
}

@Test func malformedCSV() {
    #expect(throws: CSVError.unterminatedQuote) {
        try CSVParsingService().parse(Data("x\n\"open".utf8))
    }
}

@Test func malformedQuoteRejectsOnlyItsRecord() throws {
    let data = Data("timestamp,value,source\n2026-01-01T00:00:00Z,12,R1\n2026-01-01T00:01:00Z,\"13\"extra,R1\n2026-01-01T00:02:00Z,14,R1\n".utf8)
    #expect(throws: CSVError.malformedQuote(row: 3)) {
        try CSVParsingService().parse(data)
    }
    let recovered = try CSVParsingService().parseRecovering(data)
    #expect(recovered.recordNumbers == [2, 4])
    #expect(recovered.rejectedRecords == [3])
    #expect(recovered.rows.map { $0["value"] } == ["12", "14"])
}

@Test func quoteInsideUnquotedFieldIsRejected() throws {
    let data = Data("value,source\n1\"2,R1\n13,R1\n".utf8)
    let recovered = try CSVParsingService().parseRecovering(data)
    #expect(recovered.recordNumbers == [3])
    #expect(recovered.rejectedRecords == [2])
}

@Test func recoveringCSVKeepsValidRecords() throws {
    let data = Data("timestamp,value,source\n2026-01-01T00:00:00Z,12,R1\nbad,row\n2026-01-01T00:01:00Z,13,R1\n\"unfinished".utf8)
    let parsed = try CSVParsingService().parseRecovering(data)
    #expect(parsed.rows.count == 2)
    #expect(parsed.recordNumbers == [2, 4])
    #expect(parsed.rejectedRecords == [3, 5])
}

@Test func streamingCSVVisitsLargeFixtureWithoutCollectingRows() throws {
    let count = 10_000
    let csv = "timestamp,value,source\n" +
        (0..<count).map { "2026-01-01T00:00:00Z,\($0),R1\n" }.joined()
    var visited = 0
    var rejected: [Int] = []
    try CSVParsingService().forEachRowRecovering(Data(csv.utf8), onRejected: { rejected.append($0) }) { number, row in
        if visited == 0 || visited == count - 1 {
            #expect(number == visited + 2)
            #expect(row["source"] == "R1")
        }
        visited += 1
    }
    #expect(visited == count)
    #expect(rejected.isEmpty)
}

@Test func timestampsNormalizeOffsets() {
    let a = EvenDataParser.parseDate("2026-10-25T02:30:00+02:00")
    let b = EvenDataParser.parseDate("2026-10-25T02:30:00+01:00")
    #expect(a != nil && b != nil)
    if let a, let b { #expect(b.timeIntervalSince(a) == 3600) }
}

@Test func duplicateSourceValuesCompareNumerically() {
    let date = Date(timeIntervalSince1970: 1_000)
    let first = HealthMeasurement(id: "stable", kind: .steps, timestamp: date, originalTimestamp: "1970-01-01T00:16:40Z", source: "R1", value: Decimal(string: "46"), components: [:], originalUnit: nil, canonicalUnit: nil, statistic: nil, intervalEnd: nil, sleepStage: nil, sessionEnd: nil, provenance: "steps.csv", validation: .ambiguousSemantics)
    let second = HealthMeasurement(id: "stable", kind: .steps, timestamp: date, originalTimestamp: "1970-01-01T00:16:40+00:00", source: "ring1Notify", value: Decimal(string: "46.0"), components: [:], originalUnit: nil, canonicalUnit: nil, statistic: nil, intervalEnd: nil, sleepStage: nil, sessionEnd: nil, provenance: "steps.csv", validation: .ambiguousSemantics)
    let result = MeasurementDeduplicator().resolve([first, second])
    #expect(result[1].validation == .duplicate)
}

@Test func sameTotalWithDifferentCalorieComponentsIsConflict() {
    let date = Date(timeIntervalSince1970: 1_000)
    let common = (id: "same-calories", kind: MeasurementKind.calories, timestamp: date,
                  originalTimestamp: "1970-01-01T00:16:40Z", value: Decimal(10))
    let first = HealthMeasurement(id: common.id, kind: common.kind, timestamp: common.timestamp,
        originalTimestamp: common.originalTimestamp, source: "R1", value: common.value,
        components: ["resting": 8, "active": 2], originalUnit: nil, canonicalUnit: nil,
        statistic: nil, intervalEnd: nil, sleepStage: nil, sessionEnd: nil,
        provenance: "calories.csv", validation: .ambiguousSemantics)
    let second = HealthMeasurement(id: common.id, kind: common.kind, timestamp: common.timestamp,
        originalTimestamp: common.originalTimestamp, source: "ring1Notify", value: common.value,
        components: ["resting": 7, "active": 3], originalUnit: nil, canonicalUnit: nil,
        statistic: nil, intervalEnd: nil, sleepStage: nil, sessionEnd: nil,
        provenance: "calories.csv", validation: .ambiguousSemantics)
    let result = MeasurementDeduplicator().resolve([first, second])
    #expect(result.allSatisfy { $0.validation == .conflict })
    let summary = ImportPreviewSummary(measurements: result,
        sleepPlan: SleepImportPlanner().plan(result, imported: []))
        .categories.first { $0.kind == .calories }
    #expect(summary?.conflicts == 2)
    #expect(summary?.excluded == 2)
}

@Test func missingCalorieComponentsDoNotInventAConflict() {
    let date = Date(timeIntervalSince1970: 1_000)
    func calories(source: String, components: [String: Decimal]) -> HealthMeasurement {
        HealthMeasurement(id: "same-calories", kind: .calories, timestamp: date,
            originalTimestamp: "1970-01-01T00:16:40Z", source: source, value: 10,
            components: components, originalUnit: nil, canonicalUnit: nil, statistic: nil,
            intervalEnd: nil, sleepStage: nil, sessionEnd: nil, provenance: "calories.csv",
            validation: .ambiguousSemantics)
    }
    let result = MeasurementDeduplicator().resolve([
        calories(source: "R1", components: ["resting": 8, "active": 2]),
        calories(source: "ring1Notify", components: [:])
    ])
    #expect(result.map(\.validation) == [.ambiguousSemantics, .duplicate])
}

@Test func sparseFirstCalorieRowDoesNotHideLaterComponentConflict() {
    let date = Date(timeIntervalSince1970: 1_000)
    func calories(_ source: String, components: [String: Decimal]) -> HealthMeasurement {
        HealthMeasurement(id: "same-calories", kind: .calories, timestamp: date,
            originalTimestamp: "1970-01-01T00:16:40Z", source: source, value: 10,
            components: components, originalUnit: nil, canonicalUnit: nil, statistic: nil,
            intervalEnd: nil, sleepStage: nil, sessionEnd: nil, provenance: "calories.csv",
            validation: .ambiguousSemantics)
    }
    let result = MeasurementDeduplicator().resolve([
        calories("ring1Notify", components: [:]),
        calories("R1", components: ["resting": 8, "active": 2]),
        calories("R1", components: ["resting": 7, "active": 3])
    ])
    #expect(result.allSatisfy { $0.validation == .conflict })
}

@Test func sameIdentityWithDifferentValuesIsConflictForBothSources() {
    let date = Date(timeIntervalSince1970: 1_000)
    func step(_ value: Int, source: String) -> HealthMeasurement {
        HealthMeasurement(id: "same-step", kind: .steps, timestamp: date,
            originalTimestamp: "1970-01-01T00:16:40Z", source: source, value: Decimal(value),
            components: [:], originalUnit: nil, canonicalUnit: nil, statistic: nil,
            intervalEnd: nil, sleepStage: nil, sessionEnd: nil, provenance: "steps.csv",
            validation: .ambiguousSemantics)
    }
    let result = MeasurementDeduplicator().resolve([step(46, source: "R1"), step(47, source: "ring1Notify")])
    #expect(result.allSatisfy { $0.validation == .conflict })
}

@Test func optionalLocalRealArchive() throws {
    guard let path = ProcessInfo.processInfo.environment["EVEN_HEALTH_LOCAL_ARCHIVE"] else { return }
    let dataset = try EvenDataParser().parseArchive(at: URL(fileURLWithPath: path))
    #expect(dataset.measurements.count == 3483)
    #expect(dataset.archiveHash.count == 64)
    #expect(dataset.measurements.contains { $0.validation == .duplicate })
    #expect(dataset.measurements.filter { $0.kind == .sleep && $0.validation == .eligible }.count == 25)
    #expect(dataset.measurements.filter { $0.kind == .sleep && $0.validation == .duplicate }.count == 25)
    #expect(dataset.measurements.filter { $0.kind == .sleep && $0.validation == .conflict }.count == 304)
    #expect(dataset.warnings.isEmpty)
    let plan = SleepImportPlanner().plan(dataset.measurements, imported: [])
    let sleep = ImportPreviewSummary(measurements: dataset.measurements, sleepPlan: plan)
        .categories.first { $0.kind == .sleep }
    #expect(sleep?.records == 354)
    #expect(sleep?.new == 25)
    #expect(sleep?.duplicates == 25)
    #expect(sleep?.excluded == 304)
}
