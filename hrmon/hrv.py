"""RR-interval buffering, artefact filtering, time-domain and frequency-domain HRV metrics."""
from __future__ import annotations

import bisect
import math
import statistics
from collections import deque
from dataclasses import dataclass
from typing import Optional, Sequence

# Standard HRV frequency bands (Task Force 1996), Hz
VLF_BAND = (0.003, 0.04)
LF_BAND = (0.04, 0.15)
HF_BAND = (0.15, 0.40)


@dataclass
class HRVMetrics:
    n: int                 # clean RR intervals used
    duration_s: float      # time span covered by those intervals
    mean_rr: float         # ms
    mean_hr: float         # bpm, 60000 / mean_rr
    sdnn: float            # ms, standard deviation of RR
    rmssd: float           # ms, root mean square of successive differences
    ln_rmssd: float        # natural log of RMSSD (the usual "readiness" scale)
    pnn50: float           # % of successive differences > 50 ms
    artefacts: int = 0
    artefact_pct: float = 0.0


@dataclass
class SpectralMetrics:
    vlf_ms2: float
    lf_ms2: float
    hf_ms2: float
    total_ms2: float
    lf_hf: float
    lf_nu: float           # LF / (LF + HF) in %
    hf_nu: float
    hf_peak_hz: float
    breathing_rate_bpm: float   # HF peak frequency × 60, a rough respiration estimate


def compute_metrics(rr: Sequence[float], duration_s: float = 0.0, artefacts: int = 0) -> Optional[HRVMetrics]:
    if len(rr) < 2:
        return None
    mean_rr = statistics.fmean(rr)
    sdnn = statistics.stdev(rr)
    diffs = [b - a for a, b in zip(rr, rr[1:])]
    rmssd = math.sqrt(statistics.fmean(d * d for d in diffs))
    pnn50 = 100.0 * sum(1 for d in diffs if abs(d) > 50.0) / len(diffs)
    total = len(rr) + artefacts
    return HRVMetrics(
        n=len(rr),
        duration_s=duration_s,
        mean_rr=mean_rr,
        mean_hr=60000.0 / mean_rr,
        sdnn=sdnn,
        rmssd=rmssd,
        ln_rmssd=math.log(rmssd) if rmssd > 0 else float("nan"),
        pnn50=pnn50,
        artefacts=artefacts,
        artefact_pct=100.0 * artefacts / total if total else 0.0,
    )


def poincare(rr: Sequence[float]) -> Optional[tuple[float, float]]:
    """Poincaré descriptors (ms): SD1 = short-term, beat-to-beat spread across the identity line
    (SD1² = ½·Var(ΔRR), about RMSSD/√2); SD2 = longer-term spread along it (SD2² = 2·SDNN² − SD1²)."""
    if len(rr) < 3:
        return None
    diffs = [b - a for a, b in zip(rr, rr[1:])]
    sd1_sq = 0.5 * statistics.variance(diffs)
    sd2_sq = max(0.0, 2.0 * statistics.variance(rr) - sd1_sq)
    return math.sqrt(sd1_sq), math.sqrt(sd2_sq)


def stress_index(rr: Sequence[float], bin_ms: float = 50.0, min_beats: int = 30) -> Optional[float]:
    """Baevsky's stress index on clean RR (ms): SI = AMo / (2 · Mo · MxDMn).

    The intervals go into a histogram with `bin_ms` wide bins on a fixed grid ([0, 50), [50, 100), … ms).
    Mo is the centre of the fullest bin in s (the lowest one on a tie), AMo the % of intervals in it, and
    MxDMn the spread max − min in s. A narrow, peaked histogram (rigid rhythm) gives a high SI."""
    if len(rr) < min_beats:
        return None
    mxdmn = (max(rr) - min(rr)) / 1000.0
    if mxdmn <= 0:
        return None
    counts: dict[int, int] = {}
    for v in rr:
        k = math.floor(v / bin_ms)
        counts[k] = counts.get(k, 0) + 1
    mode_bin = min(counts, key=lambda k: (-counts[k], k))
    mo = (mode_bin + 0.5) * bin_ms / 1000.0
    amo = 100.0 * counts[mode_bin] / len(rr)
    return amo / (2.0 * mo * mxdmn)


