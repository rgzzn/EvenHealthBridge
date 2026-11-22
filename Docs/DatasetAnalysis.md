# Analysis of local exports (8 and 13 November 2026)

Structural analysis of `Even_health_data_20261108.zip`, checked against
`Even_health_data_20261113.zip`. The archives contain real health data and
remain excluded from Git. This document reports schemas and aggregate statistics
only; it does not contain biometric values.

| CSV | Rows, 8 Nov | Rows, 13 Nov | Fields | Notes |
| --- | ---: | ---: | --- | --- |
| steps | 674 | 1,446 | timestamp, value, source | Two sources at each instant: R1 and ring1Notify; aggregate interval not declared |
| calories | 674 | 1,446 | timestamp, value, resting, active, source | R1 and ring1Notify; resting/active are absent from some rows; time window not declared |
| heart_rate | 594 | 1,188 | timestamp, value, source, ty | R1 and ring1Notify; min/max/avg groups with no declared statistical window |
| hrv | 624 | 1,236 | timestamp, value, source, ty | R1 and ring1Notify; min/max/avg groups; metric not declared |
| blood_oxygen | 552 | 1,122 | timestamp, value, source, ty | R1 and ring1Notify; min/max/avg groups; sampling method not declared |
| sleep | 14 | 29 | timestamp, start_ts, end_ts, total_time, wake_time, rem_time, light_time, deep_time, stages, source, tz, body_temp_delta | Stage codes 0/1/2/3 and complete intervals; one additional row in the second export |
| skin_temperature | 11 | 23 | timestamp, value, source | R1 and ring1Notify; unit and meaning not declared |

Timestamps are ISO 8601 strings with offsets. The second export retained the same headers, sources, and statistical categories. That schema stability does not prove the missing measurement semantics. `steps` does not declare aggregate duration, so the app cannot construct a reliable HealthKit interval. The `min`/`max`/`avg` series do not declare a statistical window or individual sample times, so the app must not turn them into three HealthKit samples. HRV does not identify SDNN or RMSSD. Calorie `resting` and `active` components need confirmed definitions and a time window; `value` is not interpreted as a third energy type. Temperature may be absolute or differential, and zero values may be sentinels.

## Sleep validation

For each of the seven R1 sessions, the sum of `half_minutes × 30` for each stage code exactly matches its corresponding aggregate: 0 = awake, 1 = REM, 2 = core/light, and 3 = deep. The sum of every stage exactly matches `end_ts - start_ts`; `total_time` excludes awake time. This supports the stage mapping only when the same checks pass on every import and no stages overlap or use unknown codes.

Three pairs of R1 sessions overlap in time; only one session does not overlap another. Overlapping pairs are classified as conflicts and are not written automatically. The local dataset contained 25 eligible stages, 25 cross-source copies, and 304 conflicting stage records.

The parser also compares the complete stage sequence between R1 and `ring1Notify` for the same session. If the sources agree on aggregates but differ in stage breakdown, the complete session is classified as a conflict.

## Import decision

All seven categories can be analysed and previewed. Sleep may be offered for writing only after per-import duration validation and user consent.

The parser now has a fail-closed writer contract for future `steps` and active
energy rows: it accepts a step row only with an explicit `start_ts`, `end_ts`,
`value_semantics=delta`, a declared count unit, and an integral positive value.
It accepts active energy only with those same interval and delta declarations,
a kilocalorie unit, and an explicitly named `active` component. The contract
never derives active energy from the total or resting component.

Neither real archive currently supplies those declarations. In the 13 November
archive, the 723 R1 step rows and their 723 `ring1Notify` counterparts have the
same timestamp and numerically equivalent values after normalization, but the
values are not monotonic within any observed day. For calories, every R1 total
equals `resting + active` while the `ring1Notify` value equals the R1 active
component. The app recognizes those representations as duplicate sources; it
does not interpret their reporting cadence as an interval. Therefore the
current archive still exposes zero writable step and calorie records and does
not request their HealthKit authorization.

## Observed timestamp cadence (research only)

This analysis uses timestamp differences only, grouped by source and statistical
label. It does not inspect or report biometric values. It helps describe the
export shape, but is **not** evidence of a HealthKit sample interval or a
value's meaning.

- `steps.csv` and `calories.csv`: R1 and `ring1Notify` report at the same
  unique timestamps. A 600-second gap is dominant (298 of 336 consecutive gaps
  in the 8 November export, and 654 of 722 in the 13 November export), with
  1,200-second, 1,800-second, and longer gaps also present.
- `heart_rate.csv`, `hrv.csv`, and `blood_oxygen.csv`: each source has `min`,
  `max`, and `avg` rows at shared timestamps. A 3,600-second gap is dominant
  for every label in both exports, but two-hour and longer gaps occur.
- `skin_temperature.csv`: the sources have no shared stable cadence. R1 is
  mostly separated by one or two days, while `ring1Notify` has irregular short
  and near-daily gaps.

Regular reporting cadence may be a sync schedule, a bucket boundary, or the
time at which an aggregate is emitted. Missing timestamps also make it unsafe
to infer a measurement's start or end. The app therefore does not turn the
observed 10-minute or hourly gaps into HealthKit intervals, and never treats an
absent timestamp as a gap it may fill.

Even's official [HRV guidance](https://support.evenrealities.com/hc/en-us/articles/17450890638863-Health-HRV) describes the metric generally and its hourly synchronisation, but does not say whether it is SDNN or RMSSD; HRV remains excluded. Its [temperature documentation](https://support.evenrealities.com/hc/en-us/articles/15317531195023-R1-cannot-detect-body-temperature) and [temperature-variation guidance](https://support.evenrealities.com/hc/en-us/articles/17450686313871-Health-Temperature-variation) define a sleep-time deviation from a personal baseline, not an absolute body or basal temperature. Therefore `skin_temperature.value` cannot be mapped to a writable HealthKit temperature type. The official pages for [steps](https://support.evenrealities.com/hc/en-us/articles/17450483973391-Health-Steps), [heart rate](https://support.evenrealities.com/hc/en-us/articles/17450824705423-Health-Heart-rate), [active calories](https://support.evenrealities.com/hc/en-us/articles/17450671491215-Health-Active-calories), and [SpO2](https://support.evenrealities.com/hc/en-us/articles/17451336978063-Health-SpO2) confirm the categories shown to the user, but do not define the unit, statistical window, or per-row interval in the CSV. Synchronisation frequency is not sample duration and does not unlock a HealthKit mapping.
