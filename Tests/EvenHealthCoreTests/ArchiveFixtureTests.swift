import Foundation
import Testing
import ZIPFoundation
@testable import EvenHealthCore

private func withArchive(_ files: [String: String], body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("fixture.zip")
    let archive = try Archive(url: url, accessMode: .create)
    for (path, contents) in files.sorted(by: { $0.key < $1.key }) {
        let data = Data(contents.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, count in
            data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count))
        }
    }
    try body(url)
}

@Test func sevenCSVFixtureAndValidatedSleep() throws {
    let time = "2026-10-25T02:30:00+02:00"
    let sleepStart = "2026-10-25T01:00:00+02:00"
    let sleepEnd = "2026-10-25T01:01:00+02:00"
    let stages = "\"[{\"\"type\"\":2,\"\"half_minutes\"\":2}]\""
    let sleepHeader = "timestamp,start_ts,end_ts,total_time,wake_time,rem_time,light_time,deep_time,stages,source,tz,body_temp_delta\n"
    let sleepR1 = "\(time),\(sleepStart),\(sleepEnd),60,0,0,60,0,\(stages),R1,+02:00,\n"
    let sleepNotify = "\(time),\(sleepStart),\(sleepEnd),60,0,0,60,0,\(stages),ring1Notify,+02:00,\n"
    let files = [
        "nested/steps.csv": "timestamp,value,source\n\(time),46,R1\n\(time),46.0,ring1Notify\n",
        "nested/calories.csv": "timestamp,value,resting,active,source\n\(time),10,8,2,R1\n",
        "nested/heart_rate.csv": "timestamp,value,source,ty\n\(time),62,R1,avg\n",
        "nested/hrv.csv": "timestamp,value,source,ty\n\(time),42,R1,avg\n",
        "nested/blood_oxygen.csv": "timestamp,value,source,ty\n\(time),97,R1,avg\n",
        "nested/sleep.csv": sleepHeader + sleepR1 + sleepNotify,
        "nested/skin_temperature.csv": "timestamp,value,source\n\(time),35,R1\n"
    ]
    try withArchive(files) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.warnings.isEmpty)
        #expect(dataset.measurements.count == 9)
        #expect(Set(dataset.measurements.map(\.kind)) == Set(MeasurementKind.allCases))
        #expect(dataset.measurements.filter { $0.validation == .eligible }.count == 1)
        #expect(dataset.measurements.filter { $0.validation == .duplicate }.count == 2)
        let calories = dataset.measurements.first { $0.kind == .calories }
        #expect(calories?.components["resting"] == 8)
        #expect(calories?.components["active"] == 2)
        let plan = SleepImportPlanner().plan(dataset.measurements, imported: [])
        let preview = ImportPreviewSummary(measurements: dataset.measurements, sleepPlan: plan)
        let sleep = preview.categories.first { $0.kind == .sleep }
        #expect(sleep?.records == 2)
        #expect(sleep?.new == 1)
        #expect(sleep?.duplicates == 1)
        #expect(sleep?.excluded == 0)
        #expect(sleep?.periodEnd == EvenDataParser.parseDate(sleepEnd))
        let steps = preview.categories.first { $0.kind == .steps }
        #expect(steps?.records == 2)
        #expect(steps?.new == 0)
        #expect(steps?.duplicates == 1)
        #expect(steps?.excluded == 1)
        #expect(steps?.sources["R1"] == 1)
        #expect(steps?.sources["ring1Notify"] == 1)
    }
}

@Test func duplicateCSVFilenameIsRejected() throws {
    try withArchive(["one/steps.csv": "timestamp,value,source\n", "two/steps.csv": "timestamp,value,source\n"]) { url in
        #expect(throws: ZIPImportError.self) { try ZIPExtractionService().readCSV(at: url) }
    }
}

@Test func malformedSleepIsExcludedWithWarning() throws {
    let files = ["sleep.csv": "timestamp,start_ts,end_ts,total_time,wake_time,rem_time,light_time,deep_time,stages,source,tz,body_temp_delta\n2026-01-01T00:00:00Z,2026-01-01T00:00:00Z,2026-01-01T00:01:00Z,60,0,0,60,0,\"[{\"\"type\"\":2,\"\"half_minutes\"\":1}]\",R1,+00:00,\n"]
    try withArchive(files) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.measurements.isEmpty)
        #expect(dataset.warnings.contains { $0.contains("sessione non valida") })
    }
}

@Test func duplicateCSVHeaderThrows() {
    #expect(throws: CSVError.duplicateHeader) {
        try CSVParsingService().parse(Data("timestamp,timestamp\na,b\n".utf8))
    }
}

@Test func traversalEntryIsRejected() throws {
    try withArchive(["../steps.csv": "timestamp,value,source\n"]) { url in
        #expect(throws: ZIPImportError.self) { try ZIPExtractionService().readCSV(at: url) }
    }
}

