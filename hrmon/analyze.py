"""Phase-6 tuning report: how well do the verdicts match a month of real mornings?

Inputs
  * readiness.csv – from the Mac (`sessions/readiness.csv`) or the iPhone export (Settings › Prepare CSV export),
    optionally with the check-in columns `feeling` (1–5) and `tags` (";"-separated, see readiness.TAGS)
  * beats – the iPhone's `readiness-beats.csv` (date, elapsed_s, rr_ms) and/or the Mac's per-session CSVs
    (`sessions/2026-*.csv`), used to re-run the artefact filter with other thresholds

Everything here is read-only: the report suggests changes, it never edits the model. To adopt a change, edit
`Params` defaults in readiness.py, re-export the fixtures and port the change to the Swift package.
"""
from __future__ import annotations

import csv
import math
import statistics
from dataclasses import dataclass, fields, replace
from datetime import datetime, timedelta
from pathlib import Path
from typing import Iterable, Optional

from .hrv import RRBuffer
from .readiness import (BASELINE, DEFAULT_PARAMS, MODERATE, READY, REST, TAGS, Assessment, DayRecord,
                        Params, assess_all, records_from_rows)

STATUSES = (READY, MODERATE, REST, BASELINE)
REAL_SOURCES = ("", "band", "import")          # Mac rows have no source column
DATE_FMT = "%Y-%m-%d %H:%M"

# Alternatives tried when the user gives none: one knob at a time, so each line answers one question.
DEFAULT_ALTERNATIVES = [
    "range_sd=0.75",                          # wider normal range: fewer "slightly off" days
    "range_sd=0.35",                          # narrower: more sensitive
    "w_hrv=0.8,w_hr=0.2",                     # score driven more by HRV
    "w_hrv=0.5,w_hr=0.5",                     # HR as important as HRV
    "illness_z_hr=1.0,illness_bpm=3",         # earlier illness warning
    "baseline_days=30",                       # faster-adapting baseline
    "low_quality_artefact_pct=10",            # stricter quality flag
]


# --------------------------------------------------------------------------------------------- loading

def read_rows(path: Path) -> list[dict]:
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def filter_rows(rows: list[dict], include_demo: bool = False) -> list[dict]:
    """Drop replayed recordings and demo data unless asked; they would distort a tuning report."""
    if include_demo:
        return rows
    return [r for r in rows if (r.get("source") or "").strip() in REAL_SOURCES]


Beats = list[tuple[float, float]]   # (elapsed_s, rr_ms), all received intervals including artefacts


def read_beats_export(path: Path) -> dict[str, Beats]:
    """iPhone export: one row per received interval, keyed by the measurement's `date` (minute precision)."""
    out: dict[str, Beats] = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                out.setdefault(row["date"], []).append((float(row["elapsed_s"]), float(row["rr_ms"])))
            except (KeyError, ValueError):
                continue
    return out


def read_mac_sessions(directory: Path, rows: list[dict]) -> dict[str, Beats]:
    """Mac per-session CSVs, matched to readiness rows: a row's `date` is written when the measurement ends,
    so it must fall between the session's first and last timestamp (± 2 min)."""
    sessions = []
    for path in sorted(directory.glob("*.csv")):
        if path.name == "readiness.csv":
            continue
        beats: Beats = []
        first = last = None
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                try:
                    ts = datetime.fromisoformat(row["timestamp_iso"])
                except (KeyError, ValueError):
                    continue
                first = first or ts
                last = ts
                if row.get("rr_ms"):
                    beats.append((float(row["elapsed_s"]), float(row["rr_ms"])))
        if beats and first and last:
            sessions.append((first, last, beats))
    out: dict[str, Beats] = {}
    for r in rows:
        try:
            when = datetime.strptime(r["date"], DATE_FMT)
        except (KeyError, ValueError):
            continue
        for first, last, beats in sessions:
            if first - timedelta(minutes=2) <= when <= last + timedelta(minutes=2):
                out[r["date"]] = beats
                break
    return out


# --------------------------------------------------------------------------------------------- statistics

def spearman(xs: list[float], ys: list[float]) -> Optional[float]:
    """Rank correlation (ties get average ranks). None when undefined."""
    if len(xs) < 3:
        return None

    def ranks(v: list[float]) -> list[float]:
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
                j += 1
            for k in range(i, j + 1):
                r[order[k]] = (i + j) / 2 + 1
            i = j + 1
        return r

    rx, ry = ranks(xs), ranks(ys)
    mx, my = statistics.fmean(rx), statistics.fmean(ry)
    sxy = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    sxx = sum((a - mx) ** 2 for a in rx)
    syy = sum((b - my) ** 2 for b in ry)
    return sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else None


