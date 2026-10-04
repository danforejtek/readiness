"""Readiness and illness assessment from the daily morning HRV history.

Method (Plews & Buchheit; Altini / HRV4Training):
  * one value per day: lnRMSSD and resting HR from the morning measurement
  * baseline = mean and SD over the previous `baseline_days` (default 60) days, excluding today
  * normal range = mean ± 0.5 SD (the "smallest worthwhile change")
  * 7-day rolling average of lnRMSSD shows accumulated fatigue when it drops below the normal range
  * today's z-scores drive the verdict; a raised resting HR together with a lowered HRV is the
    classic early sign of infection or heavy systemic stress and raises the illness warning
  * Regeneration and Stress (0–10, 5 = your normal) follow the Kubios PNS/SNS indices, but each component is
    scored against the same personal baseline instead of population norms:
    Regeneration from mean RR, RMSSD and SD1; Stress from mean HR, √(Baevsky stress index) and SD2 (reversed)
This is a training-guidance heuristic, not a medical device.
"""
from __future__ import annotations

import math
import statistics
from dataclasses import dataclass, field, replace
from datetime import date, datetime
from typing import Optional

MIN_BASELINE_DAYS = 7
LN_SD_FLOOR = 0.05     # avoid absurdly narrow ranges in very stable people
HR_SD_FLOOR = 1.5      # bpm

READY, MODERATE, REST, BASELINE = "ready", "moderate", "rest", "baseline"

# Morning check-in, shared with the iOS app (CSV columns `feeling` 1–5 and `tags` separated by ";").
FEELINGS = {1: "awful", 2: "poor", 3: "ok", 4: "good", 5: "great"}
TAGS = ("poor_sleep", "alcohol", "sick", "hard_training", "stress", "late_meal")


@dataclass(frozen=True)
class Params:
    """Every tunable number of the model in one place. The defaults are the published method and must stay in
    sync with the Swift port (Packages/HRVCore/Sources/HRVCore/Readiness.swift); `hrmon analyze --set` tries
    alternatives without changing them."""
    baseline_days: int = 60          # look-back window for the personal baseline
    min_baseline_days: int = MIN_BASELINE_DAYS
    ln_sd_floor: float = LN_SD_FLOOR
    hr_sd_floor: float = HR_SD_FLOOR
    range_sd: float = 0.5            # normal range = mean ± range_sd · SD ("smallest worthwhile change")
    w_hrv: float = 0.65              # score = 75 + 15 · (w_hrv · z_HRV − w_hr · z_HR)
    w_hr: float = 0.35
    illness_z_hr: float = 1.5        # illness: resting HR z ≥ this and ≥ illness_bpm above normal …
    illness_bpm: float = 4.0
    illness_z_hrv: float = -1.0      # … while HRV z ≤ this,
    illness_z_hr_alone: float = 2.5  # or resting HR z ≥ this on its own
    rest_z_hrv: float = -1.5         # rest if HRV z ≤ this, or
    rest_z_hr: float = 1.5           # resting HR z ≥ this, or both of the "combined" limits below
    rest_combo_z_hrv: float = -1.0
    rest_combo_z_hr: float = 1.0
    moderate_z_hr: float = 1.0       # moderate if HRV below range, resting HR z > this, or 7-day average below range
    saturation_z: float = 1.5        # note when HRV z ≥ this and HR z ≤ −this
    low_quality_artefact_pct: float = 15.0
    low_quality_beats: int = 60
    # Regeneration / Stress (0–10): value = clip(index_center + index_scale · z, 0, 10), z = mean of component z-scores.
    # Each component has its own SD floor, like ln_sd_floor / hr_sd_floor above (mean HR reuses hr_sd_floor).
    index_center: float = 5.0
    index_scale: float = 2.0
    rr_sd_floor: float = 25.0        # ms, mean RR (≈ 1.5 bpm at 60 bpm)
    rmssd_sd_floor: float = 2.5      # ms (≈ ln_sd_floor at RMSSD 50 ms)
    sd1_sd_floor: float = 1.8        # ms (SD1 ≈ RMSSD / √2)
    sqrt_si_sd_floor: float = 0.2    # √SI, unitless
    sd2_sd_floor: float = 3.0        # ms


DEFAULT_PARAMS = Params()


