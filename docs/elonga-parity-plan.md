# Plan: Elonga-style features for the Readiness app

## Context

Dan compared the app with screenshots of the Elonga app (mySASY). Elonga's main screen shows three morning
numbers (Regeneration 0–10, Readiness 0–100, Stress 0–10). It also shows "% above average / % since last
measurement" chips, a week strip with measured days and a completion percentage, and advice text such as
"Good time for a challenging activity". Further screens show a fitness score with long-range trends, a weekly
training plan with done ticks and a step goal, trend charts for stress and regeneration, and "what harms or
helps you".

The goal is to get the same experience from what the band and Apple Health already provide, using published
methods instead of Elonga's proprietary formulas. "Functional age" is out of scope: there is no sound open
method behind it.

Current state (end of phase 6): readiness verdict and score, why-rows, glossary, trends (14/30/90 days),
history/detail, Apple Health write, reminder, check-in (feeling + tags), CSV + beats export, Mac `hrmon analyze`.
See `docs/ios-app-plan.md` for the architecture and `README.md` for commands.

## Ground rules (unchanged)

- **Python first.** Any maths goes into `hrmon/` first with unit tests. Then run
  `.venv/bin/python tools/export_fixtures.py`, port it to `Packages/HRVCore`, and make the golden tests pass:
  `swift test --scratch-path <scratchpad>/build`.
- Presentation-only logic, such as advice text that combines the verdict with Apple Health data, may live only
  in Swift. It still goes in HRVCore or the app with unit tests.
- New `Morning` fields need defaults, so SwiftData migrates automatically.
- New CSV columns are appended at the end of `ReadinessCSV.columns`. Python ignores unknown columns.
- Never delete or move user files without asking; Dan has declined `rm`/`mv` before. Never load demo data on
  the real phone.

## Phase A – Stress and Regeneration from the morning measurement (no new data)

### A1. Maths (Python → fixtures → Swift)

`hrmon/hrv.py`:

- `stress_index(rr_ms) -> Optional[float]`: Baevsky's stress index on clean RR, with a 50 ms histogram.
  SI = AMo / (2 · Mo · MxDMn), where Mo is the modal bin centre in s, AMo is the % of intervals in the modal bin,
  and MxDMn is max − min RR in s. Returns None for fewer than 30 intervals or MxDMn = 0.
- Store per morning: `sd1_ms`, `sd2_ms` (from `poincare`) and `stress_index`. Add them as readiness.csv columns
  in `cli._finish_measure`, and in the app's `Morning` and `csvRow`.

`hrmon/readiness.py`:

- *Superseded:* the composition below was replaced by Regeneration = z(lnRMSSD) and Stress = ⅔ · z(resting HR)
  + ⅓ · −z(ln SD2) after the literature review in `docs/evidence.md` (sections G, H, I); see `hrmon/readiness.py`.
- These are Kubios-style PNS/SNS indices, but scored against the personal baseline instead of population norms.
  - Regeneration z = mean of z(mean RR), z(RMSSD) and z(SD1).
  - Stress z = mean of z(mean HR), z(√SI) and z(SD2).
  - Each z uses the same baseline window as readiness: previous 60 days, today excluded, at least 7 days.
    Each component has its own SD floor (new `Params` fields).
- Scale to 0–10: `round(clip(5 + 2·z, 0, 10), 1)`, where 5 means "your normal". If a component is missing,
  as in old Mac rows without beats, average the components that are available. With none available, return None.
- Comparisons for the chips:
  - `% vs average`: today vs baseline mean, for lnRMSSD, resting HR, Regeneration and Stress.
  - `% since last`: today vs the previous measured day.
- Add the fields to `Assessment`. Note texts stay unchanged unless a new note is clearly useful. If a note is
  added, it gets the same wording in both implementations.
- Tests: hand-computed SI on a small histogram, a scale clip test, missing-component fallback, and a baseline
  under 7 days giving None.

