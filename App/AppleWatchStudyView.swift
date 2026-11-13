import HealthKit
import SwiftUI
import UniformTypeIdentifiers
import EvenHealthCore

@MainActor
struct AppleWatchStudyHealthReader {
    private let store = HKHealthStore()

    func requestAndRead(in interval: DateInterval) async throws -> [AppleWatchReferenceSample] {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppleWatchStudyError.healthUnavailable }
        let requested = Set(AppleWatchStudyMetric.allCases.compactMap { quantityType(for: $0) as HKObjectType? })
        try await store.requestAuthorization(toShare: [], read: requested)

        var output: [AppleWatchReferenceSample] = []
        for metric in AppleWatchStudyMetric.allCases {
            guard let type = quantityType(for: metric) else { continue }
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: predicate)],
                sortDescriptors: []
            )
            let samples = try await descriptor.result(for: store)
            output += samples.compactMap { sample in
                guard isLikelyAppleWatch(sample), let value = value(of: sample, metric: metric) else { return nil }
                return AppleWatchReferenceSample(metric: metric, timestamp: sample.startDate, value: value)
            }
        }
        return output
    }

    private func quantityType(for metric: AppleWatchStudyMetric) -> HKQuantityType? {
        let identifier: HKQuantityTypeIdentifier
        switch metric {
        case .steps: identifier = .stepCount
        case .activeEnergy: identifier = .activeEnergyBurned
        case .heartRate: identifier = .heartRate
        case .hrv: identifier = .heartRateVariabilitySDNN
        case .oxygen: identifier = .oxygenSaturation
        }
        return HKObjectType.quantityType(forIdentifier: identifier)
    }

    private func isLikelyAppleWatch(_ sample: HKQuantitySample) -> Bool {
        sample.sourceRevision.source.name.localizedCaseInsensitiveContains("watch")
    }

    private func value(of sample: HKQuantitySample, metric: AppleWatchStudyMetric) -> Double? {
        let value: Double
        switch metric {
        case .steps:
            value = sample.quantity.doubleValue(for: .count())
        case .activeEnergy:
            value = sample.quantity.doubleValue(for: .kilocalorie())
        case .heartRate:
            value = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        case .hrv:
            value = sample.quantity.doubleValue(for: .secondUnit(with: .milli))
        case .oxygen:
            // HealthKit represents 98% as 0.98 in HKUnit.percent(); Even exports 98.
            value = sample.quantity.doubleValue(for: .percent()) * 100
        }
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }
}

enum AppleWatchStudyError: LocalizedError {
    case healthUnavailable

    var errorDescription: String? {
        switch self {
        case .healthUnavailable: String(localized: "Apple Salute non e disponibile su questo dispositivo.")
        }
    }
}

struct AppleWatchStudyView: View {
    let coordinator: ImportCoordinator
    @Binding var analysisTask: Task<Void, Never>?
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var endDate = Date.now
    @State private var didUseArchivePeriod = false
    @State private var isRunning = false
    @State private var report: AppleWatchStudyReport?
    @State private var error: String?
    @State private var showImporter = false

    private var dataset: ParsedDataset? { coordinator.dataset }

    private var selectedInterval: DateInterval? {
        guard endDate > startDate else { return nil }
        return DateInterval(start: startDate, end: endDate)
    }

    var body: some View {
        Form {
            archiveSection
            intervalSection
            studySection
            if let report { reportSection(report) }
            if let error {
                Section("Errore") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Studio")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let previous = analysisTask
                analysisTask = Task {
                    previous?.cancel()
                    await previous?.value
                    guard !Task.isCancelled else { return }
                    await coordinator.analyze(url)
                }
            case .failure(let importError):
                error = importError.localizedDescription
            }
        }
        .onChange(of: dataset?.archiveHash) { _, _ in
            report = nil
            error = nil
            setArchivePeriodIfNeeded()
        }
        .onAppear(perform: setArchivePeriodIfNeeded)
    }

