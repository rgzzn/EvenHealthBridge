# CODEX MASTER PROMPT — EVEN HEALTH BRIDGE
## Applicazione iPhone nativa per iOS 27

### 1. Ruolo e missione

Agisci come Senior Apple Platform Engineer, Swift Architect, HealthKit Specialist, Data Integration Engineer e iOS UI/UX Designer.

Devi progettare, sviluppare, testare e documentare **Even Health Bridge**, un'applicazione iPhone nativa che consenta di trasferire in Apple Salute i dati biometrici raccolti dallo smart ring Even Realities R1.

L'applicazione deve essere completa, affidabile, sicura e realmente utilizzabile su iPhone con iOS 27.

**Requisiti fondamentali:**
- Piattaforma esclusiva: iPhone.
- Deployment target minimo: iOS 27.0.
- Linguaggio: Swift 6, con strict concurrency checking.
- Framework UI: SwiftUI.
- Integrazione sanitaria: Apple HealthKit.
- Persistenza: SwiftData, salvo motivazione tecnica.
- Architettura: MVVM con servizi e dominio separati.
- Esecuzione completamente locale.
- Nessun account, backend o servizio cloud obbligatorio.
- Compatibilità con le API pubbliche e documentate dell'SDK iOS 27.

Utilizza una versione di Xcode che supporti effettivamente iOS 27. Verifica la disponibilità delle API prima di utilizzarle. Non inventare funzionalità di iOS 27. Non implementare fallback per iOS precedenti.

### 2. Contesto e dataset

Even Realities R1 raccoglie dati biometrici, ma non dispone di una sincronizzazione pubblica documentata con Apple HealthKit. L'app Even Realities consente di esportare informazioni sanitarie in formato ZIP contenente CSV.

Il progetto dispone di un archivio reale: `Even_health_data_20261108.zip`.

**Analizzalo direttamente** e utilizzalo come riferimento per la progettazione dei parser. La struttura attesa include:

| File | Informazioni |
|---|---|
| steps.csv | Passi |
| calories.csv | Calorie totali, a riposo e attive |
| heart_rate.csv | Frequenza cardiaca |
| hrv.csv | Variabilità cardiaca |
| blood_oxygen.csv | Saturazione ossigeno |
| sleep.csv | Sessioni e fasi del sonno |
| skin_temperature.csv | Temperatura cutanea |

Le sorgenti possono includere `R1` e `ring1Notify`. I dati possono presentare duplicati, valori aggregati, timestamp con fuso orario e statistiche min/max/avg. Il sonno può includere sequenze JSON di fasi con durata in unità di 30 secondi.

Non presumere che tutti i valori esportati siano direttamente equivalenti ai tipi HealthKit. Analizza struttura effettiva, unità, distribuzioni e anomalie prima di implementare le conversioni.

### 3. Obiettivo funzionale

1. L'utente esporta i dati dall'app Even Realities.
2. Apre Even Health Bridge.
3. Seleziona lo ZIP tramite Files o menu Condividi.
4. L'app estrae e analizza i CSV.
5. Normalizza i dati e identifica duplicati e anomalie.
6. Mostra un'anteprima delle misurazioni importabili.
7. L'utente seleziona le categorie desiderate.
8. L'app richiede le autorizzazioni HealthKit necessarie.
9. Scrive soltanto i campioni validi e non già importati.
10. Registra il risultato per le importazioni future.

L'intero processo deve essere ripetibile senza generare duplicati.

### 4. Architettura software

Organizza il codice in componenti indipendenti.

**Presentation Layer**
- DashboardView
- ImportView
- ImportPreviewView
- ImportProgressView
- ImportHistoryView
- SettingsView
- HealthPermissionsView

**Domain Layer**
- HealthMeasurement
- EvenDataSource
- ImportSession
- ImportValidation
- MeasurementDeduplicator
- HealthMappingEngine
- ImportCoordinator

**Infrastructure Layer**
- ZIPExtractionService
- CSVParsingService
- EvenDataParser
- HealthKitService
- PersistenceService
- ImportHistoryRepository
- DiagnosticLoggingService

