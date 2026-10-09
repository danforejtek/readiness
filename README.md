# Readiness – morning HRV readiness from a Bluetooth heart-rate sensor

This repository holds three pieces that share one method:

| Part | Where | What it is |
|---|---|---|
| **Readiness** | `ReadinessApp/` | SwiftUI iPhone app (iOS 17+). Measures a short resting reading every morning and tells you how ready you are to train. |
| **HRVCore** | `Packages/HRVCore` | Swift package with the maths: RR parsing, artefact filter, time- and frequency-domain HRV, readiness/illness assessment, Insights, CSV. A one-to-one port of the Python reference. |
| **hrmon** | `hrmon/` | Mac command-line tool: live heart rate and HRV, the same morning measurement and verdict, and a tuning report. It is the reference implementation; the Swift package is checked against it. |

Readiness is a training aid, not a medical device.

## What the app does for you

Every morning, right after waking, you lie still for three minutes with a heart-rate sensor on. The app measures
how much the time between heartbeats varies (heart rate variability, HRV) and your resting heart rate, and compares
both with your own previous 60 days. From that it gives:

- a **verdict**: READY (a good day for a hard session), MODERATE (train, but keep the intensity moderate) or
  REST (recovery day), with the reasons spelled out against your normal range;
- a **Readiness score** from 0 to 100, where 75 is a normal morning for you;
- **Regeneration** and **Stress** on a 0–10 scale, where 5 is your normal;
- a **possible-illness warning** when resting HR is up and HRV is down two mornings in a row;
- a 7-day HRV average that shows fatigue building up over several days;
- **Insights** after a few weeks: whether the verdict matches how you felt, what alcohol, poor sleep or hard
  training do to your mornings, whether the illness warning caught your sick days, and how steady your routine is.

Screens:

