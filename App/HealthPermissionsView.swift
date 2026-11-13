import SwiftUI

struct HealthPermissionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = String(localized: "Non verificato")

    var body: some View {
        Form {
            Section("Autorizzazione sonno") {
                LabeledContent("Scrittura", value: status)
                Text("Quando confermi l'importazione, l'app chiede accesso al sonno in lettura e scrittura. Interroga soltanto i campioni che ha creato per evitare duplicati dopo un'interruzione.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Aggiorna stato") { refresh() }
            }
            Section("Studio Apple Watch") {
                Text("La scheda Studio richiede, solo quando avvii un confronto, la lettura di passi, calorie attive, battito, HRV e ossigenazione. Non scrive o modifica campioni Apple Watch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Se il permesso è negato") {
                Text("Apri le impostazioni di Apple Salute e abilita la scrittura dei dati sul sonno per Even Health Bridge.")
            }
        }
        .navigationTitle("Permessi Salute")
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        status = HealthKitService.sleepWriteStatus()
    }
}
