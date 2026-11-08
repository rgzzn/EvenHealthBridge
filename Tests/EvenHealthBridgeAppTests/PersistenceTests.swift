import Foundation
import SwiftData
import Testing
import EvenHealthCore
@testable import EvenHealthBridge

private final class SyntheticArchiveMarker {}

@MainActor @Test func coordinatorAnalyzesSyntheticZIPOnIOS() async throws {
    let archive = try #require(Bundle(for: SyntheticArchiveMarker.self).url(forResource: "SyntheticSleep", withExtension: "zip"))
    let coordinator = ImportCoordinator()
    await coordinator.analyze(archive)

    #expect(coordinator.error == nil)
    let first = try #require(coordinator.dataset)
    #expect(first.measurements.count == 2)
    #expect(first.measurements.filter { $0.validation == .eligible }.count == 1)
    #expect(first.measurements.filter { $0.validation == .duplicate }.count == 1)
    #expect(first.warnings.count == 6)
    #expect(first.warnings.allSatisfy { $0.hasPrefix("File mancante: ") })

    await coordinator.analyze(archive)
    #expect(coordinator.error == nil)
    #expect(coordinator.dataset?.archiveHash == first.archiveHash)
}

@MainActor @Test func savedSleepSurvivesStoreReopen() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("EvenHealthBridge.store")
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(60)
    let sourceTime = ISO8601DateFormatter().string(from: start)
    let sample = HealthMeasurement(
        id: "stable-sleep-id", kind: .sleep, timestamp: start, originalTimestamp: sourceTime,
        source: "R1", value: nil, components: [:], originalUnit: "half_minutes", canonicalUnit: "seconds",
        statistic: nil, intervalEnd: end, sleepStage: 2, sessionEnd: end,
        provenance: "sleep.csv", validation: .eligible
    )

    do {
        let container = try makeContainer(at: storeURL)
        let context = ModelContext(container)
        try SwiftDataSleepRepository(context: context).record(sample)
        #expect(try context.fetchCount(FetchDescriptor<StoredSample>()) == 1)
    }

    let reopened = try makeContainer(at: storeURL)
    let context = ModelContext(reopened)
    let imported = try SwiftDataSleepRepository(context: context).existingSamples()
    #expect(imported.count == 1)
    #expect(imported.first?.id == sample.id)
    let plan = SleepImportPlanner().plan([sample], imported: imported)
    #expect(plan.newSamples.isEmpty)
    #expect(plan.alreadyImported == 1)
}

@MainActor private func makeContainer(at url: URL) throws -> ModelContainer {
    let configuration = ModelConfiguration(url: url, cloudKitDatabase: .none)
    return try ModelContainer(for: StoredImportSession.self, StoredImportAttempt.self, StoredSample.self, configurations: configuration)
}

@MainActor @Test func unavailableLocalStoreNeverFallsBackToEmptyHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = ModelConfiguration(url: directory, cloudKitDatabase: .none)
    #expect(LocalStore.open(configuration: configuration) == nil)
}

@MainActor @Test func interruptedHistoryRecordsSafeReasonAndConfirmedLocalCount() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = ModelContext(try makeContainer(at: directory.appendingPathComponent("Interrupted.store")))
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(60)
    let sample = HealthMeasurement(id: "local-stage", kind: .sleep, timestamp: start,
        originalTimestamp: ISO8601DateFormatter().string(from: start), source: "R1",
        value: nil, components: [:], originalUnit: "half_minutes", canonicalUnit: "seconds",
        statistic: nil, intervalEnd: end, sleepStage: 2, sessionEnd: end,
        provenance: "sleep.csv", validation: .eligible)
    let coordinator = ImportCoordinator()
    coordinator.dataset = ParsedDataset(measurements: [sample], warnings: [], archiveHash: "test-archive")
    try coordinator.recordStartedImport(in: context)
    try SwiftDataSleepRepository(context: context).record(sample)
    try coordinator.recordInterruptedImport(in: context, reason: .permissionDenied)

    let attempt = try #require(context.fetch(FetchDescriptor<StoredImportAttempt>()).first)
    #expect(attempt.writtenSamples == 1)
    #expect(attempt.status.contains("Permesso Salute negato"))
    #expect(attempt.status.contains("registrate localmente"))
    #expect(ImportInterruptionReason(error: NSError(domain: "private health value", code: 1)).title == "Errore di sincronizzazione")
}

@MainActor @Test func repeatedArchiveCreatesDistinctHistoryAttempts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("History.store")
    let dataset = ParsedDataset(measurements: [], warnings: [], archiveHash: "same-archive")

    do {
        let container = try makeContainer(at: storeURL)
        let context = ModelContext(container)
        let first = ImportCoordinator()
        first.dataset = dataset
        try first.recordStartedImport(in: context)
        try first.recordStartedImport(in: context)
        let second = ImportCoordinator()
        second.dataset = dataset
        try second.saveAnalysis(in: context)
        let attempts = try context.fetch(FetchDescriptor<StoredImportAttempt>())
        #expect(attempts.count == 3)
        #expect(Set(attempts.map(\.attemptID)).count == 3)
        #expect(Set(attempts.map(\.archiveHash)) == ["same-archive"])
        #expect(attempts.contains { $0.status == "Importazione avviata; esito da verificare" })
    }

    let reopened = try makeContainer(at: storeURL)
    let context = ModelContext(reopened)
    #expect(try context.fetchCount(FetchDescriptor<StoredImportAttempt>()) == 3)
    #expect(try context.fetch(FetchDescriptor<StoredImportAttempt>()).contains { $0.status == "Importazione avviata; esito da verificare" })
}

@MainActor @Test func legacyHistorySurvivesAddingAttemptModel() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("Legacy.store")

    do {
        let oldConfiguration = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let oldContainer = try ModelContainer(for: StoredImportSession.self, StoredSample.self, configurations: oldConfiguration)
        let context = ModelContext(oldContainer)
        context.insert(StoredImportSession(archiveHash: "old-archive", importedAt: .now, records: 7, duplicates: 2, excluded: 5, status: "Analizzato"))
        try context.save()
    }

    let upgraded = try makeContainer(at: storeURL)
    let context = ModelContext(upgraded)
    let legacy = try context.fetch(FetchDescriptor<StoredImportSession>())
    #expect(legacy.count == 1)
    #expect(legacy.first?.archiveHash == "old-archive")
    #expect(try context.fetchCount(FetchDescriptor<StoredImportAttempt>()) == 0)
}

@Test func previewDatesKeepDistinctOffsetsAcrossDaylightSaving() throws {
    let rome = try #require(TimeZone(identifier: "Europe/Rome"))
    let first = try #require(EvenDataParser.parseDate("2026-10-25T02:30:00+02:00"))
    let second = try #require(EvenDataParser.parseDate("2026-10-25T02:30:00+01:00"))
    #expect(PreviewDateFormatting.string(first, inDeviceTimeZone: true, deviceTimeZone: rome).hasSuffix("+02:00"))
    #expect(PreviewDateFormatting.string(second, inDeviceTimeZone: true, deviceTimeZone: rome).hasSuffix("+01:00"))
    #expect(PreviewDateFormatting.string(first, inDeviceTimeZone: false, deviceTimeZone: rome) !=
            PreviewDateFormatting.string(second, inDeviceTimeZone: false, deviceTimeZone: rome))
}
