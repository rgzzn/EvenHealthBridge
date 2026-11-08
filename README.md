# Even Health Bridge

App iPhone locale per analizzare gli export ZIP di Even Realities R1 e importare in Apple Salute le fasi del sonno verificate. Richiede iOS 27, Xcode 27 e Swift 6.

## Avvio

1. Apri `EvenHealthBridge.xcodeproj` con Xcode 27.
2. Seleziona un team di firma per il target `EvenHealthBridge` e abilita le capability HealthKit e Data Protection. Il file di entitlements e le descrizioni d'uso sono già presenti.
3. Compila su un iPhone con iOS 27. HealthKit può non essere disponibile nel simulatore.
4. Esporta lo ZIP dall'app Even Realities. Aprilo tramite **Seleziona archivio ZIP** nell'app oppure usa **Apri in Even Health Bridge** da Files o dal menu Condividi, se mostrato dal sistema. Controlla l'anteprima e scegli **Importa il sonno in Apple Salute**. La richiesta di autorizzazione compare solo a quel punto.

L'app registra il tipo ZIP come documento apribile e legge gli URL con security scope e file coordination, anche per i provider Files. Non conserva una copia dell'archivio. Le sessioni e gli identificativi dei campioni salvati restano in SwiftData sul dispositivo, con CloudKit disabilitato esplicitamente e protezione dati iOS completa. Nessun server, account o analytics.

## Dati e limiti

Il parser legge tutti e sette i CSV; i dettagli dello schema sono in [Docs/DatasetAnalysis.md](Docs/DatasetAnalysis.md). Per il sonno convalida che le durate delle fasi corrispondano agli aggregati e all'intervallo della sessione. Codici: 0 veglia, 1 REM, 2 leggero/Core, 3 profondo. Le sessioni sovrapposte sono escluse; solo le fasi validate e senza conflitti sono idonee alla scrittura.

Passi, calorie, frequenza cardiaca, HRV, SpO₂ e temperatura sono visibili nell'anteprima ma esclusi dalla scrittura: l'export non fornisce ancora le unità e/o gli intervalli o il significato statistico necessari per un mapping sicuro. In particolare HRV non specifica SDNN, e min/max/avg non sono tre campioni distinti. Un aggiornamento futuro richiederà documentazione attendibile e test dedicati.

La deduplicazione usa ID stabili tra sorgenti e importazioni; HealthKit riceve anche sync identifier/version. Il piano confronta le sessioni con i campioni locali già scritti: una seconda importazione dello stesso archivio produce zero nuovi campioni; una sessione che si sovrappone a una precedente viene esclusa. Un'importazione interrotta registra i campioni già salvati e può riprendere. L'app non legge, elimina o modifica campioni di altre app.

I log diagnostici contengono solo conteggi ed eventi, senza valori biometrici. Le colonne `resting` e `active` delle calorie vengono conservate nell'analisi in memoria, ma non ricevono un mapping HealthKit senza verifica dell'intervallo.

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

La build e il lancio sono stati verificati su un simulatore iOS 27. La scrittura reale in Apple Salute, la firma per dispositivo e i permessi HealthKit vanno verificati su un iPhone fisico con un team di sviluppo configurato.

L'apertura di un documento ZIP è stata provata sul simulatore con `Tests/Fixtures/sleep.csv` inserito in un archivio sintetico; l'anteprima è comparsa. La comparsa dell'app nel menu Condividi e il selettore Files su iPhone fisico restano da verificare.

Nell'app puoi annullare l'analisi di uno ZIP in corso. Dalle impostazioni puoi cancellare la cronologia delle analisi; gli ID dei campioni HealthKit restano conservati localmente per evitare nuove scritture duplicate.

Se apri un altro ZIP durante l'analisi, l'app attende la cancellazione dell'analisi precedente prima di iniziare la nuova. Durante la scrittura in Salute, un nuovo archivio viene rifiutato per mantenere coerente la cronologia dell'importazione. Nel riepilogo, i campioni già importati sono distinti dai dati esclusi per ambiguità o conflitto.
