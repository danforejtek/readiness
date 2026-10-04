# Tuning after a month of mornings (phase 6)

The model ships with the published defaults (Plews/Buchheit, HRV4Training style). After about a month of your
own mornings you can check whether they suit you, and change them on evidence instead of gut feeling.

## 1. Collect (every morning, 4 weeks)

- Measure right after waking, same position, same time window. The report flags measurement times that vary by
  more than an hour.
- After each measurement, fill in **How do you feel?** (1 awful … 5 great) and tick what applies: poor sleep,
  alcohol, feeling sick, hard training yesterday, stressed, late meal. It takes five seconds and is what the
  report compares the verdicts against. You can also add it later from History › the morning.
- Mark days when you are actually ill as **Feeling sick**, even if the app did not warn. Those are the cases
  that tell whether the illness warning is too strict or too loose.
- On the Mac, the same check-in works with `hrmon measure --feeling 4 --tags poor_sleep,alcohol`.

## 2. Export from the phone

Settings › Data › **Prepare CSV export** › **Share export**. It shares two files; AirDrop them to the Mac and put
them in the project folder, for example `exports/2026-11-04/`:

- `readiness.csv` – one row per morning, same columns as the Mac's `sessions/readiness.csv` plus `feeling`,
  `tags` and `source`
- `readiness-beats.csv` – every received interval, rejected ones included, so the artefact filter can be re-run

## 3. Run the report

```bash
.venv/bin/hrmon analyze --readiness exports/2026-11-04/readiness.csv --beats exports/2026-11-04/readiness-beats.csv --markdown exports/2026-11-04/report.md
```

Mac measurements: `--readiness sessions/readiness.csv --sessions sessions/`. Replayed and demo rows are ignored
unless `--include-demo` is given.

What the sections answer:

| Section | Question | Look for |
|---|---|---|
| Data | Is the protocol consistent? | ≥ 70 % of days measured, measurement times within an hour |
| Signal quality | Is the band reading cleanly? | median rejected beats < 5 %, few low-confidence mornings |
| Your numbers | Is the day-to-day noise normal? | lnRMSSD CV 3–8 % |
| Verdict vs how you felt | Do verdicts track how you feel? | mean feeling falls from ready → moderate → rest; score~feeling correlation above ~0.3 |
| Illness warning | Does it catch sick days without crying wolf? | missed sick days → loosen; warnings with no sick tag nearby → tighten |
| Context tags | Do alcohol / poor sleep show up as expected? | HRV z of tagged days clearly below the rest |
| Artefact filter | Does the result depend on the jump threshold? | small Δ at 15 % and 25 % |
| What if… | Would other settings fit you better? | higher score~feeling correlation without turning most mornings into warnings |

Try your own alternatives with `--alt`, one per comparison:

```bash
.venv/bin/hrmon analyze --readiness exports/2026-11-04/readiness.csv --alt range_sd=0.6 --alt "illness_z_hr=1.2,illness_bpm=3"
```

All tunable names are the fields of `Params` in `hrmon/readiness.py`. The artefact filter's jump threshold is
`max_deviation` of `RRBuffer` in `hrmon/hrv.py`.

## 4. Adopt a change (Python first, then Swift)

1. Change the default in `Params` (or `RRBuffer`) in `hrmon/`, and update the note texts if the meaning changed.
2. `.venv/bin/python -m unittest discover -s tests`, adjust tests that encode the old numbers.
3. `.venv/bin/python tools/export_fixtures.py` to regenerate the golden fixtures.
4. Make the same change in `Packages/HRVCore/Sources/HRVCore/Readiness.swift` (or `RRBuffer.swift`) until
   `swift test` in `Packages/HRVCore` passes again.
5. Rebuild and install the app. Your stored mornings are re-assessed automatically; nothing is lost, because
   verdicts are always computed from the raw values and beats.

Rules of thumb: change one knob at a time, prefer changes that move several weeks of evidence rather than one
memorable morning, and re-run the report a month later to confirm.
