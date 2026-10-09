"""Readiness and illness assessment from the daily morning HRV history.

Method (Plews & Buchheit; Altini / HRV4Training):
  * one value per day: lnRMSSD and resting HR from the morning measurement
  * baseline = mean and SD over the previous `baseline_days` (default 60) days, excluding today; low-quality
    mornings are left out of it (and of the 7-day average) once at least `min_baseline_days` clean ones exist
  * normal range = mean ± 0.5 SD (the "smallest worthwhile change")
  * 7-day rolling average of lnRMSSD shows accumulated fatigue when it drops below the normal range; it only
    counts towards the verdict with at least `week_min_days` (3) mornings in the window (Plews 2014)
  * today's z-scores drive the verdict; a raised resting HR together with a lowered HRV often precedes an
    infection, but alcohol, poor sleep, travel and stress produce it too; it raises the illness warning
    (thresholds are heuristics, not taken from a study)
  * Regeneration and Stress (0–10, 5 = your normal, 4–6 = ±0.5 SD, 2 points = 1 SD), scored against the same
    personal, clean-only baseline as the verdict:
      Regeneration = z(lnRMSSD), your HRV against your own normal. SD1 is RMSSD/√2 and mean RR the reciprocal
        of HR, so neither adds information (Brennan 2001, Ciccone 2017).
      Stress = strain / load, ⅔ · z(resting HR) + ⅓ · −z(ln SD2): mostly resting HR, plus a smaller part from the
        long-term variability SD2, Naranjo Orellana's (2015) Stress Score 1000/SD2 on the log scale. Without SD2
        (imported rows) it is z(resting HR) alone. No index from a short resting recording measures sympathetic
        activity (Billman 2013, Martelli 2014), so Stress is not called "sympathetic".
    See docs/evidence.md, sections G, H and I.
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
    illness_z_hr_alone: float = 2.5  # or resting HR z ≥ this on its own (still ≥ illness_bpm above normal)
    rest_z_hrv: float = -1.5         # rest if HRV z ≤ this, or
    rest_z_hr: float = 1.5           # resting HR z ≥ this, or both of the "combined" limits below
    rest_combo_z_hrv: float = -1.0
    rest_combo_z_hr: float = 1.0
    moderate_z_hr: float = 1.0       # moderate if HRV below range, resting HR z > this, or 7-day average below range
    week_min_days: int = 3           # the 7-day average needs this many mornings before it can flag fatigue
    saturation_z: float = 1.5        # note when HRV z ≥ this and HR z ≤ −this
    low_quality_artefact_pct: float = 15.0
    low_quality_beats: int = 60
    # Regeneration / Stress (0–10): value = clip(index_center + index_scale · z, 0, 10).
    # Regeneration z = z(lnRMSSD) with ln_sd_floor; Stress z = weighted mean of z(resting HR) (hr_sd_floor) and
    # −z(ln SD2) (ln_sd2_sd_floor) over the components that are present.
    index_center: float = 5.0
    index_scale: float = 2.0
    stress_w_hr: float = 2 / 3
    stress_w_sd2: float = 1 / 3
    ln_sd2_sd_floor: float = 0.05    # ln SD2, like ln_sd_floor


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
    """Today's value against the baseline average and against the previous measured morning, in %.

    For HRV (`Assessment.ln_change`) the % is of RMSSD itself, 100 · (e^(Δ lnRMSSD) − 1), not of the log value."""
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
    week_n: int = 0                  # mornings in that 7-day mean; it flags fatigue only with ≥ week_min_days
    hr_mean: Optional[float] = None
    hr_sd: Optional[float] = None
    z_hrv: Optional[float] = None
    z_hr: Optional[float] = None
    illness: bool = False
    illness_streak: int = 0
    low_confidence: bool = False
    notes: list[str] = field(default_factory=list)
    range_sd: float = 0.5
    regeneration: Optional[float] = None   # 0–10, 5 = your normal; your HRV (lnRMSSD), high = better recovered
    stress: Optional[float] = None         # 0–10, 5 = your normal; strain / load, high = more strain than usual
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


def _finite(x: Optional[float]) -> Optional[float]:
    return x if x is not None and math.isfinite(x) else None


def _components(p: Params):
    """(value of a record or None, SD floor, sign, weight) per component; the order is part of the Swift parity."""
    regeneration = (
        (lambda r: _finite(r.ln_rmssd), p.ln_sd_floor, 1.0, 1.0),
    )
    stress = (
        (lambda r: _positive(r.mean_hr), p.hr_sd_floor, 1.0, p.stress_w_hr),
        # Naranjo's Stress Score 1000/SD2 on the log scale: ln SS = ln 1000 − ln SD2, so z(ln SS) = −z(ln SD2)
        (lambda r: math.log(r.sd2) if _positive(r.sd2) else None, p.ln_sd2_sd_floor, -1.0, p.stress_w_sd2),
    )
    return regeneration, stress


def ans_z(records: list[DayRecord], index: int, params: Params = DEFAULT_PARAMS) -> tuple[Optional[float], Optional[float]]:
    """Regeneration and Stress z: the weighted mean z-score of the components that today and at least
    `min_baseline_days` baseline days have. The baseline is the verdict's (`_baseline`: same 60-day window,
    today excluded, low-quality mornings left out once enough clean ones exist)."""
    p = params
    today = records[index]
    history, _ = _baseline(records, index, p)
    out = []
    for parts in _components(p):
        num = den = 0.0
        for get, floor, sign, weight in parts:
            v = get(today)
            hist = [x for x in (get(r) for r in history) if x is not None]
            if v is None or len(hist) < p.min_baseline_days:
                continue
            num += weight * sign * (v - statistics.fmean(hist)) / max(statistics.stdev(hist), floor)
            den += weight
        out.append(num / den if den > 0 else None)
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


def rmssd_pct(ln_value: Optional[float], ln_ref: Optional[float]) -> Optional[float]:
    """% change of RMSSD between two lnRMSSD values: 100 · (e^(ln_value − ln_ref) − 1)."""
    if ln_value is None or ln_ref is None:
        return None
    return 100.0 * (math.exp(ln_value - ln_ref) - 1.0)


def _baseline(records: list[DayRecord], index: int, p: Params) -> tuple[list[DayRecord], bool]:
    """The earlier mornings in the baseline window, and whether low-quality ones were left out: they are once
    at least `min_baseline_days` clean mornings exist, otherwise every morning counts."""
    today = records[index]
    history = [r for r in records[:index] if (today.day - r.day).days <= p.baseline_days]
    clean = [r for r in history if not r.low_quality_with(p)]
    return (clean, True) if len(clean) >= p.min_baseline_days else (history, False)


def _baseline_stats(base: list[DayRecord], p: Params) -> tuple[float, float, float, float]:
    """lnRMSSD mean and SD, resting HR mean and SD, with the SD floors."""
    ln_vals = [r.ln_rmssd for r in base]
    hr_vals = [r.mean_hr for r in base]
    return (statistics.fmean(ln_vals), max(statistics.stdev(ln_vals), p.ln_sd_floor),
            statistics.fmean(hr_vals), max(statistics.stdev(hr_vals), p.hr_sd_floor))


def _illness_rule(hr_gap: float, z_hrv: float, z_hr: float, p: Params) -> bool:
    """Resting HR at least illness_bpm above normal, and either raised together with a lowered HRV
    or far up on its own."""
    if hr_gap < p.illness_bpm:
        return False
    return (z_hr >= p.illness_z_hr and z_hrv <= p.illness_z_hrv) or z_hr >= p.illness_z_hr_alone


def _ill(records: list[DayRecord], index: int, p: Params) -> bool:
    """Only the illness flag of the record at `index`: no notes, streak or Regeneration/Stress, so walking
    back over a streak stays cheap."""
    base, _ = _baseline(records, index, p)
    if len(base) < p.min_baseline_days:
        return False
    ln_mean, ln_sd, hr_mean, hr_sd = _baseline_stats(base, p)
    r = records[index]
    return _illness_rule(r.mean_hr - hr_mean, (r.ln_rmssd - ln_mean) / ln_sd, (r.mean_hr - hr_mean) / hr_sd, p)


def assess(records: list[DayRecord], index: int = -1, baseline_days: Optional[int] = None,
           params: Params = DEFAULT_PARAMS) -> Assessment:
    """Assess the record at `index` against the records before it."""
    p = params if baseline_days is None else replace(params, baseline_days=baseline_days)
    if index < 0:
        index += len(records)
    today = records[index]
    history, clean_only = _baseline(records, index, p)
    a = Assessment(record=today, status=BASELINE, score=None, baseline_n=len(history),
                   low_confidence=today.low_quality_with(p), range_sd=p.range_sd)
    # today always counts, earlier mornings by the same rule as the baseline; shown with any number of mornings,
    # but it only flags fatigue with at least week_min_days of them
    week = [r.ln_rmssd for j, r in enumerate(records[:index + 1]) if 0 <= (today.day - r.day).days < 7
            and (j == index or not (clean_only and r.low_quality_with(p)))]
    a.ln_week = statistics.fmean(week) if week else None
    a.week_n = len(week)

    a.z_regeneration, a.z_stress = ans_z(records, index, p)
    a.regeneration, a.stress = scale_index(a.z_regeneration, p), scale_index(a.z_stress, p)
    prev = records[index - 1] if index > 0 else None
    prev_regen, prev_stress = (scale_index(z, p) for z in ans_z(records, index - 1, p)) if prev else (None, None)
    a.regeneration_change = Comparison(pct_change(a.regeneration, p.index_center), pct_change(a.regeneration, prev_regen))
    a.stress_change = Comparison(pct_change(a.stress, p.index_center), pct_change(a.stress, prev_stress))
    a.ln_change = Comparison(None, rmssd_pct(today.ln_rmssd, prev.ln_rmssd if prev else None))
    a.hr_change = Comparison(None, pct_change(today.mean_hr, prev.mean_hr if prev else None))

    if len(history) < p.min_baseline_days:
        # Today's morning counts: it joins the baseline of the next one.
        recorded = len(history) + 1
        if recorded >= p.min_baseline_days:
            a.notes.append(f"Baseline complete: {recorded} mornings recorded. "
                           "Your first verdict comes with the next morning.")
        else:
            a.notes.append(f"Building your baseline: {recorded} of {p.min_baseline_days} mornings recorded. "
                           "Verdicts start after a week of mornings measured the same way.")
        if a.low_confidence:
            a.notes.append(f"Noisy reading ({today.artefact_pct:.0f} % of beats rejected, {today.beats} clean beats). "
                           "Check that the sensor sits snugly with good skin contact and keep still, so your "
                           "baseline starts from clean mornings.")
        return a

    a.ln_mean, a.ln_sd, a.hr_mean, a.hr_sd = _baseline_stats(history, p)
    a.z_hrv = (today.ln_rmssd - a.ln_mean) / a.ln_sd
    a.z_hr = (today.mean_hr - a.hr_mean) / a.hr_sd        # positive = heart beating faster than usual
    a.ln_change = replace(a.ln_change, vs_average_pct=rmssd_pct(today.ln_rmssd, a.ln_mean))
    a.hr_change = replace(a.hr_change, vs_average_pct=pct_change(today.mean_hr, a.hr_mean))

    composite = p.w_hrv * a.z_hrv - p.w_hr * a.z_hr
    a.score = int(max(0, min(100, round(75 + 15 * composite))))

    # illness / systemic stress: raised resting HR together with suppressed HRV
    a.illness = _illness_rule(today.mean_hr - a.hr_mean, a.z_hrv, a.z_hr, p)
    if a.illness:
        # consecutive calendar days with the flag, walking back from today
        j = index
        while j > 0 and (records[j].day - records[j - 1].day).days == 1 and _ill(records, j - 1, p):
            j -= 1
        a.illness_streak = index - j + 1

    week_low = (a.ln_week is not None and len(week) >= p.week_min_days
                and a.ln_week < a.ln_mean - p.range_sd * a.ln_sd)

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
                           "This pattern often appears one to three days before a cold or other infection, "
                           "but alcohol, poor sleep, travel and stress produce it too. "
                           "Take it easy, drink enough, and watch for symptoms.")
        else:
            a.notes.append(f"Resting HR is {gap:.0f} bpm above your normal{days}, far outside your usual range. "
                           "Infection, alcohol, poor sleep, travel, heavy stress or a late meal can all do this. "
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
                       "Treat today's verdict with caution. Next time check that the sensor sits snugly with "
                       "good skin contact and keep still.")
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