@Test func oversizedArchiveIsRejectedBeforeZIPParsing() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 50_000_001)
    try handle.close()
    do {
        _ = try ZIPExtractionService().readCSV(at: url)
        Issue.record("Expected archive size limit")
    } catch ZIPImportError.archiveTooLarge { }
    catch { Issue.record("Unexpected error: \(error)") }
}

@Test func differingStageSequencesRejectEntireSession() throws {
    let header = "timestamp,start_ts,end_ts,total_time,wake_time,rem_time,light_time,deep_time,stages,source,tz,body_temp_delta\n"
    let prefix = "2026-01-01T00:00:00Z,2026-01-01T00:00:00Z,2026-01-01T00:01:00Z,60,0,0,60,0,"
    let single = "\"[{\"\"type\"\":2,\"\"half_minutes\"\":2}]\""
    let split = "\"[{\"\"type\"\":2,\"\"half_minutes\"\":1},{\"\"type\"\":2,\"\"half_minutes\"\":1}]\""
    let file = header + prefix + single + ",R1,+00:00,\n" + prefix + split + ",ring1Notify,+00:00,\n"
    try withArchive(["sleep.csv": file]) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.measurements.count == 3)
        #expect(dataset.measurements.allSatisfy { $0.validation == .conflict })
    }
}

@Test func conflictingRowsFromSameSourceRejectEntireSleepSession() throws {
    let header = "timestamp,start_ts,end_ts,total_time,wake_time,rem_time,light_time,deep_time,stages,source,tz,body_temp_delta\n"
    let prefix = "2026-01-01T00:00:00Z,2026-01-01T00:00:00Z,2026-01-01T00:01:00Z,60,0,0,60,0,"
    let single = "\"[{\"\"type\"\":2,\"\"half_minutes\"\":2}]\""
    let split = "\"[{\"\"type\"\":2,\"\"half_minutes\"\":1},{\"\"type\"\":2,\"\"half_minutes\"\":1}]\""
    let file = header + prefix + single + ",R1,+00:00,\n" + prefix + split + ",R1,+00:00,\n"
    try withArchive(["sleep.csv": file]) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.measurements.count == 3)
        #expect(dataset.measurements.allSatisfy { $0.validation == .conflict })
        #expect(SleepImportPlanner().plan(dataset.measurements, imported: []).newSamples.isEmpty)
    }
}

@Test func identicalRepeatedSleepRowRemainsDeduplicated() throws {
    let header = "timestamp,start_ts,end_ts,total_time,wake_time,rem_time,light_time,deep_time,stages,source,tz,body_temp_delta\n"
    let stages = "\"[{\"\"type\"\":2,\"\"half_minutes\"\":2}]\""
    let prefix = "2026-01-01T00:00:00Z,2026-01-01T00:00:00Z,2026-01-01T00:01:00Z,60,0,0,60,0,\(stages),"
    let file = header + prefix + "R1,+00:00,\n" + prefix + "R1,+00:00,\n" + prefix + "ring1Notify,+00:00,\n"
    try withArchive(["sleep.csv": file]) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.measurements.filter { $0.validation == .eligible }.count == 1)
        #expect(dataset.measurements.filter { $0.validation == .duplicate }.count == 2)
        #expect(dataset.measurements.allSatisfy { $0.validation != .conflict })
    }
}

@Test func implausiblyLongSleepSessionIsRejected() throws {
    let header = "timestamp,start_ts,end_ts,total_time,wake_time,rem_time,light_time,deep_time,stages,source,tz,body_temp_delta\n"
    let stages = "\"[{\"\"type\"\":2,\"\"half_minutes\"\":1500},{\"\"type\"\":2,\"\"half_minutes\"\":1500}]\""
    let row = "2026-01-01T00:00:00Z,2026-01-01T00:00:00Z,2026-01-02T01:00:00Z,90000,0,0,90000,0,\(stages),R1,+00:00,\n"
    try withArchive(["sleep.csv": header + row]) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.measurements.isEmpty)
        #expect(dataset.warnings.contains { $0.contains("sessione non valida") })
    }
}

@Test func malformedCSVRecordDoesNotDiscardOtherMeasurements() throws {
    let file = "timestamp,value,source\n2026-01-01T00:00:00Z,12,R1\ninvalid,columns\n2026-01-01T00:01:00Z,13,R1\n"
    try withArchive(["steps.csv": file]) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.measurements.filter { $0.kind == .steps }.count == 2)
        #expect(dataset.warnings.contains("steps.csv: record CSV 3 scartato"))
    }
}

@Test func malformedCSVWarningsAreBounded() throws {
    let file = "timestamp,value,source\n" + Array(repeating: "bad,row\n", count: 150).joined()
    try withArchive(["steps.csv": file]) { url in
        let dataset = try EvenDataParser().parseArchive(at: url)
        #expect(dataset.measurements.isEmpty)
        #expect(dataset.warnings.count == 101)
        #expect(dataset.warnings.last?.contains("Altri 56 avvisi omessi") == true)
    }
}
