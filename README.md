# Even Health Bridge

App iPhone locale per analizzare gli export ZIP di Even Realities R1 e importare in Apple Salute le fasi del sonno verificate. Richiede iOS 27, Xcode 27 e Swift 6.

## Avvio

1. Apri `EvenHealthBridge.xcodeproj` con Xcode 27.
2. Seleziona un team di firma per il target `EvenHealthBridge` e abilita le capability HealthKit e Data Protection. Il file di entitlements e le descrizioni d'uso sono già presenti.
3. Compila su un iPhone con iOS 27. HealthKit può non essere disponibile nel simulatore.
4. Esporta lo ZIP dall'app Even Realities. Aprilo tramite **Seleziona archivio ZIP** nell'app oppure usa **Apri in Even Health Bridge** da Files o dal menu Condividi, se mostrato dal sistema. Controlla l'anteprima e scegli **Importa il sonno in Apple Salute**. La richiesta di autorizzazione compare solo a quel punto.

L'app registra il tipo ZIP come documento apribile e legge gli URL con security scope e file coordination, anche per i provider Files. Non conserva una copia dell'archivio. Le sessioni e gli identificativi dei campioni salvati restano in SwiftData sul dispositivo, con CloudKit disabilitato esplicitamente e protezione dati iOS completa. Nessun server, account o analytics.

Se lo store locale SwiftData non si apre, l'app mostra un errore e permette di riprovare. Non crea uno store temporaneo vuoto: senza gli identificativi precedenti non potrebbe prevenire con sicurezza le scritture duplicate in Salute.

Il riepilogo iniziale mostra lo stato della scrittura del sonno in Apple Salute, le categorie importate, il numero e il periodo delle fasi registrate, l'ultima sincronizzazione e l'ultima analisi. Il pulsante per aprire un archivio ZIP è in cima alla schermata, raggiungibile anche con testo molto grande; lo stato dei permessi si aggiorna al ritorno nell'app e al termine dell'importazione.

## Dati e limiti

Il parser legge tutti e sette i CSV; i dettagli dello schema sono in [Docs/DatasetAnalysis.md](Docs/DatasetAnalysis.md). Per il sonno convalida che le durate delle fasi corrispondano agli aggregati e all'intervallo della sessione. Codici: 0 veglia, 1 REM, 2 leggero/Core, 3 profondo. Le sessioni sovrapposte sono escluse; solo le fasi validate e senza conflitti sono idonee alla scrittura.

Le sessioni di sonno oltre 24 ore sono scartate come non plausibili. Se due righe della stessa sorgente descrivono fasi diverse per la stessa sessione, l'intera sessione è classificata come conflitto; copie identiche vengono deduplicate. Il lettore ZIP rifiuta archivi oltre 50 MB e limita la dimensione dei CSV decompressi prima di analizzarli.

I CSV sono decompressi e analizzati un file e una riga alla volta, senza conservare tutte le righe come dizionari o tutti i CSV decompressi insieme. Le righe con virgolette CSV malformate vengono scartate e segnalate senza alterare quelle valide. L'analisi si interrompe con un errore se l'archivio supera 100.000 misurazioni normalizzate, per evitare che l'anteprima esaurisca la memoria dell'iPhone. Se un archivio contiene molti record malformati, l'anteprima mostra i primi 100 avvisi e il numero di quelli omessi.

L'anteprima espone per ciascuna categoria misurazioni analizzate, validate, nuove, già importate, duplicate nello ZIP, escluse, conflitti, sorgenti e periodo UTC. Per il sonno ogni fase è una misurazione, quindi il conteggio differisce dal numero di righe `sleep.csv`. Le fasi nuove sono elencate con tipo, orario, durata e sorgente prima del consenso alla scrittura. Nelle Impostazioni puoi scegliere se visualizzare gli orari in UTC o nel fuso dell'iPhone; in entrambi i casi è mostrato l'offset temporale.

Passi, calorie, frequenza cardiaca, HRV, SpO₂ e temperatura sono visibili nell'anteprima ma esclusi dalla scrittura: l'export non fornisce ancora le unità e/o gli intervalli o il significato statistico necessari per un mapping sicuro. In particolare HRV non specifica SDNN, e min/max/avg non sono tre campioni distinti. Un aggiornamento futuro richiederà documentazione attendibile e test dedicati.

La deduplicazione usa ID stabili tra sorgenti e importazioni; confronta anche le componenti `resting` e `active` delle calorie e segnala come conflitto tutte le righe con lo stesso ID ma contenuto discordante. HealthKit riceve anche sync identifier/version. Il piano confronta le sessioni con i campioni locali già scritti: una seconda importazione dello stesso archivio produce zero nuovi campioni; una sessione che si sovrappone a una precedente viene esclusa. Prima di ogni nuova scrittura, l'app cerca l'ID tra i campioni di sonno creati da sé in HealthKit. Se un'interruzione è avvenuta dopo il salvataggio in Salute ma prima della registrazione locale, recupera l'ID senza riscrivere il campione. Se la verifica non riesce o trova dati discordanti, interrompe l'importazione. L'app non legge, elimina o modifica campioni di altre app.

