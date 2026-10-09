# Plan: "Readiness" iOS app for a Bluetooth LE heart-rate armband

## Context

The Mac tool (`hrmon`) proved that the band is a standard Bluetooth LE Heart Rate Profile sensor that sends
RR intervals, and it already implements the full pipeline: artefact filtering, time- and frequency-domain HRV,
a personal baseline, and a readiness / illness verdict (`hrmon/hrv.py`, `hrmon/readiness.py`).

The goal now is to move the daily use to the iPhone, where the morning measurement naturally happens:
wake up, open the app, lie still for two minutes, read the verdict and the explanation, look at the trend.
The Mac stays the development/analysis tool; the phone becomes the daily device. Both must produce the same
numbers from the same beats.

Environment: Xcode 27 / Swift 6.4 on this Mac, iPhone + iPad + Apple Watch available. The iOS **Simulator
has no Bluetooth**, so anything touching the band is tested on the real iPhone (free Apple ID signing is
enough for personal use; 7-day re-sign, or a paid account for TestFlight).

## Product scope (v1)

1. **Measure** – guided morning protocol identical to `hrmon measure`: connect, 60 s settle, 120 s
   measurement (extended by up to 60 s while fewer than 80 clean beats are in), live HR and RR while it runs,
   result card at the end.
2. **Today** – verdict (READY / MODERATE / REST, score, illness flag), *why* in plain language, today's
   lnRMSSD and resting HR placed on your normal range, HF/LF and breathing rate.
3. **Trends** – charts over 2 weeks / 1 month / 3 months: lnRMSSD with the normal band and 7-day average,
   resting HR with its band, score, breathing rate; tap a point to open that morning.
4. **Morning detail** – tachogram (RR over time), Poincaré plot, spectrum (LF/HF bands shaded), metrics table.
5. **Data** – local store, export/import CSV compatible with `sessions/readiness.csv`, optional HealthKit
   write (HRV SDNN, resting HR), morning reminder notification.

Not in v1: Apple Watch app, cloud sync, ANT+, multiple users, sleep/activity inputs.

## Architecture

```
ReadinessApp/                      (Xcode project, SwiftUI, iOS 17+)
  Packages/HRVCore/                Swift package, no UI, no Bluetooth – pure maths, fully unit-tested
    Sources/HRVCore/
      HeartRateMeasurement.swift   parser for 0x2A37 (port of ble.parse_hr_measurement)
      RRBuffer.swift               artefact filter + beat clock (port of hrv.RRBuffer)
      TimeDomain.swift             RMSSD, lnRMSSD, SDNN, pNN50 (compute_metrics)
      Spectral.swift               Lomb-Scargle PSD, LF/HF, breathing rate (spectral_metrics)
      Readiness.swift              DayRecord, Assessment, assess(), notes text (port of readiness.py)
      CSV.swift                    readiness.csv / session CSV read+write, same columns as hrmon
    Tests/HRVCoreTests/            golden-value tests generated from the Python implementation
  ReadinessApp/
    App/ReadinessApp.swift         entry, SwiftData container, dependency wiring
    Bluetooth/
      HeartRateSource.swift        protocol: AsyncStream<HeartRateSample>, connectionState, battery
      BLEHeartRateSource.swift     CoreBluetooth central: scan 0x180D, connect, subscribe 0x2A37, 0x2A19
      ReplayHeartRateSource.swift  replays a session CSV in real time (dev, previews, UI tests)
    Model/
      Morning.swift                SwiftData @Model: date, metrics, spectral, quality, verdict snapshot
      Beat.swift                   SwiftData @Model: per-beat RR (child of Morning) – or a blob column
      Baseline.swift               computed on the fly from Morning rows via HRVCore.assess
    Features/
      Today/TodayView.swift        verdict card + explanation + "where you are vs normal" gauge
      Measure/MeasureFlow.swift    state machine: intro → connecting → settling → measuring → result
      Measure/LiveMeasureView.swift   HR number, RR tachogram sparkline, countdown ring, quality hint
      Trends/TrendsView.swift      Swift Charts, range picker, selection → MorningDetailView
      History/MorningDetailView.swift tachogram, Poincaré, spectrum, table, delete/retake
      Settings/SettingsView.swift  band picker, durations, HealthKit toggle, reminder, export/import
    Services/
      MeasurementSession.swift     drives a measurement from a HeartRateSource into HRVCore, persists
      HealthKitService.swift       writes HKQuantityType .heartRateVariabilitySDNN and .restingHeartRate
      ReminderService.swift        UNUserNotificationCenter daily reminder
      ExportService.swift          CSV export via ShareLink / Files, import via fileImporter
```

