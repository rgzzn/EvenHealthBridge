# Even Health Bridge

App iPhone locale per analizzare gli export ZIP di Even Realities R1 e importare in Apple Salute le fasi del sonno verificate. Richiede iOS 27, Xcode 27 e Swift 6.

## Avvio

1. Apri `EvenHealthBridge.xcodeproj` con Xcode 27.
2. Seleziona un team di firma per il target `EvenHealthBridge` e abilita la capability HealthKit. Il file di entitlements e le descrizioni d'uso sono già presenti.
3. Compila su un iPhone con iOS 27. HealthKit può non essere disponibile nel simulatore.
4. Esporta lo ZIP dall'app Even Realities, tocca **Seleziona archivio ZIP**, controlla l'anteprima e scegli **Importa il sonno in Apple Salute**. La richiesta di autorizzazione compare solo a quel punto.

L'app legge lo ZIP tramite Files e security scoped URL. Non conserva una copia dell'archivio. Le sessioni e gli identificativi dei campioni salvati restano in SwiftData sul dispositivo. Nessun server, account o analytics.

## Dati e limiti

Il parser legge tutti e sette i CSV; i dettagli dello schema sono in [Docs/DatasetAnalysis.md](Docs/DatasetAnalysis.md). Per il sonno convalida che le durate delle fasi corrispondano agli aggregati e all'intervallo della sessione. Codici: 0 veglia, 1 REM, 2 leggero/Core, 3 profondo. Le sessioni sovrapposte sono escluse; solo le fasi validate e senza conflitti sono idonee alla scrittura.

Passi, calorie, frequenza cardiaca, HRV, SpO₂ e temperatura sono visibili nell'anteprima ma esclusi dalla scrittura: l'export non fornisce ancora le unità e/o gli intervalli o il significato statistico necessari per un mapping sicuro. In particolare HRV non specifica SDNN, e min/max/avg non sono tre campioni distinti. Un aggiornamento futuro richiederà documentazione attendibile e test dedicati.

La deduplicazione usa ID stabili tra sorgenti e importazioni; HealthKit riceve anche sync identifier/version. Una seconda importazione dello stesso archivio non deve creare nuovi campioni. L'app non legge, elimina o modifica campioni di altre app.

## Verifiche

```sh
swift test
xcodebuild -project EvenHealthBridge.xcodeproj -scheme EvenHealthBridge -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO build
```

Un test facoltativo esamina l'archivio reale solo sul computer locale, senza distribuirlo:

```sh
EVEN_HEALTH_LOCAL_ARCHIVE=/percorso/privato/Even_health_data_20261108.zip swift test --filter optionalLocalRealArchive
```

Il dataset reale è escluso da Git tramite `.gitignore`; per i test condivisi usare solo fixture sintetiche.
