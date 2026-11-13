# Even Health Bridge

A local iPhone app that analyses Even Realities R1 ZIP exports and imports verified sleep stages into Apple Health. It requires iOS 27, Xcode 27, and Swift 6.

## Getting started

1. Open `EvenHealthBridge.xcodeproj` in Xcode 27.
2. Select a signing team for the `EvenHealthBridge` target and enable the HealthKit and Data Protection capabilities. The entitlements file and usage descriptions are already present.
3. Build to an iPhone running iOS 27. HealthKit may be unavailable in Simulator.
4. Export a ZIP archive from the Even Realities app. Open it from **Select ZIP archive** in the app, or use **Open in Even Health Bridge** from Files or the Share sheet when iOS displays it. Review the preview and choose **Import sleep into Apple Health**. The authorization prompt is shown only at that point.

The app registers the ZIP type as an openable document and reads URLs with security-scoped access and file coordination, including URLs from Files providers. It does not retain an archive copy. Import sessions and saved sample identifiers stay in on-device SwiftData, with CloudKit explicitly disabled and iOS Complete data protection. There is no server, account, or analytics.

If the local SwiftData store cannot be opened, the app displays an error and lets the user retry. It never creates an empty temporary store: without existing identifiers it could not safely prevent duplicate Health writes.

The dashboard shows the Apple Health sleep-write status, imported categories, saved-stage count and date range, the latest sync, and the latest analysis. The ZIP button is at the top of the screen and remains reachable with very large text. Permission status refreshes when the app becomes active and after an import finishes.

## Data and limitations

The parser reads all seven CSV files; schema details are in [Docs/DatasetAnalysis.md](Docs/DatasetAnalysis.md). For sleep it verifies that stage durations agree with session aggregates and the session interval. Stage codes are: 0 awake, 1 REM, 2 core/light, and 3 deep. Overlapping sessions are excluded; only validated, conflict-free stages are eligible for writing.

Sleep sessions longer than 24 hours are rejected as implausible. If two rows from the same source describe different stages for the same session, the whole session is classified as a conflict; identical copies are deduplicated. The ZIP reader rejects archives larger than 50 MB and limits decompressed CSV size before analysis.

CSV files are decompressed and parsed one file and one row at a time. The app does not retain all rows as dictionaries or all decompressed CSV files at once. Rows with malformed CSV quoting are skipped and reported without changing valid rows. Analysis stops with an error above 100,000 normalized measurements, preventing the preview from exhausting iPhone memory. For archives with many malformed records, the preview shows the first 100 warnings and the number omitted.

The preview shows, for each category, analysed, validated, new, previously imported, in-ZIP duplicate, excluded, and conflicting measurements, as well as sources and the UTC range. Each sleep stage is one measurement, so its count differs from the number of `sleep.csv` rows. New sleep stages list their type, time, duration, and source before any write is authorized. In Settings, users can choose UTC or iPhone-local times; the offset is always displayed.

Steps, calories, heart rate, HRV, SpO₂, and temperature appear in the preview but are excluded from writing. The current export does not yet provide the units, intervals, or statistical meaning required for a safe mapping. In particular, Even does not specify whether HRV is SDNN, and min/max/avg are not three independent samples. Enabling another category in the future requires reliable documentation and dedicated testing.

## Apple Watch study

After analysing a ZIP archive, open the **Study** tab and select the comparison start and end dates. **Compare with Apple Watch** requests read-only HealthKit access to steps, active energy, heart rate, HRV, and oxygen saturation at that time. It never requests write access, changes Apple Watch samples, or persists the values it reads; the report exists only in memory while the screen is open.

The report filters HealthKit records whose source name contains “Watch”, measures how many Apple Watch readings occur near Even records, and reports the median absolute difference for heart rate, HRV, and SpO₂. It compares only Even `avg` records for those metrics; `min` and `max` are not samples. For steps and active energy it reports temporal coverage only, because the Even interval duration is not documented. A comparison, even a strong correlation, is research evidence rather than proof that a new category can be imported automatically. HRV remains excluded until Even confirms that its metric is SDNN.

## Duplicate prevention and HealthKit safety

Deduplication uses stable identifiers across sources and imports. It also compares the `resting` and `active` calorie components and classifies matching IDs with conflicting content as conflicts. HealthKit samples include a sync identifier and sync version. The planner compares sessions with locally saved samples: importing the same archive again creates zero new samples, while a session overlapping a prior session is excluded. Before each write, the app searches only for matching sleep samples that it created itself in HealthKit. If an interruption happens after a Health save but before local persistence, it recovers the identifier without writing a duplicate. If verification fails or finds conflicting data, the import stops. The app never reads, deletes, or changes samples from other apps.