Utilizza dependency injection e protocolli per rendere testabili i servizi. Evita singleton globali non necessari. Utilizza async/await, actor isolation e cancellazione strutturata delle operazioni.

### 5. Importazione ZIP e CSV

Implementa:
- FileImporter SwiftUI e, se fattibile, ricezione tramite Share Sheet.
- File da iCloud Drive e memoria locale.
- Security-scoped resources.
- ZIP con sottocartelle.
- CSV con campi opzionali, stringhe quotate e JSON incorporato.
- Timestamp ISO 8601 con offset.
- Numeri interi e decimali.
- File incompleti o malformati.
- Elaborazione efficiente di dataset grandi.

Non usare semplici split delle virgole per il parsing CSV. Previeni ZIP bomb, path traversal ed estrazioni non sicure. Non conservare inutilmente copie permanenti dei dati originali.

### 6. Normalizzazione e deduplicazione

Il modello canonico di ogni misurazione deve conservare:
- Tipo di dato.
- Timestamp UTC e fuso originale.
- Valore normalizzato.
- Unità originale e canonica.
- Sorgente.
- Eventuale intervallo e statistica aggregata.
- Identificativo deterministico.
- Provenienza e stato di validazione.

Gestisci duplicati tra `R1` e `ring1Notify`: valori come `46` e `46.0`, se riferiti alla stessa misurazione, sono equivalenti. Non usare soltanto timestamp e valore come criterio universale: considera tipo, sorgente, semantica e intervallo. Registra i conflitti senza scartarli silenziosamente. La deduplicazione deve funzionare anche tra ZIP esportati in giorni differenti.

### 7. Mapping HealthKit

| Even R1 | HealthKit |
|---|---|
| Passi | `HKQuantityTypeIdentifier.stepCount` |
| Calorie attive | `activeEnergyBurned` |
| Calorie a riposo | `basalEnergyBurned`, solo se semanticamente corretto |
| Frequenza cardiaca | `heartRate` |
| HRV | `heartRateVariabilitySDNN`, solo se confermato |
| Ossigenazione | `oxygenSaturation` |
| Sonno | `sleepAnalysis` |
| Temperatura cutanea | Tipo appropriato, solo se disponibile e compatibile |

Non importare min, max e avg come tre misurazioni indipendenti. Non confondere calorie totali, attive e basali; HRV SDNN con RMSSD; temperatura cutanea con temperatura corporea. Non inventare durate o frequenze di campionamento. Verifica il significato di valori `0.0`. Usa metadati HealthKit per provenienza, versione di sincronizzazione e identificativi stabili. Se la semantica non è dimostrabile, escludi la categoria dall'importazione automatica e documenta il motivo.

### 8. Ricostruzione del sonno

Analizza `stages` in `sleep.csv`, per esempio `{"type":0,"half_minutes":33}`.

1. Identifica la codifica delle fasi senza ipotesi arbitrarie.
2. Ricostruisci le durate.
3. Verifica coerenza con `start_ts`, `end_ts` e aggregati.
4. Gestisci correttamente fuso orario e ora legale.
5. Evita sovrapposizioni.
6. Converti nelle categorie HealthKit corrette.
7. Conserva informazioni diagnostiche.

Se il mapping dei codici non è verificabile, escludi le fasi dall'importazione automatica finché non viene validato.

### 9. Sincronizzazione incrementale

Memorizza con SwiftData:
- Importazioni eseguite e hash degli archivi.
- Identificativi dei record.
- Campioni importati o esclusi.
- Errori e stati parziali.
- Versioni del parser e dei mapping.
- Timestamp dell'ultima sincronizzazione.

Una seconda importazione dello stesso ZIP non deve produrre nuovi campioni. Prevedi recupero da interruzioni e scritture parziali. Non modificare o cancellare dati di Apple Watch o altre app. Non presumere che il permesso di scrittura HealthKit implichi quello di lettura.

### 10. Interfaccia nativa iOS 27

Progetta una UI moderna coerente con le Human Interface Guidelines e il linguaggio visivo di iOS 27. Usa componenti SwiftUI nativi, NavigationStack, TabView quando appropriato, SF Symbols, materiali di sistema, tipografia dinamica, animazioni discrete, Light/Dark Mode, VoiceOver, Dynamic Type, Reduce Motion e feedback aptico dove utile.

