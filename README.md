# hrmon – use the Elonga armband as a normal heart-rate monitor

The Elonga band (made for mySASY by Fitcare, the same OEM behind the COOSPO HW9/HW807 armbands) is a
standard **Bluetooth LE Heart Rate Profile** sensor with **ANT+** on top. It is not locked to the Elonga app:
anything that can pair a Bluetooth or ANT+ heart-rate sensor can use it, and it sends **RR intervals**
(beat-to-beat times) so HRV can be computed from it.

Verified on this band (`Elonga-0007631`, software V2.8.5):

| Service | What it gives |
|---|---|
| Heart Rate 0x180D | HR every second, RR intervals when the band is worn (flag bit 4) |
| Battery 0x180F | battery % |
| Device Information 0x180A | manufacturer `MULL`, hardware V2.1, software V2.8.5 |
| User Data 0x181C | VO₂max estimate |
| Vendor 0xFD00 | Fitcare private channel, not needed |

RR intervals are only included once the optical signal is valid, i.e. when the band sits snugly on skin.
Lying on the desk it reports ~200 bpm with no RR, which is normal for optical sensors.

## The band itself

| Action / LED | Meaning |
|---|---|
| Short press | power on, starts measuring and advertising immediately (there is no separate pairing mode) |
| Long press | power off |
| Blue blinking | on and advertising / connecting |
| Red blinking | battery low, charge it |
| Blinking while on the magnetic charger | charging; solid green = full |

Wear it on the **inner forearm**, snug enough that it does not slide. One Bluetooth connection at a time:
if a phone app (including the Elonga app, which auto-connects in the background) holds the band, nothing
else will see it. ANT+ is broadcast and has no such limit, so a Garmin or bike computer can listen on ANT+
while the Mac uses Bluetooth.

## Mac tool

```bash
python3 -m venv .venv && .venv/bin/pip install -e .
```

Run it from **Terminal.app** (or the terminal panel in Claude): macOS only lets processes whose parent app
declares Bluetooth usage talk to CoreBluetooth; a Python launched from some other apps gets killed with
`SIGABRT` / exit code 134. The first run shows a one-time "would like to use Bluetooth" prompt.

```bash
.venv/bin/hrmon scan                 # list heart-rate bands in range, remember the strongest one
.venv/bin/hrmon dump                 # GATT table + 20 s of raw notifications (diagnostics)
.venv/bin/hrmon monitor              # live HR, RR, RMSSD/SDNN panel; logs sessions/<timestamp>.csv
.venv/bin/hrmon monitor --duration 600
.venv/bin/hrmon measure              # morning protocol: 60 s settle + 120 s (+ up to 60 s), verdict, appends sessions/readiness.csv
.venv/bin/hrmon readiness            # today's readiness / illness verdict and 14-day trend
```

Add `--wait 10` to `scan`/`dump` to keep scanning until the band is switched on. `monitor` and `measure`
keep retrying on their own and reconnect automatically if the band drops out of range.

Options: `--address <CoreBluetooth UUID>` or `--name Elonga` to pick a specific band, `--window 60` for the
rolling RMSSD window, `--out file.csv` for a custom log path.

Tests: `.venv/bin/python -m unittest discover -s tests`

### Files

- `sessions/<timestamp>.csv` – one row per RR interval: `timestamp_iso, elapsed_s, hr_bpm, rr_ms, contact, battery_pct`
  (rows with an empty `rr_ms` are notifications that carried no RR).
- `sessions/readiness.csv` – one row per `measure` run: mean HR, mean RR, RMSSD, lnRMSSD, SDNN, pNN50, artefact %, quality, LF, HF, LF/HF, breathing rate, check-in, Poincaré SD1/SD2 and Baevsky's stress index.
- `~/.config/hrmon/device.json` – the remembered band.

### Morning readiness and illness warning, Elonga-style

