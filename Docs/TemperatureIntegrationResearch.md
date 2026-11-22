# Temperature variation: integration research

## Decision

Even Health Bridge does **not** import `skin_temperature.csv` into Apple Health. This is an intentional, stable safety decision rather than an unfinished mapping.

The local study can compare the *temporal presence* of Even nightly temperature-variation records with Apple Watch sleeping-wrist-temperature records. It does not compare values, retain Apple readings, or write any HealthKit sample.

## Evidence from the export

The real 13 November 2026 archive contains `Even_health_data/skin_temperature.csv` with exactly three fields: `timestamp`, `value`, and `source`; it has 23 data rows. There is no unit, baseline definition, start/end interval, or measurement location column. The raw archive remains outside source control.

The earlier and later local export analyses also show irregular cadence across `R1` and `ring1Notify`, so timestamp gaps cannot safely be converted into nightly sample intervals. See [DatasetAnalysis.md](DatasetAnalysis.md).

## Vendor and platform semantics

- [Even: Temperature variation](https://support.evenrealities.com/hc/en-us/articles/17450686313871-Health-Temperature-variation) says R1 reports nightly shifts relative to a personal baseline, and explicitly says it does not measure absolute temperature.
- [Even: R1 cannot detect body temperature](https://support.evenrealities.com/hc/en-us/articles/15317531195023-R1-cannot-detect-body-temperature) confirms the baseline is established from sleep data and the feature is sleep-only.
- Apple defines [`bodyTemperature`](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/bodytemperature) as a discrete **absolute body-temperature** reading, so it is not an appropriate target.
- Apple defines [`basalBodyTemperature`](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/basalbodytemperature) as temperature at rest, such as immediately after waking. A nightly finger-temperature deviation is not that measurement.
- Apple’s [`appleSleepingWristTemperature`](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature) is an absolute overnight wrist temperature. Apple documents that it is **read-only**: an app may ask to read it but cannot ask to share or save it.

These facts rule out all current HealthKit temperature writers. Writing an Even baseline deviation as a body, basal, or wrist temperature would fabricate a meaning the data does not have.

## Implemented local research workflow

1. The existing parser continues to retain the Even timestamp, source, raw value, and the absence of unit or interval evidence; it does not mark the records as HealthKit-eligible.
2. In **Study**, **Nightly temperature variation** appears when the selected archive window contains temperature rows.
3. Selecting it requests HealthKit **read** access only to `appleSleepingWristTemperature` and only for the chosen study interval.
4. The adapter deliberately does not read the Apple temperature quantity. It keeps only timestamp presence in memory and pairs records at most once inside a twelve-hour research window.
5. The report exposes counts and temporal coverage, never a numeric difference. It is not stored and cannot enable an import.

The twelve-hour matching window is a research tolerance for the differing timestamp conventions of an overnight summary. It is not a measurement interval, a claim of physiological equivalence, or a permission to fill a gap.

## What would be required to revisit imports

Even would need to document an absolute, calibrated temperature with a unit, body or sensor location, exact nightly interval, and its relationship to the personal baseline. In addition, there must be a writable public HealthKit type with matching semantics. The current Apple sleeping-wrist type can never be the write target because Apple marks it read-only. A future proposal would require new fixtures, parser validation, overlap planning, consent UI, idempotency and recovery tests, and a physical-iPhone write/replay test before a write gate could change.
