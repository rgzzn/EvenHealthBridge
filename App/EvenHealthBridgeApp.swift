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
    case healthUnavailable, permissionDenied, invalidSample
    var errorDescription: String? {
        switch self {
        case .healthUnavailable: "Apple Salute non è disponibile su questo dispositivo."
        case .permissionDenied: "Autorizzazione alla scrittura del sonno non concessa."
        case .invalidSample: "Campione di sonno non valido."
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

    func analyze(_ url: URL) async {
        isWorking = true
        error = nil
        persisted = false
        writtenCount = nil
        defer { isWorking = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let parser = EvenDataParser()
            dataset = try await Task.detached(priority: .userInitiated) { try parser.parseArchive(at: url) }.value
            DiagnosticLoggingService.logger.info("Archive analyzed; records: \(self.dataset?.measurements.count ?? 0, privacy: .public)")
        } catch {
            dataset = nil
            self.error = "Impossibile analizzare l'archivio: \(error.localizedDescription)"
            DiagnosticLoggingService.logger.error("Archive analysis failed")
        }
    }

    func importSleep(in context: ModelContext) async {
        guard let dataset else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            writtenCount = try await SleepImportExecutor().run(dataset.measurements, writer: HealthKitService(), repository: SwiftDataSleepRepository(context: context))
            try saveAnalysis(in: context)
            DiagnosticLoggingService.logger.info("Sleep import completed; written: \(self.writtenCount ?? 0, privacy: .public)")
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
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredImportSession.importedAt, order: .reverse) private var sessions: [StoredImportSession]
    @Query private var savedSamples: [StoredSample]
    @State private var showImporter = false
    @State private var includeSleep = true

    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section {
                        Label("Dati elaborati sul dispositivo", systemImage: "lock.shield")
                        if let latest = sessions.first {
                            LabeledContent("Ultima analisi", value: latest.importedAt.formatted())
                            LabeledContent("Record", value: "\(latest.records)")
                        }
                    }
                    Section {
                        Button("Seleziona archivio ZIP") { showImporter = true }
                            .font(.headline)
                        if coordinator.isWorking { ProgressView("Analisi in corso") }
                        if let error = coordinator.error { Text(error).foregroundStyle(.red) }
                    }
                    if let dataset = coordinator.dataset { preview(dataset) }
                }
                .navigationTitle("Even Health Bridge")
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls): if let url = urls.first { Task { await coordinator.analyze(url) } }
                    case .failure(let error): coordinator.error = error.localizedDescription
                    }
                }
            }
            .tabItem { Label("Importa", systemImage: "square.and.arrow.down") }

            NavigationStack {
                List(sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.importedAt.formatted()).font(.headline)
                        Text("\(session.records) record · \(session.duplicates) duplicati")
                        Text(session.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Cronologia")
            }
            .tabItem { Label("Cronologia", systemImage: "clock") }

            NavigationStack {
                Form {
                    Section("Privacy") { Text("Gli archivi vengono letti localmente. Le misurazioni non vengono inviate a server.") }
                    Section("Apple Salute") { Text("Le fasi del sonno sono importabili dopo la verifica delle durate. Le altre categorie richiedono chiarimenti sulla semantica dell'export.") }
                    Section("Permessi") { NavigationLink("Stato autorizzazione Salute") { HealthPermissionsView() } }
                }
                .navigationTitle("Impostazioni")
            }
            .tabItem { Label("Impostazioni", systemImage: "gear") }
        }
    }

    @ViewBuilder
    private func preview(_ dataset: ParsedDataset) -> some View {
        let imported = savedSamples.map {
            ImportedSleepSample(id: $0.stableID, start: $0.start, end: $0.end, sessionStart: $0.sessionStart, sessionEnd: $0.sessionEnd, stage: $0.stage)
        }
        let plan = SleepImportPlanner().plan(dataset.measurements, imported: imported)
        Section("Anteprima") {
            if let first = dataset.measurements.map(\.timestamp).min(), let last = dataset.measurements.map(\.timestamp).max() {
                LabeledContent("Periodo", value: "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
            }
            ForEach(MeasurementKind.allCases, id: \.self) { kind in
                let records = dataset.measurements.filter { $0.kind == kind }
                VStack(alignment: .leading) {
                    Text(kind.rawValue).font(.headline)
                    Text("\(records.count) record · \(records.filter { $0.validation == .eligible }.count) importabili · \(records.filter { $0.validation == .duplicate }.count) duplicati · \(records.filter { $0.validation == .conflict }.count) conflitti")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(dataset.warnings, id: \.self) { warning in Text(warning).font(.caption) }
            LabeledContent("Sonno nuovo", value: "\(plan.newSamples.count) fasi")
            LabeledContent("Già importato", value: "\(plan.alreadyImported) fasi")
            LabeledContent("Conflitti con importazioni precedenti", value: "\(plan.conflicts) fasi")
            Text("Solo il sonno verificato è importabile in Apple Salute. Conferma l'operazione prima della richiesta di autorizzazione.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Includi il sonno", isOn: $includeSleep)
            if let written = coordinator.writtenCount { Text("Nuovi campioni sonno scritti: \(written)") }
            Button("Importa il sonno in Apple Salute") {
                Task { await coordinator.importSleep(in: context) }
            }
            .disabled(coordinator.isWorking || !includeSleep || plan.newSamples.isEmpty)
            Button(coordinator.persisted ? "Analisi registrata" : "Registra analisi") {
                do { try coordinator.saveAnalysis(in: context) }
                catch { coordinator.error = error.localizedDescription }
            }
            .disabled(coordinator.persisted)
        }
    }
}
