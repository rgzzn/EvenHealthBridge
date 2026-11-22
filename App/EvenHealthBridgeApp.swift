import SwiftUI
import SwiftData
import HealthKit
import EvenHealthCore
import os

enum DiagnosticLoggingService {
    static let logger = Logger(subsystem: "com.rgzzn.EvenHealthBridge", category: "Import")
}

enum ImportFormatVersion {
    static let parser = 4
    static let mapping = 2
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

/// App-owned quantity import records remain separate from sleep stages so the
/// existing persistence schema can evolve without fabricating sleep metadata.
@Model
final class StoredQuantitySample {
    @Attribute(.unique) var stableID: String
    var category: String
    var savedAt: Date
    var start: Date
    var end: Date
    var valueText: String
    var unit: String
    var source: String = ""
    var parserVersion: Int
    var mappingVersion: Int

    init(_ sample: QuantityImportCandidate) {
        self.stableID = sample.id
        self.category = sample.kind.rawValue
        self.savedAt = .now
        self.start = sample.start
        self.end = sample.end
        self.valueText = NSDecimalNumber(decimal: sample.value).stringValue
        self.unit = sample.unit
        self.source = sample.source
        self.parserVersion = sample.parserVersion
        self.mappingVersion = sample.mappingVersion
    }
}

@MainActor struct HealthKitService: SleepSampleWriting, QuantitySampleWriting {
    private let store = HKHealthStore()

    static func sleepWriteStatus() -> String {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return String(localized: "Non disponibile") }
        switch HKHealthStore().authorizationStatus(for: type) {
        case .sharingAuthorized: return String(localized: "Scrittura consentita")
        case .sharingDenied: return String(localized: "Scrittura negata")
        case .notDetermined: return String(localized: "Non ancora richiesta")
        @unknown default: return String(localized: "Stato sconosciuto")
        }
    }

    static func quantityWriteStatus(for kind: QuantityImportKind) -> String {
        guard HKHealthStore.isHealthDataAvailable() else { return String(localized: "Non disponibile") }
        let identifier: HKQuantityTypeIdentifier = switch kind {
        case .steps: .stepCount
        case .activeEnergy: .activeEnergyBurned
        }
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return String(localized: "Non disponibile")
        }
        switch HKHealthStore().authorizationStatus(for: type) {
        case .sharingAuthorized: return String(localized: "Scrittura consentita")
        case .sharingDenied: return String(localized: "Scrittura negata")
        case .notDetermined: return String(localized: "Non ancora richiesta")
        @unknown default: return String(localized: "Stato sconosciuto")
        }
    }

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportFailure.healthUnavailable }
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { throw ImportFailure.healthUnavailable }
        try await store.requestAuthorization(toShare: [type], read: [type])
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { throw ImportFailure.permissionDenied }
    }

    func alreadySaved(_ item: HealthMeasurement) async throws -> Bool {
        guard SleepWriteEligibility.accepts(item),
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
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
        guard SleepWriteEligibility.accepts(item),
              let end = item.intervalEnd,
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { throw ImportFailure.invalidSample }
        let value = try sleepValue(for: item)
        let sample = HKCategorySample(type: type, value: value.rawValue, start: item.timestamp, end: end, metadata: [HKMetadataKeySyncIdentifier: item.id, HKMetadataKeySyncVersion: 1, "EvenHealthBridgeSource": item.source])
        try await store.save(sample)
    }

    func authorize(for kind: QuantityImportKind) async throws {
        guard HKHealthStore.isHealthDataAvailable(), let type = quantityType(for: kind) else {
            throw ImportFailure.healthUnavailable
        }
        try await store.requestAuthorization(toShare: [type], read: [type])
        guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            throw ImportFailure.quantityPermissionDenied(kind)
        }
    }

    func alreadySaved(_ item: QuantityImportCandidate) async throws -> Bool {
        guard let type = quantityType(for: item.kind) else { throw ImportFailure.invalidQuantitySample }
        let ownSource = HKQuery.predicateForObjects(from: HKSource.default())
        let identifier = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [item.id])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [ownSource, identifier])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)], sortDescriptors: [], limit: 2
        )
        let matches = try await descriptor.result(for: store)
        guard matches.count <= 1 else { throw ImportFailure.conflictingSavedSample }
        guard let match = matches.first else { return false }
        let expected = NSDecimalNumber(decimal: item.value).doubleValue
        let observed = match.quantity.doubleValue(for: quantityUnit(for: item.kind))
        guard match.startDate == item.start, match.endDate == item.end,
              abs(observed - expected) < 0.000_000_1 else { throw ImportFailure.conflictingSavedSample }
        return true
    }

    func save(_ item: QuantityImportCandidate) async throws {
        guard let type = quantityType(for: item.kind), item.end > item.start else {
            throw ImportFailure.invalidQuantitySample
        }
        let value = NSDecimalNumber(decimal: item.value).doubleValue
        guard value.isFinite, value > 0 else { throw ImportFailure.invalidQuantitySample }
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: quantityUnit(for: item.kind), doubleValue: value),
            start: item.start,
            end: item.end,
            metadata: [
                HKMetadataKeySyncIdentifier: item.id,
                HKMetadataKeySyncVersion: item.mappingVersion,
                "EvenHealthBridgeSource": item.source,
                "EvenHealthBridgeParserVersion": String(item.parserVersion),
                "EvenHealthBridgeMappingVersion": String(item.mappingVersion)
            ]
        )
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

    private func quantityType(for kind: QuantityImportKind) -> HKQuantityType? {
        let identifier: HKQuantityTypeIdentifier = switch kind {
        case .steps: .stepCount
        case .activeEnergy: .activeEnergyBurned
        }
        return HKObjectType.quantityType(forIdentifier: identifier)
    }

    private func quantityUnit(for kind: QuantityImportKind) -> HKUnit {
        switch kind {
        case .steps: .count()
        case .activeEnergy: .kilocalorie()
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
        guard SleepWriteEligibility.accepts(item),
              let end = item.intervalEnd, let stage = item.sleepStage,
              let sessionStart = EvenDataParser.parseDate(item.originalTimestamp),
              let sessionEnd = item.sessionEnd else { throw ImportFailure.invalidSample }
        context.insert(StoredSample(stableID: item.id, category: "sleep", start: item.timestamp, end: end, sessionStart: sessionStart, sessionEnd: sessionEnd, stage: stage))
        try context.save()
    }
}

