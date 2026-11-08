import SwiftUI
import HealthKit

struct HealthPermissionsView: View {
    @State private var status = "Non verificato"

    var body: some View {
        Form {
            Section("Autorizzazione sonno") {
                LabeledContent("Scrittura", value: status)
                Text("Quando confermi l'importazione, l'app chiede accesso al sonno in lettura e scrittura. Interroga soltanto i campioni che ha creato per evitare duplicati dopo un'interruzione.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Aggiorna stato") { refresh() }
            }
            Section("Se il permesso è negato") {
                Text("Apri le impostazioni di Apple Salute e abilita la scrittura dei dati sul sonno per Even Health Bridge.")
            }
        }
        .navigationTitle("Permessi Salute")
        .onAppear(perform: refresh)
    }

    private func refresh() {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Non disponibile"
            return
        }
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            status = "Tipo non disponibile"
            return
        }
        switch HKHealthStore().authorizationStatus(for: type) {
        case .sharingAuthorized: status = "Consentita"
        case .sharingDenied: status = "Negata"
        case .notDetermined: status = "Non ancora richiesta"
        @unknown default: status = "Sconosciuto"
        }
    }
}