| Screen | Content |
|---|---|
| Today | Week strip (Mon–Sun, measured mornings marked), three rings (Regeneration, Readiness, Stress) with "% vs average" and "% since last" chips, the verdict card (with a *Provisional* badge while the baseline is young), why-rows for HRV and resting HR against your normal range, a *Live heart rate* button. |
| Measure | 60 s settle and 120 s measurement ring, live HR and RR tachogram with rejected beats in amber, automatic extension when too many beats are rejected, a haptic pulse at the extension and at the end, then the result and the *How do you feel?* check-in. |
| Trends | 2 weeks, 1, 3 or 6 months, 1 year: lnRMSSD with the normal band and the 7-day average (hollow points = provisional verdicts), resting HR, Regeneration, Stress, score, breathing rate. |
| Insights | Cards that compare your mornings with each other and with your check-ins (see [Insights](#insights)). |
| History | Every morning; the detail view has the tachogram, Poincaré plot, spectrum, all numbers with explanations, and the check-in. Swipe left to delete. |
| Settings | Appearance, morning protocol, heart-rate source and sensor battery, baseline reset, morning reminder, Apple Health, CSV import/export, demo data, and *How the verdict works*, which explains the whole method in plain language. |

The rings and the numbers in a morning's detail have an ⓘ button with a plain-language explanation
(`Features/Explain/Glossary.swift`).

## The sensor

Any sensor that implements the standard **Bluetooth LE Heart Rate Profile** and sends **RR intervals** (beat-to-beat
times) works: an ECG chest strap or an optical (PPG) armband. Nothing is tied to a particular brand. The app and the
Mac tool connect to the first device advertising the Heart Rate Service and remember it.

Services a typical armband offers:

| Service | What it gives |
|---|---|
| Heart Rate 0x180D | Heart Rate Measurement 0x2A37 every second; RR intervals when flag bit 4 is set |
| Battery 0x180F | battery % |
| Device Information 0x180A | manufacturer, hardware and software version |
| User Data 0x181C | on some armbands, a VO₂max estimate (not used) |
| Vendor-specific services | manufacturer channels, not needed |

Practical notes:

- **RR only with skin contact.** An optical sensor includes RR intervals only once its signal is valid, i.e. when
  it sits snugly on skin. Lying on a desk it may report around 200 bpm with no RR, which is normal. Chest straps
  wake and send RR once worn with moistened electrodes.
- **One Bluetooth connection at a time.** Most sensors accept a single connection. If a phone app or watch holds
  the sensor, nothing else will see it; disconnect there first. **ANT+**, if the sensor has it, is a broadcast
  without that limit, so a watch or bike computer can listen on ANT+ while the phone or Mac uses Bluetooth.
- **Wearing an armband.** On the inner forearm, snug enough that it does not slide. Keep the arm still during
  the measurement.
- **Armband button and LED** (the armband this project was developed with; check your sensor's manual):

  | Action / LED | Meaning |
  |---|---|
  | Short press | power on; starts measuring and advertising immediately (no separate pairing mode) |
  | Long press | power off |
  | Blue blinking | on and advertising / connecting |
  | Red blinking | battery low, charge it |
  | Blinking on the magnetic charger | charging; solid green = full |

- Stick with one sensor. Values from different sensors are not directly comparable; after switching, start a new
  baseline (Settings › Baseline › *Start a new baseline*).

## Running the iPhone app

Generate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and open it:

```bash
cd ReadinessApp && xcodegen generate && open ReadinessApp.xcodeproj
```

Run `xcodegen generate` again after adding or removing files. The app icon is generated by
`swift tools/make_icon.swift`.

**Simulator.** The Simulator has no Bluetooth, so the app replays a recorded session from
`ReadinessApp/ReadinessApp/Resources/Fixtures` (Settings › Heart-rate source › *Recording to replay*, with a replay
speed of 1–20×). *Load demo history* fills in a synthetic 35-day history plus one replayed real morning; use it only
for trying the app, not on the phone you measure with. Debug launch variables (`READINESS_DEMO=1`,
`READINESS_TAB=…`, `READINESS_AUTOMEASURE=1` and others) are listed in `App/AppSettings.swift`.

**On the iPhone.**

1. Connect the phone by USB, tap *Trust* on the phone, and turn on Developer Mode (Settings › Privacy & Security ›
   Developer Mode, then restart).
2. In Xcode › Settings › Accounts, sign in with an Apple ID. Pick that Personal Team under the target's *Signing &
   Capabilities*.
3. Choose the iPhone as the run destination and press Run.
4. The first launch is refused until you trust the certificate on the phone: Settings › General › VPN & Device
   Management › Developer App › your Apple ID › Trust.

A build signed with a free Apple ID expires after 7 days; run again from Xcode to re-sign. If Xcode shows the phone
as "unsupported" after tapping Trust, open Window › Devices and Simulators with the phone unlocked, or re-plug the
cable; pairing finishes there. Items that can only be checked on a real phone are listed in
[`docs/phone-checklist.md`](docs/phone-checklist.md).

**First measurement.** Wake the sensor (put it on; press the armband's button so it blinks blue), tap *Measure now*.
The app scans for 30 s for a heart-rate sensor, connects to the first one it finds and remembers it; next time it
prefers that one (Settings › *Forget sensor* to switch). If the connection drops during a measurement, the clock
pauses and resumes on reconnection; after 60 s without a connection the measurement fails with a message. The
sensor's battery is shown in Settings; below 20 % the app warns before the next measurement.

**Other settings.** A morning reminder (skipped on days you have already measured; tapping it opens the
measurement). *Save to Apple Health* (see [What goes to Apple Health](#what-goes-to-apple-health)). CSV import of
`readiness.csv` from the Mac tool, and *Prepare CSV export* › *Share export* for the tuning report.

## Measurements and what they rest on

Each subsection gives what the number is, how it is computed, how the app uses it, and the literature behind it.
Full references, and where the app departs from them, are in [`docs/evidence.md`](docs/evidence.md) (section
letters in brackets). All numbers below are the defaults in `hrmon/readiness.py` (`Params`), `hrmon/hrv.py`,
`hrmon/protocol.py` and their Swift ports.

### Measurement protocol

- **What.** One short resting reading per morning, taken the same way every day.
- **How.** Right after waking, before getting up, coffee or phone; lying on your back; empty your bladder first, or
  always do the same. The clock starts with the first heartbeat received. The first **60 s** settle and are
  discarded, then **120 s** are measured. If fewer than **80** clean beats are in when the 120 s are up, the
  measurement continues until 80 are in or for at most **60 s** more, whichever comes first (the ring turns amber
  and shows "extending · N more clean beats"). The stored `duration_s` is the real span of the clean beats. Fewer
  than 30 clean beats in the end gives no result. Settle (0–60 s) and duration (60–300 s) can be changed in
  Settings or with `--settle`/`--duration`; keep them identical every day.
- **Interpretation.** Same conditions every day make mornings comparable; one morning is compared only with your
  own history.
- **Pulse-rate variability.** An optical armband measures the pulse at the arm, not the heart's electrical signal.
  At rest this agrees well with ECG, but it can read short-term variability slightly high and is more sensitive to
  movement, so keep the arm still.
- **Sources (D, K).** On waking, same conditions daily: Buchheit 2014, https://doi.org/10.3389/fphys.2014.00073;
  Plews 2013 (Sports Med), https://doi.org/10.1007/s40279-013-0071-8. About 1 min of stabilisation: Flatt & Esco
  2016, https://doi.org/10.1111/cpf.12233. 120 s is enough for RMSSD: Munoz 2015,
  https://doi.org/10.1371/journal.pone.0138921; Esco & Flatt 2014, https://pubmed.ncbi.nlm.nih.gov/25177179/.
  Bladder: Fagius & Karhuvaara 1989, https://doi.org/10.1161/01.HYP.14.5.511. Optical sensors: Schäfer & Vagedes
  2013, https://doi.org/10.1016/j.ijcard.2012.03.119; Plews 2017, https://doi.org/10.1123/ijspp.2016-0668. The
  80-beat / +60 s extension rule is this project's own choice.

### Artefact filter

- **What.** Removes intervals that cannot be real beats (movement, a loose sensor, missed or extra beats).
- **How.** An interval is rejected when it is outside **300–2000 ms**, or (once at least 3 beats are accepted) when
  it differs by more than **20 %** from the median of the last **5** accepted intervals. Recovery from a genuine
  change of heart rate: after **5** jump rejections in a row that agree with each other (each within 20 % of their
  own median), they become the new reference; those 5 stay counted as rejected, and beats are accepted again from
  the sixth. Rejected beats are dropped, not interpolated. The successive difference across a rejected beat is
  **skipped** by RMSSD, pNN50 and SD1, because it is not a real beat-to-beat change; SDNN and mean RR/HR use every
  clean beat. Rejected % = rejected / (clean + rejected) after the settle period.
- **Interpretation.** Rejected beats show in amber in the tachogram. A high rejected share lowers confidence (next
  subsection).
- **Sources (F).** Relative-threshold filters with roughly 20–40 % limits: Karlsson 2012,
  https://doi.org/10.1186/1475-925X-11-2. Skipping or correcting differences across artefacts: Lipponen & Tarvainen
  2019, https://doi.org/10.1080/03091902.2019.1640306. Spectral error grows with the artefact rate: Clifford &
  Tarassenko 2005, https://doi.org/10.1109/TBME.2005.844028. One missed artefact can distort ultra-short HRV:
  Shaffer 2020, https://doi.org/10.3389/fnins.2020.594880. The filter is simpler than Lipponen's.

### Signal quality and low confidence

- **What.** Whether a morning is clean enough to trust.
- **How.** A morning is **low confidence** when more than **5 %** of beats were rejected or fewer than **60** clean
  beats remain. The CSV `quality` label is coarser: `good` below 5 %, `fair` below 15 %, `poor` above.
- **Interpretation.** A low-confidence morning still gets a verdict, with a "Noisy reading" note. Once the 60-day
  window holds at least 7 clean mornings, low-confidence mornings are left out of the baseline and of the 7-day
  average of later days; until then every morning counts. If several mornings per day exist, the one with the
  lowest rejected % is used.
- **Sources (F).** Many studies exclude recordings above about 5 % artefacts, but no single validated cut-off was
  found; 5 % is common practice (Clifford 2005; Lipponen 2019; Shaffer 2020, above). The 60-beat floor is this
  project's choice.

### Mean HR and mean RR

- **What.** Average time between beats (mean RR, ms) and the matching heart rate. Mean HR over the measurement is
  the morning's **resting HR**.
- **How.** Mean RR = mean of all clean intervals; mean HR = 60 000 / mean RR (1000 ms = 60 bpm).
- **Interpretation.** Resting HR is one of the two inputs of the verdict (z_HR) and two thirds of Stress. A rise of
  several bpm over your normal is one of the earliest signs of illness, stress or fatigue. Mean RR is shown but not
  used separately, because it is just the reciprocal of HR.
- **Sources (C, I).** Resting HR above the personal baseline is the most robust early sign in wearable studies:
  Mishra 2020, https://doi.org/10.1038/s41551-020-00640-6; Natarajan 2020,
  https://doi.org/10.1038/s41746-020-00363-7. Heart period tracked cardiac sympathetic nerve activity better than LF
  power: Martelli 2014, https://doi.org/10.1152/ajpheart.00361.2014.

### RMSSD and lnRMSSD

- **What.** RMSSD (ms): how much consecutive beats differ, the standard short-recording index of cardiac vagal
  (recovery) activity. lnRMSSD: its natural logarithm.
- **How.** RMSSD = square root of the mean of the squared successive differences (differences across a rejected
  beat left out). lnRMSSD = ln(RMSSD).
- **Interpretation.** lnRMSSD is the HRV value the verdict, the baseline, the 7-day average, the score and
  Regeneration use. Most adults sit between about 3 and 5, but only your own trend matters. RMSSD in ms is shown
  next to it and is the basis of the "%" chips.
- **Sources (A, D, I).** Plews 2012, https://doi.org/10.1007/s00421-012-2354-4; Plews 2013 (IJSPP),
  https://doi.org/10.1123/ijspp.8.6.688; Buchheit 2014 (above); Laborde 2017,
  https://doi.org/10.3389/fpsyg.2017.00213. Log transform for variables whose error scales with their size: Hopkins
  2009, https://doi.org/10.1249/MSS.0b013e31818cb278. Robust to recording length: Munoz 2015 (above).

### SDNN

- **What.** Standard deviation of all clean intervals (ms); mixes beat-to-beat and slower changes.
- **How.** Sample standard deviation of the clean RR series.
- **Interpretation.** Shown for reference and written to Apple Health (which stores HRV as SDNN). It depends more on
  breathing and posture than RMSSD and does not enter the verdict. SD2 (below) is derived from it.
- **Sources (D).** Shaffer & Ginsberg 2017, https://doi.org/10.3389/fpubh.2017.00258.

### pNN50

- **What.** Share of successive differences larger than 50 ms, in %.
- **How.** Count of |difference| > 50 ms over all valid differences (across-gap differences left out).
- **Interpretation.** Shown for reference; it moves together with RMSSD and is not used by the verdict.
- **Sources (D).** Shaffer & Ginsberg 2017 (above).

### Poincaré SD1 and SD2

- **What.** From the Poincaré plot (each interval against the next). SD1 is the width of the cloud across the
  diagonal (fast, beat-to-beat variation); SD2 its length along it (slower variation).
- **How.** SD1 = √(½ · variance of the successive differences), about RMSSD/√2. SD2 = √(2 · SDNN² − SD1²).
  Differences across a rejected beat are left out, as for RMSSD.
- **Interpretation.** SD1 is shown but not counted separately, because it tells the same story as RMSSD. ln SD2
  makes up one third of Stress. Mornings imported without beats have no SD1/SD2.
- **Sources (G).** Brennan 2001, https://doi.org/10.1109/10.959330; Ciccone 2017, https://doi.org/10.1002/mus.25573.

### Baevsky stress index

- **What.** A histogram index of how rigid the rhythm is.
- **How.** Clean intervals go into **50 ms** bins on a fixed grid ([0, 50), [50, 100) … ms). SI = AMo / (2 · Mo ·
  MxDMn), with Mo the centre of the fullest bin in seconds (lowest bin on a tie), AMo the % of intervals in it, and
  MxDMn the range max − min in seconds. Needs at least 30 clean beats. No square root is taken.
- **Interpretation.** **Shown for reference only.** It mostly repeats resting HR and SD2 and is coarse at 2 minutes
  (Mo moves in 50 ms steps), so Stress does not use it. Values are only comparable with the same bin width; resting
  values differ widely between people, and no reference range is claimed.
- **Sources (H).** Baevsky & Chernikova 2017, https://doi.org/10.12710/cardiometry.2017.10.6676 (existence verified,
  numbers unverified); Brisinda 2024, https://doi.org/10.36922/bh.3503.

### Spectrum: VLF, LF, HF, LF/HF and normalised units

- **What.** How the variability splits by speed: VLF 0.003–0.04 Hz, LF 0.04–0.15 Hz (mainly blood-pressure
  regulation), HF 0.15–0.40 Hz (breathing speed, 9–24 breaths/min).
- **How.** A Lomb-Scargle periodogram of the clean RR values at their real beat times (reconstructed from the
  cumulative RR sum), so no interpolation is needed and a rejected beat is simply a missing sample. Only the mean is
  removed (no detrending). The grid runs from 0.003 to 0.50 Hz in 0.002 Hz steps and is scaled so that the integral
  equals the RR variance; band powers (ms²) are the sums over each band. LF/HF = LF / HF; normalised units
  LF nu = 100 · LF / (LF + HF), HF nu likewise. Computed when there are at least 30 clean beats over at least 60 s.
- **Interpretation.** HF and LF power and LF/HF are stored and shown in the morning's detail (the Mac tool also shows
  LF nu). **LF and LF/HF are indicative only from 2 minutes**: a 2-minute recording holds only about five LF cycles,
  and LF/HF shifts strongly with breathing. When breathing is below 9 breaths/min the detail view says "Slow
  breathing: LF/HF is not interpretable this morning." VLF is computed but neither stored nor shown, since it needs
  about 5 minutes. The verdict uses none of these. The HF band is not capped at the mean Nyquist frequency (0.375 Hz
  at 45 bpm), a known small gap.
- **Sources (D, E, J).** Bands: Task Force 1996, https://doi.org/10.1161/01.CIR.93.5.1043. Minimum durations (1 min
  HF, 2 min LF, 5 min VLF): Shaffer & Ginsberg 2017 (above); LF needed 4 min: Bourdillon 2017,
  https://doi.org/10.3389/fnins.2017.00456. Lomb-Scargle on beat times: Laguna 1998,
  https://doi.org/10.1109/10.678605; Clifford & Tarassenko 2005 (above). LF/HF and breathing: Brown 1993,
  https://doi.org/10.1152/jappl.1993.75.5.2310; Saboul 2013, https://doi.org/10.1080/17461391.2013.767947; Saboul
  2014, https://doi.org/10.1080/17461391.2012.691116. LF/HF is not a sympatho-vagal balance: Billman 2013,
  https://doi.org/10.3389/fphys.2013.00026.

### Breathing rate

- **What.** Breaths per minute, estimated from the spectrum.
- **How.** The highest spectral bin between **0.10 Hz** (6/min) and **min(0.50 Hz, mean HR / 120)**, the mean
  Nyquist frequency of a once-per-beat series (25/min at 50 bpm), times 60. A peak in the first or last bin of that
  window means breathing outside it or no clear rhythm, and the value is left **blank**.
- **Interpretation.** A check on the measurement: a morning with unusually fast or slow breathing is less comparable
  with the others. Below 9/min, breathing-driven variation moves into the LF band and LF/HF is not interpretable
  (see above). Trends leave mornings without a peak out of the breathing chart. Not used by the verdict.
- **Sources (E, J).** Laguna 1998 (above); Shaffer & Ginsberg 2017 (above); Saboul 2014 (above).

### Personal baseline (your normal)

- **What.** The mean and standard deviation of lnRMSSD and of resting HR over your recent mornings.
- **How.** The mornings of the previous **60 days**, today excluded, one per calendar day. Low-confidence mornings
  are left out once the window holds at least **7** clean ones. Verdicts need at least **7** baseline mornings
  ("building baseline" until then, so the first verdict comes on the eighth morning) and are **provisional** while
  the baseline holds fewer than **14**: same rules, plus a note and a *Provisional* badge. SD floors avoid absurdly
  narrow ranges in very stable people: **0.05** for lnRMSSD and ln SD2, **1.5 bpm** for resting HR. In the app, a
  baseline reset starts a fresh baseline period; earlier mornings keep their verdicts, and the reset can be undone.
- **Interpretation.** Everything below is relative to this baseline, so the method adapts to fitness changes.
- **Sources (A, B).** Plews built the normal range from two weeks of mornings: Plews 2012 (above); Plews 2014,
  https://doi.org/10.1123/ijspp.2013-0455. Javaloyes 2019 used a 4-week baseline:
  https://doi.org/10.1123/ijspp.2018-0122. The 60-day window, the 7-morning start and the SD floors are this
  project's choices.

### Normal range (±0.5 SD)

- **What.** Baseline mean ± **0.5** SD, for lnRMSSD and for resting HR.
- **How.** Shown as the green band in the why-rows and Trends.
- **Interpretation.** The smallest change that matters. The 7-day average is judged against it. A single morning's
  HRV is judged against a wider band (−1 SD, see the verdict); today's HRV between −0.5 and −1 SD reads "within the
  day-to-day noise" and its marker stays green.
- **Sources (A).** Smallest worthwhile change of 0.5 × the individual variation: Plews 2012 (above), following
  Hopkins 2009 (above). The ±0.5 SD-of-daily-values form is the one used by Altini; scaled to SD rather than CV it
  is close to Plews' version.

### 7-day average

- **What.** Mean lnRMSSD over the last seven calendar days, today included.
- **How.** Earlier low-confidence mornings are left out by the same rule as the baseline. It is always shown, but
  it can flag fatigue only when at least **3** mornings fall in the seven days.
- **Interpretation.** Below the ±0.5 SD range means fatigue has been building up over several days: MODERATE, with
  a note to plan an easier week.
- **Sources (A, B, L).** Weekly lnRMSSD tracked performance changes, single days did not: Plews 2013 (IJSPP, above).
  Three randomly spread mornings a week reproduce the weekly picture: Plews 2014 (above). Guided training on the
  7-day average: Vesterinen 2016, https://doi.org/10.1249/MSS.0000000000000910; Javaloyes 2019 (above).

### z-scores

- **What.** Today's distance from your normal in your own standard deviations.
- **How.** z_HRV = (lnRMSSD today − baseline mean) / baseline SD; z_HR = (resting HR today − baseline mean) /
  baseline SD (positive = heart faster than usual). Sample SDs with the floors above.
- **Interpretation.** They drive the verdict, the score and the illness flag, and appear in the Mac readiness panel
  and in Insights' tag effects.
- **Sources (A).** Hopkins 2009; Buchheit 2014 (above).

### Verdict: REST, MODERATE, READY

- **How.** Checked in this order:

  | Verdict | Rule |
  |---|---|
  | **REST** | illness warning, or z_HRV ≤ −1.5, or z_HR ≥ +1.5, or z_HRV ≤ −1 together with z_HR ≥ +1 |
  | **MODERATE** | z_HRV ≤ −1, or z_HR > +1, or the 7-day average below the normal range (with ≥ 3 mornings) |
  | **READY** | everything else |

- **Interpretation.** A single morning's HRV counts only from **−1 SD**, not from the edge of the ±0.5 SD range:
  with ordinary day-to-day noise about one morning in three falls below that edge. The 7-day average keeps the
  ±0.5 SD range. Extra notes: when HRV z ≥ +1.5 and HR z ≤ −1.5 together, the app notes that this usually means good
  recovery but can mean overreaching if you feel flat; low confidence and provisional verdicts add their own notes.
- **Sources (A, L).** Kiviniemi 2007 (high intensity unless HRV fell below the mean − 1 SD),
  https://doi.org/10.1007/s00421-007-0552-2; Plews 2012/2013 (above). Meta-analyses suggest fewer unnecessary hard
  sessions with similar or slightly better gains, not clearly better performance: Düking 2021,
  https://doi.org/10.1016/j.jsams.2021.04.012; Manresa-Rocamora 2021, https://doi.org/10.3390/ijerph181910299. The
  ±1.5 SD REST limits and the combined rule are this project's choices.

### Readiness score

- **What.** A 0–100 summary of the morning; 75 is your normal.
- **How.** score = 75 + 15 · (0.65 · z_HRV − 0.35 · z_HR), rounded and clipped to 0–100. HRV 1 SD above normal adds
  about 10 points; resting HR 1 SD above takes about 5 off.
- **Interpretation.** The verdict colour comes from the rules above, not from the score. **The 0.65/0.35 weights and
  the 75 ± 15 scaling are this app's design choice, not part of a published method** (evidence.md, recommendation
  10).

### Illness signal and warning

- **How.** A morning is **flagged** (`illness_signal`) when resting HR is at least **+4 bpm** above normal and either
  z_HR ≥ **+1.5** with z_HRV ≤ **−1**, or z_HR ≥ **+2.5** on its own. The **warning** ("Possible illness", a REST
  day) needs **2 flagged mornings in a row**: consecutive calendar days, each judged against its own baseline; a day
  without a measurement ends the streak.
- **Interpretation.** A single flagged morning only adds a note (one morning like this can be alcohol, poor sleep,
  travel or stress) and the verdict follows the usual rules. The pattern often appears one to three days before a
  cold or other infection, but alcohol, poor sleep, travel and stress produce it too. For training decisions, not a
  diagnosis. **The thresholds are heuristics, not taken from a study**; tune them with `hrmon analyze` against
  `sick` tags.
- **Sources (C).** Mishra 2020 (above); Alavi 2022, https://doi.org/10.1038/s41591-021-01593-2 (multi-day logic,
  false alarms from stress, alcohol and travel); Altini & Plews 2021, https://doi.org/10.3390/s21237932 (sickness
  days averaged +6 % resting HR and −10 % HRV in morning readings; alcohol similar). The large studies used
  overnight or all-day data, not a 2-minute morning reading.

