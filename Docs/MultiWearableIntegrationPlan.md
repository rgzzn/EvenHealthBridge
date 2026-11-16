# Multi-Wearable Overlay Integration Plan

## Goal

Import a future, semantically validated Even metric into Apple Health without altering Apple Watch or third-party samples, duplicating overlapping coverage, or fabricating partial biometric values.

Even Health Bridge remains fully local. It does not upload Health data, retain a permanent copy of an export, or infer medical semantics from numerical correlation.

## Current baseline

- All seven Even CSV categories are parsed and previewed.
- Only validated sleep stages can be written today.
- Apple Watch comparison is read-only and source-scoped using the HealthKit source revision product type, with a narrow historical fallback for samples without a product type. The Study tab can also discover other sources found in the selected window, show only their metric-type and sample-count availability, and let the user select one for a local comparison. A discovered source uses its exact product type when available, so a similarly named device cannot be included accidentally.
- The comparison engine is source-neutral, and the HealthKit reader accepts a `ReferenceSourceDefinition`. For each study, the user chooses from metric types represented in the selected Even archive window; the comparison requests read access only to those selected types. A source selected through local discovery uses its exact product type and exact historical name fallback; a future wearable must provide a documented source product type or an intentionally narrow historical marker.
- Reference samples preserve their actual end date when HealthKit provides one.
- `ConservativeOverlayPlanner` accepts a complete interval only when it is eligible and has no overlap with existing coverage. It never splits, interpolates, or redistributes a value across a partially uncovered interval.

## Non-negotiable safety rules

1. Never modify or delete a sample written by Apple Watch or another app.
2. Do not treat a timestamp as an interval. A numeric HealthKit sample needs a valid start, end, and compatible unit. [Apple documentation](https://developer.apple.com/documentation/healthkit/hkquantitysample/init%28type%3Aquantity%3Astart%3Aend%3Ametadata%3A)
3. Do not transform `min`, `max`, and `avg` into independent samples unless Even documents their statistical window and meaning.
4. Do not fill a partial gap by scaling or splitting an aggregate value.
5. Keep a category blocked when its unit, metric identity, or interval is unverified, even if the Apple Watch comparison is strong.
6. Require an explicit preview and HealthKit permission for every newly enabled category.

## Evidence gates by category

| Category | HealthKit target after validation | Missing evidence | Status |
| --- | --- | --- | --- |
| Sleep stages | `sleepAnalysis` | Stage consistency and non-overlap are checked per archive | Enabled conservatively |
| Steps | `stepCount` | Delta versus cumulative semantics and represented interval | Blocked |
| Active energy | `activeEnergyBurned` | Active component definition, unit, and measurement window | Blocked |
| Resting energy | `basalEnergyBurned` | Physiological meaning and measurement window | Blocked |
| Heart rate | `heartRate` | Unit and aggregation window behind `avg` | Blocked |
| HRV | `heartRateVariabilitySDNN` | Confirmation that Even reports SDNN, not another HRV metric | Blocked |
| Oxygen saturation | `oxygenSaturation` | Unit, aggregation method, and interval | Blocked |
| Temperature | No target selected | Export meaning compatible with a HealthKit type; R1 support describes a sleep temperature deviation from baseline, not body temperature | Blocked |

## Current vendor evidence review

The current Even support pages describe steps as a daily total, heart rate in beats per minute, active calories as excluding resting metabolic burn, and SpO₂ as oxygen-related blood data. They also state continuous collection and periodic synchronization. This confirms the user-facing categories, but it does **not** specify what one exported CSV row represents, its canonical unit, the `min`/`max`/`avg` statistical window, or the start and end of that row’s measurement interval. Therefore it does not change any write gate.

Rechecked on 2026-11-15: the export article confirms only that the downloaded archive contains CSV files. The dashboard article describes heart rate and blood oxygen as showing a most recent value and an average, but still does not define the statistical window or the representation of an exported row. Neither source unblocks a HealthKit write.

- [Export health data](https://support.evenrealities.com/hc/en-us/articles/17995748835599-Export-Your-Health-Data)
- [Dashboard](https://support.evenrealities.com/hc/en-us/articles/14269247458319-Dashboard)
- [Steps](https://support.evenrealities.com/hc/en-us/articles/17450483973391-Health-Steps)
- [Heart rate](https://support.evenrealities.com/hc/en-us/articles/17450824705423-Health-Heart-rate)
- [Active calories](https://support.evenrealities.com/hc/en-us/articles/17450671491215-Health-Active-calories)
- [SpO₂](https://support.evenrealities.com/hc/en-us/articles/17451336978063-Health-SpO2)
- [HRV](https://support.evenrealities.com/hc/en-us/articles/17450890638863-Health-HRV)
- [Sleep temperature deviation](https://support.evenrealities.com/hc/en-us/articles/15317531195023-R1-cannot-detect-body-temperature)

## Implementation sequence for one newly documented category

1. **Evidence capture** — archive the vendor documentation link, expected unit, interval semantics, aggregation behavior, and a synthetic anonymized fixture. Update `Docs/DatasetAnalysis.md` without committing real exports.
2. **Contract** — add a category-specific mapping contract, range validation, unit conversion, interval validation, and deterministic sample identifier. Change `HealthImportReadiness` only in the same change set.
3. **Coverage plan** — query only the selected reference source in the requested time range. Pass its actual intervals to `ConservativeOverlayPlanner`; a record with any overlap remains excluded.
4. **Preview** — show eligible, already-covered, missing-interval, malformed, duplicate, and conflict counts before authorization. Explain that a comparison does not prove clinical equivalence.
5. **Writer** — create only app-owned HealthKit samples with sync metadata, record local reconciliation state in SwiftData, and provide cancellation recovery. Never use an Apple Watch sample as a write target.
6. **Verification** — add parser, mapping, overlap-boundary, idempotency, partial-write recovery, and physical-iPhone tests. Validate an initial write and replay separately.

## Acceptance criteria for a future metric

The metric is ready for a release only when all of the following are true:

- The vendor defines the exact metric, canonical unit, time representation, and aggregation behavior.
- The parser rejects malformed, implausible, duplicate, and conflicting records.
- The app can build a complete non-invented interval for every candidate sample.
- Overlay planning excludes every overlap and treats touching half-open intervals correctly.
- Replaying the same archive writes zero new app-owned samples.
- A physical iPhone test verifies permission handling, write behavior, local reconciliation, and repeat import.
- The UI and README describe the limitation in English and Italian where user-facing.

## What would unblock the next category

A vendor statement or export field that specifies one complete mapping, for example: “heart-rate `avg` is beats per minute for the preceding N-minute interval” or “steps `value` is the count during `start_ts`–`end_ts`.” A numeric match with Apple Watch alone is not enough.