At import time, the authorization request includes read and write access only for sleep. The query uses [the app’s HealthKit source](https://developer.apple.com/documentation/healthkit/hksource/default%28%29) so it is limited to samples created by Even Health Bridge; [Apple documents](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data) that an app can still see its own samples when read access to other sources is denied. Each sample has a [sync identifier and version](https://developer.apple.com/documentation/healthkit/hkmetadatakeysyncidentifier).

Diagnostic logs include only counts and events, never biometric values. The `resting` and `active` calorie columns are kept in the in-memory analysis, but receive no HealthKit mapping until their interval is verified.

## Verification

```sh
swift test
xcodebuild -project EvenHealthBridge.xcodeproj -scheme EvenHealthBridge -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project EvenHealthBridge.xcodeproj -scheme EvenHealthBridge -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test -only-testing:EvenHealthBridgeAppTests
```

An optional test can inspect a real archive only on the local computer, without distributing it:

```sh
EVEN_HEALTH_LOCAL_ARCHIVE=/private/path/Even_health_data_20261108.zip swift test --filter optionalLocalRealArchive
```

The real dataset is excluded from Git through `.gitignore`; shared tests use synthetic fixtures only.

The build and launch were verified in an iOS 27 Simulator. On 11 November 2026, with Xcode 27.2, a signed build was installed and launched on an iPhone 18 Pro running iOS 27.3. The project configures the embedded-framework search path for a physical device. Seven `EvenHealthBridgeAppTests` passed on the iPhone; 37 Swift core tests passed on the Mac, including the optional local real-archive test. On the device, the dashboard, initially empty history, and Files picker were observed. The iOS integration test analysed `SyntheticSleep.zip` through the coordinator without writing to Health.

On the physical device, `SyntheticSleep.zip` was copied into the app’s current container and opened from a URL delivered with `devicectl`. The preview showed one new sleep stage and six warnings for missing CSV files. Choosing **Record analysis only** created a History item with two records, one duplicate, and zero written samples.

On 11 November 2026, one real HealthKit write was completed on the iPhone: consent enabled read and write access for sleep, with reading limited to the latest 30 days and future data. The app saved one synthetic core-sleep stage lasting one minute, and History recorded “1 samples, 1 new in this attempt”. The sample remains in Apple Health as agreed. Reopening the same ZIP showed one previously imported stage, zero new stages, and zero conflicts; the import button was disabled, so a second write could not occur. Manual ZIP selection in Files and the Share sheet on the physical iPhone still require separate verification.

The synthetic preview was checked in Simulator Dark Mode with `accessibility-large` text: headings, counts, warnings, and controls remained legible and reachable by scrolling. The Simulator appearance and text size were then restored.

iOS tests use temporary SwiftData stores. They verify that a stage ID survives reopening, that analysing the same ZIP twice creates two distinct attempt records, and that history from the first schema remains readable after adding the newer model. An additional test delivers a synthetic ZIP to the iOS coordinator and verifies repeated analysis. They do not perform a real HealthKit write.

In the iOS 27 Simulator, `SyntheticSleep.zip` was opened from the app’s Files picker. The preview showed one new stage, zero imported stages, and six warnings for missing CSV files. Recording the analysis appeared in History with two records, one duplicate, and zero Health writes. The same ZIP was then opened through the Files Share sheet: Even Health Bridge appeared as a destination and showed the same preview without writing to Health. The iOS test suite also covers repeated ZIP analysis after the coordinator receives its URL.

You can cancel an in-progress ZIP analysis. In Settings, you can clear analysis history; saved HealthKit sample identifiers remain on-device to prevent future duplicate writes.

The **Diagnostics** screen in Settings shows app version, parser and mapping versions, local counts, and the latest attempt status. It never displays biometric values or sends data.

Each recorded analysis and each Health write attempt creates a History entry, including a ZIP whose hash matches an earlier one. Before a write begins, the app saves an attempt with a status awaiting verification; if the app stops unexpectedly, the entry remains visible. Records from the first schema appear in **Previous history**.

For an interrupted attempt, History distinguishes cancellation, denied permission, unavailable Health, conflicts, and other errors using predefined messages without biometric details. The count reflects stages confirmed in local storage; Health saves made immediately before an interruption are reconciled at the next attempt.

If another ZIP is opened during analysis, the app waits for the earlier analysis to cancel before beginning the new one. While Health is being written, a new archive is rejected to keep import history consistent. In the summary, previously imported samples are distinct from data excluded due to ambiguity or conflict.