### Regeneration and Stress (0–10)

- **What.** Two indices against the same 60-day, clean-only baseline as the verdict. **Regeneration** is your HRV
  against your own normal; higher = better recovered. **Stress** is strain or load on your system; higher = more
  strain than usual.
- **How.** Regeneration z = z(lnRMSSD). Stress z = ⅔ · z(resting HR) + ⅓ · −z(ln SD2); mornings without SD2
  (imported rows) use resting HR alone. Each component needs today's value and at least 7 baseline values. Value =
  5 + 2 · z, clipped to 0–10 and rounded to one decimal: **5 = your normal**, 4–6 = ±0.5 SD (green band), 2 points
  = 1 SD. The app distinguishes better than normal, normal (4–6), more than 1 point worse and more than 3 points
  (1.5 SD) worse. They do not change the verdict.
- **Interpretation.** Nothing else goes into Regeneration: SD1 is RMSSD/√2 and mean RR is the reciprocal of HR, so
  adding them would count the same information twice. The SD2 part of Stress is Naranjo Orellana's Stress Score
  1000/SD2 on the log scale. Stress is **not** a measure of sympathetic activity: no index from a short resting
  recording validly measures that. Baevsky's index is not used (see above).
- **Sources (G, H, I).** Brennan 2001; Ciccone 2017 (above); Naranjo Orellana 2015,
  https://doi.org/10.1123/ijspp.2014-0235; Billman 2013 (above); Martelli 2014 (above); Goldstein 2011,
  https://doi.org/10.1113/expphysiol.2010.056259; Laborde, Altini, Mosley & Plews 2026 (Human Kinetics excerpt),
  https://us.humankinetics.com/blogs/excerpt/does-hrv-represent-sympathetic-nervous-system-activity. The ⅔/⅓
  weights and the 5 + 2·z scale are this project's choices; the support for the SD2 part is low (evidence.md I).

