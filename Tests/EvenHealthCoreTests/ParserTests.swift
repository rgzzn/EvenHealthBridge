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
}