Key decisions:

- **HRVCore is a straight port** of the Python modules, same constants (300–2000 ms, 20 % deviation,
  0.5 SD normal range, 60-day baseline, 7-day minimum, score 75 + 15·(0.65 z_HRV − 0.35 z_HR), illness
  rule). Python stays the reference; a script exports golden fixtures the Swift tests must match.
- **Source abstraction** (`HeartRateSource`) so the whole UI runs on the Simulator and in previews from
  recorded sessions (`sessions/*.csv` from the Mac are the first fixtures). Only `BLEHeartRateSource`
  needs the phone.
- **SwiftData** for storage (iOS 17+), per-morning rows plus beats, so detail charts work offline and the
  baseline can be recomputed when the algorithm changes. CSV import/export keeps the Mac and phone
  interchangeable.
- **Swift Charts** for all plots (line + area band for normal range, rule marks for today, scatter for
  Poincaré, bar/area for spectrum).
- **Explanations** come from the same `notes` logic as Python, plus a structured "why" built from the
  assessment: each driver (HRV vs range, HR vs range, 7-day trend, quality) rendered as a row with an
  icon, the measured value, your range, and a one-line meaning. No free-text generation at runtime.

## Bluetooth details (from the verified band)

- Scan for service `180D`; the band advertises with its model name and serial. Remember its `CBPeripheral.identifier`.
- Subscribe to `2A37`; parse flags (bit0 16-bit HR, bit4 RR present, RR in 1/1024 s). Read `2A19` battery,
  `2A29/2A24/2A26/2A28` device info. Ignore vendor service `FD00`.
- No pairing/bonding; the band accepts one central at a time, so disconnect when the measurement ends.
- `Info.plist`: `NSBluetoothAlwaysUsageDescription`. Background mode `bluetooth-central` is optional:
  keep the screen on during the 2½ minutes (`isIdleTimerDisabled = true`) instead; simpler and reliable.
- Handle: band off (scan timeout → instructions with the LED meanings), band held by another app, drop
  mid-measurement (auto-reconnect, pause the clock, mark the morning as interrupted if > 10 s lost).

## Measurement flow (state machine in `MeasureFlow`)

```
intro ──start──▶ connecting ──first sample──▶ settling(60 s) ──▶ measuring(120 s, +≤60 s) ──▶ result
   ▲                 │ timeout / not found                            │ disconnect
   └─────────────────┴──────── help sheet ◀────────────────────── reconnecting (clock paused)
```

- Settle and measurement start from the first heartbeat, as in `hrmon`.
- Auto-extension (same rule as `hrmon/protocol.py`, constants in `AppSettings.minCleanBeats` /
  `maxExtensionS`): when the nominal time is up with fewer than 80 clean beats, keep measuring until 80 are in
  or 60 s more have passed. The ring turns amber and shows "extending · N more clean beats". The stored
  `durationS` is the real measured span.
- Live view: big HR, countdown ring, RR tachogram of the last 60 s, quality hint ("hold still" when
  artefacts rise above 10 %).
- Result: HRVCore metrics + spectral + `assess()` against stored mornings → persisted `Morning`, verdict
  shown immediately, HealthKit write if enabled.

## Screens and explanations

**Today**
- Verdict card: colour, label, score ring, illness badge, low-confidence badge.
- "Why" rows: lnRMSSD today vs normal range (gauge with the dot), resting HR vs range, 7-day average vs
  range, signal quality. Each row ends with the sentence from `Assessment.notes`.
- Baseline progress while < 7 mornings: "3 of 7 mornings recorded", with what the chart will show later.
- Secondary numbers: RMSSD, SDNN, HF/LF, breathing rate, battery of the band.