@dataclass
class DayRecord:
    day: date
    when: datetime
    ln_rmssd: float
    rmssd: float
    mean_hr: float
    sdnn: float
    beats: int
    artefact_pct: float
    hf_ms2: Optional[float] = None
    lf_ms2: Optional[float] = None
    breathing_rate: Optional[float] = None
    feeling: Optional[int] = None          # 1–5 check-in, not used by the verdict (tuning only)
    tags: tuple[str, ...] = ()
    source: str = ""                       # band / import / replay / demo (empty for Mac rows)
    mean_rr: Optional[float] = None        # ms; the rest of these need the beats, so old Mac rows lack them
    sd1: Optional[float] = None            # Poincaré SD1, ms
    sd2: Optional[float] = None            # Poincaré SD2, ms
    stress_index: Optional[float] = None   # Baevsky's stress index

    @property
    def low_quality(self) -> bool:
        return self.low_quality_with(DEFAULT_PARAMS)

    def low_quality_with(self, p: "Params") -> bool:
        return self.artefact_pct > p.low_quality_artefact_pct or self.beats < p.low_quality_beats


@dataclass(frozen=True)
class Comparison:
    """Today's value against the baseline average and against the previous measured morning, in %."""
    vs_average_pct: Optional[float] = None
    vs_last_pct: Optional[float] = None


@dataclass
class Assessment:
    record: DayRecord
    status: str                      # ready | moderate | rest | baseline
    score: Optional[int]             # 0-100, 75 = your normal day; None while building the baseline
    baseline_n: int
    ln_mean: Optional[float] = None
    ln_sd: Optional[float] = None
    ln_week: Optional[float] = None  # 7-day rolling mean incl. today
    hr_mean: Optional[float] = None
    hr_sd: Optional[float] = None
    z_hrv: Optional[float] = None
    z_hr: Optional[float] = None
    illness: bool = False
    illness_streak: int = 0
    low_confidence: bool = False
    notes: list[str] = field(default_factory=list)
    range_sd: float = 0.5
    regeneration: Optional[float] = None   # 0–10, 5 = your normal, high = good (parasympathetic)
    stress: Optional[float] = None         # 0–10, 5 = your normal, high = bad (sympathetic)
    z_regeneration: Optional[float] = None
    z_stress: Optional[float] = None
    ln_change: Comparison = Comparison()
    hr_change: Comparison = Comparison()
    regeneration_change: Comparison = Comparison()   # "vs average" is against 5, the baseline by definition
    stress_change: Comparison = Comparison()

    @property
    def ln_range(self) -> Optional[tuple[float, float]]:
        if self.ln_mean is None:
            return None
        return self.ln_mean - self.range_sd * self.ln_sd, self.ln_mean + self.range_sd * self.ln_sd

    @property
    def hr_range(self) -> Optional[tuple[float, float]]:
        if self.hr_mean is None:
            return None
        return self.hr_mean - self.range_sd * self.hr_sd, self.hr_mean + self.range_sd * self.hr_sd


def _f(row: dict, key: str) -> Optional[float]:
    v = row.get(key)
    try:
        return float(v) if v not in (None, "") else None
    except ValueError:
        return None


def parse_tags(text: Optional[str]) -> tuple[str, ...]:
    return tuple(t.strip() for t in (text or "").split(";") if t.strip())


def records_from_rows(rows: list[dict]) -> list[DayRecord]:
    """Turn readiness.csv rows into one record per calendar day (the best-quality measurement wins)."""
    per_day: dict[date, DayRecord] = {}
    for row in rows:
        try:
            when = datetime.strptime(row["date"], "%Y-%m-%d %H:%M")
        except (KeyError, ValueError):
            continue
        ln = _f(row, "ln_rmssd")
        hr = _f(row, "mean_hr")
        if ln is None or hr is None:
            continue
        feeling = _f(row, "feeling")
        rec = DayRecord(
            day=when.date(), when=when, ln_rmssd=ln, rmssd=_f(row, "rmssd_ms") or 0.0, mean_hr=hr,
            sdnn=_f(row, "sdnn_ms") or 0.0, beats=int(_f(row, "beats") or 0),
            artefact_pct=_f(row, "artefact_pct") or 0.0, hf_ms2=_f(row, "hf_ms2"),
            lf_ms2=_f(row, "lf_ms2"), breathing_rate=_f(row, "breathing_bpm"),
            feeling=int(feeling) if feeling is not None else None,
            tags=parse_tags(row.get("tags")), source=(row.get("source") or "").strip(),
            mean_rr=_f(row, "mean_rr_ms"), sd1=_f(row, "sd1_ms"), sd2=_f(row, "sd2_ms"),
            stress_index=_f(row, "stress_index"),
        )
        prev = per_day.get(rec.day)
        if prev is None or rec.artefact_pct < prev.artefact_pct:
            per_day[rec.day] = rec
    return [per_day[d] for d in sorted(per_day)]