def quantile(xs: list[float], q: float) -> float:
    s = sorted(xs)
    if not s:
        return float("nan")
    pos = (len(s) - 1) * q
    lo, hi = math.floor(pos), math.ceil(pos)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def parse_alternative(text: str) -> Params:
    """'range_sd=0.75,w_hrv=0.8' → Params with those fields changed (types follow the defaults)."""
    known = {f.name: f for f in fields(Params)}
    changes = {}
    for part in text.split(","):
        if not part.strip():
            continue
        key, _, value = part.partition("=")
        key = key.strip()
        if key not in known:
            raise ValueError(f"unknown parameter {key!r}; known: {', '.join(known)}")
        default = getattr(DEFAULT_PARAMS, key)
        changes[key] = type(default)(float(value)) if isinstance(default, int) else float(value)
    return replace(DEFAULT_PARAMS, **changes)


# --------------------------------------------------------------------------------------------- report

@dataclass
class Section:
    title: str
    columns: list[str]
    rows: list[list[str]]
    note: str = ""


def _fmt(x: Optional[float], digits: int = 2) -> str:
    return "–" if x is None or (isinstance(x, float) and math.isnan(x)) else f"{x:.{digits}f}"


def overview(rows: list[dict], records: list[DayRecord]) -> Section:
    if not records:
        return Section("Data", ["", ""], [["mornings", "0"]], "No usable rows.")
    first, last = records[0].day, records[-1].day
    span = (last - first).days + 1
    # minutes after 04:00, so measurements just before and after midnight count as close together
    minutes = [(r.when.hour * 60 + r.when.minute - 240) % 1440 for r in records]
    med = (quantile(minutes, 0.5) + 240) % 1440
    iqr = quantile(minutes, 0.75) - quantile(minutes, 0.25)
    sources: dict[str, int] = {}
    for r in rows:
        key = (r.get("source") or "mac").strip() or "mac"
        sources[key] = sources.get(key, 0) + 1
    checked_in = sum(1 for r in records if r.feeling is not None)
    out = [
        ["Mornings (one per day)", f"{len(records)} of {span} days ({len(rows)} rows)"],
        ["Period", f"{first} – {last}"],
        ["Typical measurement time", f"{int(med) // 60:02d}:{int(med) % 60:02d}, middle half within {iqr:.0f} min"],
        ["Sources", ", ".join(f"{k} {v}" for k, v in sorted(sources.items()))],
        ["Check-ins (feeling)", f"{checked_in} of {len(records)}"],
    ]
    note = ""
    if iqr > 60:
        note = "Measurement times vary by more than an hour; HRV changes over the morning, so measure at a fixed point."
    elif span and len(records) / span < 0.7:
        note = "Fewer than 70 % of days measured; gaps make the 7-day average and illness streaks less reliable."
    return Section("Data", ["", ""], out, note)


def quality(records: list[DayRecord], p: Params) -> Section:
    arts = [r.artefact_pct for r in records]
    beats = [r.beats for r in records]
    low = [r for r in records if r.low_quality_with(p)]
    rows = [
        ["Rejected beats, median / 90th percentile", f"{_fmt(quantile(arts, .5), 1)} % / {_fmt(quantile(arts, .9), 1)} %"],
        ["Clean beats, median / lowest", f"{quantile(beats, .5):.0f} / {min(beats) if beats else 0}"],
        ["Low-confidence mornings", f"{len(low)} ({', '.join(str(r.day) for r in low[:6])}{' …' if len(low) > 6 else ''})"],
    ]
    note = ""
    if arts and quantile(arts, .9) > p.low_quality_artefact_pct:
        note = "More than one morning in ten is noisy: check band position before tuning the model."
    return Section("Signal quality", ["", ""], rows, note)


def baseline_stats(records: list[DayRecord]) -> Section:
    ln = [r.ln_rmssd for r in records]
    hr = [r.mean_hr for r in records]
    rows = []
    if len(ln) >= 2:
        sd = statistics.stdev(ln)
        rows += [
            ["lnRMSSD mean ± SD", f"{statistics.fmean(ln):.2f} ± {sd:.2f}  (CV {100 * sd / statistics.fmean(ln):.1f} %)"],
            ["Resting HR mean ± SD", f"{statistics.fmean(hr):.1f} ± {statistics.stdev(hr):.1f} bpm"],
            ["lnRMSSD vs resting HR (rank corr.)", _fmt(spearman(ln, hr))],
        ]
    note = ("Typical day-to-day CV of lnRMSSD is about 3–13 % (most people 4–8 %). Much higher usually means an "
            "inconsistent protocol (time, posture, movement) rather than real changes. Published values are mostly "
            "weekly CVs; this one spans the whole history, so real trends make it read a little higher "
            "(docs/evidence.md, section B).")
    return Section("Your numbers", ["", ""], rows, note)