**Today, top (phase A)** – week strip and *Today's numbers*: Regeneration (0–10), Readiness, Stress (0–10) rings
with "% vs average / since last" chips; see `docs/three-numbers-plan.md`.

**Trends** – Swift Charts: `LineMark` lnRMSSD, `AreaMark` normal band (mean ± 0.5 SD computed per day
from the preceding 60 days), dashed `LineMark` 7-day average, `PointMark` coloured by verdict, `RuleMark`
on selection; same for resting HR; score as bars; breathing rate as line. Range picker 2w/1m/3m.

**Morning detail** – tachogram with artefacts marked, Poincaré (RRₙ vs RRₙ₊₁) with SD1/SD2 ellipse,
spectrum with LF/HF shaded, table of all metrics, notes, delete or retake.

## Status

- Phase 1 done: `Packages/HRVCore`, 14 golden tests against Python fixtures.
- Phase 2 done: `ReadinessApp/` (XcodeGen spec `project.yml`, run `xcodegen generate` after adding files).
  SwiftData model `Morning`, `ReplayHeartRateSource`, `MeasurementSession`, Today / Measure / Trends /
  History / Detail / Settings screens, CSV import/export, demo data. Verified in the iOS 18.2 Simulator
  (the iOS 17.5 simulator under Xcode 27 ignores injected taps; use an 18.2 device for UI checks).
  Debug launch environment for automated checks: `READINESS_DEMO=1`, `READINESS_TAB=trends`,
  `READINESS_AUTOMEASURE=1`, `READINESS_REPLAY_SPEED=10` (pass via `SIMCTL_CHILD_` with `simctl launch`).
- Phase 3 code done: `Bluetooth/BLEHeartRateSource.swift` (CoreBluetooth central: scans `180D`, connects to the
  remembered band first, subscribes `2A37`, reads `2A19`, reconnects with the clock paused, 30 s scan / 60 s
  reconnect timeouts with help text), registered in `ReadinessApp.init`. Remembered band in UserDefaults
  (`bandIdentifier`, `bandName`) with a *Forget band* button in Settings. Builds for the Simulator and for the
  unsigned iOS device slice. Signed with the free Personal Team (`DEVELOPMENT_TEAM` in `project.yml`).
  **Verified on the iPhone 17 Pro (iOS 26.6.2) on 2026-10-04**: connects to the band, measurement completes,
  result shown. Not yet exercised: band-off scan timeout, Bluetooth-off message, range loss mid-measurement.
