import SwiftUI
import SwiftData
import HealthKit
import EvenHealthCore

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

    init(archiveHash: String, importedAt: Date, records: Int, duplicates: Int, excluded: Int, status: String) {
        self.archiveHash = archiveHash
        self.importedAt = importedAt
        self.records = records
        self.duplicates = duplicates
        self.excluded = excluded
        self.parserVersion = 1
        self.mappingVersion = 1
        self.status = status
    }
}

@Model
final class StoredSample {
    @Attribute(.unique) var stableID: String
    var savedAt: Date
    var category: String

    init(stableID: String, category: String) {
        self.stableID = stableID
        self.savedAt = .now
        self.category = category
    }
}

@MainActor struct HealthKitService {
    private let store = HKHealthStore()

    func writeSleep(_ samples: [HealthMeasurement], context: ModelContext) async throws -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportFailure.healthUnavailable }
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        try await store.requestAuthorization(toShare: [type], read: [])
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { throw ImportFailure.permissionDenied }
        var written = 0
        for item in samples where item.validation == .eligible && item.kind == .sleep {
            let stableID = item.id
            let descriptor = FetchDescriptor<StoredSample>(predicate: #Predicate { $0.stableID == stableID })
            if try context.fetchCount(descriptor) > 0 { continue }
            guard let end = item.intervalEnd, let stage = item.sleepStage else { continue }
            let value: HKCategoryValueSleepAnalysis
            switch stage {
            case 0: value = .awake
            case 1: value = .asleepREM
            case 2: value = .asleepCore
            case 3: value = .asleepDeep
            default: continue
            }
            let sample = HKCategorySample(type: type, value: value.rawValue, start: item.timestamp, end: end, metadata: [HKMetadataKeySyncIdentifier: stableID, HKMetadataKeySyncVersion: 1, "EvenHealthBridgeSource": item.source])
            try await store.save(sample)
            context.insert(StoredSample(stableID: stableID, category: "sleep"))
            try context.save()
            written += 1
        }
        return written
    }
}

enum ImportFailure: LocalizedError {
    case healthUnavailable, permissionDenied
    var errorDescription: String? {
        switch self {
        case .healthUnavailable: "Apple Salute non è disponibile su questo dispositivo."
        case .permissionDenied: "Autorizzazione alla scrittura del sonno non concessa."
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
        } catch {
            dataset = nil
            self.error = "Impossibile analizzare l'archivio: \(error.localizedDescription)"
        }
    }

    func importSleep(in context: ModelContext) async {
        guard let dataset else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            writtenCount = try await HealthKitService().writeSleep(dataset.measurements, context: context)
            try saveAnalysis(in: context)
        } catch { self.error = error.localizedDescription }
    }

    func saveAnalysis(in context: ModelContext) throws {
        guard let dataset else { return }
        let hash = dataset.archiveHash
        let descriptor = FetchDescriptor<StoredImportSession>(predicate: #Predicate { $0.archiveHash == hash })
        if try context.fetchCount(descriptor) > 0 {
            persisted = true
            return
        }
        let count = dataset.measurements.count
        let duplicates = dataset.measurements.filter { $0.validation == .duplicate }.count
        let status = writtenCount.map { "Sonno importato: \($0) nuovi campioni" } ?? "Analizzato; nessun campione scritto"
        context.insert(StoredImportSession(archiveHash: hash, importedAt: .now, records: count, duplicates: duplicates, excluded: count - duplicates - (writtenCount ?? 0), status: status))
        try context.save()
        persisted = true
    }
}

@main
struct EvenHealthBridgeApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(for: [StoredImportSession.self, StoredSample.self])
    }
}

struct RootView: View {
    @State private var coordinator = ImportCoordinator()
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredImportSession.importedAt, order: .reverse) private var sessions: [StoredImportSession]
    @State private var showImporter = false

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
                }
                .navigationTitle("Impostazioni")
            }
            .tabItem { Label("Impostazioni", systemImage: "gear") }
        }
    }

    @ViewBuilder
    private func preview(_ dataset: ParsedDataset) -> some View {
        Section("Anteprima") {
            ForEach(MeasurementKind.allCases, id: \.self) { kind in
                let records = dataset.measurements.filter { $0.kind == kind }
                VStack(alignment: .leading) {
                    Text(kind.rawValue).font(.headline)
                    Text("\(records.count) record · \(records.filter { $0.validation == .eligible }.count) importabili · \(records.filter { $0.validation == .duplicate }.count) duplicati · \(records.filter { $0.validation == .conflict }.count) conflitti")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(dataset.warnings, id: \.self) { warning in Text(warning).font(.caption) }
            Text("Solo il sonno verificato è importabile in Apple Salute. Conferma l'operazione prima della richiesta di autorizzazione.")
                .font(.footnote).foregroundStyle(.secondary)
            if let written = coordinator.writtenCount { Text("Nuovi campioni sonno scritti: \(written)") }
            Button("Importa il sonno in Apple Salute") {
                Task { await coordinator.importSleep(in: context) }
            }
            .disabled(coordinator.isWorking || !dataset.measurements.contains { $0.kind == .sleep && $0.validation == .eligible })
            Button(coordinator.persisted ? "Analisi registrata" : "Registra analisi") {
                do { try coordinator.saveAnalysis(in: context) }
                catch { coordinator.error = error.localizedDescription }
            }
            .disabled(coordinator.persisted)
        }
    }
}