@MainActor struct SwiftDataQuantityRepository: QuantityImportRecording {
    let context: ModelContext

    func existingSamples(for kind: QuantityImportKind) throws -> [ImportedQuantitySample] {
        try context.fetch(FetchDescriptor<StoredQuantitySample>()).compactMap { stored in
            guard stored.category == kind.rawValue else { return nil }
            guard let value = Decimal(string: stored.valueText, locale: Locale(identifier: "en_US_POSIX")) else {
                return nil
            }
            return .init(id: stored.stableID, kind: kind, start: stored.start, end: stored.end,
                         value: value, unit: stored.unit)
        }
    }

    func record(_ sample: QuantityImportCandidate) throws {
        context.insert(StoredQuantitySample(sample))
        try context.save()
    }
}

enum ImportFailure: LocalizedError {
    case healthUnavailable, permissionDenied, quantityPermissionDenied(QuantityImportKind), invalidSample,
         invalidQuantitySample, unreadableArchive, conflictingSavedSample
    var errorDescription: String? {
        switch self {
        case .healthUnavailable: String(localized: "Apple Salute non è disponibile su questo dispositivo.")
        case .permissionDenied: String(localized: "Autorizzazione alla scrittura del sonno non concessa.")
        case .quantityPermissionDenied(let kind):
            switch kind {
            case .steps: String(localized: "Autorizzazione alla scrittura dei passi non concessa.")
            case .activeEnergy: String(localized: "Autorizzazione alla scrittura delle calorie attive non concessa.")
            }
        case .invalidSample: String(localized: "Campione di sonno non valido.")
        case .invalidQuantitySample: String(localized: "Campione di passi o calorie attive non valido.")
        case .unreadableArchive: String(localized: "Impossibile leggere il file selezionato.")
        case .conflictingSavedSample: String(localized: "In Apple Salute esiste già un campione con lo stesso identificativo ma dati diversi. Importazione interrotta.")
        }
    }
}

enum ImportInterruptionReason {
    case cancelled, permissionDenied, healthUnavailable, conflictingSample, invalidSample, other

