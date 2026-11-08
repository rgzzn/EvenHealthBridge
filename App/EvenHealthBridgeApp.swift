import SwiftUI
import SwiftData
import HealthKit
import EvenHealthCore
import os

enum DiagnosticLoggingService {
    static let logger = Logger(subsystem: "com.rgzzn.EvenHealthBridge", category: "Import")
}

enum ImportFormatVersion {
    static let parser = 1
    static let mapping = 1
}

@Model
final class StoredImportSession {
    // Historical one-row-per-archive records from the first app schema.
    @Attribute(.unique) var archiveHash: String
    var importedAt: Date
    var records: Int
    var duplicates: Int
    var excluded: Int
    var parserVersion: Int
    var mappingVersion: Int
    var status: String
    var writtenSamples: Int
    var lastSyncedAt: Date?

    init(archiveHash: String, importedAt: Date, records: Int, duplicates: Int, excluded: Int, status: String) {
        self.archiveHash = archiveHash
        self.importedAt = importedAt
        self.records = records
        self.duplicates = duplicates
        self.excluded = excluded
        self.parserVersion = ImportFormatVersion.parser
        self.mappingVersion = ImportFormatVersion.mapping
        self.status = status
        self.writtenSamples = 0
        self.lastSyncedAt = nil
    }
}

@Model
final class StoredImportAttempt {
    @Attribute(.unique) var attemptID: UUID
    var archiveHash: String
    var importedAt: Date
    var records: Int
    var duplicates: Int
    var excluded: Int
    var parserVersion: Int
    var mappingVersion: Int
    var status: String
    var writtenSamples: Int
    var lastSyncedAt: Date?

    init(attemptID: UUID, archiveHash: String, importedAt: Date, records: Int, duplicates: Int, excluded: Int, status: String) {
        self.attemptID = attemptID
        self.archiveHash = archiveHash
        self.importedAt = importedAt
        self.records = records
        self.duplicates = duplicates
        self.excluded = excluded
        self.parserVersion = ImportFormatVersion.parser
        self.mappingVersion = ImportFormatVersion.mapping
        self.status = status
        self.writtenSamples = 0
        self.lastSyncedAt = nil
    }
}

@Model
final class StoredSample {
    @Attribute(.unique) var stableID: String
    var savedAt: Date
    var category: String
    var start: Date
    var end: Date
    var sessionStart: Date
    var sessionEnd: Date
    var stage: Int

    init(stableID: String, category: String, start: Date, end: Date, sessionStart: Date, sessionEnd: Date, stage: Int) {
        self.stableID = stableID
        self.savedAt = .now
        self.category = category
        self.start = start
        self.end = end
        self.sessionStart = sessionStart
        self.sessionEnd = sessionEnd
        self.stage = stage
    }
}

@MainActor struct HealthKitService: SleepSampleWriting {
    private let store = HKHealthStore()

    static func sleepWriteStatus() -> String {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return "Non disponibile" }
        switch HKHealthStore().authorizationStatus(for: type) {
        case .sharingAuthorized: return "Scrittura consentita"
        case .sharingDenied: return "Scrittura negata"
        case .notDetermined: return "Non ancora richiesta"
        @unknown default: return "Stato sconosciuto"
        }
    }

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportFailure.healthUnavailable }
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { throw ImportFailure.healthUnavailable }
        try await store.requestAuthorization(toShare: [type], read: [type])
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { throw ImportFailure.permissionDenied }
    }

    func alreadySaved(_ item: HealthMeasurement) async throws -> Bool {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              let end = item.intervalEnd else { throw ImportFailure.invalidSample }
        let ownSource = HKQuery.predicateForObjects(from: HKSource.default())
        let identifier = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [item.id])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownSource, identifier])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [], limit: 2
        )
        let matches = try await descriptor.result(for: store)
        guard matches.count <= 1 else { throw ImportFailure.conflictingSavedSample }
        guard let match = matches.first else { return false }
        let expectedValue = try sleepValue(for: item).rawValue
        guard match.startDate == item.timestamp, match.endDate == end,
              match.value == expectedValue else { throw ImportFailure.conflictingSavedSample }
        return true
    }

    func save(_ item: HealthMeasurement) async throws {
        guard let end = item.intervalEnd,
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { throw ImportFailure.invalidSample }
        let value = try sleepValue(for: item)
        let sample = HKCategorySample(type: type, value: value.rawValue, start: item.timestamp, end: end, metadata: [HKMetadataKeySyncIdentifier: item.id, HKMetadataKeySyncVersion: 1, "EvenHealthBridgeSource": item.source])
        try await store.save(sample)
    }

    private func sleepValue(for item: HealthMeasurement) throws -> HKCategoryValueSleepAnalysis {
        guard let stage = item.sleepStage else { throw ImportFailure.invalidSample }
        switch stage {
        case 0: return .awake
        case 1: return .asleepREM
        case 2: return .asleepCore
        case 3: return .asleepDeep
        default: throw ImportFailure.invalidSample
        }
    }
}