### "% vs average" and "% since last" chips

- **What.** Small chips under the rings and the HRV / resting-HR rows, e.g. "▲ 8 % vs avg", "▼ 1 % since last
  measurement".
- **How.** *vs average* compares with the baseline mean; *since last* with the previous measured morning.
  - HRV: the % is of **RMSSD**, 100 · (e^(Δ lnRMSSD) − 1), not of the log value.
  - Resting HR: plain % of bpm.
  - Regeneration and Stress: % of the 0–10 value; the average is 5 by definition, and "since last" compares with the
    previous morning's value.

  Rounded to whole %; 0 % reads "= your average" / "= same as last measurement". Green when the change is good
  (up for HRV and Regeneration, down for resting HR and Stress).
- **Interpretation.** Orientation only; they do not change the verdict. *vs average* needs a baseline; *since last* needs a
  previous morning (for Regeneration and Stress, one that already had a value).

### Day-to-day CV of lnRMSSD

- **What.** How much your lnRMSSD varies from morning to morning: SD / mean × 100, in %.
- **How.** Over all mornings in the current history (Insights › *Measurement quality*; `hrmon analyze` › *Your
  numbers*).
- **Interpretation.** About **3–13 %** is typical (most people 4–8 %). Much higher usually means an inconsistent
  protocol (time, posture, movement) rather than real change. Published values are mostly weekly CVs; this one spans
  the whole history, so real trends make it read a little higher.
