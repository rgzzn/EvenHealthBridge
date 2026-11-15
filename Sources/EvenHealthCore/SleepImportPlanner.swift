import Foundation

public struct ImportedSleepSample: Sendable, Hashable {
    public let id: String
    public let start: Date
    public let end: Date
    public let sessionStart: Date
    public let sessionEnd: Date
    public let stage: Int

    public init(id: String, start: Date, end: Date, sessionStart: Date, sessionEnd: Date, stage: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.sessionStart = sessionStart
        self.sessionEnd = sessionEnd
        self.stage = stage
    }
}

public struct SleepImportPlan: Sendable {
    public let newSamples: [HealthMeasurement]
    public let alreadyImported: Int
    public let conflicts: Int
}

/// The last semantic gate before a record may reach a HealthKit sleep writer.
/// Keeping this outside the UI and planner makes accidental future call sites fail closed.
public enum SleepWriteEligibility {
    public static func accepts(_ measurement: HealthMeasurement) -> Bool {
        guard measurement.kind == .sleep,
              measurement.validation == .eligible,
              !measurement.id.isEmpty,
              let stage = measurement.sleepStage,
              (0...3).contains(stage),
              let end = measurement.intervalEnd,
              end > measurement.timestamp,
              let sessionEnd = measurement.sessionEnd,
              sessionEnd >= end else { return false }
        return EvenDataParser.parseDate(measurement.originalTimestamp) != nil
    }
}

public struct SleepImportPlanner: Sendable {
    public init() {}

    public func plan(_ measurements: [HealthMeasurement], imported: [ImportedSleepSample]) -> SleepImportPlan {
        let candidates = measurements.filter(SleepWriteEligibility.accepts)
        let existing = Dictionary(imported.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var newSamples: [HealthMeasurement] = []
        var duplicates = 0
        var conflicts = 0

        let sessions = Dictionary(grouping: candidates) { item in
            SessionKey(start: EvenDataParser.parseDate(item.originalTimestamp) ?? item.timestamp, end: item.sessionEnd ?? item.intervalEnd ?? item.timestamp)
        }
        for (session, items) in sessions {
            let overlapsExisting = imported.contains { stored in
                session.start < stored.sessionEnd && stored.sessionStart < session.end &&
                (session.start != stored.sessionStart || session.end != stored.sessionEnd)
            }
            let changedSample = items.contains { item in
                guard let stored = existing[item.id] else { return false }
                return stored.start != item.timestamp || stored.end != item.intervalEnd || stored.stage != item.sleepStage || stored.sessionStart != session.start || stored.sessionEnd != session.end
            }
            if overlapsExisting || changedSample {
                conflicts += items.count
                continue
            }
            for item in items {
                if existing[item.id] != nil { duplicates += 1 }
                else { newSamples.append(item) }
            }
        }
        return SleepImportPlan(newSamples: newSamples.sorted { $0.timestamp < $1.timestamp }, alreadyImported: duplicates, conflicts: conflicts)
    }

    private struct SessionKey: Hashable {
        let start: Date
        let end: Date
    }
}
