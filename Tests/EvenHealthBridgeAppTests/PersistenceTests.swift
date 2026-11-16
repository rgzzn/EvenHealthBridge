import Foundation
import SwiftData
import Testing
import EvenHealthCore
@testable import EvenHealthBridge

private final class SyntheticArchiveMarker {}

@Test func principalInterfaceStringsHaveEnglishTranslations() throws {
    let appBundle = Bundle(for: ImportCoordinator.self)
    let englishPath = try #require(appBundle.path(forResource: "en", ofType: "lproj"))
    let english = try #require(Bundle(path: englishPath))
    let expectedTranslations = [
        "Importa": "Import",
        "Studio": "Study",
        "Cronologia": "History",
        "Impostazioni": "Settings",
        "Seleziona archivio ZIP": "Select ZIP archive",
        "Importa il sonno in Apple Salute": "Import sleep into Apple Health",
        "Confronta con Apple Watch": "Compare with Apple Watch",
        "Intervallo di confronto": "Comparison interval",
        "Metriche da confrontare": "Metrics to compare",
        "Cerca solo le fonti presenti nell’intervallo e per le metriche selezionate. I nomi e i dati delle fonti restano sul dispositivo e non vengono salvati dall’app.": "Searches only sources present in the selected interval and for the selected metrics. Source names and data stay on this device and are not saved by the app.",
        "Permessi Salute": "Health permissions",
        "Dati e cronologia restano sull'iPhone. Nessun account, server o tracciamento. Gli archivi non vengono conservati.": "Data and history stay on iPhone. No account, server, or tracking. Archives are not retained."
    ]

    for (key, translation) in expectedTranslations {
        #expect(english.localizedString(forKey: key, value: nil, table: "Localizable") == translation)
    }
}

@MainActor @Test func appIntentsRouteToTheirFocusedWorkflow() async throws {
    let router = EvenHealthBridgeIntentRouter.shared
    router.pendingRoute = nil
    defer { router.pendingRoute = nil }

    _ = try await ImportEvenDataIntent().perform()
    #expect(ImportEvenDataIntent.targetDestination == .importArchive)
    #expect(router.pendingRoute?.destination == .importArchive)
    #expect(EvenHealthBridgeDestination.importArchive.tabIndex == 0)

    _ = try await StudyEvenDataIntent().perform()
    #expect(StudyEvenDataIntent.targetDestination == .appleWatchStudy)
    #expect(router.pendingRoute?.destination == .appleWatchStudy)
    #expect(EvenHealthBridgeDestination.appleWatchStudy.tabIndex == 1)
}

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
    #expect(first.warnings.allSatisfy { $0.contains(".csv") })

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

@MainActor private func makeInMemoryContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
    let context = ModelContext(try makeInMemoryContainer())
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
    #expect(!attempt.status.isEmpty)
    #expect(!attempt.status.localizedCaseInsensitiveContains("private health value"))
    #expect(!ImportInterruptionReason(error: NSError(domain: "private health value", code: 1)).title.isEmpty)
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
        #expect(attempts.allSatisfy { !$0.status.isEmpty })
    }

    let reopened = try makeContainer(at: storeURL)
    let context = ModelContext(reopened)
    #expect(try context.fetchCount(FetchDescriptor<StoredImportAttempt>()) == 3)
    #expect(try context.fetch(FetchDescriptor<StoredImportAttempt>()).allSatisfy { !$0.status.isEmpty })
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