- **Sources (B).** Bellenger 2022, https://doi.org/10.3390/s22186723; Flatt & Esco 2015,
  https://doi.org/10.1123/ijspp.2014-0556; Plews 2014 (above); Al Haddad 2011,
  https://doi.org/10.1055/s-0031-1275356.

### Insights

The Insights tab is the user-facing half of `hrmon analyze` (`Packages/HRVCore/Sources/HRVCore/Insights.swift`). It
compares your mornings with each other and with the morning check-in (*How do you feel?* 1–5, and tags: poor sleep,
alcohol, feeling sick, hard training yesterday, stressed, late meal). The check-in never affects the verdict.
Insights sharpen over four weeks (28 check-ins).

| Card | How | Reading |
|---|---|---|
| Does the verdict match how you feel? | Mean feeling per verdict, and the Spearman rank correlation of score vs feeling. Appears after 7 scored mornings with a check-in; "first impression" below 14. | Correlation ≥ 0.3 "tracks", ≥ 0.1 "loosely", otherwise "not yet". The cut-offs are rules of thumb. |
| What moves your mornings | For each tag on at least 2 scored mornings (and 2 without): mean RMSSD in % vs your normal and mean resting HR in bpm vs your normal, against the other mornings. | Alcohol and poor sleep typically show HRV well below normal (Altini & Plews 2021). |
| Illness warning | Sick-tagged days with a warning within ±2 days (caught), without (missed), and warnings with no sick tag nearby. | Tells whether to trust the warning; tag sick days even without a warning. |
| Your routine | Mornings measured of the days spanned, typical (median) measurement time and the window half of them fall in, check-ins. Needs 3 mornings. | Flags times spread over more than an hour, or fewer than 70 % of days measured. |
| Measurement quality | Median and 90th-percentile rejected %, number of low-confidence mornings, day-to-day CV. Needs 3 mornings. | Flags more than one noisy morning in ten; CV against 3–13 %. |

