"""Export golden fixtures from the Python implementation for the Swift HRVCore tests.

Run from the project root:  .venv/bin/python tools/export_fixtures.py
"""
from __future__ import annotations

import csv
import json
import math
import random
from dataclasses import asdict
from datetime import date, datetime, timedelta
from pathlib import Path

from hrmon.ble import parse_hr_measurement
from hrmon.hrv import RRBuffer, compute_metrics, poincare, spectral_metrics, stress_index
from hrmon.readiness import DayRecord, assess_all

OUT = Path("Packages/HRVCore/Tests/HRVCoreTests/Fixtures")
OUT.mkdir(parents=True, exist_ok=True)


def clean(obj):
    """JSON has no NaN/inf: encode them as null (Swift side maps null back to .nan / .infinity)."""
    if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
        return None
    if isinstance(obj, dict):
        return {k: clean(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [clean(v) for v in obj]
    return obj


def dump(name: str, obj) -> None:
    (OUT / f"{name}.json").write_text(json.dumps(clean(obj), indent=1, allow_nan=False))
    print("wrote", name)


# --- parser --------------------------------------------------------------------------
cases = []
for hx in ["16480004" + "3403", "092c011000", "0041", "0038", "10385004", "103a3804d803", "1038b0048804", "00c9"]:
    s = parse_hr_measurement(bytes.fromhex(hx))
    cases.append({"hex": hx, "hr": s.hr, "contact": s.contact, "energy": s.energy_kj, "rr_ms": s.rr_ms})
dump("parser", cases)

# --- time domain ---------------------------------------------------------------------
td = []
rng_td = random.Random(7)
long_rr = [round(950 + 120 * math.sin(i / 3) + rng_td.gauss(0, 25), 1) for i in range(90)]
for rr in ([1000, 1050, 950, 1000, 1100, 900], [800.5, 812.3, 790.1, 805.0], [1000, 1000], [1000],
           [1010.0] * 18 + [960.0] * 8 + [1100.0] * 4, [960.0] * 15 + [1010.0] * 15, [1000.0] * 40, long_rr):
    m = compute_metrics(rr, duration_s=sum(rr[1:]) / 1000, artefacts=2)
    pc = poincare(rr)
    td.append({"rr": rr, "metrics": None if m is None else asdict(m), "poincare": None if pc is None else list(pc),
               "stress_index": stress_index(rr)})
dump("time_domain", td)

# --- RR buffer -----------------------------------------------------------------------
seq = [1000, 1010, 990, 1000, 2500, 1400, 1150, 1000, 250, 980, 1005]
b = RRBuffer()
inputs = []
t = 0.0
for v in seq:
    t += v / 1000
    inputs.append([v, t])
    b.add(v, t)
# packet-time behaviour: two intervals in one packet share t, and a gap forces a re-sync
b2 = RRBuffer()
packets = [[1000, 1.0], [500, 2.0], [500, 2.0], [1000, 10.0], [1000, 11.0]]
for v, tt in packets:
    b2.add(v, tt)
dump("rr_buffer", {
    "sequential": {"inputs": inputs, "values": b.values, "times": b.times, "beat_times": b.beat_times,
                   "artefacts": b.artefacts, "total": b.total, "window_2_5": b.window(2.5)},
    "packets": {"inputs": packets, "values": b2.values, "beat_times": b2.beat_times},
})

# --- spectral ------------------------------------------------------------------------
def series(freq, amp, base, length, noise=0.0, seed=1):
    rng = random.Random(seed)
    t, rr, clock = [], [], 0.0
    while clock < length:
        v = base + amp * math.sin(2 * math.pi * freq * clock) + (rng.gauss(0, noise) if noise else 0.0)
        clock += v / 1000
        t.append(clock)
        rr.append(v)
    return t, rr

spec = []
for freq, amp, base, length, noise in ((0.1, 50, 1000, 120, 0.0), (0.25, 40, 900, 150, 3.0), (0.3, 30, 800, 100, 5.0)):
    t, rr = series(freq, amp, base, length, noise)
    sp = spectral_metrics(t, rr)
    spec.append({"t": t, "rr": rr, "spectral": asdict(sp)})
spec.append({"t": [0, 1, 2], "rr": [1000, 1000, 1000], "spectral": None})
dump("spectral", spec)

# --- real sessions -------------------------------------------------------------------
sessions = []
for path in sorted(Path("sessions").glob("2026-*.csv")):
    beats = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if row["rr_ms"]:
                beats.append([float(row["rr_ms"]), float(row["elapsed_s"])])
    for settle in (0.0, 15.0):
        buf = RRBuffer()
        for rr, el in beats:
            if el >= settle:
                buf.add(rr, el)
        m = buf.metrics()
        sp = buf.spectral()
        sessions.append({"file": path.name, "settle_s": settle, "beats": beats,
                         "metrics": None if m is None else asdict(m),
                         "spectral": None if sp is None else asdict(sp),
                         "artefacts": buf.artefacts, "total": buf.total,
                         "poincare": None if poincare(buf.values) is None else list(poincare(buf.values)),
                         "stress_index": stress_index(buf.values)})
dump("sessions", sessions)

# --- readiness -----------------------------------------------------------------------
def beat_fields(ln, hr, wobble=0.0):
    """Beat-derived fields consistent with lnRMSSD and HR: SD1 ≈ RMSSD/√2, SD2 and the stress index move with HRV."""
    rmssd = math.exp(ln)
    return dict(mean_rr=60000.0 / hr, sd1=rmssd / math.sqrt(2) + wobble, sd2=1.6 * rmssd - 2 * wobble,
                stress_index=6000.0 / rmssd + 3 * wobble)

def make_history(n=30, ln=4.0, hr=52.0, start=datetime(2026, 9, 1, 7, 0), old_mac_days=5):
    recs = []
    for i in range(n):
        when = start + timedelta(days=i)
        w = (i * 7) % 5 - 2
        day_ln, day_hr = ln + w * 0.04, hr + ((i * 3) % 5 - 2) * 0.8
        # the first mornings are old Mac rows without beats: no mean RR, SD1, SD2 or stress index
        extra = {} if i < old_mac_days else beat_fields(day_ln, day_hr, wobble=((i * 3) % 4 - 1.5))
        recs.append(DayRecord(day=when.date(), when=when, ln_rmssd=day_ln, rmssd=55.0 + 1.5 * w,
                              mean_hr=day_hr, sdnn=60.0, beats=120, artefact_pct=2.0,
                              hf_ms2=1500.0 + i, lf_ms2=600.0, breathing_rate=13.0, **extra))
    return recs

def add_day(recs, ln, hr, beats=120, artefacts=2.0, gap_days=1, with_beats=True):
    when = recs[-1].when + timedelta(days=gap_days)
    recs.append(DayRecord(day=when.date(), when=when, ln_rmssd=ln, rmssd=math.exp(ln), mean_hr=hr,
                          sdnn=60.0, beats=beats, artefact_pct=artefacts, **(beat_fields(ln, hr) if with_beats else {})))
    return recs

recs = make_history()
recs = add_day(recs, 4.02, 52.5)            # ready
recs = add_day(recs, 3.85, 53.0)            # low HRV
recs = add_day(recs, 3.80, 60.0)            # illness day 1
recs = add_day(recs, 3.78, 61.0)            # illness day 2 (streak)
recs = add_day(recs, 4.0, 52.0, beats=40, artefacts=25.0, with_beats=False)   # low quality, imported row without beats
recs = add_day(recs, 4.3, 46.0)             # saturation note
recs = add_day(recs, 4.02, 61.0)            # resting HR far up, HRV normal: illness by HR alone
for _ in range(6):
    recs = add_day(recs, 3.93, 52.0)        # weekly average drifting below range
recs = add_day(recs, 4.0, 52.0, gap_days=70)   # after a long gap the baseline shrinks below 7 days

def rec_json(r: DayRecord):
    return {"when": r.when.strftime("%Y-%m-%d %H:%M"), "ln_rmssd": r.ln_rmssd, "rmssd": r.rmssd, "mean_hr": r.mean_hr,
            "sdnn": r.sdnn, "beats": r.beats, "artefact_pct": r.artefact_pct, "hf_ms2": r.hf_ms2,
            "lf_ms2": r.lf_ms2, "breathing_rate": r.breathing_rate, "mean_rr": r.mean_rr, "sd1": r.sd1, "sd2": r.sd2,
            "stress_index": r.stress_index}

def change_json(c):
    return [c.vs_average_pct, c.vs_last_pct]

def assess_json(a):
    return {"status": a.status, "score": a.score, "baseline_n": a.baseline_n, "ln_mean": a.ln_mean, "ln_sd": a.ln_sd,
            "ln_week": a.ln_week, "hr_mean": a.hr_mean, "hr_sd": a.hr_sd, "z_hrv": a.z_hrv, "z_hr": a.z_hr,
            "illness": a.illness, "illness_streak": a.illness_streak, "low_confidence": a.low_confidence,
            "notes": a.notes, "regeneration": a.regeneration, "stress": a.stress, "z_regeneration": a.z_regeneration,
            "z_stress": a.z_stress, "ln_change": change_json(a.ln_change), "hr_change": change_json(a.hr_change),
            "regeneration_change": change_json(a.regeneration_change), "stress_change": change_json(a.stress_change)}

dump("readiness", {"records": [rec_json(r) for r in recs], "assessments": [assess_json(a) for a in assess_all(recs)]})

# readiness.csv -> records grouping (best quality per day wins, bad rows skipped)
rows = [
    {"date": "2026-10-04 07:00", "ln_rmssd": "4.1", "mean_hr": "50", "rmssd_ms": "60", "sdnn_ms": "70", "beats": "100", "artefact_pct": "12"},
    {"date": "2026-10-04 07:05", "ln_rmssd": "4.0", "mean_hr": "51", "rmssd_ms": "55", "sdnn_ms": "60", "beats": "120", "artefact_pct": "2", "hf_ms2": "900", "breathing_bpm": "14.5"},
    {"date": "2026-10-05 06:50", "ln_rmssd": "3.9", "mean_hr": "53", "rmssd_ms": "49", "sdnn_ms": "58", "beats": "118", "artefact_pct": "4",
     "mean_rr_ms": "1132.1", "sd1_ms": "34.6", "sd2_ms": "72.0", "stress_index": "88.4"},
    {"date": "garbage", "ln_rmssd": "4.0", "mean_hr": "51"},
    {"date": "2026-10-06 07:00", "ln_rmssd": "", "mean_hr": "51"},
]
from hrmon.readiness import records_from_rows
dump("readiness_rows", {"rows": rows, "records": [rec_json(r) for r in records_from_rows(rows)]})
