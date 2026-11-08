# Analisi dell'export locale (8 novembre 2026)

Analisi strutturale di `Even_health_data_20261108.zip`. L'archivio contiene dati sanitari reali e resta escluso da Git. Questo documento riporta solo schemi e statistiche aggregate.

| CSV | Righe | Campi | Osservazioni |
| --- | ---: | --- | --- |
| steps | 674 | timestamp, value, source | 337 istanti, due sorgenti per istante; valori 0–548, 290 zeri |
| calories | 674 | timestamp, value, resting, active, source | 337 istanti; resting/active presenti nelle 337 righe R1, assenti in ring1Notify; value 0–64 |
| heart_rate | 594 | timestamp, value, source, ty | 99 istanti × min/max/avg × due sorgenti; 48–139 |
| hrv | 624 | timestamp, value, source, ty | 104 istanti × min/max/avg × due sorgenti; 23–96, metrica non dichiarata |
| blood_oxygen | 552 | timestamp, value, source, ty | 92 istanti × min/max/avg × due sorgenti; 89–99 |
| sleep | 14 | timestamp, start_ts, end_ts, total_time, wake_time, rem_time, light_time, deep_time, stages, source, tz, body_temp_delta | 7 sessioni × due sorgenti; codici stage 0/1/2/3, significato non documentato; body_temp_delta presente solo in metà righe, sempre zero |
| skin_temperature | 11 | timestamp, value, source | 4 R1 e 7 ring1Notify; valore 0–35, unità e significato non dichiarati |

I timestamp sono stringhe ISO 8601 con offset. `steps` non dichiara la durata dell'aggregato: non si può costruire un intervallo HealthKit affidabile. Le serie `min/max/avg` non dichiarano né finestra statistica né istante dei singoli campioni: non vanno trasformate in tre campioni HealthKit. HRV non specifica SDNN o RMSSD. Calorie `resting` e `active` richiedono conferma della definizione e della finestra; `value` non va interpretato come un terzo tipo di energia. La temperatura può essere assoluta o differenziale e gli zeri possono essere sentinelle.

Verifica interna del sonno: per ognuna delle 7 sessioni R1 la somma `half_minutes × 30` di ciascun codice coincide esattamente con l'aggregato omonimo: 0 = veglia, 1 = REM, 2 = leggero, 3 = profondo. La somma di tutte le fasi coincide esattamente con `end_ts - start_ts`; `total_time` esclude la veglia. Questo supporta il mapping delle fasi, purché le medesime uguaglianze siano verificate a ogni importazione e non vi siano fasi sovrapposte o codici ignoti.

Tre coppie di sessioni R1 si sovrappongono nel tempo; solo una sessione non si sovrappone ad altre. Le coppie sovrapposte sono classificate come conflitti e non vengono scritte automaticamente. Nel dataset locale risultano 25 fasi idonee, 25 copie tra sorgenti e 304 record di fase in conflitto.

Il parser confronta anche l'intera sequenza di fasi tra `R1` e `ring1Notify` per la stessa sessione. Se le due sorgenti concordano sugli aggregati ma differiscono nella suddivisione delle fasi, l'intera sessione viene classificata come conflitto.

Decisione: tutte le sette categorie sono analizzabili e visualizzabili; il sonno può essere proposto per la scrittura solo dopo validazione puntuale delle durate e consenso. Le altre categorie restano escluse fino alla conferma di unità, semantica e intervalli.

Le [istruzioni ufficiali Even per HRV](https://support.evenrealities.com/hc/en-us/articles/17450890638863-Health-HRV) descrivono la metrica in termini generali e la sincronizzazione oraria, senza specificare SDNN o RMSSD: HRV resta esclusa. La [documentazione ufficiale sulla temperatura](https://support.evenrealities.com/hc/en-us/articles/15317531195023-R1-cannot-detect-body-temperature) la descrive come deviazione durante il sonno rispetto a una baseline, quindi `skin_temperature.value` non può essere trattato come temperatura corporea assoluta. Le pagine ufficiali per [passi](https://support.evenrealities.com/hc/en-us/articles/17450483973391-Health-Steps), [frequenza cardiaca](https://support.evenrealities.com/hc/en-us/articles/17450824705423-Health-Heart-rate) e [calorie attive](https://support.evenrealities.com/hc/en-us/articles/17450671491215-Health-Active-calories) indicano la frequenza di sincronizzazione, non la durata dei campioni nel CSV.