    init(error: Error) {
        switch error {
        case ImportFailure.permissionDenied: self = .permissionDenied
        case ImportFailure.quantityPermissionDenied: self = .permissionDenied
        case ImportFailure.healthUnavailable: self = .healthUnavailable
        case ImportFailure.conflictingSavedSample: self = .conflictingSample
        case ImportFailure.invalidSample, ImportFailure.invalidQuantitySample: self = .invalidSample
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .cancelled: String(localized: "Annullata")
        case .permissionDenied: String(localized: "Permesso Salute negato")
        case .healthUnavailable: String(localized: "Apple Salute non disponibile")
        case .conflictingSample: String(localized: "Conflitto in Apple Salute")
        case .invalidSample: String(localized: "Campione di sonno non valido")
        case .other: String(localized: "Errore di sincronizzazione")
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
    var quantityWrittenCounts: [QuantityImportKind: Int] = [:]
    var progress: (completed: Int, total: Int)?
    private var activeAttemptID: UUID?

    func analyze(_ url: URL) async {
        guard !Task.isCancelled else { return }
        guard !isWorking else {
            error = String(localized: "Attendi la fine dell'importazione prima di aprire un altro archivio.")
            return
        }
        isWorking = true
        dataset = nil
        activeAttemptID = nil
        error = nil
        persisted = false
        writtenCount = nil
        quantityWrittenCounts = [:]
        progress = nil
        defer { isWorking = false }
        let inbox = FileImporterInbox.currentAppInbox()
        _ = try? inbox?.discardCopies(except: url)
        defer { _ = try? inbox?.discardIfOwnedCopy(url) }
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
            let format = String(localized: "Impossibile analizzare l'archivio: %@")
            self.error = String(format: format, locale: .current, error.localizedDescription)
            DiagnosticLoggingService.logger.error("Archive analysis failed")
        }
    }

    func importSleep(in context: ModelContext) async {
        guard !isWorking, let dataset else { return }
        isWorking = true
        error = nil
        progress = nil
        writtenCount = nil
        quantityWrittenCounts = [:]
        defer { isWorking = false }
        do {
            try recordStartedImport(in: context)
            writtenCount = try await SleepImportExecutor().run(dataset.measurements, writer: HealthKitService(), repository: SwiftDataSleepRepository(context: context)) { completed, total in
                self.progress = (completed, total)
            }
            try saveAnalysis(in: context)
            DiagnosticLoggingService.logger.info("Sleep import completed; written: \(self.writtenCount ?? 0, privacy: .public)")
        } catch is CancellationError {
            self.error = String(localized: "Importazione interrotta. Puoi riprendere quando vuoi.")
            try? recordInterruptedImport(in: context, reason: .cancelled)
            DiagnosticLoggingService.logger.info("Sleep import cancelled")
        } catch {
            self.error = error.localizedDescription
            try? recordInterruptedImport(in: context, reason: ImportInterruptionReason(error: error))
            DiagnosticLoggingService.logger.error("Sleep import interrupted")
        }
    }

    func importQuantities(in context: ModelContext, kinds: Set<QuantityImportKind>) async {
        guard !isWorking, let dataset, !kinds.isEmpty else { return }
        isWorking = true
        error = nil
        progress = nil
        writtenCount = nil
        quantityWrittenCounts = [:]
        defer { isWorking = false }
        do {
            try recordStartedImport(in: context)
            var totalWritten = 0
            for kind in QuantityImportKind.allCases where kinds.contains(kind) {
                let written = try await QuantityImportExecutor().run(
                    dataset.measurements, kind: kind, writer: HealthKitService(),
                    repository: SwiftDataQuantityRepository(context: context)
                ) { completed, total in
                    self.progress = (completed, total)
                }
                totalWritten += written
                writtenCount = totalWritten
                quantityWrittenCounts[kind] = written
            }
            try saveAnalysis(in: context)
            DiagnosticLoggingService.logger.info("Quantity import completed; written: \(totalWritten, privacy: .public)")
        } catch is CancellationError {
            self.error = String(localized: "Importazione interrotta. Puoi riprendere quando vuoi.")
            try? recordInterruptedImport(in: context, reason: .cancelled)
            DiagnosticLoggingService.logger.info("Quantity import cancelled")
        } catch {
            self.error = error.localizedDescription
            try? recordInterruptedImport(in: context, reason: ImportInterruptionReason(error: error))
            DiagnosticLoggingService.logger.error("Quantity import interrupted")
        }
    }

    func recordStartedImport(in context: ModelContext) throws {
        guard let dataset else { return }
        if persisted { activeAttemptID = UUID() }
        let attempt = try currentAttempt(in: context, dataset: dataset)
        attempt.status = String(localized: "Importazione avviata; esito da verificare")
        attempt.excluded = try excludedCount(in: context)
        try context.save()
        persisted = true
    }

    func recordInterruptedImport(in context: ModelContext, reason: ImportInterruptionReason) throws {
        guard let dataset else { return }
        let saved = try confirmedStoredCount(in: context, dataset: dataset)
        let session = try currentAttempt(in: context, dataset: dataset)
        session.writtenSamples = saved
        session.excluded = try excludedCount(in: context)
        let format = String(localized: "%@: %@ campioni registrati localmente; verifica al prossimo tentativo.")
        session.status = String(format: format, locale: .current, reason.title, String(saved))
        try context.save()
    }

    func saveAnalysis(in context: ModelContext) throws {
        guard let dataset else { return }
        let session = try currentAttempt(in: context, dataset: dataset)
        if let writtenCount {
            let saved = try confirmedStoredCount(in: context, dataset: dataset)
            session.writtenSamples = saved
            session.lastSyncedAt = .now
            let statusFormat = String(localized: "Dati sincronizzati: %lld campioni, %lld nuovi in questo tentativo")
            session.status = String(format: statusFormat, locale: .current, saved, writtenCount)
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
            excluded: 0, status: String(localized: "Analizzato; nessun campione scritto")
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
        let quantityConflicts = try QuantityImportKind.allCases.reduce(0) { total, kind in
            total + QuantityImportPlanner().plan(
                dataset.measurements, kind: kind,
                imported: try SwiftDataQuantityRepository(context: context).existingSamples(for: kind)
            ).conflicts
        }
        return invalidOrAmbiguous + overlapConflicts + quantityConflicts
    }

    private func confirmedStoredCount(in context: ModelContext, dataset: ParsedDataset) throws -> Int {
        let sleepIDs = Set(dataset.measurements.filter { $0.kind == .sleep }.map(\.id))
        let sleepCount = try context.fetch(FetchDescriptor<StoredSample>()).filter { sleepIDs.contains($0.stableID) }.count
        let storedQuantityIDs = Set(try context.fetch(FetchDescriptor<StoredQuantitySample>()).map(\.stableID))
        let quantityCount = try QuantityImportKind.allCases.reduce(0) { total, kind in
            total + QuantityImportPlanner().plan(
                dataset.measurements, kind: kind,
                imported: try SwiftDataQuantityRepository(context: context).existingSamples(for: kind)
            ).candidates.filter { storedQuantityIDs.contains($0.id) }.count
        }
        return sleepCount + quantityCount
    }
}

enum LocalStore {
    static func open(configuration: ModelConfiguration = ModelConfiguration(cloudKitDatabase: .none)) -> ModelContainer? {
        do {
            return try ModelContainer(for: StoredImportSession.self, StoredImportAttempt.self, StoredSample.self, StoredQuantitySample.self, configurations: configuration)
        } catch {
            DiagnosticLoggingService.logger.error("Local history store unavailable")
            return nil
        }
    }
}

@main
struct EvenHealthBridgeApp: App {
    @State private var container = LocalStore.open()

    init() {
        // iOS can leave a document-provider copy here if the process ends before analysis starts.
        // This is the app-owned Inbox only; the original file in Files is never touched.
        try? FileImporterInbox.currentAppInbox()?.discardCopies()
    }

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
    @State private var intentRouter = EvenHealthBridgeIntentRouter.shared
    @State private var analysisTask: Task<Void, Never>?
    @State private var handledIntentRouteID: UUID?
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ImportView(coordinator: coordinator, analysisTask: $analysisTask)
            }
            .tabItem { Label("Importa", systemImage: "square.and.arrow.down") }
            .tag(0)
            NavigationStack {
                AppleWatchStudyView(coordinator: coordinator, analysisTask: $analysisTask)
            }
            .tabItem { Label("Studio", systemImage: "applewatch") }
            .tag(1)
            NavigationStack {
                ImportHistoryView()
            }
            .tabItem { Label("Cronologia", systemImage: "clock") }
            .tag(2)
            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Impostazioni", systemImage: "gear") }
            .tag(3)
        }
        .onOpenURL { url in
            guard let archive = IncomingArchive(url: url) else { return }
            selectedTab = 0
            let previous = analysisTask
            analysisTask = Task {
                previous?.cancel()
                await previous?.value
                guard !Task.isCancelled else { return }
                await coordinator.analyze(archive.url)
            }
        }
        .onChange(of: intentRouter.pendingRoute?.id, initial: true) { _, _ in
            applyPendingIntentDestination()
        }
    }

    private func applyPendingIntentDestination() {
        guard let route = intentRouter.pendingRoute, route.id != handledIntentRouteID else { return }
        selectedTab = route.destination.tabIndex
        handledIntentRouteID = route.id
    }
}
