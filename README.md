# Even Health Bridge

App iPhone locale per analizzare gli export ZIP di Even Realities R1 e importare in Apple Salute le fasi del sonno verificate. Richiede iOS 27, Xcode 27 e Swift 6.

## Avvio

1. Apri `EvenHealthBridge.xcodeproj` con Xcode 27.
2. Seleziona un team di firma per il target `EvenHealthBridge` e abilita le capability HealthKit e Data Protection. Il file di entitlements e le descrizioni d'uso sono già presenti.
3. Compila su un iPhone con iOS 27. HealthKit può non essere disponibile nel simulatore.
4. Esporta lo ZIP dall'app Even Realities. Aprilo tramite **Seleziona archivio ZIP** nell'app oppure usa **Apri in Even Health Bridge** da Files o dal menu Condividi, se mostrato dal sistema. Controlla l'anteprima e scegli **Importa il sonno in Apple Salute**. La richiesta di autorizzazione compare solo a quel punto.

L'app registra il tipo ZIP come documento apribile e legge gli URL con security scope e file coordination, anche per i provider Files. Non conserva una copia dell'archivio. Le sessioni e gli identificativi dei campioni salvati restano in SwiftData sul dispositivo, con CloudKit disabilitato esplicitamente e protezione dati iOS completa. Nessun server, account o analytics.

Il riepilogo iniziale mostra lo stato della scrittura del sonno in Apple Salute, le categorie importate, il numero e il periodo delle fasi registrate, l'ultima sincronizzazione e l'ultima analisi. Il pulsante per aprire un archivio ZIP è nello stesso riepilogo; lo stato dei permessi si aggiorna al ritorno nell'app e al termine dell'importazione.

## Dati e limiti

Il parser legge tutti e sette i CSV; i dettagli dello schema sono in [Docs/DatasetAnalysis.md](Docs/DatasetAnalysis.md). Per il sonno convalida che le durate delle fasi corrispondano agli aggregati e all'intervallo della sessione. Codici: 0 veglia, 1 REM, 2 leggero/Core, 3 profondo. Le sessioni sovrapposte sono escluse; solo le fasi validate e senza conflitti sono idonee alla scrittura.

Le sessioni di sonno oltre 24 ore sono scartate come non plausibili. Se due righe della stessa sorgente descrivono fasi diverse per la stessa sessione, l'intera sessione è classificata come conflitto; copie identiche vengono deduplicate. Il lettore ZIP rifiuta archivi oltre 50 MB e limita la dimensione dei CSV decompressi prima di analizzarli.

L'anteprima espone per ciascuna categoria misurazioni analizzate, validate, nuove, già importate, duplicate nello ZIP, escluse, conflitti, sorgenti e periodo UTC. Per il sonno ogni fase è una misurazione, quindi il conteggio differisce dal numero di righe `sleep.csv`. Le fasi nuove sono elencate con tipo, orario UTC, durata e sorgente prima del consenso alla scrittura.

Passi, calorie, frequenza cardiaca, HRV, SpO₂ e temperatura sono visibili nell'anteprima ma esclusi dalla scrittura: l'export non fornisce ancora le unità e/o gli intervalli o il significato statistico necessari per un mapping sicuro. In particolare HRV non specifica SDNN, e min/max/avg non sono tre campioni distinti. Un aggiornamento futuro richiederà documentazione attendibile e test dedicati.

La deduplicazione usa ID stabili tra sorgenti e importazioni; confronta anche le componenti `resting` e `active` delle calorie e segnala come conflitto tutte le righe con lo stesso ID ma contenuto discordante. HealthKit riceve anche sync identifier/version. Il piano confronta le sessioni con i campioni locali già scritti: una seconda importazione dello stesso archivio produce zero nuovi campioni; una sessione che si sovrappone a una precedente viene esclusa. Prima di ogni nuova scrittura, l'app cerca l'ID tra i campioni di sonno creati da sé in HealthKit. Se un'interruzione è avvenuta dopo il salvataggio in Salute ma prima della registrazione locale, recupera l'ID senza riscrivere il campione. Se la verifica non riesce o trova dati discordanti, interrompe l'importazione. L'app non legge, elimina o modifica campioni di altre app.

La richiesta di autorizzazione al momento dell'importazione comprende lettura e scrittura del solo tipo sonno. La query è limitata ai campioni creati da Even Health Bridge; [Apple documenta](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data) che questi restano visibili all'app anche quando l'accesso in lettura ai dati di altre sorgenti è negato.

I log diagnostici contengono solo conteggi ed eventi, senza valori biometrici. Le colonne `resting` e `active` delle calorie vengono conservate nell'analisi in memoria, ma non ricevono un mapping HealthKit senza verifica dell'intervallo.

## Verifiche

```sh
swift test
xcodebuild -project EvenHealthBridge.xcodeproj -scheme EvenHealthBridge -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project EvenHealthBridge.xcodeproj -scheme EvenHealthBridge -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test -only-testing:EvenHealthBridgeAppTests
```

Un test facoltativo esamina l'archivio reale solo sul computer locale, senza distribuirlo:

```sh
EVEN_HEALTH_LOCAL_ARCHIVE=/percorso/privato/Even_health_data_20261108.zip swift test --filter optionalLocalRealArchive
```

Il dataset reale è escluso da Git tramite `.gitignore`; per i test condivisi usare solo fixture sintetiche.

La build e il lancio sono stati verificati su un simulatore iOS 27. La scrittura reale in Apple Salute, la firma per dispositivo e i permessi HealthKit vanno verificati su un iPhone fisico con un team di sviluppo configurato.

I test iOS usano store SwiftData temporanei: verificano che un ID di fase sopravviva alla riapertura, che due analisi dello stesso ZIP producano due voci distinte e che la cronologia del primo schema resti leggibile dopo l'aggiunta del nuovo modello. Non eseguono una scrittura HealthKit reale.

L'apertura di un documento ZIP è stata provata sul simulatore con `Tests/Fixtures/sleep.csv` inserito in un archivio sintetico; l'anteprima è comparsa. La comparsa dell'app nel menu Condividi e il selettore Files su iPhone fisico restano da verificare.

Nell'app puoi annullare l'analisi di uno ZIP in corso. Dalle impostazioni puoi cancellare la cronologia delle analisi; gli ID dei campioni HealthKit restano conservati localmente per evitare nuove scritture duplicate.

Ogni nuova analisi registrata e ogni nuovo tentativo di scrittura creano una voce di cronologia, anche se lo ZIP ha lo stesso hash di uno precedente. Quando avvii una scrittura, l'app salva prima una voce con esito da verificare: se si arresta improvvisamente, la voce rimane visibile. Le vecchie voci del primo schema compaiono nella sezione **Cronologia precedente**.

Se apri un altro ZIP durante l'analisi, l'app attende la cancellazione dell'analisi precedente prima di iniziare la nuova. Durante la scrittura in Salute, un nuovo archivio viene rifiutato per mantenere coerente la cronologia dell'importazione. Nel riepilogo, i campioni già importati sono distinti dai dati esclusi per ambiguità o conflitto.
