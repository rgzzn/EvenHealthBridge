import Foundation

@MainActor public protocol SleepSampleWriting {
    func authorize() async throws
    func save(_ sample: HealthMeasurement) async throws
}

@MainActor public protocol SleepImportRecording {
    func existingSamples() throws -> [ImportedSleepSample]
    func record(_ sample: HealthMeasurement) throws
}

@MainActor public struct SleepImportExecutor {
    public init() {}

    @discardableResult
    public func run(_ measurements: [HealthMeasurement], writer: any SleepSampleWriting, repository: any SleepImportRecording, progress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Int {
        let plan = SleepImportPlanner().plan(measurements, imported: try repository.existingSamples())
        guard !plan.newSamples.isEmpty else { return 0 }
        progress?(0, plan.newSamples.count)
        try await writer.authorize()
        var written = 0
        for sample in plan.newSamples {
            try Task.checkCancellation()
            try await writer.save(sample)
            try repository.record(sample)
            written += 1
            progress?(written, plan.newSamples.count)
        }
        return written
    }
}
