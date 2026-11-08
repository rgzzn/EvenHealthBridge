import Foundation
import SwiftData
import Testing
import EvenHealthCore
@testable import EvenHealthBridge

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
    return try ModelContainer(for: StoredImportSession.self, StoredSample.self, configurations: configuration)
}
