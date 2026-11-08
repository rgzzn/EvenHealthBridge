import Foundation

@MainActor public protocol SleepSampleWriting {
    func authorize() async throws
    func alreadySaved(_ sample: HealthMeasurement) async throws -> Bool
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
        for (index, sample) in plan.newSamples.enumerated() {
            try Task.checkCancellation()
            let alreadySaved = try await writer.alreadySaved(sample)
            try Task.checkCancellation()
            if !alreadySaved {
                try await writer.save(sample)
                written += 1
            }
            try repository.record(sample)
            progress?(index + 1, plan.newSamples.count)
        }
        return written
    }
}