Elonga's score comes from a short resting HRV reading every morning compared with your own history.
`hrmon measure` reproduces that protocol and adds the verdict:

1. Right after waking, before coffee, phone or getting up: lie on your back, band snug on the inner forearm.
   Empty your bladder first, or always do the same (a full bladder raises blood pressure; Fagius 1989). The
   optical band measures pulse-rate variability, which agrees with ECG at rest but is more sensitive to arm
   movement (Schäfer & Vagedes 2013), so keep the arm still.
2. `hrmon measure` waits for the first heartbeat, discards 60 s to settle (about the minute the studies used;
   Flatt & Esco 2016, [`docs/evidence.md`](docs/evidence.md) K), then measures **120 s** (Elonga's duration). Use `--duration`/`--settle` to change it; keep it identical every day. When too many
   beats are rejected and fewer than 80 clean beats are in after the 120 s, it keeps measuring until 80 are in
   or for at most 60 s more; the panel then shows "extending · N more clean beats". Both limits live in
   `hrmon/protocol.py` (the iOS app mirrors them in `AppSettings`); the stored `duration_s` is the real
   measured span.
3. It prints time-domain HRV (RMSSD, lnRMSSD, SDNN, pNN50), frequency-domain HRV from a Lomb-Scargle
   spectrum of the beat series (LF and HF power, LF/HF, breathing rate from the spectral peak at 6–30
   breaths/min, but never above half the heart rate, the mean Nyquist frequency of a once-per-beat series
   (Laguna 1998); empty when there is no clear peak), appends a row to
   `sessions/readiness.csv`, and shows the readiness panel. `hrmon readiness` shows it again any time.
   Rejected beats are dropped, and the successive difference across a dropped beat is skipped by RMSSD, pNN50
   and SD1, so artefacts do not inflate them (Lipponen & Tarvainen 2019); SDNN and mean HR use every clean beat.

**How the verdict is computed** (`hrmon/readiness.py`), following the method used in sports science
(Plews & Buchheit) and apps such as HRV4Training:

- Baseline = mean and SD of **lnRMSSD** and **resting HR** over the previous 60 days (needs at least 7
  mornings; until then it reports "building baseline").
- Verdicts are **provisional** while the baseline holds 7 to 13 mornings and firm from 14 (`firm_baseline_days`):
  Plews built the normal range from two weeks of mornings (Plews 2012/2014; evidence.md A and B). A provisional
  verdict follows the same rules; it only adds a note ("Your normal range is still settling …") and a
  "Provisional" badge in the app.
- Normal range = mean ± 0.5 SD. The 7-day rolling lnRMSSD average is compared against it as well, because a
  slow drift below the range means accumulated fatigue even when single days look fine. It is always shown, but
  it can only flag fatigue once at least 3 mornings fall in the 7 days (`week_min_days`): Plews et al. 2014 found
  3 randomly spread mornings a week enough to reproduce the weekly picture.
- Today's deviation in SD units drives the verdict:
  **READY** inside the normal range, or HRV only slightly below it · **MODERATE** HRV at or below −1 SD, or HR
  above +1 SD, or weekly average below range · **REST** HRV at or below −1.5 SD, HR at or above +1.5 SD, both
  clearly off (HRV ≤ −1 SD with HR ≥ +1 SD), or the illness warning.
  A single morning's HRV only counts from −1 SD (`moderate_z_hrv`), not from the edge of the ±0.5 SD range: about
  one ordinary morning in three falls below that edge, and the HRV-guided training trials acted on the 7-day
  average or on single-day drops of at least 1 SD (Kiviniemi 2007; Plews 2012/2013; evidence.md A and L). The 7-day
  average keeps the ±0.5 SD range. The why-rows and charts still show the ±0.5 SD range; today's HRV between −0.5
  and −1 SD reads "within the day-to-day noise" and its marker stays green.
- Score 0–100 = 75 + 15 × (0.65·z_HRV − 0.35·z_HR), so 75 is your normal morning. The 0.65/0.35 weights and the
  75 ± 15 scaling are this app's design choice, not part of a published method.
- **Illness warning**: a morning is flagged when resting HR is at least +4 bpm above normal and either at least
  +1.5 SD while HRV is at least 1 SD below, or at least +2.5 SD on its own. The warning ("Possible illness", a REST
  day) needs **2 flagged mornings in a row** (`illness_min_days`); flagged days in a row are counted, and a day
  without a measurement ends the streak. A single flagged morning (`illness_signal`) only adds a note that one
  morning like this can be alcohol, poor sleep, travel or stress, and the verdict follows the usual rules. Resting
  HR up with HRV down often appears one to three days before a cold or other infection, but alcohol, poor sleep,
  travel and stress produce the same pattern, and the published detectors use multi-day logic (Mishra 2020,
  Alavi 2022, Altini & Plews 2021; evidence.md C). The thresholds are heuristics, not taken from a study, for
  training decisions, not a diagnosis.
- Measurements with > 5 % artefacts or < 60 beats are marked low confidence (15 % until 2026-10-09; many studies
  exclude recordings above about 5 %, evidence.md F). They still get a verdict, but
  once the 60-day window holds at least 7 clean mornings, low-confidence mornings are left out of the baseline
  (mean, SD, number of mornings) and of the 7-day average of later days; until then every morning counts.
- **Regeneration and Stress (0–10, 5 = your normal)**, both against the same 60-day, clean-only baseline as the
  verdict. **Regeneration** is your HRV, z(lnRMSSD), against your own normal. Nothing else is averaged in: SD1 is
  RMSSD/√2 and mean RR is the reciprocal of HR, so they would only count the same information twice (Brennan
  2001, Ciccone 2017). **Stress** is strain / load on your system: ⅔ · z(resting HR) + ⅓ · −z(ln SD2), mostly
  resting HR plus a smaller part from the long-term variability SD2. The SD2 part is Naranjo Orellana et al.'s
  (2015) Stress Score 1000/SD2 on the log scale; mornings without SD2 (imported rows) use resting HR alone. Stress
  is not a measure of sympathetic activity: no index from a short resting recording validly measures that
  (Billman 2013, Martelli 2014). Baevsky's stress index is still stored and shown, but not used: it mostly repeats
  HR and SD2. Value = 5 + 2·z, clipped to 0–10: 5 = your normal, 4–6 = ±0.5 SD, 2 points = 1 SD. They also come
  with "% vs average" and "% since last" comparisons (as do HRV, where the % is of RMSSD itself, e^Δln − 1, and
  resting HR). They do not change the verdict.

**Sources.** Every rule above, and where it departs from the literature, is checked against published studies in
[`docs/evidence.md`](docs/evidence.md): the lnRMSSD baseline and 7-day average (sections A, B), the illness
pattern (C), recording length and spectral limits (D, E, J), artefact handling (F), and the Regeneration/Stress
composition (G, H, I).

What Elonga calls "spectral analysis" maps onto the LF/HF numbers here, but their exact scoring is
proprietary; the model above is the published, open approach and is tuned to your own history, which is
what makes any of these scores work.

## iOS app (runs on iPhone; phases 1–6 tooling and Elonga-parity phase A done)

`ReadinessApp/` is the SwiftUI app (iOS 17+). Generate the project with XcodeGen and open it:

```bash
cd ReadinessApp && xcodegen generate && open ReadinessApp.xcodeproj
```

Screens: Today (week strip, Regeneration / Readiness / Stress rings with % vs average and since last, verdict, why-rows against your normal range, numbers), Measure (60 s settle + 120 s, extended by up to
60 s when too many beats are rejected, live HR and RR tachogram), Trends over 2 weeks to 1 year (lnRMSSD with normal band and 7-day average, resting HR, Regeneration, Stress, score, breathing),
History and per-morning detail (tachogram, Poincaré, spectrum), Settings (protocol, data source, CSV
import/export compatible with `sessions/readiness.csv`, demo data). On an iPhone it connects to the band over
CoreBluetooth (`Bluetooth/BLEHeartRateSource.swift`): press the band's button so it blinks blue, tap *Measure now*,
and the app finds the first heart-rate sensor, remembers it, and connects to that one first next time (Settings
› *Forget band* to switch). In the Simulator, or with *Use the Bluetooth band* off, it replays the recorded sessions
bundled in `ReadinessApp/Resources/Fixtures`.

Settings also has an optional morning reminder (skipped on days you already measured) and *Save to Apple
Health*, which writes HRV as SDNN plus resting heart rate. The app icon is generated by `swift tools/make_icon.swift`.
What still needs a hand on the phone is listed in `docs/phone-checklist.md`.

After each measurement the app asks *How do you feel?* (1–5 plus tags such as poor sleep or alcohol). The verdict
ignores it; after a month, `hrmon analyze` uses it to check whether the verdicts match how you felt and what other
settings would change (see `docs/tuning.md`):

```bash
.venv/bin/hrmon analyze --readiness readiness.csv --beats readiness-beats.csv --markdown report.md
```

Running on the phone: connect it by USB, tap *Trust* on the phone, turn on Developer Mode
(Settings › Privacy & Security › Developer Mode, restart), sign in to Xcode › Settings › Accounts with an Apple ID,
pick that Personal Team under the target's *Signing & Capabilities*, choose the iPhone as the run destination and
press Run. The first launch is refused until you trust the certificate on the phone: Settings › General › VPN &
Device Management › Developer App › your Apple ID › Trust. A free Apple ID build expires after 7 days; run again
from Xcode to re-sign. If Xcode shows the phone as "unsupported" after tapping Trust, open Window › Devices and
Simulators with the phone unlocked, or re-plug the cable; it finishes pairing there.


Plan: `docs/ios-app-plan.md`. Phase 1 is done: `Packages/HRVCore` is a Swift package that ports the Python
maths one-to-one (parser, artefact filter, time-domain and Lomb-Scargle spectral HRV, readiness/illness
assessment, CSV compatibility). Its tests compare against golden fixtures exported from Python:

```bash
.venv/bin/python tools/export_fixtures.py        # regenerate fixtures after changing the Python reference
cd Packages/HRVCore && swift test                # must stay green: Swift == Python on every fixture
```

Whenever the algorithm changes, change `hrmon/` first, re-export the fixtures, then make the Swift port match.

## Pairing with other devices

**Garmin watch / Edge** – Settings → Sensors & Accessories → Add New → Heart Rate. Prefer ANT+ so the Mac
or phone can use Bluetooth at the same time. Garmin stores RR for HRV status only from some sensors; HR
works regardless.

**Polar / Suunto / Coros watch** – Settings → Sensors (or General → Pair) → Heart rate sensor, with the band
on and blinking blue.

**Bike computer, Zwift, Wahoo, TrainerRoad, Rouvy** – add a heart-rate sensor in the app's sensor/devices
screen; the band appears as `Elonga-…`. Bluetooth or ANT+ both work.

**iPhone / iPad** – do *not* pair in Settings → Bluetooth (LE heart-rate sensors never show up there). Pair
inside the app. Apps that read RR intervals / HRV from any standard sensor: HRV4Training, Elite HRV,
Kubios HRV, HRV Logger. Plain heart rate: Polar Beat, Strava, Wahoo, Zwift, Apple's Fitness via third-party apps.

**Troubleshooting** – band not found: check it is blinking blue and that no phone app holds it (force-quit
Elonga or toggle the phone's Bluetooth off), then power-cycle the band. No RR / HRV: tighten the strap,
move it a little further up the inner forearm, wait 10–20 s for the signal to settle.