def verdicts(assessments: list[Assessment]) -> Section:
    counts = {s: 0 for s in STATUSES}
    for a in assessments:
        counts[a.status] += 1
    scored = [a.score for a in assessments if a.score is not None]
    ill = [a for a in assessments if a.illness]
    rows = [[s, str(counts[s])] for s in STATUSES]
    rows.append(["score median (10th–90th pct)",
                 f"{quantile(scored, .5):.0f} ({quantile(scored, .1):.0f}–{quantile(scored, .9):.0f})" if scored else "–"])
    rows.append(["illness warnings", ", ".join(f"{a.record.day} (day {a.illness_streak})" for a in ill) or "none"])
    return Section("Verdicts with current settings", ["", ""], rows)


def feeling_agreement(assessments: list[Assessment]) -> Section:
    pairs = [(a, a.record.feeling) for a in assessments if a.record.feeling is not None and a.score is not None]
    rows = []
    for s in (READY, MODERATE, REST):
        fs = [f for a, f in pairs if a.status == s]
        rows.append([s, str(len(fs)), _fmt(statistics.fmean(fs), 1) if fs else "–"])
    rho = spearman([float(a.score) for a, _ in pairs], [float(f) for _, f in pairs]) if pairs else None
    note = (f"Score vs feeling rank correlation: {_fmt(rho)} over {len(pairs)} mornings. "
            "Above ~0.3 the verdict tracks how you feel; near 0 it does not (yet).")
    if len(pairs) < 14:
        note += " Fewer than 14 check-ins: treat this as a first impression."
    return Section("Verdict vs how you felt (1 awful … 5 great)", ["verdict", "mornings", "mean feeling"], rows, note)


def illness_check(assessments: list[Assessment]) -> Section:
    sick = {a.record.day for a in assessments if "sick" in a.record.tags}
    flagged = {a.record.day for a in assessments if a.illness}

    def near(day, days) -> bool:
        return any(abs((day - d).days) <= 2 for d in days)

    hits = sorted(d for d in sick if near(d, flagged))
    missed = sorted(d for d in sick if not near(d, flagged))
    false = sorted(d for d in flagged if not near(d, sick))
    rows = [
        ["Sick days caught (warning within ±2 days)", ", ".join(map(str, hits)) or "–"],
        ["Sick days missed", ", ".join(map(str, missed)) or "–"],
        ["Warnings without a sick tag nearby", ", ".join(map(str, false)) or "–"],
    ]
    note = "Tag mornings as 'sick' when you are; misses suggest lowering illness_z_hr / illness_bpm."
    return Section("Illness warning", ["", ""], rows, note)


def tag_effects(assessments: list[Assessment]) -> Section:
    scored = [a for a in assessments if a.z_hrv is not None]
    rows = []
    for tag in TAGS:
        with_tag = [a for a in scored if tag in a.record.tags]
        if not with_tag:
            continue
        without = [a for a in scored if tag not in a.record.tags]
        rows.append([tag, str(len(with_tag)),
                     _fmt(statistics.fmean(a.z_hrv for a in with_tag)),
                     _fmt(statistics.fmean(a.z_hrv for a in without)) if without else "–",
                     _fmt(statistics.fmean(a.z_hr for a in with_tag)),
                     _fmt(statistics.fmean(a.z_hr for a in without)) if without else "–"])
    note = "z = standard deviations from your normal. Alcohol and poor sleep typically show HRV z well below 0."
    return Section("Context tags", ["tag", "mornings", "HRV z (tag)", "HRV z (others)", "HR z (tag)", "HR z (others)"],
                   rows, note if rows else "No tags recorded yet.")