`tools/export_fixtures.py`: export `stress_index` and `poincare` per session, and the new `Assessment` fields
in `readiness.json`. In Swift, port `stressIndex(rr:)`, extend `Assessment`/`DayRecord`, and extend the
`ReadinessTests` and `RealSessionTests` comparisons.

Backfill: `Morning` rows that have beats get `sd1`/`sd2`/`stressIndex` computed on first launch, through a
migration helper in `MorningStore`. Imported rows without beats keep them empty.

### A2. UI

- **Today, top:** a "Today's numbers" card with three rings: Regeneration (0–10), Readiness (score, or baseline
  progress) and Stress (0–10, where high is bad). Each ring has an ⓘ with a glossary entry. The verdict card
  stays below as the explanation.
- **Chips** under each why-row and in the numbers card: "▲ 8 % above average" and "▼ 1 % since last
  measurement". They are coloured good/bad per metric direction; Stress and resting HR are inverted.
- **Week strip** at the top of Today: Mon–Sun with a dot on measured days and today highlighted. It shows
  "5 of 7 mornings this week" as a small ring. Tapping a day opens that morning's detail.
- **Trends:** add 6 months and 1 year to the range picker. Add Regeneration and Stress charts, with the band at
  4–6 = normal and points coloured like the verdicts.
- **Detail:** the all-numbers table gains SD1/SD2 (already there), the stress index, Regeneration and Stress.
- **Glossary and Method page:** add Regeneration, Stress and stress index entries, plus a "Stress and
  Regeneration" section that explains the Kubios-style method and that 5 = your normal.

Verification:

- Python and Swift tests pass, fixtures regenerated.
- In the iOS 27 simulator, with `READINESS_DEMO=1` and `READINESS_TAB=today|trends`, screenshots in light and
  dark mode show the rings, chips, week strip and new charts.
- On the phone, the real mornings show values. The phone has to be connected for installing; see "Practical
  notes".

## Phase B – Read Apple Health (activity, sleep, fitness)

### B1. Data access

`Services/HealthKitService.swift`, read access, added to the existing write request:

- `HKWorkoutType`: start, duration, activity type, active energy, average HR. Effort score where available
  (iOS 18+ `workoutEffortScore`).
- Step count: daily sums via `HKStatisticsCollectionQuery`.
- `sleepAnalysis`: asleep duration for the night before each morning.
- `vo2Max`: latest value and history.
- `restingHeartRate` from other sources is not needed; ours stays authoritative.

Info.plist: update `NSHealthShareUsageDescription` to say what is read and why.

Intensity per workout:

- Use the effort score when present: 1–3 easy, 4–6 moderate, 7–10 hard.
- Otherwise use average HR as % of HRmax: below 70 % easy, 70–85 % moderate, above 85 % hard.
- HRmax is a Settings value, defaulting to 208 − 0.7 · age, with age entered once in Settings.

`Model/DayActivity.swift`: a SwiftData cache per calendar day with steps, sleep hours, workouts (type, minutes,
kcal, intensity) and VO₂max. It is refreshed on app activation for the last 14 days. That keeps Today fast and
makes it work offline.

### B2. Advice and fitness

- A pure function `Advice.today(assessment:, yesterday: DayActivity?, sleepHours:) -> (title, body)` in HRVCore,
  with a rule table and unit tests. Examples:
  - READY with no hard session yesterday: "Good time for a challenging activity".
  - READY after a hard day: "Recovered from yesterday's hard session – a quality session is fine".
  - MODERATE after under 6 h of sleep: "Short night – keep it moderate".
  - REST or illness: rest-day text. The illness text takes precedence.
- It replaces the generic status subtitle on Today. The note texts stay in the why-section.
- Fitness card: the VO₂max trend from Apple Health over Week / Month / ¼ / ½ / Year, with change vs the start of
  the range. Without VO₂max data the card is hidden. There is no made-up score.
