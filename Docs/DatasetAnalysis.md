# Analisi degli export locali (8 e 13 novembre 2026)

Analisi strutturale di `Even_health_data_20261108.zip`, verificata contro `Even_health_data_20261113.zip`. Gli archivi contengono dati sanitari reali e restano esclusi da Git. Questo documento riporta solo schemi e statistiche aggregate.

| CSV | Righe 8 nov | Righe 13 nov | Campi | Osservazioni |
| --- | ---: | ---: | --- | --- |
| steps | 674 | 1446 | timestamp, value, source | Due sorgenti per istante: R1 e ring1Notify; intervallo dell'aggregato non dichiarato |
| calories | 674 | 1446 | timestamp, value, resting, active, source | R1 e ring1Notify; resting/active non sono presenti in tutte le righe; finestra temporale non dichiarata |
| heart_rate | 594 | 1188 | timestamp, value, source, ty | R1 e ring1Notify; gruppi min/max/avg, senza finestra statistica dichiarata |
| hrv | 624 | 1236 | timestamp, value, source, ty | R1 e ring1Notify; gruppi min/max/avg, metrica non dichiarata |
| blood_oxygen | 552 | 1122 | timestamp, value, source, ty | R1 e ring1Notify; gruppi min/max/avg, metodo di campionamento non dichiarato |
| sleep | 14 | 29 | timestamp, start_ts, end_ts, total_time, wake_time, rem_time, light_time, deep_time, stages, source, tz, body_temp_delta | Codici stage 0/1/2/3 e intervalli completi; un record aggiuntivo nel secondo export |
| skin_temperature | 11 | 23 | timestamp, value, source | R1 e ring1Notify; unità e significato non dichiarati |

I timestamp sono stringhe ISO 8601 con offset. Il secondo export ha mantenuto esattamente le stesse intestazioni, le due sorgenti e le categorie statistiche; questa stabilità di schema non dimostra tuttavia le semantiche mancanti. `steps` non dichiara la durata dell'aggregato: non si può costruire un intervallo HealthKit affidabile. Le serie `min/max/avg` non dichiarano né finestra statistica né istante dei singoli campioni: non vanno trasformate in tre campioni HealthKit. HRV non specifica SDNN o RMSSD. Calorie `resting` e `active` richiedono conferma della definizione e della finestra; `value` non va interpretato come un terzo tipo di energia. La temperatura può essere assoluta o differenziale e gli zeri possono essere sentinelle.

Verifica interna del sonno: per ognuna delle 7 sessioni R1 la somma `half_minutes × 30` di ciascun codice coincide esattamente con l'aggregato omonimo: 0 = veglia, 1 = REM, 2 = leggero, 3 = profondo. La somma di tutte le fasi coincide esattamente con `end_ts - start_ts`; `total_time` esclude la veglia. Questo supporta il mapping delle fasi, purché le medesime uguaglianze siano verificate a ogni importazione e non vi siano fasi sovrapposte o codici ignoti.

Tre coppie di sessioni R1 si sovrappongono nel tempo; solo una sessione non si sovrappone ad altre. Le coppie sovrapposte sono classificate come conflitti e non vengono scritte automaticamente. Nel dataset locale risultano 25 fasi idonee, 25 copie tra sorgenti e 304 record di fase in conflitto.

Il parser confronta anche l'intera sequenza di fasi tra `R1` e `ring1Notify` per la stessa sessione. Se le due sorgenti concordano sugli aggregati ma differiscono nella suddivisione delle fasi, l'intera sessione viene classificata come conflitto.

Decisione: tutte le sette categorie sono analizzabili e visualizzabili; il sonno può essere proposto per la scrittura solo dopo validazione puntuale delle durate e consenso. Le altre categorie restano escluse fino alla conferma di unità, semantica e intervalli.

Le [istruzioni ufficiali Even per HRV](https://support.evenrealities.com/hc/en-us/articles/17450890638863-Health-HRV) descrivono la metrica in termini generali e la sincronizzazione oraria, senza specificare SDNN o RMSSD: HRV resta esclusa. La [documentazione ufficiale sulla temperatura](https://support.evenrealities.com/hc/en-us/articles/15317531195023-R1-cannot-detect-body-temperature) la descrive come deviazione durante il sonno rispetto a una baseline, quindi `skin_temperature.value` non può essere trattato come temperatura corporea assoluta. Le pagine ufficiali per [passi](https://support.evenrealities.com/hc/en-us/articles/17450483973391-Health-Steps), [frequenza cardiaca](https://support.evenrealities.com/hc/en-us/articles/17450824705423-Health-Heart-rate) e [calorie attive](https://support.evenrealities.com/hc/en-us/articles/17450671491215-Health-Active-calories) indicano la frequenza di sincronizzazione, non la durata dei campioni nel CSV.