def filter_sensitivity(rows: list[dict], beats: dict[str, Beats],
                       deviations: Iterable[float] = (0.15, 0.20, 0.25, 0.30)) -> Section:
    """Re-run the artefact filter per morning with other jump thresholds; compare lnRMSSD with the stored value."""
    out = []
    matched = [(r, beats[r["date"]]) for r in rows if r.get("date") in beats]
    for dev in deviations:
        deltas, arts = [], []
        for r, bs in matched:
            settle = float(r.get("settle_s") or 0)
            buf = RRBuffer(max_deviation=dev)
            for el, rr in bs:
                if el >= settle:
                    buf.add(rr, el)
            m = buf.metrics()
            if m is None or not math.isfinite(m.ln_rmssd):
                continue
            stored = float(r["ln_rmssd"])
            deltas.append(abs(m.ln_rmssd - stored))
            arts.append(m.artefact_pct)
        out.append([f"{dev * 100:.0f} %" + ("  (current)" if abs(dev - 0.20) < 1e-9 else ""), str(len(deltas)),
                    _fmt(quantile(deltas, .5), 3) if deltas else "–", _fmt(max(deltas), 3) if deltas else "–",
                    _fmt(quantile(arts, .5), 1) if arts else "–"])
    note = (f"{len(matched)} mornings with beat data. Small differences (< ~0.03) mean the result does not hinge on "
            "the threshold. Large ones mean it does: open those mornings' beat charts in the app and check whether the "
            "rejected beats (orange) look like real beats or like movement spikes before changing max_deviation.")
    return Section("Artefact filter: jump threshold", ["max jump", "mornings", "median |ΔlnRMSSD|",
                                                       "max |ΔlnRMSSD|", "median rejected %"], out, note)


def what_if(records: list[DayRecord], base: list[Assessment], alternatives: list[str]) -> Section:
    out = []
    base_by_day = {a.record.day: a for a in base}
    for text in alternatives:
        try:
            p = parse_alternative(text)
        except ValueError as e:
            out.append([text, "error", str(e), "", ""])
            continue
        alt = assess_all(records, params=p)
        changed = [a for a in alt if a.status != base_by_day[a.record.day].status]
        counts = {s: sum(1 for a in alt if a.status == s) for s in (READY, MODERATE, REST)}
        pairs = [(a.score, a.record.feeling) for a in alt if a.score is not None and a.record.feeling is not None]
        rho = spearman([float(s) for s, _ in pairs], [float(f) for _, f in pairs]) if pairs else None
        out.append([text, str(len(changed)), f"{counts[READY]} / {counts[MODERATE]} / {counts[REST]}",
                    str(sum(1 for a in alt if a.illness)), _fmt(rho)])
    base_pairs = [(a.score, a.record.feeling) for a in base if a.score is not None and a.record.feeling is not None]
    base_rho = spearman([float(s) for s, _ in base_pairs], [float(f) for _, f in base_pairs]) if base_pairs else None
    counts = {s: sum(1 for a in base if a.status == s) for s in (READY, MODERATE, REST)}
    out.insert(0, ["current settings", "0", f"{counts[READY]} / {counts[MODERATE]} / {counts[REST]}",
                   str(sum(1 for a in base if a.illness)), _fmt(base_rho)])
    note = ("A change is worth adopting when it raises the feeling correlation (or catches sick days) without "
            "turning most mornings into warnings. Adopt by editing Params in hrmon/readiness.py.")
    return Section("What if…", ["settings", "verdicts changed", "ready / moderate / rest", "illness days",
                                "score~feeling"], out, note)


def build_report(rows: list[dict], beats: dict[str, Beats], alternatives: list[str],
                 params: Params = DEFAULT_PARAMS) -> list[Section]:
    records = records_from_rows(rows)
    if not records:
        return [Section("Data", ["", ""], [["mornings", "0"]], "No usable rows in the readiness file.")]
    assessments = assess_all(records, params=params)
    sections = [overview(rows, records), quality(records, params), baseline_stats(records), verdicts(assessments),
                feeling_agreement(assessments), illness_check(assessments), tag_effects(assessments)]
    if beats:
        sections.append(filter_sensitivity(rows, beats))
    sections.append(what_if(records, assessments, alternatives))
    return sections


def to_markdown(sections: list[Section], title: str = "Readiness tuning report") -> str:
    lines = [f"# {title}", "", f"Generated {datetime.now():%Y-%m-%d %H:%M}.", ""]
    for s in sections:
        lines += [f"## {s.title}", ""]
        if s.rows:
            header = s.columns if any(s.columns) else ["", ""]
            lines.append("| " + " | ".join(header) + " |")
            lines.append("|" + "---|" * len(header))
            lines += ["| " + " | ".join(c.replace("|", "/") for c in r) + " |" for r in s.rows]
            lines.append("")
        if s.note:
            lines += [s.note, ""]
    return "\n".join(lines)