def _positive(x: Optional[float]) -> Optional[float]:
    return x if x is not None and x > 0 else None


def _components(p: Params):
    """(value of a record or None, SD floor, sign) per component; the order is part of the Swift parity."""
    regeneration = (
        (lambda r: _positive(r.mean_rr), p.rr_sd_floor, 1.0),
        (lambda r: _positive(r.rmssd), p.rmssd_sd_floor, 1.0),
        (lambda r: _positive(r.sd1), p.sd1_sd_floor, 1.0),
    )
    stress = (
        (lambda r: _positive(r.mean_hr), p.hr_sd_floor, 1.0),
        (lambda r: math.sqrt(r.stress_index) if _positive(r.stress_index) else None, p.sqrt_si_sd_floor, 1.0),
        (lambda r: _positive(r.sd2), p.sd2_sd_floor, -1.0),   # less long-term variability = more sympathetic
    )
    return regeneration, stress


def ans_z(records: list[DayRecord], index: int, params: Params = DEFAULT_PARAMS) -> tuple[Optional[float], Optional[float]]:
    """Regeneration and Stress z: the mean z-score of the components that today and at least
    `min_baseline_days` baseline days have (same 60-day window as the verdict, today excluded)."""
    p = params
    today = records[index]
    history = [r for r in records[:index] if (today.day - r.day).days <= p.baseline_days]
    out = []
    for parts in _components(p):
        zs = []
        for get, floor, sign in parts:
            v = get(today)
            hist = [x for x in (get(r) for r in history) if x is not None]
            if v is None or len(hist) < p.min_baseline_days:
                continue
            zs.append(sign * (v - statistics.fmean(hist)) / max(statistics.stdev(hist), floor))
        out.append(statistics.fmean(zs) if zs else None)
    return out[0], out[1]


def scale_index(z: Optional[float], params: Params = DEFAULT_PARAMS) -> Optional[float]:
    """z → 0–10 with 5 = your normal: round(clip(5 + 2·z, 0, 10), 1)."""
    if z is None:
        return None
    return round(min(10.0, max(0.0, params.index_center + params.index_scale * z)), 1)


def pct_change(value: Optional[float], ref: Optional[float]) -> Optional[float]:
    if value is None or ref is None or ref == 0:
        return None
    return 100.0 * (value - ref) / abs(ref)