@MainActor struct SwiftDataSleepRepository: SleepImportRecording {
    let context: ModelContext

    func existingSamples() throws -> [ImportedSleepSample] {
        try context.fetch(FetchDescriptor<StoredSample>()).map {
            ImportedSleepSample(id: $0.stableID, start: $0.start, end: $0.end, sessionStart: $0.sessionStart, sessionEnd: $0.sessionEnd, stage: $0.stage)
        }
    }

    func record(_ item: HealthMeasurement) throws {
        guard let end = item.intervalEnd, let stage = item.sleepStage,
              let sessionStart = EvenDataParser.parseDate(item.originalTimestamp),
              let sessionEnd = item.sessionEnd else { throw ImportFailure.invalidSample }
        context.insert(StoredSample(stableID: item.id, category: "sleep", start: item.timestamp, end: end, sessionStart: sessionStart, sessionEnd: sessionEnd, stage: stage))
        try context.save()
    }
}

enum ImportFailure: LocalizedError {
    case healthUnavailable, permissionDenied, invalidSample, unreadableArchive, conflictingSavedSample
    var errorDescription: String? {
        switch self {
        case .healthUnavailable: "Apple Salute non è disponibile su questo dispositivo."
        case .permissionDenied: "Autorizzazione alla scrittura del sonno non concessa."
        case .invalidSample: "Campione di sonno non valido."
        case .unreadableArchive: "Impossibile leggere il file selezionato."
        case .conflictingSavedSample: "In Apple Salute esiste già un campione con lo stesso identificativo ma dati diversi. Importazione interrotta."
        }
    }
}

@MainActor @Observable
final class ImportCoordinator {
    var dataset: ParsedDataset?
    var error: String?
    var isWorking = false
    var persisted = false
    var writtenCount: Int?
    var progress: (completed: Int, total: Int)?
    private var activeAttemptID: UUID?

