import Foundation
import Testing
@testable import EvenHealthCore

private func quantityMeasurement(
    id: String = "quantity-id",
    kind: MeasurementKind = .steps,
    value: Decimal? = 42,
    components: [String: Decimal] = [:],
    unit: String? = "count",
    semantics: String? = "delta",
    start: TimeInterval = 1_000,
    end: TimeInterval? = 1_600,
    explicitStart: Bool = true,
    validation: ImportValidation = .eligible
) -> HealthMeasurement {
    HealthMeasurement(
        id: id, kind: kind, timestamp: Date(timeIntervalSince1970: start),
        originalTimestamp: "1970-01-01T00:16:40Z", source: "R1", value: value,
        components: components, originalUnit: unit, canonicalUnit: nil, statistic: nil,
        intervalEnd: end.map { Date(timeIntervalSince1970: $0) }, sleepStage: nil,
        sessionEnd: nil, provenance: kind == .steps ? "steps.csv" : "calories.csv",
        validation: validation, semantics: semantics, hasExplicitIntervalStart: explicitStart
    )
}

@Test func stepContractRequiresDeclaredDeltaUnitAndInterval() {
    let valid = quantityMeasurement()
    let candidate = StepMappingContract.candidate(for: valid)
    #expect(candidate?.kind == .steps)
    #expect(candidate?.value == 42)
    #expect(candidate?.unit == "count")
    #expect(StepMappingContract.candidate(for: quantityMeasurement(unit: nil)) == nil)
    #expect(StepMappingContract.candidate(for: quantityMeasurement(semantics: "cumulative")) == nil)
    #expect(StepMappingContract.candidate(for: quantityMeasurement(end: nil)) == nil)
    #expect(StepMappingContract.candidate(for: quantityMeasurement(value: Decimal(string: "42.5"))) == nil)
}

@Test func activeEnergyUsesOnlyTheDeclaredActiveComponent() {
    let valid = quantityMeasurement(
        id: "energy", kind: .calories, value: 19,
        components: ["resting": 12, "active": 7], unit: "kcal"
    )
    let candidate = ActiveEnergyMappingContract.candidate(for: valid)
    #expect(candidate?.kind == .activeEnergy)
    #expect(candidate?.value == 7)
    #expect(candidate?.unit == "kcal")
    #expect(ActiveEnergyMappingContract.candidate(for: quantityMeasurement(
        kind: .calories, value: 19, components: ["resting": 12], unit: "kcal"
    )) == nil)
    #expect(ActiveEnergyMappingContract.candidate(for: quantityMeasurement(
        kind: .calories, value: 19, components: ["active": 7], unit: nil
    )) == nil)
}

@Test func quantityPlannerPreventsReplayAndRejectsChangedLocalRecord() throws {
    let sample = quantityMeasurement()
    let candidate = try #require(QuantityMappingContract.candidate(for: sample))
    let matching = ImportedQuantitySample(id: candidate.id, kind: candidate.kind, start: candidate.start,
                                          end: candidate.end, value: candidate.value, unit: candidate.unit)
    let replay = QuantityImportPlanner().plan([sample], kind: .steps, imported: [matching])
    #expect(replay.newSamples.isEmpty)
    #expect(replay.alreadyImported == 1)
    #expect(replay.conflicts == 0)

    let changed = ImportedQuantitySample(id: candidate.id, kind: candidate.kind, start: candidate.start,
                                         end: candidate.end, value: 41, unit: candidate.unit)
    let conflict = QuantityImportPlanner().plan([sample], kind: .steps, imported: [changed])
    #expect(conflict.newSamples.isEmpty)
    #expect(conflict.alreadyImported == 0)
    #expect(conflict.conflicts == 1)
}

@MainActor private final class QuantityWriter: QuantitySampleWriting {
    var authorized: [QuantityImportKind] = []
    var saved = Set<String>()
    var failSave = false

    func authorize(for kind: QuantityImportKind) async throws { authorized.append(kind) }
    func alreadySaved(_ sample: QuantityImportCandidate) async throws -> Bool { saved.contains(sample.id) }
    func save(_ sample: QuantityImportCandidate) async throws {
        if failSave { throw TestFailure.save }
        saved.insert(sample.id)
    }
}

@MainActor private final class QuantityRepository: QuantityImportRecording {
    var samples: [ImportedQuantitySample] = []

    func existingSamples(for kind: QuantityImportKind) throws -> [ImportedQuantitySample] {
        samples.filter { $0.kind == kind }
    }

    func record(_ sample: QuantityImportCandidate) throws {
        if !samples.contains(where: { $0.id == sample.id }) {
            samples.append(.init(id: sample.id, kind: sample.kind, start: sample.start, end: sample.end,
                                 value: sample.value, unit: sample.unit))
        }
    }
}

private enum TestFailure: Error { case save }

@Test @MainActor func quantityExecutorReconcilesHealthSaveBeforeLocalPersistence() async throws {
    let sample = quantityMeasurement()
    let candidate = try #require(QuantityMappingContract.candidate(for: sample))
    let writer = QuantityWriter()
    writer.saved.insert(candidate.id) // HealthKit succeeded before SwiftData was reached.
    let repository = QuantityRepository()

    let written = try await QuantityImportExecutor().run([sample], kind: .steps,
                                                          writer: writer, repository: repository)
    #expect(written == 0)
    #expect(writer.authorized == [.steps])
    #expect(repository.samples.count == 1)
    #expect(repository.samples.first?.id == candidate.id)
}

@Test @MainActor func quantityExecutorDoesNotRecordAfterFailedHealthSave() async throws {
    let writer = QuantityWriter()
    writer.failSave = true
    let repository = QuantityRepository()
    await #expect(throws: TestFailure.save) {
        try await QuantityImportExecutor().run([quantityMeasurement()], kind: .steps,
                                                writer: writer, repository: repository)
    }
    #expect(repository.samples.isEmpty)
}
