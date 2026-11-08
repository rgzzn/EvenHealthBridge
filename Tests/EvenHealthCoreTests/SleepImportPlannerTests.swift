import Foundation
import Testing
@testable import EvenHealthCore

private func stage(_ id: String, start: TimeInterval, end: TimeInterval, sessionStart: TimeInterval = 0, sessionEnd: TimeInterval = 120, code: Int = 2) -> HealthMeasurement {
    let origin = Date(timeIntervalSince1970: sessionStart)
    let iso = ISO8601DateFormatter().string(from: origin)
    return HealthMeasurement(id: id, kind: .sleep, timestamp: Date(timeIntervalSince1970: start), originalTimestamp: iso, source: "R1", value: nil, components: [:], originalUnit: "half_minutes", canonicalUnit: "seconds", statistic: nil, intervalEnd: Date(timeIntervalSince1970: end), sleepStage: code, sessionEnd: Date(timeIntervalSince1970: sessionEnd), provenance: "sleep.csv", validation: .eligible)
}

private func stored(_ item: HealthMeasurement) -> ImportedSleepSample {
    ImportedSleepSample(id: item.id, start: item.timestamp, end: item.intervalEnd!, sessionStart: EvenDataParser.parseDate(item.originalTimestamp)!, sessionEnd: item.sessionEnd!, stage: item.sleepStage!)
}

@Test func repeatArchiveProducesNoNewSleep() {
    let samples = [stage("a", start: 0, end: 60), stage("b", start: 60, end: 120)]
    let plan = SleepImportPlanner().plan(samples, imported: samples.map(stored))
    #expect(plan.newSamples.isEmpty)
    #expect(plan.alreadyImported == 2)
    #expect(plan.conflicts == 0)
}

@Test func interruptedImportResumesMissingStages() {
    let samples = [stage("a", start: 0, end: 60), stage("b", start: 60, end: 120)]
    let plan = SleepImportPlanner().plan(samples, imported: [stored(samples[0])])
    #expect(plan.newSamples.map(\.id) == ["b"])
    #expect(plan.alreadyImported == 1)
}

@Test func overlappingExportRejectsWholeSession() {
    let prior = stage("prior", start: 0, end: 120)
    let candidates = [stage("a", start: 60, end: 120, sessionStart: 60, sessionEnd: 180), stage("b", start: 120, end: 180, sessionStart: 60, sessionEnd: 180)]
    let plan = SleepImportPlanner().plan(candidates, imported: [stored(prior)])
    #expect(plan.newSamples.isEmpty)
    #expect(plan.conflicts == 2)
    let preview = ImportPreviewSummary(measurements: candidates, sleepPlan: plan)
    let sleep = preview.categories.first { $0.kind == .sleep }
    #expect(sleep?.records == 2)
    #expect(sleep?.new == 0)
    #expect(sleep?.excluded == 2)
    #expect(sleep?.conflicts == 2)
}

@Test func changedStageConflictsInsteadOfReplacing() {
    let prior = stage("same", start: 0, end: 120)
    let changed = stage("same", start: 0, end: 120, code: 3)
    let plan = SleepImportPlanner().plan([changed], imported: [stored(prior)])
    #expect(plan.newSamples.isEmpty)
    #expect(plan.conflicts == 1)
}