def lomb_scargle_psd(t: Sequence[float], y: Sequence[float], freqs: Sequence[float]) -> list[float]:
    """Lomb-Scargle power spectral density of unevenly sampled data.

    Returns the PSD in units of y² per Hz, scaled so that integrating over frequency gives the
    variance of y (classic periodogram normalisation, times 2 × mean sampling interval).
    """
    n = len(t)
    mean = sum(y) / n
    yc = [v - mean for v in y]
    mean_dt = (t[-1] - t[0]) / (n - 1)
    out = []
    for f in freqs:
        w = 2.0 * math.pi * f
        s2 = sum(math.sin(2.0 * w * ti) for ti in t)
        c2 = sum(math.cos(2.0 * w * ti) for ti in t)
        tau = math.atan2(s2, c2) / (2.0 * w)
        cs = ss = cc = sq = 0.0
        for ti, yi in zip(t, yc):
            a = w * (ti - tau)
            c = math.cos(a)
            s = math.sin(a)
            cs += yi * c
            ss += yi * s
            cc += c * c
            sq += s * s
        p = 0.5 * ((cs * cs / cc if cc > 0 else 0.0) + (ss * ss / sq if sq > 0 else 0.0))
        out.append(2.0 * mean_dt * p)
    return out


def spectral_metrics(beat_times: Sequence[float], rr_ms: Sequence[float],
                     min_beats: int = 30, min_span_s: float = 60.0) -> Optional[SpectralMetrics]:
    """Frequency-domain HRV from beat timestamps (s) and RR intervals (ms)."""
    if len(rr_ms) < min_beats or beat_times[-1] - beat_times[0] < min_span_s:
        return None
    step = 0.002
    freqs = [VLF_BAND[0] + i * step for i in range(int((HF_BAND[1] - VLF_BAND[0]) / step) + 1)]
    psd = lomb_scargle_psd(beat_times, rr_ms, freqs)

    def band(lo: float, hi: float) -> float:
        return sum(p * step for f, p in zip(freqs, psd) if lo <= f < hi)

    vlf, lf, hf = band(*VLF_BAND), band(*LF_BAND), band(*HF_BAND)
    hf_idx = max((i for i, f in enumerate(freqs) if HF_BAND[0] <= f < HF_BAND[1]), key=lambda i: psd[i])
    hf_peak = freqs[hf_idx]
    lf_hf_sum = lf + hf
    return SpectralMetrics(
        vlf_ms2=vlf, lf_ms2=lf, hf_ms2=hf, total_ms2=vlf + lf + hf,
        lf_hf=lf / hf if hf > 0 else float("inf"),
        lf_nu=100.0 * lf / lf_hf_sum if lf_hf_sum else 0.0,
        hf_nu=100.0 * hf / lf_hf_sum if lf_hf_sum else 0.0,
        hf_peak_hz=hf_peak,
        breathing_rate_bpm=hf_peak * 60.0,
    )


class RRBuffer:
    """Keeps clean RR intervals with timestamps; rejects physiologically implausible beats.

    An interval is an artefact when it is outside [min_rr, max_rr] ms or deviates more than
    max_deviation (fraction) from the median of the last few accepted intervals.
    `times` are packet arrival times (for windowing); `beat_times` are reconstructed from the
    cumulative RR sum (for spectral analysis), re-synced to packet time when they drift apart.
    """

    def __init__(self, min_rr: float = 300.0, max_rr: float = 2000.0,
                 max_deviation: float = 0.20, history: int = 5):
        self.min_rr = min_rr
        self.max_rr = max_rr
        self.max_deviation = max_deviation
        self.times: list[float] = []
        self.beat_times: list[float] = []
        self.values: list[float] = []
        self.artefacts = 0
        self.total = 0
        self._recent: deque[float] = deque(maxlen=history)
        self._beat_clock: Optional[float] = None

    def add(self, rr_ms: float, t_s: float) -> bool:
        """Add one interval observed at elapsed time t_s. Returns True if accepted."""
        self.total += 1
        if self._beat_clock is None or abs(self._beat_clock + rr_ms / 1000.0 - t_s) > 1.5:
            self._beat_clock = t_s
        else:
            self._beat_clock += rr_ms / 1000.0
        ok = self.min_rr <= rr_ms <= self.max_rr
        if ok and len(self._recent) >= 3:
            med = statistics.median(self._recent)
            ok = abs(rr_ms - med) / med <= self.max_deviation
        if not ok:
            self.artefacts += 1
            return False
        self._recent.append(rr_ms)
        self.times.append(t_s)
        self.beat_times.append(self._beat_clock)
        self.values.append(rr_ms)
        return True

    def _start_index(self, seconds: Optional[float]) -> int:
        if seconds is None or not self.times:
            return 0
        return bisect.bisect_left(self.times, self.times[-1] - seconds)

    def window(self, seconds: Optional[float] = None) -> list[float]:
        return self.values[self._start_index(seconds):]

    def metrics(self, seconds: Optional[float] = None) -> Optional[HRVMetrics]:
        vals = self.window(seconds)
        if len(vals) < 2:
            return None
        duration = self.times[-1] - self.times[-len(vals)]
        return compute_metrics(vals, duration, self.artefacts if seconds is None else 0)

    def spectral(self, seconds: Optional[float] = None) -> Optional[SpectralMetrics]:
        i = self._start_index(seconds)
        return spectral_metrics(self.beat_times[i:], self.values[i:])