Adotta le convenzioni native di iOS 27 senza inventare effetti o API. Non sacrificare accessibilità e leggibilità per l'estetica.

**Dashboard:** stato HealthKit, ultima sincronizzazione, categorie importate, intervallo storico e pulsante principale.

**Anteprima:** record per categoria, validi, duplicati, nuovi, esclusi, periodo e avvisi.

**Sincronizzazione:** avanzamento, categoria corrente, errori e riepilogo.

**Cronologia:** tutte le importazioni precedenti.

**Impostazioni:** permessi, preferenze, diagnostica, privacy e gestione storico.

### 11. Privacy e sicurezza

I dati sanitari devono rimanere sul dispositivo. Non implementare analytics, tracking, backend, telemetria sanitaria o upload. Usa la protezione dati iOS. Cancella i temporanei. Non includere misurazioni nei log ordinari. Richiedi autorizzazioni granulari solo quando necessarie. Gestisci permessi negati, revocati o parziali. Configura capability e usage description HealthKit necessarie.

### 12. Test e qualità

Crea test per tutti i CSV, date, fusi orari, ora legale, JSON del sonno, deduplicazione, conversioni, statistiche aggregate, valori mancanti, misurazioni non plausibili, ZIP malformati, importazioni ripetute, scritture parziali, errori HealthKit e persistenza tra riavvii.

Usa mock HealthKit e fixture sintetiche anonimizzate. Non includere l'archivio sanitario reale nel repository pubblico. Esegui build e test con SDK iOS 27, se disponibile. Non dichiarare eseguiti test che non hai realmente effettuato.

### 13. Estensioni future

Prepara l'architettura per Share Sheet, App Intents, Comandi Rapidi, widget iOS, automazioni locali consentite dal sistema, nuovi formati Even ed eventuali API ufficiali. La sincronizzazione Bluetooth diretta non è un requisito della prima versione.

### 14. Piano di esecuzione

**Fase 1 — Analisi reale:** ispeziona lo ZIP e documenta schema, unità, anomalie, duplicati e compatibilità HealthKit.

**Fase 2 — Architettura:** definisci modelli, servizi, persistenza, pipeline e sicurezza.

**Fase 3 — Implementazione:** crea il progetto Xcode e implementa l'MVP completo.

**Fase 4 — Verifica:** esegui test unitari, di integrazione e build quando possibile.

**Fase 5 — Consegna:** fornisci sorgenti, progetto Xcode, README, istruzioni di installazione, configurazione HealthKit, test e limitazioni residue.

### 15. Criteri di accettazione

Il progetto è completato quando:
- Funziona su iPhone con iOS 27.
- Importa ZIP Even validi e analizza tutti e sette i CSV.
- Riconosce duplicati ed esclude dati ambigui.
- Mostra un'anteprima completa.
- Scrive in HealthKit soltanto dopo consenso.
- Evita duplicati nelle importazioni successive.
- Gestisce errori e interruzioni.
- Funziona offline.
- Offre un'interfaccia nativa e accessibile.
- Include test e documentazione.

### 16. Istruzioni operative finali

**Non produrre soltanto un piano: implementa concretamente l'app.** Lavora autonomamente sulle scelte tecniche ordinarie. Documenta le ambiguità biometriche e adotta il comportamento più conservativo. Non inventare API iOS 27, mapping sanitari o risultati di compilazione. Mantieni il codice pulito, modulare, sicuro ed estendibile.

Priorità: accuratezza sanitaria, privacy, affidabilità, deduplicazione, esperienza nativa iOS 27, manutenibilità e automazione futura.

**Inizia analizzando `Even_health_data_20261108.zip`, poi sviluppa l'intero progetto Even Health Bridge.**


## Regole operative per Codex
- Leggi questo AGENTS.md prima di modificare il progetto.
- Non aggiungere il dataset sanitario reale al controllo versione; inseriscilo in .gitignore.
- Procedi fino a codice, test e documentazione, indicando esplicitamente le verifiche non eseguibili.
