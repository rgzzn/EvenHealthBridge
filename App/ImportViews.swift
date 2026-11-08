import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import EvenHealthCore

private protocol ImportHistoryRecord {
    var importedAt: Date { get }
    var records: Int { get }
    var duplicates: Int { get }
    var excluded: Int { get }
    var parserVersion: Int { get }
    var mappingVersion: Int { get }
    var status: String { get }
    var writtenSamples: Int { get }
}

extension StoredImportSession: ImportHistoryRecord {}
extension StoredImportAttempt: ImportHistoryRecord {}

struct ImportView: View {
    let coordinator: ImportCoordinator
    @Binding var analysisTask: Task<Void, Never>?
    @State private var showImporter = false

    var body: some View {
        List {
            DashboardView(isWorking: coordinator.isWorking) { showImporter = true }
            if coordinator.isWorking && coordinator.progress == nil {
                Section("Analisi") {
                    Button("Annulla analisi", role: .cancel) { analysisTask?.cancel() }
                }
            }
            if coordinator.isWorking || coordinator.progress != nil {
                ImportProgressView(coordinator: coordinator)
            }
            if let error = coordinator.error {
                Section("Errore") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            if let dataset = coordinator.dataset {
                ImportPreviewView(dataset: dataset, coordinator: coordinator)
            }
        }
        .navigationTitle("Importa")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let previous = analysisTask
                    analysisTask = Task {
                        previous?.cancel()
                        await previous?.value
                        guard !Task.isCancelled else { return }
                        await coordinator.analyze(url)
                    }
                }
            case .failure(let error): coordinator.error = error.localizedDescription
            }
        }
    }
}