- Phase 4 done (2026-10-04): copy review of every note in `hrmon/readiness.py` and the Swift port (fixed: the
  illness note claimed "HRV suppressed" when the rule fired on resting HR alone; the rest note said "below" when
  HR was the cause). Poincaré SD1/SD2 added to Python (`hrv.poincare`) → fixtures → Swift (`poincare(rr:)`).
  App: plain-language why-rows (no "SD" jargon), baseline-period text, ⓘ glossary popovers on every number
  (`Features/Explain/Glossary.swift`), "How the verdict works" page (`MethodView`), detail screen with why-rows,
  annotated tachogram, Poincaré with SD1/SD2 ellipse, spectrum with breathing-rate marker and band powers,
  full metrics table, delete. 21 Python and 14 Swift tests pass. Builds for device; UI checked on the iPhone by
  hand (the Mac's simulator runtimes were removed on 2026-10-04).
- Phase 5 done in code (2026-10-04): `Services/HealthKitService.swift` writes SDNN and resting HR per morning
  with a sync identifier (re-saving replaces, deleting a morning removes its samples), opt-in in Settings with a
  backfill button; only band and imported mornings are written (replays too, but only in the Simulator).
  `Services/ReminderService.swift` plans one notification per day for 30 days, skips today once measured,
  re-plans on app activation and after each measurement; tapping opens Measure (`App/AppDelegate.swift`,
  `AppRouter`). App icon with light/dark/tinted variants drawn by `tools/make_icon.swift`. HealthKit entitlement
  signs fine with the free Personal Team. Verified in the iOS 27 Simulator (iPhone 18 Pro): reminders planned
  (30 pending), delivered as banner and to Notification Center; Health sheet lists exactly Resting HR and HRV
  for writing, and only real (here: replayed) mornings were saved, demo data skipped; dark mode checked on
  Today and Trends. Not verifiable there (injected taps on switches and lock-screen notifications are ignored):
  tapping a reminder opening Measure. On-phone checks are listed in `docs/phone-checklist.md`.
  More debug launch switches: `READINESS_REMINDER_TEST=1` (reminder one minute from now) and
  `READINESS_HEALTH_TEST=1` (request Health access, save eligible mornings; result in the unified log,
  subsystem `com.danforejtek.readiness`). Simulator quirk: after `simctl install` over an existing copy,
  scheduling notifications can fail with "Source is not authorized"; `simctl uninstall` first.
- Phase 6 tooling done (2026-10-04); the month of use starts now. Morning check-in (feeling 1–5 + tags) on
  the result and detail screens (`Features/CheckIn/CheckInCard.swift`), stored on `Morning`, exported as
  `feeling`, `tags`, `source` columns (also in `ReadinessCSV.columns`). Export now shares two files: readiness.csv
  and readiness-beats.csv (every received interval). Python: model constants gathered in `Params`
  (`hrmon/readiness.py`, fixtures byte-identical), `hrmon measure --feeling --tags`, and `hrmon analyze`
  (`hrmon/analyze.py`): data consistency, signal quality, verdict vs feeling, illness hits/misses, tag effects,
  artefact-filter sensitivity, what-if with alternative `Params`. 30 Python and 14 Swift tests pass. Verified in
  the Simulator: check-in saved and exported, phone export analysed on the Mac. Procedure: `docs/tuning.md`.
  Debug switch `READINESS_EXPORT_TEST=1` writes both export files into the app's Documents folder.
- Phase A of `docs/three-numbers-plan.md` done (2026-10-04). **A1 maths:** `hrv.stress_index` (Baevsky,
  50 ms bins on a fixed grid, lowest bin wins a tie, ≥ 30 beats) → `stressIndex(rr:)`; per morning `sd1_ms`,
  `sd2_ms`, `stress_index` in readiness.csv (Mac `_finish_measure`, appended to `ReadinessCSV.columns`, `Morning`
  fields with nil defaults, `csvRow` and import). `readiness.ans_z` / `Readiness.ansZ`: Regeneration z = mean of
  z(mean RR), z(RMSSD), z(SD1); Stress z = mean of z(mean HR), z(√SI), −z(SD2) (SD2 reversed as in Kubios: less
  slow variation = more sympathetic). Same 60-day window and 7-day minimum per component, own SD floors in `Params`
  (`rr_sd_floor` 25 ms, `rmssd_sd_floor` 2.5 ms, `sd1_sd_floor` 1.8 ms, `sqrt_si_sd_floor` 0.2, `sd2_sd_floor`
  3 ms; mean HR reuses `hr_sd_floor`), missing components are skipped. Scale `round(clip(5 + 2z, 0, 10), 1)`.
  `Assessment` gains `regeneration`, `stress`, their z, and `Comparison(vs_average_pct, vs_last_pct)` for lnRMSSD,
  resting HR, Regeneration and Stress (Regeneration/Stress "vs average" is against 5). Notes unchanged.
  *Superseded (October 2026, after `docs/evidence.md` sections G, H, I):* SD1 ≡ RMSSD/√2, mean RR is the
  reciprocal of HR and √SI tracks HR and SD2, so the Kubios-style averages counted the same information twice.
  Now Regeneration z = z(lnRMSSD) (`ln_sd_floor`); Stress z = ⅔ · z(resting HR) + ⅓ · −z(ln SD2) (Naranjo
  Orellana 2015's Stress Score on the log scale; `stress_w_hr`, `stress_w_sd2`, `ln_sd2_sd_floor` 0.05), or
  z(HR) alone without SD2; both use the verdict's clean-only baseline (`_baseline`). The old floors are gone.
  Stress is described as strain / load, not sympathetic activity. In the same pass: successive differences
  across a rejected beat are skipped by RMSSD, pNN50 and SD1 (`RRBuffer.breaks`, `Morning.breakIndices`,
  recovered at launch for stored mornings by re-running the filter; section F), the 7-day average needs
  `week_min_days` = 3 mornings to flag fatigue (section B), the breathing search stops at min(0.50, HR/120) Hz
  (section J), and the illness notes name alcohol, poor sleep, travel and stress as other causes (section C).
  `MorningStore.backfillBeatDerived` fills mornings with beats at launch. The demo CSV gained the three columns.
  **A2 UI:** Today has a week strip (`WeekStripView`, Mon–Sun, tap a day → detail, "N of 7" ring) and *Today's
  numbers* (`TodayNumbers.swift`: Regeneration / Readiness / Stress rings with ⓘ, level label, short chips); the
  HRV and resting-HR why-rows show chips; Numbers grid adds stress index and SD1/SD2. Trends: 2 wk / 1 mo / 3 mo /
  6 mo / 1 yr and Regeneration and Stress charts (4–6 band, points coloured by level). Detail table adds stress
  index, score, Regeneration and Stress. Glossary entries for Regeneration, Stress and stress index, Method
  section "Stress and Regeneration". Level bands, chip wording/colour direction and the week strip are pure
  helpers in `HRVCore/Presentation.swift` with tests. 38 Python and 18 Swift tests pass; fixtures regenerated
  (existing verdict fields unchanged). Verified in the iOS 27 Simulator: migration + backfill of an existing
  store (replay morning SD1 69.9 / SD2 84.2 / SI 35.0, identical to Python), Today and Trends in light and dark,
  1-year range, week-strip tap → detail; device build compiles. On-phone checks in `docs/phone-checklist.md`.
- Next: phase B of `docs/three-numbers-plan.md` (Apple Health read), alongside the month of mornings with
  check-ins, then `hrmon analyze` and one-knob-at-a-time changes.

## Phases

1. **HRVCore port + golden tests** (Mac only). Export fixtures from Python: feed `tests/` sine series and
   the two real sessions through `hrmon`, dump JSON (metrics, spectral, assessments for a synthetic
   30-day history). Swift tests assert equality within 1e-6 (time domain) and 1 % (spectral).
2. **App skeleton with ReplaySource**: SwiftData models, Measure flow and Today/Trends views running in the
   Simulator from the recorded CSVs. Import of `readiness.csv` so the real history is visible from day one.
3. **BLE on device**: `BLEHeartRateSource`, scan/connect/subscribe, device-info/battery, reconnect; first
   real morning measurement on the iPhone; compare the stored row with a simultaneous… (not possible: one
   connection) – instead compare against a Mac `hrmon measure` taken right after.
4. **Explanations and detail charts**: why-rows, Poincaré, spectrum, notes; copy review of all sentences.
5. **Data and polish**: CSV export/import, HealthKit, reminder, settings, app icon, light/dark.
6. **Use it for a month**, then tune: artefact thresholds, score weights, wording; adjust Python in step
   so both stay in sync.

## Verification

- `swift test` in `Packages/HRVCore` passes the golden fixtures from Python.
- Simulator: full measurement flow with `ReplayHeartRateSource` on `sessions/2026-10-04_001437.csv`
  ends with the same lnRMSSD 4.59 / HF 4417 ms² / breathing 13 as the Mac run.
- Device: scan finds the band, live HR updates once per second, RR arrives when worn, measurement
  completes, row persisted, verdict shown; airplane-mode and band-off error paths show the help sheet.
- Trends render with 1, 7 and 60 synthetic mornings (baseline progress, first verdicts, full band).
- Export → import round-trip of `readiness.csv` reproduces identical assessments.

## Risks and open points

- **Simulator has no CoreBluetooth**: every Bluetooth change needs the phone plugged in; mitigated by the
  `HeartRateSource` abstraction.
- **Optical RR quality** at the forearm is lower than a chest strap; the 20 % artefact filter is tuned on
  two sessions only. Keep the beats, so re-filtering later is possible.
- **The commercial app's exact score is proprietary**; this app reproduces the open method, which only becomes
  meaningful after a week of mornings. Say so in the UI.
- **HealthKit HRV is SDNN only**; RMSSD stays in the app.
- Decide: free Apple ID sideload (re-sign weekly) vs paid developer account (TestFlight, no expiry).