- Steps: today's steps against a goal (Settings, default 10 000) as a bar on Today.

Verification:

- Seed Health in the simulator with a debug switch, `READINESS_HEALTH_SEED=1`. It writes sample workouts,
  steps, sleep and VO₂max for the last 14 days, in the simulator only.
- Unit tests for intensity classification and the advice rules.
- On the phone, real Garmin/Apple Watch data appears. Garmin Connect must sync to Apple Health.

## Phase C – Weekly plan (HRV-guided training)

- A **Plan tab**, a fifth tab between Trends and History. It shows the week strip and the planned intensity per
  day, then finished activities from Health with ticks.
- The rule follows Kiviniemi 2007 and Vesterinen 2016 (HRV-guided training):
  - Hard sessions are planned only on mornings whose verdict is READY and whose 7-day trend is not below range.
  - Otherwise the plan is moderate or easy. REST days are always easy or off.
  - Weekly targets live in Settings and default to 2 hard, 2 moderate and a 10 000 steps/day goal.
- The progress ring shows completion of the weekly targets, like Elonga's "80 %, 2 days to go".
- The plan is recomputed every morning after the measurement. Past days show what was actually done.
- Pure planning logic goes in HRVCore with unit tests. Python parity is not required because it doesn't
  affect the readiness model.

## Phase D – "What harms or helps you" (after ~4 weeks of check-ins)

- Port the tag-effects logic from `hrmon/analyze.py` (`tag_effects`) to Swift. Add effects of sleep hours and of
  yesterday's training load from `DayActivity`.
- An Insights section on Trends, e.g. "Alcohol: HRV −1.8 SD on average (3 mornings)". It shows only factors
  with at least 3 tagged mornings, and adds "early estimate" until 8.
- Python stays the reference: keep `hrmon analyze` and the Swift insight numbers equal on a shared fixture.

## Order and size

| Step | Content | Size |
|---|---|---|
| A1 | stress index, SD2, Regeneration and Stress maths, fixtures, Swift port | 1 session |
| A2 | rings, chips, week strip, trends ranges, glossary | 1 session |
| B1–B2 | Health read, DayActivity, advice, steps, VO₂max card | 1–2 sessions |
| C | Plan tab | 1 session |
| D | Insights | after the month of data |

## Practical notes for the implementing session

- Python: `.venv/bin/python -m unittest discover -s tests`; currently 30 tests pass.
- Swift package: `cd Packages/HRVCore && swift test --scratch-path <your scratchpad>/build`. Use a fresh scratch
  path; the repo's `.build` caused issues before. Currently 14 tests pass.
- App: `cd ReadinessApp && xcodegen generate` after adding files. Simulator build:
  `xcodebuild -project ReadinessApp.xcodeproj -scheme ReadinessApp -destination 'id=DC998CD4-A7B4-4299-B807-CE588ADE38B5' -derivedDataPath <scratchpad>/dd build`
  (iPhone 18 Pro, iOS 27). Use `xcrun simctl uninstall` before `install` when testing notifications.
- Simulator quirks:
  - The display lags several seconds, so wait before screenshots.
  - Injected taps on switches and on lock-screen notifications are ignored; plain buttons work.
  - Prefer the debug launch variables (`SIMCTL_CHILD_READINESS_*`, listed in `docs/ios-app-plan.md`) over taps.
- Phone: "Dan – iPhone", UDID `00008150-000A5CD81190C01C`, Personal Team `96XQ29U7ZA` (already in
  `project.yml`). Build with `-allowProvisioningUpdates`, then install with
  `xcrun devicectl device install app --device <UDID> <path>/Debug-iphoneos/Readiness.app`. Don't take device
  screenshots while Dan may be using the phone.
- When a phase is done, update the Status section of `docs/ios-app-plan.md`, the README and
  `docs/phone-checklist.md`.