### What goes to Apple Health

With *Save to Apple Health* on, each real measurement (from a sensor, or imported from the Mac tool; never demo or
replay data) writes two samples over the measurement's time span: **Heart Rate Variability as SDNN** (the HRV type
Apple Health uses, so it reads higher than the app's RMSSD) and **Resting Heart Rate** (the morning's mean HR). Each
sample carries a per-morning sync identifier, so saving twice replaces instead of duplicating, and deleting a morning
in the app removes its Health entries. RMSSD, the score and the verdict stay in the app; the app reads nothing from
Health.

## Mac tool `hrmon`

```bash
python3 -m venv .venv && .venv/bin/pip install -e .
```

Run it from **Terminal.app** (or another terminal that declares Bluetooth usage): macOS only lets processes whose
parent app declares Bluetooth usage talk to CoreBluetooth, and a Python launched from some other apps is killed with
`SIGABRT` / exit code 134. The first run shows a one-time "would like to use Bluetooth" prompt.

```bash
.venv/bin/hrmon scan                  # list heart-rate sensors in range, remember the strongest one
.venv/bin/hrmon dump                  # GATT table + 20 s of raw notifications (diagnostics)
.venv/bin/hrmon monitor               # live HR, RR, RMSSD/SDNN panel; logs sessions/<timestamp>.csv
.venv/bin/hrmon monitor --duration 600
.venv/bin/hrmon measure               # morning protocol: 60 s settle + 120 s (+ up to 60 s), verdict, appends sessions/readiness.csv
.venv/bin/hrmon measure --feeling 4 --tags poor_sleep,alcohol
.venv/bin/hrmon readiness             # today's verdict and the last 14 mornings
.venv/bin/hrmon analyze               # tuning report (see docs/tuning.md)
```