    @ViewBuilder
    private var archiveSection: some View {
        Section("Archivio Even") {
            if let dataset, let period = datasetPeriod(dataset) {
                LabeledContent("Misurazioni analizzate", value: "\(dataset.measurements.count)")
                LabeledContent("Periodo ZIP", value: "\(period.start.formatted(date: .abbreviated, time: .omitted)) – \(period.end.formatted(date: .abbreviated, time: .omitted))")
                Text("Lo studio usa questo archivio e confronta solo il periodo selezionato.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Apri prima un archivio ZIP", systemImage: "doc.zipper",
                    description: Text("Seleziona un export Even per avviare il confronto."))
                Button("Seleziona archivio Even") { showImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var intervalSection: some View {
        Section("Intervallo di confronto") {
            DatePicker("Da", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
            DatePicker("A", selection: $endDate, in: startDate..., displayedComponents: [.date, .hourAndMinute])
            Text("I dati Apple Watch vengono interrogati solo in questo intervallo e non sono salvati nel database dell'app.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var studySection: some View {
        Section("Confronto Apple Watch") {
            Text("Richiede la lettura di passi, calorie attive, battito, HRV e ossigenazione. Non richiede scrittura e non modifica i dati in Apple Salute.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                Task { await runStudy() }
            } label: {
                if isRunning {
                    Label("Confronto in corso", systemImage: "chart.xyaxis.line")
                } else {
                    Label("Confronta con Apple Watch", systemImage: "applewatch")
                }
            }
            .disabled(dataset == nil || selectedInterval == nil || isRunning)
            .accessibilityHint("Chiede lettura in Apple Salute, non scrive alcun campione")
        }
    }

    @ViewBuilder
    private func reportSection(_ report: AppleWatchStudyReport) -> some View {
        Section("Risultato locale") {
            Text("Il confronto segnala compatibilita temporale e numerica; non abilita automaticamente alcuna nuova importazione.")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(report.results) { result in
                DisclosureGroup(result.metric.title) {
                    LabeledContent("Record Even nel periodo", value: "\(result.evenRecordsInRange)")
                    LabeledContent("Record confrontabili", value: "\(result.comparableEvenRecords)")
                    LabeledContent("Record Apple Watch", value: "\(result.appleWatchRecords)")
                    LabeledContent("Corrispondenze vicine", value: "\(result.matchedRecords)")
                    LabeledContent("Even senza confronto", value: "\(result.unmatchedEvenRecords)")
                    if let coverage = result.coverage {
                        LabeledContent("Copertura del confronto", value: coverage.formatted(.percent.precision(.fractionLength(0))))
                    }
                    if let difference = result.medianAbsoluteDifference {
                        LabeledContent("Differenza assoluta mediana", value: difference.formatted(.number.precision(.fractionLength(1))))
                    } else if result.metric == .steps || result.metric == .activeEnergy {
                        Text("Mostra la copertura temporale, non una differenza numerica: l'intervallo del record Even non e ancora documentato.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if result.metric == .hrv {
                        Text("Anche una buona correlazione non dimostra che l'HRV Even sia SDNN: resta escluso dall'importazione.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func runStudy() async {
        guard let dataset, let interval = selectedInterval else { return }
        isRunning = true
        error = nil
        report = nil
        defer { isRunning = false }
        do {
            let references = try await AppleWatchStudyHealthReader().requestAndRead(in: interval)
            guard !Task.isCancelled else { return }
            report = AppleWatchStudyEngine().study(measurements: dataset.measurements, references: references, interval: interval)
        } catch is CancellationError {
            return
        } catch {
            self.error = String(localized: "Impossibile leggere i dati Apple Watch: \(error.localizedDescription)")
        }
    }

    private func datasetPeriod(_ dataset: ParsedDataset) -> DateInterval? {
        guard let first = dataset.measurements.map(\.timestamp).min(),
              let last = dataset.measurements.map(\.timestamp).max(), last >= first else { return nil }
        return DateInterval(start: first, end: last)
    }

    private func setArchivePeriodIfNeeded() {
        guard !didUseArchivePeriod, let dataset, let period = datasetPeriod(dataset) else { return }
        startDate = period.start
        endDate = period.end.addingTimeInterval(1)
        didUseArchivePeriod = true
    }
}
