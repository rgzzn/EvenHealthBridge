import HealthKit
import SwiftUI
import UniformTypeIdentifiers
import EvenHealthCore

@MainActor
struct HealthKitReferenceReader {
    private let store = HKHealthStore()
    private let referenceSource: ReferenceSourceDefinition

    init(referenceSource: ReferenceSourceDefinition = .appleWatch) {
        self.referenceSource = referenceSource
    }

    func requestAndRead(
        in interval: DateInterval,
        metrics: [AppleWatchStudyMetric]
    ) async throws -> [AppleWatchReferenceSample] {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppleWatchStudyError.healthUnavailable }
        guard !metrics.isEmpty else { return [] }
        try await requestReadAuthorization(for: metrics)

        var output: [AppleWatchReferenceSample] = []
        for metric in metrics {
            let samples = try await samples(for: metric, in: interval)
            output += samples.compactMap { sample in
                guard matchesReferenceSource(sample), let value = value(of: sample, metric: metric) else { return nil }
                return AppleWatchReferenceSample(
                    id: sample.uuid.uuidString,
                    metric: metric,
                    timestamp: sample.startDate,
                    intervalEnd: sample.endDate,
                    value: value
                )
            }
        }
        return output
    }

    /// Discovers only the source identity of samples in the selected study window. The caller
    /// keeps the result in view state and no HealthKit samples or source list are persisted.
    func discoverSources(
        in interval: DateInterval,
        metrics: [AppleWatchStudyMetric]
    ) async throws -> [ReferenceSourceAvailability] {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppleWatchStudyError.healthUnavailable }
        guard !metrics.isEmpty else { return [] }
        try await requestReadAuthorization(for: metrics)

        var observations: [ReferenceSourceObservation] = []
        for metric in metrics {
            for sample in try await samples(for: metric, in: interval) {
                observations.append(.init(
                    identity: .init(
                        productType: sample.sourceRevision.productType,
                        sourceName: sample.sourceRevision.source.name
                    ),
                    metric: metric
                ))
            }
        }
        return ReferenceSourceAvailability.summarize(observations)
    }

    private func requestReadAuthorization(for metrics: [AppleWatchStudyMetric]) async throws {
        let requested = Set(metrics.compactMap { quantityType(for: $0) as HKObjectType? })
        try await store.requestAuthorization(toShare: [], read: requested)
    }

    private func samples(for metric: AppleWatchStudyMetric, in interval: DateInterval) async throws -> [HKQuantitySample] {
        guard let type = quantityType(for: metric) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: []
        )
        return try await descriptor.result(for: store)
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

    private func matchesReferenceSource(_ sample: HKQuantitySample) -> Bool {
        referenceSource.matches(.init(
            productType: sample.sourceRevision.productType,
            sourceName: sample.sourceRevision.source.name
        ))
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
    @State private var isDiscoveringSources = false
    @State private var report: AppleWatchStudyReport?
    @State private var reportSource: ReferenceSourceDefinition?
    @State private var error: String?
    @State private var showImporter = false
    @State private var selectedReferenceSource = ReferenceSourceDefinition.appleWatch
    @State private var discoveredReferenceSources: [ReferenceSourceAvailability] = []
    @State private var selectedComparisonMetrics = Set<AppleWatchStudyMetric>()

    private var dataset: ParsedDataset? { coordinator.dataset }

    private var selectedInterval: DateInterval? {
        guard endDate > startDate else { return nil }
        return DateInterval(start: startDate, end: endDate)
    }

    private var availableComparisonMetrics: [AppleWatchStudyMetric] {
        guard let dataset, let interval = selectedInterval else { return [] }
        return AppleWatchStudyEngine().metricsForStudy(measurements: dataset.measurements, interval: interval)
    }

    private var comparisonMetrics: [AppleWatchStudyMetric] {
        availableComparisonMetrics.filter { selectedComparisonMetrics.contains($0) }
    }

    var body: some View {
        Form {
            archiveSection
            intervalSection
            metricSelectionSection
            sourceSection
            studySection
            if let report, let reportSource { reportSection(report, source: reportSource) }
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
            resetComparisonState()
            error = nil
            didUseArchivePeriod = false
            setArchivePeriodIfNeeded()
            selectAllAvailableMetrics()
        }
        .onChange(of: startDate) { _, _ in
            resetComparisonState()
            retainAvailableMetricSelections()
        }
        .onChange(of: endDate) { _, _ in
            resetComparisonState()
            retainAvailableMetricSelections()
        }
        .onChange(of: selectedReferenceSource) { _, _ in
            report = nil
            reportSource = nil
        }
        .onAppear {
            setArchivePeriodIfNeeded()
            if selectedComparisonMetrics.isEmpty { selectAllAvailableMetrics() }
        }
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
                .disabled(isRunning || isDiscoveringSources)
            DatePicker("A", selection: $endDate, in: startDate..., displayedComponents: [.date, .hourAndMinute])
                .disabled(isRunning || isDiscoveringSources)
            Text("I dati della fonte selezionata vengono interrogati solo in questo intervallo e non sono salvati nel database dell'app.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var metricSelectionSection: some View {
        if !availableComparisonMetrics.isEmpty {
            Section("Metriche da confrontare") {
                ForEach(availableComparisonMetrics) { metric in
                    Toggle(metric.title, isOn: metricSelectionBinding(for: metric))
                        .disabled(isRunning || isDiscoveringSources)
                }
                Text("Scegli quali metriche leggere e confrontare. La selezione non abilita l'importazione in Apple Salute.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var studySection: some View {
        Section("Confronto") {
            if availableComparisonMetrics.isEmpty {
                Text("Nessuna metrica Even confrontabile nell'intervallo selezionato.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if comparisonMetrics.isEmpty {
                Text("Seleziona almeno una metrica da confrontare.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                let format = String(localized: "Richiede la lettura solo di queste metriche selezionate: %@. Non richiede scrittura e non modifica i dati in Apple Salute.")
                Text(String(format: format, locale: .current, comparisonMetrics.map(\.title).joined(separator: ", ")))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await runStudy() }
            } label: {
                if isRunning {
                    Label("Confronto in corso", systemImage: "chart.xyaxis.line")
                } else {
                    Label(String(format: String(localized: "Confronta con %@"), locale: .current, selectedReferenceSource.displayName), systemImage: selectedReferenceSource == .appleWatch ? "applewatch" : "sensor.tag.radiowaves.forward")
                }
            }
            .disabled(dataset == nil || selectedInterval == nil || comparisonMetrics.isEmpty || isRunning || isDiscoveringSources)
            .accessibilityHint("Chiede lettura in Apple Salute, non scrive alcun campione")
        }
    }

    private var sourceSection: some View {
        Section("Fonte di confronto") {
            Picker("Fonte", selection: $selectedReferenceSource) {
                ForEach(referenceSourceOptions) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .disabled(isRunning || isDiscoveringSources)
            Button {
                Task { await discoverReferenceSources() }
            } label: {
                if isDiscoveringSources {
                    Label("Ricerca fonti in corso", systemImage: "magnifyingglass")
                } else {
                    Label("Cerca altre fonti", systemImage: "sensor.tag.radiowaves.forward")
                }
            }
            .disabled(selectedInterval == nil || comparisonMetrics.isEmpty || isDiscoveringSources || isRunning)
            Text("Cerca solo le fonti presenti nell’intervallo e per le metriche selezionate. I nomi e i dati delle fonti restano sul dispositivo e non vengono salvati dall’app.")
                .font(.footnote).foregroundStyle(.secondary)
            if let availability = selectedSourceAvailability {
                LabeledContent("Metriche trovate", value: availability.metrics.map(\.title).joined(separator: ", "))
                LabeledContent("Campioni trovati", value: "\(availability.totalSamples)")
            }
        }
    }

    @ViewBuilder
    private func reportSection(_ report: AppleWatchStudyReport, source: ReferenceSourceDefinition) -> some View {
        Section("Risultato locale") {
            Text("Questo è uno studio locale: non abilita automaticamente importazioni.")
                .font(.footnote).foregroundStyle(.secondary)
            ShareLink(
                item: shareSummary(for: report, source: source),
                subject: Text("Sintesi studio Even Health Bridge"),
                message: Text("Riepilogo locale senza campioni individuali")
            ) {
                Label("Condividi sintesi", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("Condivide solo intervallo e conteggi aggregati, senza campioni individuali")
            Text("La sintesi condivisibile contiene l'intervallo e conteggi aggregati, non campioni individuali Apple Salute.")
                .font(.footnote).foregroundStyle(.secondary)
            if report.referenceRecordCount == 0 {
                Label(String(format: String(localized: "Nessun campione %@ trovato nell'intervallo. Verifica l'intervallo e il permesso di lettura in Apple Salute; Apple non comunica all'app se il permesso di lettura è stato negato."), locale: .current, source.displayName), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                LabeledContent(String(format: String(localized: "Campioni %@ trovati"), locale: .current, source.displayName), value: "\(report.referenceRecordCount)")
            }
            ForEach(report.results) { result in
                DisclosureGroup(result.metric.title) {
                    LabeledContent("Record Even nel periodo", value: "\(result.evenRecordsInRange)")
                    LabeledContent("Record confrontabili", value: "\(result.comparableEvenRecords)")
                    LabeledContent("Record Even esclusi", value: "\(result.excludedEvenRecords)")
                    LabeledContent("Conflitti nel file Even", value: "\(result.conflictingEvenRecords)")
                    LabeledContent("Record della fonte", value: "\(result.referenceRecords)")
                    LabeledContent("Corrispondenze vicine", value: "\(result.matchedRecords)")
                    LabeledContent("Even senza confronto", value: "\(result.unmatchedEvenRecords)")
                    LabeledContent("Record della fonte senza corrispondenza", value: "\(result.unmatchedReferenceRecords)")
                    if let coverage = result.coverage {
                        LabeledContent("Copertura del confronto", value: coverage.formatted(.percent.precision(.fractionLength(0))))
                    }
                    if let difference = result.medianAbsoluteDifference {
                        LabeledContent("Differenza assoluta mediana", value: difference.formatted(.number.precision(.fractionLength(1))))
                    } else if result.contract.comparisonMode == .temporalPresence {
                        Text("Mostra la copertura temporale, non una differenza numerica: l'intervallo del record Even non e ancora documentato.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if result.metric == .hrv {
                        Text("La metrica HRV Even non è stata confermata come SDNN: il report mostra solo presenza temporale e resta esclusa dall'importazione.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Questo confronto non identifica lacune da riempire né modifica i dati in Apple Salute.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func runStudy() async {
        guard let dataset, let interval = selectedInterval else { return }
        let engine = AppleWatchStudyEngine()
        let metrics = comparisonMetrics
        guard !metrics.isEmpty else { return }
        isRunning = true
        error = nil
        report = nil
        reportSource = nil
        defer { isRunning = false }
        do {
            let source = selectedReferenceSource
            let references = try await HealthKitReferenceReader(referenceSource: source).requestAndRead(in: interval, metrics: metrics)
            guard !Task.isCancelled else { return }
            reportSource = source
            report = engine.study(
                measurements: dataset.measurements,
                references: references,
                interval: interval,
                metrics: Set(metrics)
            )
        } catch is CancellationError {
            return
        } catch {
            let format = String(localized: "Impossibile leggere i dati della fonte: %@")
            self.error = String(format: format, locale: .current, error.localizedDescription)
        }
    }

    private var referenceSourceOptions: [ReferenceSourceDefinition] {
        Array(Set([ReferenceSourceDefinition.appleWatch] + discoveredReferenceSources.map(\.source))).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var selectedSourceAvailability: ReferenceSourceAvailability? {
        discoveredReferenceSources.first { $0.source == selectedReferenceSource }
    }

    private func discoverReferenceSources() async {
        guard let interval = selectedInterval else { return }
        let metrics = comparisonMetrics
        guard !metrics.isEmpty else { return }
        isDiscoveringSources = true
        error = nil
        defer { isDiscoveringSources = false }
        do {
            discoveredReferenceSources = try await HealthKitReferenceReader().discoverSources(in: interval, metrics: metrics)
            if !referenceSourceOptions.contains(selectedReferenceSource) {
                selectedReferenceSource = .appleWatch
            }
        } catch is CancellationError {
            return
        } catch {
            let format = String(localized: "Impossibile cercare le fonti in Apple Salute: %@")
            self.error = String(format: format, locale: .current, error.localizedDescription)
        }
    }

    private func resetComparisonState() {
        report = nil
        reportSource = nil
        discoveredReferenceSources = []
        selectedReferenceSource = .appleWatch
    }

    private func metricSelectionBinding(for metric: AppleWatchStudyMetric) -> Binding<Bool> {
        Binding(
            get: { selectedComparisonMetrics.contains(metric) },
            set: { isSelected in
                if isSelected {
                    selectedComparisonMetrics.insert(metric)
                } else {
                    selectedComparisonMetrics.remove(metric)
                }
                resetComparisonState()
            }
        )
    }

    private func selectAllAvailableMetrics() {
        selectedComparisonMetrics = Set(availableComparisonMetrics)
    }

    private func retainAvailableMetricSelections() {
        selectedComparisonMetrics.formIntersection(Set(availableComparisonMetrics))
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

    private func shareSummary(for report: AppleWatchStudyReport, source: ReferenceSourceDefinition) -> String {
        let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let interval = "\(report.interval.start.formatted(dateFormat)) – \(report.interval.end.formatted(dateFormat))"
        let header = String(localized: "Sintesi studio locale")
        let sourceLabel = String(localized: "Fonte")
        let periodLabel = String(localized: "Intervallo di confronto")
        let matchedLabel = String(localized: "Corrispondenze vicine")
        let comparableLabel = String(localized: "Record confrontabili")
        let coverageLabel = String(localized: "Copertura del confronto")
        let differenceLabel = String(localized: "Differenza assoluta mediana")
        let privacy = String(localized: "Riepilogo locale senza campioni individuali")
        let results = report.results.map { result in
            var fields = [
                "\(matchedLabel): \(result.matchedRecords)",
                "\(comparableLabel): \(result.comparableEvenRecords)"
            ]
            if let coverage = result.coverage {
                fields.append("\(coverageLabel): \(coverage.formatted(.percent.precision(.fractionLength(0))))")
            }
            if let difference = result.medianAbsoluteDifference {
                fields.append("\(differenceLabel): \(difference.formatted(.number.precision(.fractionLength(1))))")
            }
            return "\(result.metric.title): \(fields.joined(separator: ", "))"
        }
        return ([
            header,
            "\(sourceLabel): \(source.displayName)",
            "\(periodLabel): \(interval)",
            "",
            privacy
        ] + results).joined(separator: "\n")
    }
}