    func analyze(_ url: URL) async {
        guard !Task.isCancelled else { return }
        guard !isWorking else {
            error = "Attendi la fine dell'importazione prima di aprire un altro archivio."
            return
        }
        isWorking = true
        dataset = nil
        activeAttemptID = nil
        error = nil
        persisted = false
        writtenCount = nil
        progress = nil
        defer { isWorking = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let parser = EvenDataParser()
            let worker = Task.detached(priority: .userInitiated) {
                var coordinationError: NSError?
                var outcome: Result<ParsedDataset, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                    outcome = Result { try parser.parseArchive(at: readableURL) }
                }
                if let coordinationError { throw coordinationError }
                guard let outcome else { throw ImportFailure.unreadableArchive }
                return try outcome.get()
            }
            let parsed = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            dataset = parsed
            activeAttemptID = UUID()
            DiagnosticLoggingService.logger.info("Archive analyzed; records: \(self.dataset?.measurements.count ?? 0, privacy: .public)")
        } catch is CancellationError {
            dataset = nil
        } catch {
            dataset = nil
            self.error = "Impossibile analizzare l'archivio: \(error.localizedDescription)"
            DiagnosticLoggingService.logger.error("Archive analysis failed")
        }
    }

    func importSleep(in context: ModelContext) async {
        guard !isWorking, let dataset else { return }
        isWorking = true
        error = nil
        progress = nil
        writtenCount = nil
        defer { isWorking = false }
        do {
            try recordStartedImport(in: context)
            writtenCount = try await SleepImportExecutor().run(dataset.measurements, writer: HealthKitService(), repository: SwiftDataSleepRepository(context: context)) { completed, total in
                self.progress = (completed, total)
            }
            try saveAnalysis(in: context)
            DiagnosticLoggingService.logger.info("Sleep import completed; written: \(self.writtenCount ?? 0, privacy: .public)")
        } catch is CancellationError {
            self.error = "Importazione interrotta. Puoi riprendere quando vuoi."
            try? recordInterruptedImport(in: context)
            DiagnosticLoggingService.logger.info("Sleep import cancelled")
        } catch {
            self.error = error.localizedDescription
            try? recordInterruptedImport(in: context)
            DiagnosticLoggingService.logger.error("Sleep import interrupted")
        }
    }

    func recordStartedImport(in context: ModelContext) throws {
        guard let dataset else { return }
        if persisted { activeAttemptID = UUID() }
        let attempt = try currentAttempt(in: context, dataset: dataset)
        attempt.status = "Importazione avviata; esito da verificare"
        attempt.excluded = try excludedCount(in: context)
        try context.save()
        persisted = true
    }

    private func recordInterruptedImport(in context: ModelContext) throws {
        guard let dataset else { return }
        let ids = Set(dataset.measurements.filter { $0.kind == .sleep }.map(\.id))
        let saved = try context.fetch(FetchDescriptor<StoredSample>()).filter { ids.contains($0.stableID) }.count
        let session = try currentAttempt(in: context, dataset: dataset)
        session.writtenSamples = saved
        session.excluded = try excludedCount(in: context)
        session.status = "Importazione interrotta; \(saved) fasi salvate. Riprova per continuare."
        try context.save()
    }

    func saveAnalysis(in context: ModelContext) throws {
        guard let dataset else { return }
        let session = try currentAttempt(in: context, dataset: dataset)
        if let writtenCount {
            let ids = Set(dataset.measurements.filter { $0.kind == .sleep }.map(\.id))
            let saved = try context.fetch(FetchDescriptor<StoredSample>()).filter { ids.contains($0.stableID) }.count
            session.writtenSamples = saved
            session.lastSyncedAt = .now
            session.status = "Sonno sincronizzato: \(saved) campioni, \(writtenCount) nuovi in questo tentativo"
        }
        session.excluded = try excludedCount(in: context)
        try context.save()
        persisted = true
    }

    private func currentAttempt(in context: ModelContext, dataset: ParsedDataset) throws -> StoredImportAttempt {
        let id = activeAttemptID ?? UUID()
        activeAttemptID = id
        let descriptor = FetchDescriptor<StoredImportAttempt>(predicate: #Predicate { $0.attemptID == id })
        if let existing = try context.fetch(descriptor).first { return existing }
        let attempt = StoredImportAttempt(
            attemptID: id, archiveHash: dataset.archiveHash, importedAt: .now,
            records: dataset.measurements.count,
            duplicates: dataset.measurements.filter { $0.validation == .duplicate }.count,
            excluded: 0, status: "Analizzato; nessun campione scritto"
        )
        context.insert(attempt)
        return attempt
    }

    private func excludedCount(in context: ModelContext) throws -> Int {
        guard let dataset else { return 0 }
        let invalidOrAmbiguous = dataset.measurements.filter {
            $0.validation != .eligible && $0.validation != .duplicate
        }.count
        let saved = try SwiftDataSleepRepository(context: context).existingSamples()
        let overlapConflicts = SleepImportPlanner().plan(dataset.measurements, imported: saved).conflicts
        return invalidOrAmbiguous + overlapConflicts
    }
}

enum LocalStore {
    static func open(configuration: ModelConfiguration = ModelConfiguration(cloudKitDatabase: .none)) -> ModelContainer? {
        do {
            return try ModelContainer(for: StoredImportSession.self, StoredImportAttempt.self, StoredSample.self, configurations: configuration)
        } catch {
            DiagnosticLoggingService.logger.error("Local history store unavailable")
            return nil
        }
    }
}

@main
struct EvenHealthBridgeApp: App {
    @State private var container = LocalStore.open()

    var body: some Scene {
        WindowGroup {
            if let container {
                RootView().modelContainer(container)
            } else {
                StorageUnavailableView { container = LocalStore.open() }
            }
        }
    }
}

private struct StorageUnavailableView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView("Archivio locale non disponibile", systemImage: "externaldrive",
                description: Text("L'app non può verificare i campioni già importati. Riprova quando lo spazio e l'archivio del dispositivo sono disponibili."))
            Button("Riprova", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct RootView: View {
    @State private var coordinator = ImportCoordinator()
    @State private var analysisTask: Task<Void, Never>?
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ImportView(coordinator: coordinator, analysisTask: $analysisTask)
            }
            .tabItem { Label("Importa", systemImage: "square.and.arrow.down") }
            .tag(0)
            NavigationStack {
                ImportHistoryView()
            }
            .tabItem { Label("Cronologia", systemImage: "clock") }
            .tag(1)
            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Impostazioni", systemImage: "gear") }
            .tag(2)
        }
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "zip" else { return }
            selectedTab = 0
            let previous = analysisTask
            analysisTask = Task {
                previous?.cancel()
                await previous?.value
                guard !Task.isCancelled else { return }
                await coordinator.analyze(url)
            }
        }
    }
}
