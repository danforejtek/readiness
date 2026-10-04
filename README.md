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
.venv/bin/hrmon measure              # morning protocol: 15 s settle + 120 s, verdict, appends sessions/readiness.csv
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
2. `hrmon measure` waits for the first heartbeat, discards 15 s to settle, then measures **120 s**
   (Elonga's duration). Use `--duration`/`--settle` to change it; keep it identical every day.
3. It prints time-domain HRV (RMSSD, lnRMSSD, SDNN, pNN50), frequency-domain HRV from a Lomb-Scargle
   spectrum of the beat series (LF and HF power, LF/HF, breathing rate from the HF peak), appends a row to
   `sessions/readiness.csv`, and shows the readiness panel. `hrmon readiness` shows it again any time.

**How the verdict is computed** (`hrmon/readiness.py`), following the method used in sports science
(Plews & Buchheit) and apps such as HRV4Training:

- Baseline = mean and SD of **lnRMSSD** and **resting HR** over the previous 60 days (needs at least 7
  mornings; until then it reports "building baseline").
- Normal range = mean ± 0.5 SD. The 7-day rolling lnRMSSD average is compared against it as well, because a
  slow drift below the range means accumulated fatigue even when single days look fine.
- Today's deviation in SD units drives the verdict:
  **READY** inside the normal range · **MODERATE** HRV below −0.5 SD or HR above +1 SD or weekly average
  below range · **REST** HRV below −1.5 SD, HR above +1.5 SD, or both clearly off.
- Score 0–100 = 75 + 15 × (0.65·z_HRV − 0.35·z_HR), so 75 is your normal morning.
- **Illness warning**: resting HR at least +1.5 SD *and* +4 bpm above normal while HRV is at least 1 SD
  below, or HR above +2.5 SD on its own. This is the classic pattern a day or two before an infection shows
  symptoms; consecutive flagged days are counted. It is a heuristic for training decisions, not a diagnosis.
- Measurements with > 15 % artefacts or < 60 beats are marked low confidence.
- **Regeneration and Stress (0–10, 5 = your normal)**: Kubios-style PNS / SNS indices, but each part is compared
  with your own 60-day baseline instead of population norms. Regeneration averages the z-scores of mean RR, RMSSD
  and Poincaré SD1; Stress averages those of resting HR, √(Baevsky's stress index) and SD2 (reversed: less slow
  variation counts as more stress). Value = 5 + 2·z, clipped to 0–10, so 4–6 is your normal range. Mornings
  without beats use the parts they have. They also come with "% vs average" and "% since last" comparisons. They
  do not change the verdict.

What Elonga calls "spectral analysis" maps onto the LF/HF numbers here, but their exact scoring is
proprietary; the model above is the published, open approach and is tuned to your own history, which is
what makes any of these scores work.

## iOS app (runs on iPhone; phases 1–6 tooling and Elonga-parity phase A done)

`ReadinessApp/` is the SwiftUI app (iOS 17+). Generate the project with XcodeGen and open it:

```bash
cd ReadinessApp && xcodegen generate && open ReadinessApp.xcodeproj
```

Screens: Today (week strip, Regeneration / Readiness / Stress rings with % vs average and since last, verdict, why-rows against your normal range, numbers), Measure (15 s settle + 120 s, live HR
and RR tachogram), Trends over 2 weeks to 1 year (lnRMSSD with normal band and 7-day average, resting HR, Regeneration, Stress, score, breathing),
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
