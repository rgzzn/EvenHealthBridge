import SwiftUI
import SwiftData
import HealthKit
import EvenHealthCore
import os

enum DiagnosticLoggingService {
    static let logger = Logger(subsystem: "com.rgzzn.EvenHealthBridge", category: "Import")
}

@Model
final class StoredImportSession {
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
        self.parserVersion = 1
        self.mappingVersion = 1
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

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportFailure.healthUnavailable }
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        try await store.requestAuthorization(toShare: [type], read: [])
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { throw ImportFailure.permissionDenied }
    }

    func save(_ item: HealthMeasurement) async throws {
        guard let end = item.intervalEnd, let stage = item.sleepStage,
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { throw ImportFailure.invalidSample }
        let value: HKCategoryValueSleepAnalysis
        switch stage {
        case 0: value = .awake
        case 1: value = .asleepREM
        case 2: value = .asleepCore
        case 3: value = .asleepDeep
        default: throw ImportFailure.invalidSample
        }
        let sample = HKCategorySample(type: type, value: value.rawValue, start: item.timestamp, end: end, metadata: [HKMetadataKeySyncIdentifier: item.id, HKMetadataKeySyncVersion: 1, "EvenHealthBridgeSource": item.source])
        try await store.save(sample)
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
    case healthUnavailable, permissionDenied, invalidSample, unreadableArchive
    var errorDescription: String? {
        switch self {
        case .healthUnavailable: "Apple Salute non è disponibile su questo dispositivo."
        case .permissionDenied: "Autorizzazione alla scrittura del sonno non concessa."
        case .invalidSample: "Campione di sonno non valido."
        case .unreadableArchive: "Impossibile leggere il file selezionato."
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

    func analyze(_ url: URL) async {
        isWorking = true
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
            dataset = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
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
        guard let dataset else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
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

    private func recordInterruptedImport(in context: ModelContext) throws {
        guard let dataset else { return }
        let ids = Set(dataset.measurements.filter { $0.kind == .sleep }.map(\.id))
        let saved = try context.fetch(FetchDescriptor<StoredSample>()).filter { ids.contains($0.stableID) }.count
        let hash = dataset.archiveHash
        let descriptor = FetchDescriptor<StoredImportSession>(predicate: #Predicate { $0.archiveHash == hash })
        let session: StoredImportSession
        if let existing = try context.fetch(descriptor).first { session = existing }
        else {
            session = StoredImportSession(archiveHash: hash, importedAt: .now, records: dataset.measurements.count, duplicates: dataset.measurements.filter { $0.validation == .duplicate }.count, excluded: 0, status: "")
            context.insert(session)
        }
        session.writtenSamples = saved
        session.status = "Importazione interrotta; \(saved) fasi salvate. Riprova per continuare."
        try context.save()
    }

    func saveAnalysis(in context: ModelContext) throws {
        guard let dataset else { return }
        let hash = dataset.archiveHash
        let descriptor = FetchDescriptor<StoredImportSession>(predicate: #Predicate { $0.archiveHash == hash })
        if let existing = try context.fetch(descriptor).first {
            if writtenCount != nil {
                let ids = Set(dataset.measurements.filter { $0.kind == .sleep }.map(\.id))
                let saved = try context.fetch(FetchDescriptor<StoredSample>()).filter { ids.contains($0.stableID) }.count
                existing.writtenSamples = saved
                existing.lastSyncedAt = .now
                existing.status = "Sonno sincronizzato: \(saved) campioni, \(writtenCount ?? 0) nuovi in questo tentativo"
                try context.save()
            }
            persisted = true
            return
        }
        let count = dataset.measurements.count
        let duplicates = dataset.measurements.filter { $0.validation == .duplicate }.count
        let status = writtenCount.map { "Sonno importato: \($0) nuovi campioni" } ?? "Analizzato; nessun campione scritto"
        let session = StoredImportSession(archiveHash: hash, importedAt: .now, records: count, duplicates: duplicates, excluded: count - duplicates - (writtenCount ?? 0), status: status)
        session.writtenSamples = writtenCount ?? 0
        session.lastSyncedAt = writtenCount == nil ? nil : .now
        context.insert(session)
        try context.save()
        persisted = true
    }
}

@main
struct EvenHealthBridgeApp: App {
    private let container: ModelContainer = {
        let configuration = ModelConfiguration(cloudKitDatabase: .none)
        return try! ModelContainer(for: StoredImportSession.self, StoredSample.self, configurations: configuration)
    }()

    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(container)
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
            analysisTask?.cancel()
            analysisTask = Task { await coordinator.analyze(url) }
        }
    }
}