La richiesta di autorizzazione al momento dell'importazione comprende lettura e scrittura del solo tipo sonno. La query usa [la sorgente dell'app](https://developer.apple.com/documentation/healthkit/hksource/default%28%29) per limitarsi ai campioni creati da Even Health Bridge; [Apple documenta](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data) che questi restano visibili all'app anche quando l'accesso in lettura ai dati di altre sorgenti è negato. Ogni campione porta [identificativo e versione di sincronizzazione](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier).

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

La build e il lancio sono stati verificati su un simulatore iOS 27. L'11 novembre 2026, con Xcode 27.2, la build firmata è stata installata e avviata su un iPhone 18 Pro con iOS 27.3. Il progetto configura il percorso di ricerca dei framework incorporati anche sul dispositivo fisico. I 7 test `EvenHealthBridgeAppTests` sono passati sull'iPhone; i 37 test Swift del core sono passati sul Mac, incluso il test facoltativo dell'archivio reale locale. Sul dispositivo sono state osservate la dashboard, la cronologia inizialmente vuota e l'apertura del selettore Files. Il test d'integrazione iOS ha analizzato `SyntheticSleep.zip` tramite il coordinatore, senza scrivere in Salute.

Sul dispositivo fisico `SyntheticSleep.zip` è stato copiato nel contenitore corrente dell'app e aperto con un URL passato da `devicectl`: l'anteprima ha mostrato 1 fase di sonno nuova e 6 avvisi per i CSV assenti. La scelta «Registra solo l'analisi» ha creato una voce in Cronologia con 2 record, 1 duplicato e 0 campioni scritti.

L'11 novembre 2026 è stata inoltre completata una scrittura HealthKit reale su iPhone: il consenso ha abilitato lettura e scrittura del sonno con accesso in lettura limitato agli ultimi 30 giorni e ai dati futuri. L'app ha salvato una sola fase sintetica di sonno leggero, della durata di un minuto, e la Cronologia ha registrato «1 campioni, 1 nuovi in questo tentativo». Il campione è rimasto in Apple Salute come concordato. Aprendo di nuovo lo stesso ZIP sul dispositivo, l'anteprima ha mostrato 1 fase già importata, 0 nuove e 0 conflitti; il pulsante di importazione era disabilitato, senza una seconda scrittura. La selezione manuale dello ZIP nel selettore Files e il menu Condividi su iPhone fisico restano da verificare separatamente.

L'anteprima sintetica è stata controllata nel simulatore in Dark Mode con testo alla dimensione `accessibility-large`: titoli, conteggi, avvisi e pulsanti restano leggibili e raggiungibili scorrendo. L'aspetto e la dimensione del testo del simulatore sono stati poi ripristinati.

I test iOS usano store SwiftData temporanei: verificano che un ID di fase sopravviva alla riapertura, che due analisi dello stesso ZIP producano due voci distinte e che la cronologia del primo schema resti leggibile dopo l'aggiunta del nuovo modello. Un test aggiuntivo passa uno ZIP sintetico al coordinatore iOS e verifica l'analisi ripetuta. Non eseguono una scrittura HealthKit reale.

Nel simulatore iOS 27 è stato aperto `SyntheticSleep.zip` dal selettore Files dell'app: l'anteprima ha mostrato 1 fase nuova, 0 già importate e 6 avvisi per i CSV assenti nella fixture. La registrazione della sola analisi è comparsa in Cronologia con 2 record, 1 duplicato e 0 campioni scritti. Lo stesso ZIP è stato poi aperto tramite il menu Condividi di Files: Even Health Bridge compariva tra le destinazioni e ha mostrato nuovamente l'anteprima con 1 fase nuova, senza scrivere in Salute. Il test iOS copre inoltre l'analisi ripetuta dello ZIP dopo la consegna del suo URL al coordinatore.

Nell'app puoi annullare l'analisi di uno ZIP in corso. Dalle impostazioni puoi cancellare la cronologia delle analisi; gli ID dei campioni HealthKit restano conservati localmente per evitare nuove scritture duplicate.

La schermata **Diagnostica** nelle Impostazioni mostra versione dell'app, versioni di parser e mapping, conteggi locali e stato dell'ultimo tentativo. Non espone valori biometrici e non invia dati.

Ogni nuova analisi registrata e ogni nuovo tentativo di scrittura creano una voce di cronologia, anche se lo ZIP ha lo stesso hash di uno precedente. Quando avvii una scrittura, l'app salva prima una voce con esito da verificare: se si arresta improvvisamente, la voce rimane visibile. Le vecchie voci del primo schema compaiono nella sezione **Cronologia precedente**.

Per un tentativo interrotto, la cronologia distingue cancellazione, permesso negato, indisponibilità di Salute, conflitto e altri errori con messaggi predefiniti, senza registrare dettagli biometrici. Il conteggio indica le fasi confermate nell'archivio locale: eventuali scritture in Salute avvenute immediatamente prima dell'interruzione vengono riconciliate al tentativo successivo.

Se apri un altro ZIP durante l'analisi, l'app attende la cancellazione dell'analisi precedente prima di iniziare la nuova. Durante la scrittura in Salute, un nuovo archivio viene rifiutato per mantenere coerente la cronologia dell'importazione. Nel riepilogo, i campioni già importati sono distinti dai dati esclusi per ambiguità o conflitto.