Options:

| Command | Options and defaults |
|---|---|
| all | `--address <CoreBluetooth UUID>` (default: the sensor saved by `scan`), `--name <text>` (advertised name contains it), `--scan-timeout 10` (s per scan) |
| `scan` | `--all` (every BLE device), `--wait MIN` (keep scanning up to MIN minutes), `--no-save` |
| `dump` | `--seconds 20`, `--wait MIN`, `--no-save` |
| `monitor` | `--duration` (s, unlimited by default), `--window 60` (rolling RMSSD window, s), `--out file.csv` |
| `measure` | `--duration 120`, `--settle 60` (both from `hrmon/protocol.py`), extension to 80 clean beats for at most 60 s more, `--window 60`, `--out`, `--feeling 1-5`, `--tags` (comma-separated: `poor_sleep`, `alcohol`, `sick`, `hard_training`, `stress`, `late_meal`) |
| `readiness` | `--days 14` |
| `analyze` | `--readiness sessions/readiness.csv`, `--beats readiness-beats.csv` (iPhone export; enables the artefact-filter check), `--sessions sessions/` (Mac per-session CSVs), `--alt KEY=VAL[,KEY=VAL]` (repeatable), `--include-demo`, `--markdown report.md` |

`monitor` and `measure` keep retrying until the sensor appears and reconnect automatically if it drops out of
range. Without `--alt`, `analyze` compares the current settings with these one-knob alternatives
(`DEFAULT_ALTERNATIVES` in `hrmon/analyze.py`): `range_sd=0.75`, `range_sd=0.35`, `w_hrv=0.8,w_hr=0.2`,
`w_hrv=0.5,w_hr=0.5`, `illness_z_hr=1.0,illness_bpm=3`, `baseline_days=30`, `low_quality_artefact_pct=15` (the old,
looser quality flag). Any field of `Params` in `hrmon/readiness.py` can be tried with `--alt`; the report never
changes the model.

### Files

- `sessions/<timestamp>.csv`: one row per RR interval, columns `timestamp_iso, elapsed_s, hr_bpm, rr_ms, contact,
  battery_pct` (rows with an empty `rr_ms` are notifications that carried no RR).