def assess(records: list[DayRecord], index: int = -1, baseline_days: Optional[int] = None,
           params: Params = DEFAULT_PARAMS) -> Assessment:
    """Assess the record at `index` against the records before it."""
    p = params if baseline_days is None else replace(params, baseline_days=baseline_days)
    if index < 0:
        index += len(records)
    today = records[index]
    history = [r for r in records[:index] if (today.day - r.day).days <= p.baseline_days]
    a = Assessment(record=today, status=BASELINE, score=None, baseline_n=len(history),
                   low_confidence=today.low_quality_with(p), range_sd=p.range_sd)
    week = [r.ln_rmssd for r in records[:index + 1] if 0 <= (today.day - r.day).days < 7]
    a.ln_week = statistics.fmean(week) if week else None

    a.z_regeneration, a.z_stress = ans_z(records, index, p)
    a.regeneration, a.stress = scale_index(a.z_regeneration, p), scale_index(a.z_stress, p)
    prev = records[index - 1] if index > 0 else None
    prev_regen, prev_stress = (scale_index(z, p) for z in ans_z(records, index - 1, p)) if prev else (None, None)
    a.regeneration_change = Comparison(pct_change(a.regeneration, p.index_center), pct_change(a.regeneration, prev_regen))
    a.stress_change = Comparison(pct_change(a.stress, p.index_center), pct_change(a.stress, prev_stress))
    a.ln_change = Comparison(None, pct_change(today.ln_rmssd, prev.ln_rmssd if prev else None))
    a.hr_change = Comparison(None, pct_change(today.mean_hr, prev.mean_hr if prev else None))

    if len(history) < p.min_baseline_days:
        a.notes.append(f"Building your baseline: {len(history)} of {p.min_baseline_days} mornings recorded. "
                       "Verdicts start after a week of mornings measured the same way.")
        if a.low_confidence:
            a.notes.append(f"Noisy reading ({today.artefact_pct:.0f} % of beats rejected, {today.beats} clean beats). "
                           "Tighten the band on the inner forearm and keep still, so your baseline starts "
                           "from clean mornings.")
        return a

    ln_vals = [r.ln_rmssd for r in history]
    hr_vals = [r.mean_hr for r in history]
    a.ln_mean = statistics.fmean(ln_vals)
    a.ln_sd = max(statistics.stdev(ln_vals), p.ln_sd_floor)
    a.hr_mean = statistics.fmean(hr_vals)
    a.hr_sd = max(statistics.stdev(hr_vals), p.hr_sd_floor)
    a.z_hrv = (today.ln_rmssd - a.ln_mean) / a.ln_sd
    a.z_hr = (today.mean_hr - a.hr_mean) / a.hr_sd        # positive = heart beating faster than usual
    a.ln_change = replace(a.ln_change, vs_average_pct=pct_change(today.ln_rmssd, a.ln_mean))
    a.hr_change = replace(a.hr_change, vs_average_pct=pct_change(today.mean_hr, a.hr_mean))

    composite = p.w_hrv * a.z_hrv - p.w_hr * a.z_hr
    a.score = int(max(0, min(100, round(75 + 15 * composite))))

    # illness / systemic stress: raised resting HR together with suppressed HRV
    hr_up = a.z_hr >= p.illness_z_hr and today.mean_hr - a.hr_mean >= p.illness_bpm
    a.illness = (hr_up and a.z_hrv <= p.illness_z_hrv) or a.z_hr >= p.illness_z_hr_alone
    if a.illness:
        streak = 1
        for j in range(index - 1, max(-1, index - 4), -1):
            prev = assess(records, j, params=p) if j >= 0 else None
            if prev is None or not prev.illness:
                break
            streak += 1
        a.illness_streak = streak

    week_low = a.ln_week is not None and a.ln_week < a.ln_mean - p.range_sd * a.ln_sd

    if (a.illness or a.z_hrv <= p.rest_z_hrv or a.z_hr >= p.rest_z_hr
            or (a.z_hrv <= p.rest_combo_z_hrv and a.z_hr >= p.rest_combo_z_hr)):
        a.status = REST
    elif a.z_hrv < -p.range_sd or a.z_hr > p.moderate_z_hr or week_low:
        a.status = MODERATE
    else:
        a.status = READY

    if a.illness:
        gap = today.mean_hr - a.hr_mean
        days = f" for {a.illness_streak} days in a row" if a.illness_streak > 1 else ""
        if a.z_hrv <= p.illness_z_hrv:
            a.notes.append(f"Resting HR is {gap:.0f} bpm above your normal and HRV is below your normal{days}. "
                           "This combination often appears a day or two before a cold or other infection, "
                           "or after heavy stress. Take it easy, drink enough, and watch for symptoms.")
        else:
            a.notes.append(f"Resting HR is {gap:.0f} bpm above your normal{days}, far outside your usual range. "
                           "Infection, heavy stress, a late meal or alcohol can all do this. "
                           "Take it easy and watch for symptoms.")
    if week_low:
        a.notes.append("Your 7-day HRV average is below your normal range. Fatigue has been building up "
                       "over several days, so plan an easier week.")
    if a.z_hrv >= p.saturation_z and a.z_hr <= -p.saturation_z:
        a.notes.append("HRV is unusually high and resting HR unusually low. Usually that means good recovery. "
                       "If you still feel flat or heavy-legged, it can be a sign of overreaching after a hard "
                       "training block.")
    if a.low_confidence:
        a.notes.append(f"Noisy reading ({today.artefact_pct:.0f} % of beats rejected, {today.beats} clean beats). "
                       "Treat today's verdict with caution. Next time tighten the band on the inner forearm "
                       "and keep still.")
    if a.status == READY and not a.notes:
        a.notes.append("HRV and resting HR are within your normal range. A good day for a hard session.")
    elif a.status == MODERATE and not a.illness:
        a.notes.append("Slightly off your normal. Training is fine, but keep the intensity moderate "
                       "and listen to your body.")
    elif a.status == REST and not a.illness:
        a.notes.append("Clearly off your normal. Make it a recovery day with easy movement only.")
    return a


def assess_all(records: list[DayRecord], baseline_days: Optional[int] = None,
               params: Params = DEFAULT_PARAMS) -> list[Assessment]:
    return [assess(records, i, baseline_days, params) for i in range(len(records))]