struct DashboardView: View {
    let isWorking: Bool
    let openArchive: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \StoredImportAttempt.importedAt, order: .reverse) private var attempts: [StoredImportAttempt]
    @Query(sort: \StoredImportSession.importedAt, order: .reverse) private var legacySessions: [StoredImportSession]
    @Query private var savedSamples: [StoredSample]
    @State private var healthStatus = "Non verificato"

    private var latest: (any ImportHistoryRecord)? {
        let attempt = attempts.first
        let legacy = legacySessions.first
        if let attempt, let legacy { return attempt.importedAt >= legacy.importedAt ? attempt : legacy }
        if let attempt { return attempt }
        return legacy
    }

    private var lastSync: Date? {
        (attempts.compactMap(\.lastSyncedAt) + legacySessions.compactMap(\.lastSyncedAt)).max()
    }

    private var importedCategories: String {
        let names = Set(savedSamples.map(\.category)).sorted().map { $0 == "sleep" ? "Sonno" : $0 }
        return names.isEmpty ? "Nessuna" : names.joined(separator: ", ")
    }

    var body: some View {
        Section("Riepilogo") {
            Button(action: openArchive) {
                Label("Seleziona archivio ZIP", systemImage: "doc.zipper")
                    .font(.headline)
            }
            .disabled(isWorking)
            Text("Apri un archivio Even da Files. Analisi sul dispositivo.")
                .font(.footnote).foregroundStyle(.secondary)
            LabeledContent("Apple Salute · sonno", value: healthStatus)
            LabeledContent("Categorie importate", value: importedCategories)
            LabeledContent("Fasi del sonno registrate", value: "\(savedSamples.count)")
            if let first = savedSamples.map(\.start).min(), let last = savedSamples.map(\.end).max() {
                LabeledContent("Periodo importato", value: "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
            }
            if let lastSync {
                LabeledContent("Ultima sincronizzazione", value: lastSync.formatted(date: .abbreviated, time: .shortened))
            } else {
                LabeledContent("Ultima sincronizzazione", value: "Mai")
            }
            if let latest {
                LabeledContent("Ultima analisi", value: latest.importedAt.formatted(date: .abbreviated, time: .shortened))
                Text(latest.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { healthStatus = HealthKitService.sleepWriteStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { healthStatus = HealthKitService.sleepWriteStatus() }
        }
        .onChange(of: isWorking) { _, working in
            if !working { healthStatus = HealthKitService.sleepWriteStatus() }
        }
    }
}

struct ImportProgressView: View {
    let coordinator: ImportCoordinator

    var body: some View {
        Section("Avanzamento") {
            if let progress = coordinator.progress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                    Text("Scrittura del sonno")
                } currentValueLabel: {
                    Text("\(progress.completed) di \(progress.total) fasi")
                }
                .accessibilityLabel("Scrittura del sonno, \(progress.completed) di \(progress.total) fasi")
            } else if coordinator.isWorking {
                ProgressView("Analisi o autorizzazione in corso")
            }
        }
    }
}

struct ImportPreviewView: View {
    let dataset: ParsedDataset
    let coordinator: ImportCoordinator
    @Environment(\.modelContext) private var context
    @Query private var savedSamples: [StoredSample]
    @State private var includeSleep = true
    @State private var importTask: Task<Void, Never>?
    @AppStorage("previewInDeviceTimeZone") private var previewInDeviceTimeZone = false

    private var plan: SleepImportPlan {
        let imported = savedSamples.map {
            ImportedSleepSample(id: $0.stableID, start: $0.start, end: $0.end, sessionStart: $0.sessionStart, sessionEnd: $0.sessionEnd, stage: $0.stage)
        }
        return SleepImportPlanner().plan(dataset.measurements, imported: imported)
    }

    var body: some View {
        let plan = self.plan
        let summary = ImportPreviewSummary(measurements: dataset.measurements, sleepPlan: plan)
        Section("Anteprima") {
            if let first = summary.categories.compactMap(\.periodStart).min(),
               let last = summary.categories.compactMap(\.periodEnd).max() {
                LabeledContent("Periodo", value: "\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
            }
            ForEach(summary.categories, id: \.kind) { category in
                CategorySummaryRow(summary: category, previewInDeviceTimeZone: previewInDeviceTimeZone)
            }
        }
        Section("Sonno importabile") {
            LabeledContent("Nuove fasi", value: "\(plan.newSamples.count)")
            LabeledContent("Già importate", value: "\(plan.alreadyImported)")
            LabeledContent("Conflitti tra archivi", value: "\(plan.conflicts)")
            Toggle("Includi il sonno", isOn: $includeSleep)
            Text("Le altre categorie sono escluse finché unità, intervalli e significato dei valori non sono verificati.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !plan.newSamples.isEmpty {
                DisclosureGroup("Esamina le \(plan.newSamples.count) fasi nuove") {
                    ForEach(plan.newSamples) { sample in
                        SleepStagePreviewRow(sample: sample, previewInDeviceTimeZone: previewInDeviceTimeZone)
                    }
                }
            }
            if let written = coordinator.writtenCount {
                Label("Nuove fasi salvate: \(written)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            Button("Importa il sonno in Apple Salute") {
                importTask = Task { await coordinator.importSleep(in: context) }
            }
            .disabled(coordinator.isWorking || !includeSleep || plan.newSamples.isEmpty)
            .accessibilityHint("Richiede il permesso di scrittura del sonno prima di salvare i campioni")
            if coordinator.isWorking && coordinator.progress != nil {
                Button("Interrompi importazione", role: .cancel) { importTask?.cancel() }
            }
            Button(coordinator.persisted ? "Analisi registrata" : "Registra solo l'analisi") {
                do { try coordinator.saveAnalysis(in: context) }
                catch { coordinator.error = error.localizedDescription }
            }
            .disabled(coordinator.persisted || coordinator.isWorking)
        }
        if !dataset.warnings.isEmpty {
            Section("Avvisi") {
                ForEach(dataset.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }
        }
    }
}

private struct CategorySummaryRow: View {
    let summary: CategoryPreviewSummary
    let previewInDeviceTimeZone: Bool

    private var title: String {
        switch summary.kind {
        case .steps: "Passi"
        case .calories: "Calorie"
        case .heartRate: "Frequenza cardiaca"
        case .hrv: "Variabilità cardiaca"
        case .oxygen: "Ossigenazione"
        case .sleep: "Sonno"
        case .skinTemperature: "Temperatura"
        }
    }

    var body: some View {
        DisclosureGroup {
            LabeledContent("Misurazioni analizzate", value: "\(summary.records)")
            LabeledContent("Validati nello ZIP", value: "\(summary.eligible)")
            LabeledContent("Nuovi in Salute", value: "\(summary.new)")
            LabeledContent("Già importati", value: "\(summary.alreadyImported)")
            LabeledContent("Duplicati nello ZIP", value: "\(summary.duplicates)")
            LabeledContent("Esclusi", value: "\(summary.excluded)")
            LabeledContent("Conflitti", value: "\(summary.conflicts)")
            if let start = summary.periodStart, let end = summary.periodEnd {
                LabeledContent(previewInDeviceTimeZone ? "Periodo nel fuso iPhone" : "Periodo UTC",
                    value: "\(PreviewDateFormatting.string(start, inDeviceTimeZone: previewInDeviceTimeZone)) – \(PreviewDateFormatting.string(end, inDeviceTimeZone: previewInDeviceTimeZone))")
            }
            if !summary.sources.isEmpty {
                let sourceText = summary.sources.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: " · ")
                LabeledContent("Sorgenti", value: sourceText)
            }
            if summary.kind != .sleep {
                Text("Scrittura esclusa: unità, intervallo o significato dei valori non verificati.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text("\(summary.records) misurazioni · \(summary.new) nuove · \(summary.duplicates) duplicate · \(summary.excluded) escluse")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SleepStagePreviewRow: View {
    let sample: HealthMeasurement
    let previewInDeviceTimeZone: Bool

    private var stageName: String {
        switch sample.sleepStage {
        case 0: "Veglia"
        case 1: "REM"
        case 2: "Sonno leggero"
        case 3: "Sonno profondo"
        default: "Fase sconosciuta"
        }
    }

    var body: some View {
        if let end = sample.intervalEnd {
            let duration = Int(end.timeIntervalSince(sample.timestamp))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stageName).font(.headline)
                    Spacer()
                    Text("\(duration / 60) min \(duration % 60) s")
                        .foregroundStyle(.secondary)
                }
                Text("\(PreviewDateFormatting.string(sample.timestamp, inDeviceTimeZone: previewInDeviceTimeZone)) – \(PreviewDateFormatting.string(end, inDeviceTimeZone: previewInDeviceTimeZone))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Sorgente: \(sample.source)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

enum PreviewDateFormatting {
    static func string(_ date: Date, inDeviceTimeZone: Bool, deviceTimeZone: TimeZone = .current) -> String {
        guard inDeviceTimeZone else { return date.ISO8601Format() }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = deviceTimeZone
        return formatter.string(from: date)
    }
}

struct ImportHistoryView: View {
    @Query(sort: \StoredImportAttempt.importedAt, order: .reverse) private var attempts: [StoredImportAttempt]
    @Query(sort: \StoredImportSession.importedAt, order: .reverse) private var legacySessions: [StoredImportSession]

    var body: some View {
        List {
            if attempts.isEmpty && legacySessions.isEmpty {
                ContentUnavailableView("Nessuna importazione", systemImage: "clock", description: Text("Le analisi registrate compariranno qui."))
            }
            if !attempts.isEmpty {
                Section("Importazioni") {
                    ForEach(attempts) { attempt in
                        NavigationLink {
                            ImportSessionDetailView(session: attempt)
                        } label: {
                            ImportHistoryRow(session: attempt)
                        }
                    }
                }
            }
            if !legacySessions.isEmpty {
                Section("Cronologia precedente") {
                    ForEach(legacySessions) { session in
                        NavigationLink {
                            ImportSessionDetailView(session: session)
                        } label: {
                            ImportHistoryRow(session: session)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cronologia")
    }
}

private struct ImportHistoryRow: View {
    let session: any ImportHistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.importedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            Text(session.status).font(.subheadline)
            Text("\(session.records) record · \(session.duplicates) duplicati · \(session.writtenSamples) fasi salvate")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ImportSessionDetailView: View {
    let session: any ImportHistoryRecord

    var body: some View {
        Form {
            Section("Risultato") {
                Text(session.status)
                LabeledContent("Record analizzati", value: "\(session.records)")
                LabeledContent("Duplicati", value: "\(session.duplicates)")
                LabeledContent("Esclusi", value: "\(session.excluded)")
                LabeledContent("Fasi salvate", value: "\(session.writtenSamples)")
            }
            Section("Versioni") {
                LabeledContent("Parser", value: "\(session.parserVersion)")
                LabeledContent("Mapping", value: "\(session.mappingVersion)")
            }
        }
        .navigationTitle("Importazione")
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var attempts: [StoredImportAttempt]
    @Query private var legacySessions: [StoredImportSession]
    @State private var showingClearConfirmation = false
    @State private var error: String?
    @AppStorage("previewInDeviceTimeZone") private var previewInDeviceTimeZone = false

    var body: some View {
        Form {
            Section("Apple Salute") {
                NavigationLink("Permessi Salute") { HealthPermissionsView() }
                Text("Solo le fasi del sonno validate vengono scritte. I dati di altre app restano invariati.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Anteprima") {
                Toggle("Mostra orari nel fuso dell'iPhone", isOn: $previewInDeviceTimeZone)
                Text("Gli orari includono sempre il fuso: UTC o quello impostato sull'iPhone. Le date dei campioni salvati non cambiano.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Dati e cronologia restano sull'iPhone. Nessun account, server o tracciamento. Gli archivi non vengono conservati.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Diagnostica") {
                NavigationLink("Stato dell'app") { DiagnosticsView() }
                Text("Mostra solo versioni e conteggi locali, senza valori biometrici.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Cronologia") {
                Button("Cancella cronologia delle analisi", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(attempts.isEmpty && legacySessions.isEmpty)
                Text("Gli identificativi dei campioni salvati restano sul dispositivo per prevenire duplicati nelle importazioni future.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Impostazioni")
        .confirmationDialog("Cancellare la cronologia delle analisi?", isPresented: $showingClearConfirmation) {
            Button("Cancella cronologia", role: .destructive) {
                for attempt in attempts { context.delete(attempt) }
                for session in legacySessions { context.delete(session) }
                do { try context.save() }
                catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("I campioni già importati e i loro identificativi rimangono in Apple Salute e sul dispositivo.")
        }
    }
}

private struct DiagnosticsView: View {
    @Query(sort: \StoredImportAttempt.importedAt, order: .reverse) private var attempts: [StoredImportAttempt]
    @Query private var legacySessions: [StoredImportSession]
    @Query private var savedSamples: [StoredSample]

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section("Versioni") {
                LabeledContent("App", value: appVersion)
                LabeledContent("Parser", value: "\(ImportFormatVersion.parser)")
                LabeledContent("Mapping Salute", value: "\(ImportFormatVersion.mapping)")
            }
            Section("Stato locale") {
                LabeledContent("Tentativi registrati", value: "\(attempts.count)")
                LabeledContent("Importazioni precedenti", value: "\(legacySessions.count)")
                LabeledContent("Fasi registrate", value: "\(savedSamples.count)")
                if let latest = attempts.first {
                    LabeledContent("Ultimo tentativo", value: latest.importedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(latest.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Text("Questi conteggi sono letti dal dispositivo. Nessun dato viene inviato all'esterno.")
            }
        }
        .navigationTitle("Diagnostica")
    }
}