- `sessions/readiness.csv`: one row per morning measurement. The iPhone export (`readiness.csv`) and import use the
  same columns, in this order (`ReadinessCSV.columns` in `CSV.swift`):

  | Column | Content |
  |---|---|
  | `date` | end of the measurement, `YYYY-MM-DD HH:MM` |
  | `duration_s` | measured span of the clean beats, s |
  | `beats` | clean beats |
  | `mean_hr` | mean HR (resting HR), bpm |
  | `mean_rr_ms` | mean RR, ms |
  | `rmssd_ms`, `ln_rmssd` | RMSSD and lnRMSSD |
  | `sdnn_ms` | SDNN, ms |
  | `pnn50_pct` | pNN50, % |
  | `artefact_pct` | rejected beats, % |
  | `quality` | `good` < 5 %, `fair` < 15 %, else `poor` |
  | `lf_ms2`, `hf_ms2`, `lf_hf` | LF and HF power, LF/HF (empty when not computable) |
  | `breathing_bpm` | breathing rate, empty when unresolved |
  | `settle_s` | settle period used, s |
  | `feeling` | check-in 1–5 (tuning only) |
  | `tags` | check-in tags separated by `;` (tuning only) |
  | `source` | `band`, `import`, `replay` or `demo` (empty in older Mac rows) |
  | `sd1_ms`, `sd2_ms` | Poincaré SD1 and SD2, ms |
  | `stress_index` | Baevsky's stress index |

  New columns are only ever appended at the end; Python ignores unknown columns. If a day has several rows, the one
  with the lowest `artefact_pct` counts.
- `readiness-beats.csv` (iPhone export): `date, elapsed_s, rr_ms`, every received interval including rejected ones,
  so `hrmon analyze` can re-run the artefact filter.
- `~/.config/hrmon/device.json`: the remembered sensor (override the path with `HRMON_CONFIG`).

`sessions/` and `exports/` are git-ignored.

## Pairing with other devices

- **Garmin watch / Edge**: Settings › Sensors & Accessories › Add New › Heart Rate. Prefer ANT+ (if the sensor has
  it) so the phone or Mac can use Bluetooth at the same time. Garmin uses RR for HRV status only from some sensors;
  heart rate works regardless.
- **Polar / Suunto / Coros watch**: Settings › Sensors (or General › Pair) › Heart rate sensor, with the sensor awake.
- **Bike computers and training apps** (Zwift, Wahoo, TrainerRoad, Rouvy): add a heart-rate sensor in the app's
  sensor/devices screen. Bluetooth or ANT+ both work.
- **iPhone / iPad**: do *not* pair in Settings › Bluetooth; LE heart-rate sensors never show up there. Pair inside
  the app. Any app that reads RR intervals from a standard sensor can compute HRV from it.

Remember the one-connection rule: close or disconnect the other app or watch before measuring with Readiness or
`hrmon`.

## Troubleshooting

- **Sensor not found**: check it is awake (armband blinking blue; chest strap worn with moistened electrodes) and
  charged, and that no phone app or watch holds it (force-quit the app or toggle the phone's Bluetooth off). Then
  power-cycle the sensor. On the Mac, `hrmon scan --wait 5` keeps looking for 5 minutes.
- **No RR / no HRV**: tighten the strap, move an armband a little further up the inner forearm, wait 10–20 s for
  the signal to settle. `hrmon dump` shows whether notifications carry RR (flag bit 4).
- **Many rejected beats / low confidence**: keep still, check the fit, keep the arm relaxed. The measurement extends
  by up to 60 s on its own; a reading with fewer than 30 clean beats is discarded.
- **Python killed with exit code 134 on the Mac**: run it from Terminal.app (see above).
- **App build refused on the phone**: trust the developer certificate again (Settings › General › VPN & Device
  Management); free-Apple-ID builds expire after 7 days.

## Tests and changing the method

Python is the reference. **Python first**: any change to the maths goes into `hrmon/` with unit tests, then the
golden fixtures are re-exported, then the Swift port is made to match.

```bash
.venv/bin/python -m unittest discover -s tests                     # Python reference
.venv/bin/python tools/export_fixtures.py                          # regenerate Packages/HRVCore/Tests/HRVCoreTests/Fixtures
cd Packages/HRVCore && swift test --scratch-path "$TMPDIR/hrvcore-build"   # Swift == Python on every fixture
```

Use a fresh scratch path outside the repository for `swift test`; the package's own `.build` folder has caused
problems before. Presentation-only rules (chips, index levels, week strip) live only in Swift, in
`HRVCore/Presentation.swift`, with their own tests. `hrmon/protocol.py` and `App/AppSettings.swift` hold the
measurement timing and must be changed together. After a month of mornings, [`docs/tuning.md`](docs/tuning.md)
describes how to check and adopt other settings.

Plans and status: [`docs/ios-app-plan.md`](docs/ios-app-plan.md) (architecture), the other files in `docs/`, and
[`docs/phone-checklist.md`](docs/phone-checklist.md) (on-phone checks).

## Sources

Every rule and number above is checked against the published literature, with full references and the places where
the app departs from it, in [`docs/evidence.md`](docs/evidence.md). How to tune the defaults on your own data is in
[`docs/tuning.md`](docs/tuning.md).
