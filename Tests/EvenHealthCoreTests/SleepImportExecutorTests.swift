import Foundation
import Testing
@testable import EvenHealthCore

@MainActor private final class FakeWriter: SleepSampleWriting {
    enum Failure: Error { case interrupted }
    var authorizationCalls = 0
    var saved: [String] = []
    var failAfter: Int?

    func authorize() async throws { authorizationCalls += 1 }
    func save(_ sample: HealthMeasurement) async throws {
        if let failAfter, saved.count >= failAfter { throw Failure.interrupted }
        saved.append(sample.id)
    }
}

@MainActor private final class FakeRepository: SleepImportRecording {
    var stored: [ImportedSleepSample] = []
    func existingSamples() throws -> [ImportedSleepSample] { stored }
    func record(_ sample: HealthMeasurement) throws {
        stored.append(ImportedSleepSample(id: sample.id, start: sample.timestamp, end: sample.intervalEnd!, sessionStart: EvenDataParser.parseDate(sample.originalTimestamp)!, sessionEnd: sample.sessionEnd!, stage: sample.sleepStage!))
    }
}

private func sample(_ id: String, start: TimeInterval, end: TimeInterval) -> HealthMeasurement {
    HealthMeasurement(id: id, kind: .sleep, timestamp: Date(timeIntervalSince1970: start), originalTimestamp: "1970-01-01T00:00:00Z", source: "R1", value: nil, components: [:], originalUnit: "half_minutes", canonicalUnit: "seconds", statistic: nil, intervalEnd: Date(timeIntervalSince1970: end), sleepStage: 2, sessionEnd: Date(timeIntervalSince1970: 120), provenance: "sleep.csv", validation: .eligible)
}

@MainActor @Test func executorSecondImportWritesZero() async throws {
    let writer = FakeWriter()
    let repository = FakeRepository()
    let input = [sample("a", start: 0, end: 60), sample("b", start: 60, end: 120)]
    let first = try await SleepImportExecutor().run(input, writer: writer, repository: repository)
    let second = try await SleepImportExecutor().run(input, writer: writer, repository: repository)
    #expect(first == 2)
    #expect(second == 0)
    #expect(writer.authorizationCalls == 1)
    #expect(writer.saved == ["a", "b"])
}

@MainActor @Test func executorResumesAfterPartialFailure() async throws {
    let writer = FakeWriter()
    let repository = FakeRepository()
    let input = [sample("a", start: 0, end: 60), sample("b", start: 60, end: 120)]
    writer.failAfter = 1
    do {
        _ = try await SleepImportExecutor().run(input, writer: writer, repository: repository)
        Issue.record("Expected interruption")
    } catch FakeWriter.Failure.interrupted { }
    #expect(repository.stored.map(\.id) == ["a"])
    writer.failAfter = nil
    let resumed = try await SleepImportExecutor().run(input, writer: writer, repository: repository)
    #expect(resumed == 1)
    #expect(repository.stored.map(\.id) == ["a", "b"])
}
