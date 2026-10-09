import csv
import math
import statistics
import tempfile
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from hrmon.log import append_readiness, read_readiness
from hrmon.readiness import (BASELINE, MODERATE, READY, REST, DayRecord, Params, ans_z, assess, assess_all,
                             records_from_rows, scale_index)


def make_history(n=20, ln=4.0, hr=52.0, start=datetime(2026, 9, 1, 7, 0)):
    recs = []
    for i in range(n):
        when = start + timedelta(days=i)
        jitter_ln = ((i * 7) % 5 - 2) * 0.04   # ±0.08 deterministic wobble
        jitter_hr = ((i * 3) % 5 - 2) * 0.8
        recs.append(DayRecord(day=when.date(), when=when, ln_rmssd=ln + jitter_ln, rmssd=55.0,
                              mean_hr=hr + jitter_hr, sdnn=60.0, beats=120, artefact_pct=2.0))
    return recs


def with_beats(recs):
    """Give every record the beat-derived fields (mean RR, SD1, SD2, stress index) with a deterministic wobble."""
    for i, r in enumerate(recs):
        w = (i * 7) % 5 - 2
        r.mean_rr = 60000.0 / r.mean_hr
        r.rmssd = 55.0 + 2.0 * w
        r.sd1 = r.rmssd / 1.414
        r.sd2 = 80.0 - 3.0 * w
        r.stress_index = 100.0 - 8.0 * w
    return recs


def add_day(recs, ln, hr, beats=120, artefacts=2.0):
    when = recs[-1].when + timedelta(days=1)
    recs.append(DayRecord(day=when.date(), when=when, ln_rmssd=ln, rmssd=55.0, mean_hr=hr,
                          sdnn=60.0, beats=beats, artefact_pct=artefacts))
    return recs


class ReadinessTests(unittest.TestCase):
    def test_building_baseline(self):
        recs = make_history(5)
        a = assess(recs)
        self.assertEqual(a.status, BASELINE)
        self.assertIsNone(a.score)
        # Five mornings measured, today included: the note counts what the user sees in the week strip.
        self.assertIn("5 of 7", a.notes[0])

    def test_baseline_complete_on_seventh_morning(self):
        a = assess(make_history(7))
        self.assertEqual(a.status, BASELINE)
        self.assertEqual(a.baseline_n, 6)
        self.assertIn("Baseline complete: 7 mornings", a.notes[0])
        a = assess(make_history(8))
        self.assertIsNotNone(a.score)

    def test_normal_day_is_ready(self):
        recs = add_day(make_history(), ln=4.02, hr=52.5)
        a = assess(recs)
        self.assertEqual(a.status, READY)
        self.assertTrue(65 <= a.score <= 85, a.score)
        self.assertFalse(a.illness)
        self.assertFalse(a.illness_signal)

    def test_low_hrv_is_moderate_or_rest(self):
        recs = add_day(make_history(), ln=3.85, hr=53.0)   # ~ -2.5 SD on HRV, HR normal-ish
        a = assess(recs)
        self.assertLessEqual(a.z_hrv, -1.0)
        self.assertIn(a.status, (MODERATE, REST))
        self.assertLess(a.score, 70)

    def _day_at(self, z_hrv):
        """A normal history plus today at `z_hrv` SD on HRV, with resting HR exactly on its mean."""
        recs = make_history()
        ln = [r.ln_rmssd for r in recs]
        hr = statistics.fmean(r.mean_hr for r in recs)
        a = assess(add_day(recs, ln=statistics.fmean(ln) + z_hrv * statistics.stdev(ln), hr=hr))
        self.assertAlmostEqual(a.z_hrv, z_hrv)
        self.assertAlmostEqual(a.z_hr, 0.0)
        self.assertGreaterEqual(a.ln_week, a.ln_range[0])          # the week is normal
        return a

    def test_single_day_below_range_but_above_minus_one_sd_is_ready(self):
        # one morning between -0.5 and -1 SD is day-to-day noise (Kiviniemi 2007, Plews 2012/2013)
        a = self._day_at(-0.7)
        self.assertLess(a.record.ln_rmssd, a.ln_range[0])           # below the ±0.5 SD range shown …
        self.assertEqual(a.status, READY)                           # … but not a MODERATE day
        self.assertEqual(Params().moderate_z_hrv, -1.0)

    def test_single_day_at_minus_one_sd_is_moderate(self):
        a = self._day_at(-1.1)
        self.assertEqual(a.status, MODERATE)
        self.assertTrue(any("Slightly off your normal" in n for n in a.notes))
        # the old −0.5 SD trigger is still available as a parameter
        recs = make_history()
        ln = [r.ln_rmssd for r in recs]
        hr = statistics.fmean(r.mean_hr for r in recs)
        recs = add_day(recs, ln=statistics.fmean(ln) - 0.7 * statistics.stdev(ln), hr=hr)
        self.assertEqual(assess(recs, params=Params(moderate_z_hrv=-0.5)).status, MODERATE)

    def test_illness_pattern(self):
        recs = add_day(make_history(), ln=3.80, hr=60.0)   # HRV down, HR +8 bpm
        a = assess(recs)
        # one morning is a signal, not yet the warning: the ordinary rules decide (resting HR z ≥ 1.5 → rest)
        self.assertTrue(a.illness_signal)
        self.assertFalse(a.illness)
        self.assertEqual(a.illness_streak, 1)
        self.assertEqual(a.status, REST)
        self.assertTrue(any(n.startswith("Resting HR is 8 bpm above your normal and HRV is below your normal. "
                                         "One morning like this can be alcohol, poor sleep, travel or stress; "
                                         "if it is the same tomorrow the app raises the illness warning.")
                            for n in a.notes))
        self.assertFalse(any("one to three days before a cold" in n for n in a.notes))
        self.assertTrue(any("Clearly off your normal" in n for n in a.notes))
        # the second morning in a row raises the warning
        a = assess(add_day(recs, ln=3.80, hr=60.0))
        self.assertTrue(a.illness_signal)
        self.assertTrue(a.illness)
        self.assertEqual(a.illness_streak, 2)
        self.assertEqual(a.status, REST)
        self.assertTrue(any("one to three days before a cold or other infection" in n for n in a.notes))
        # the same pattern has other causes, and the note says so
        self.assertTrue(any("alcohol, poor sleep, travel and stress produce it too" in n for n in a.notes))
        self.assertFalse(any("if it is the same tomorrow" in n for n in a.notes))
        self.assertFalse(any("Clearly off your normal" in n for n in a.notes))
        self.assertEqual(Params().illness_min_days, 2)
        # illness_min_days=1 restores the single-morning warning
        self.assertTrue(assess(recs, params=Params(illness_min_days=1)).illness)

    def test_illness_by_heart_rate_alone_does_not_claim_low_hrv(self):
        recs = add_day(make_history(), ln=4.02, hr=61.0)   # HRV normal, HR +9 bpm
        a = assess(recs)
        self.assertTrue(a.illness_signal)
        self.assertFalse(a.illness)
        self.assertTrue(any(n.startswith("Resting HR is 9 bpm above your normal. One morning like this can be "
                                         "alcohol, poor sleep, travel or stress;") for n in a.notes))
        self.assertFalse(any("HRV is below" in n for n in a.notes))
        a = assess(add_day(recs, ln=4.02, hr=61.0))
        self.assertTrue(a.illness)
        self.assertGreater(a.z_hrv, -1.0)
        self.assertFalse(any("HRV is below" in n for n in a.notes))
        self.assertTrue(any("far outside your usual range" in n for n in a.notes))
        self.assertTrue(any("Infection, alcohol, poor sleep, travel, heavy stress or a late meal" in n for n in a.notes))

    def test_illness_by_heart_rate_alone_needs_four_bpm(self):
        # the HR SD here is below the 1.5 bpm floor, so +3.8 bpm is z ≈ 2.5 but not 4 bpm above normal
        recs = make_history()
        hr_mean = sum(r.mean_hr for r in recs) / len(recs)
        a = assess(add_day(recs, ln=4.0, hr=hr_mean + 3.8))
        self.assertEqual(a.hr_sd, 1.5)
        self.assertGreaterEqual(a.z_hr, 2.5)
        self.assertFalse(a.illness_signal)
        self.assertFalse(a.illness)
        self.assertEqual(a.status, REST)            # still far off: HR z ≥ 1.5

    def test_rest_note_does_not_say_below_when_hr_is_the_cause(self):
        recs = add_day(make_history(), ln=4.0, hr=55.0)    # HRV on baseline, HR clearly up but not illness
        a = assess(recs)
        if a.status == REST and not a.illness:
            self.assertFalse(any("below your normal" in n for n in a.notes))

    def test_illness_streak_counts_consecutive_days(self):
        recs = add_day(add_day(make_history(), ln=3.80, hr=60.0), ln=3.78, hr=61.0)
        a = assess(recs)
        self.assertTrue(a.illness)
        self.assertEqual(a.illness_streak, 2)

    def test_illness_streak_has_no_cap(self):
        recs = make_history()
        for _ in range(6):
            recs = add_day(recs, ln=3.80, hr=60.0)
        a = assess(recs)
        self.assertEqual(a.illness_streak, 6)
        self.assertTrue(any("for 6 days in a row" in n for n in a.notes))

    def test_gap_day_breaks_illness_streak(self):
        recs = add_day(make_history(), ln=3.80, hr=60.0)
        when = recs[-1].when + timedelta(days=2)             # one day not measured
        recs.append(DayRecord(day=when.date(), when=when, ln_rmssd=3.78, rmssd=55.0, mean_hr=61.0,
                              sdnn=60.0, beats=120, artefact_pct=2.0))
        a = assess(recs)
        self.assertTrue(a.illness_signal)
        self.assertTrue(assess(recs, len(recs) - 2).illness_signal)
        self.assertEqual(a.illness_streak, 1)
        self.assertFalse(a.illness)                          # two flagged mornings, but not in a row

    def test_long_illness_streak_stays_fast(self):
        # the streak used to recurse through assess(); 14 flagged days in a row took thousands of calls
        recs = make_history(46)
        for _ in range(14):
            recs = add_day(recs, ln=3.80, hr=60.0)
        start = time.perf_counter()
        out = assess_all(recs)
        self.assertLess(time.perf_counter() - start, 0.5)
        self.assertEqual(len(out), 60)
        self.assertEqual(out[-1].illness_streak, 14)

    def test_weekly_average_below_range_flags_fatigue(self):
        recs = make_history(30)
        for _ in range(6):
            recs = add_day(recs, ln=3.93, hr=52.0)          # each day only mildly low
        a = assess(recs)
        self.assertIn(a.status, (MODERATE, REST))
        self.assertTrue(any("7-day" in n for n in a.notes))

    def test_weekly_average_needs_three_mornings(self):
        # after a week without measurements, one very low morning and a normal one: the 7-day average of those
        # two is below range, but two mornings are too few to call it a trend
        recs = make_history(30)
        when = recs[-1].when + timedelta(days=8)
        recs.append(DayRecord(day=when.date(), when=when, ln_rmssd=3.80, rmssd=55.0, mean_hr=52.0, sdnn=60.0,
                              beats=120, artefact_pct=2.0))
        recs = add_day(recs, ln=3.99, hr=52.0)
        a = assess(recs)
        lo, _ = a.ln_range
        self.assertAlmostEqual(a.ln_week, (3.80 + 3.99) / 2)     # still computed and shown
        self.assertEqual(a.week_n, 2)
        self.assertLess(a.ln_week, lo)
        self.assertGreater(a.z_hrv, -0.5)
        self.assertEqual(a.status, READY)
        self.assertFalse(any("7-day" in n for n in a.notes))
        # the third morning makes it count
        a = assess(add_day(recs, ln=3.99, hr=52.0))
        self.assertLess(a.ln_week, a.ln_range[0])
        self.assertGreater(a.z_hrv, -0.5)
        self.assertEqual(a.status, MODERATE)
        self.assertTrue(any("7-day" in n for n in a.notes))
        self.assertEqual(Params().week_min_days, 3)

    def test_low_quality_flagged(self):
        recs = add_day(make_history(), ln=4.0, hr=52.0, beats=40, artefacts=25.0)
        a = assess(recs)
        self.assertTrue(a.low_confidence)
        self.assertIsNotNone(a.score)                  # a noisy morning still gets a verdict

    def test_noisy_morning_stays_out_of_the_baseline(self):
        clean = add_day(make_history(), ln=4.0, hr=52.0)
        noisy = make_history()
        add_day(noisy, ln=4.8, hr=48.0, beats=45, artefacts=30.0)    # inflated lnRMSSD from artefacts
        noisy = add_day(noisy, ln=4.0, hr=52.0)
        a, b = assess(clean), assess(noisy)
        self.assertEqual(b.baseline_n, 20)
        self.assertEqual((b.ln_mean, b.ln_sd, b.hr_mean, b.hr_sd), (a.ln_mean, a.ln_sd, a.hr_mean, a.hr_sd))
        self.assertEqual(b.ln_range, a.ln_range)
        # … and out of the 7-day average: today's 4.0 and the five clean days before the noisy one
        self.assertAlmostEqual(b.ln_week, (4.0 + sum(r.ln_rmssd for r in noisy[-7:-2])) / 6)
        # the noisy morning itself is still assessed, against the clean baseline
        c = assess(noisy, len(noisy) - 2)
        self.assertTrue(c.low_confidence)
        self.assertEqual(c.baseline_n, 20)
        self.assertAlmostEqual(c.ln_week, (4.8 + sum(r.ln_rmssd for r in noisy[-8:-2])) / 7)

    def test_noisy_mornings_count_while_clean_ones_are_too_few(self):
        recs = make_history(10)
        for r in recs[:5]:
            r.beats, r.artefact_pct = 40, 25.0                       # only 5 clean mornings: fall back to all
        a = assess(add_day(recs, ln=4.0, hr=52.0))
        self.assertEqual(a.baseline_n, 10)
        self.assertAlmostEqual(a.ln_mean, sum(r.ln_rmssd for r in recs[:-1]) / 10)
        self.assertAlmostEqual(a.ln_week, sum(r.ln_rmssd for r in recs[-7:]) / 7)

    def test_regeneration_and_stress_on_a_normal_day_are_near_five(self):
        recs = with_beats(make_history(30))
        a = assess(recs)
        self.assertIsNotNone(a.regeneration)
        self.assertTrue(3.0 <= a.regeneration <= 7.0, a.regeneration)
        self.assertTrue(3.0 <= a.stress <= 7.0, a.stress)
        self.assertEqual(a.regeneration, round(a.regeneration, 1))

    def test_strained_morning_has_low_regeneration_and_high_stress(self):
        recs = with_beats(make_history(30))
        recs = add_day(recs, ln=3.7, hr=58.0)
        r = recs[-1]
        r.mean_rr, r.rmssd, r.sd1, r.sd2, r.stress_index = 60000 / 58.0, 40.0, 28.0, 60.0, 180.0
        a = assess(recs)
        self.assertLess(a.regeneration, 3.0)
        self.assertGreater(a.stress, 7.0)
        # Stress = ⅔ · z(resting HR) + ⅓ · −z(ln SD2), Naranjo's Stress Score 1000/SD2 on the log scale
        p, hist = Params(), recs[:-1]
        z_hr = (58.0 - statistics.fmean(h.mean_hr for h in hist)) / max(statistics.stdev(h.mean_hr for h in hist), p.hr_sd_floor)
        ln_sd2 = [math.log(h.sd2) for h in hist]
        z_sd2 = (math.log(60.0) - statistics.fmean(ln_sd2)) / max(statistics.stdev(ln_sd2), p.ln_sd2_sd_floor)
        self.assertAlmostEqual(a.z_stress, (2 / 3) * z_hr - (1 / 3) * z_sd2)
        # a lower SD2 alone raises Stress
        hi, lo = with_beats(make_history(30)), with_beats(make_history(30))
        hi[-1].sd2, lo[-1].sd2 = 90.0, 60.0
        self.assertLess(ans_z(hi, len(hi) - 1)[1], ans_z(lo, len(lo) - 1)[1])
        # mean RR, SD1 and the stress index no longer enter either index
        other = with_beats(make_history(30))
        other[-1].mean_rr, other[-1].sd1, other[-1].stress_index = 2000.0, 90.0, 900.0
        self.assertEqual(ans_z(other, len(other) - 1), ans_z(with_beats(make_history(30)), 29))

    def test_regeneration_is_the_hrv_z_score(self):
        recs = with_beats(add_day(make_history(30), ln=3.9, hr=53.0))
        a = assess(recs)
        self.assertAlmostEqual(a.z_regeneration, a.z_hrv)
        self.assertEqual(a.regeneration, scale_index(a.z_hrv))

    def test_regeneration_and_stress_use_the_clean_baseline(self):
        # a noisy morning with inflated HRV stays out of the Regeneration / Stress baseline, as out of the verdict's
        clean = with_beats(add_day(make_history(20), ln=4.0, hr=52.0))
        noisy = make_history(20)
        add_day(noisy, ln=4.8, hr=48.0, beats=45, artefacts=30.0)
        noisy = with_beats(add_day(noisy, ln=4.0, hr=52.0))
        # same beat-derived values on the shared days
        for c, n in zip(clean[:20], noisy[:20]):
            self.assertEqual((c.sd2, c.mean_hr), (n.sd2, n.mean_hr))
        noisy[-1].sd2 = clean[-1].sd2
        a, b = assess(clean), assess(noisy)
        self.assertAlmostEqual(b.z_regeneration, a.z_regeneration)
        self.assertAlmostEqual(b.z_stress, a.z_stress)

    def test_scale_clips_to_zero_and_ten(self):
        self.assertEqual(scale_index(0.0), 5.0)
        self.assertEqual(scale_index(1.26), 7.5)
        self.assertEqual(scale_index(4.0), 10.0)
        self.assertEqual(scale_index(-3.0), 0.0)
        self.assertIsNone(scale_index(None))
        self.assertEqual(scale_index(1.0, Params(index_scale=1.0)), 6.0)

    def test_missing_components_fall_back_to_the_available_ones(self):
        # old Mac rows: no beats, so no SD2; Stress is then resting HR alone, Regeneration is lnRMSSD as always
        recs = make_history(30)
        z_regen, z_stress = ans_z(recs, len(recs) - 1)
        p = Params()
        hist = recs[:-1]
        mean_hr = sum(r.mean_hr for r in hist) / len(hist)
        sd_hr = max(statistics.stdev(r.mean_hr for r in hist), p.hr_sd_floor)
        self.assertAlmostEqual(z_stress, (recs[-1].mean_hr - mean_hr) / sd_hr)
        ln = [r.ln_rmssd for r in hist]
        self.assertAlmostEqual(z_regen, (recs[-1].ln_rmssd - statistics.fmean(ln)) / max(statistics.stdev(ln), p.ln_sd_floor))
        # a component only counts once 7 baseline days have it: SD2 on the last 3 days only is ignored
        for r in recs[-3:]:
            r.sd2 = 50.0
        self.assertAlmostEqual(ans_z(recs, len(recs) - 1)[1], z_stress)
        # no resting HR -> no Stress; Regeneration only needs lnRMSSD
        bare = [DayRecord(day=r.day, when=r.when, ln_rmssd=r.ln_rmssd, rmssd=0.0, mean_hr=0.0, sdnn=0.0,
                          beats=0, artefact_pct=0.0) for r in recs]
        self.assertIsNone(ans_z(bare, len(bare) - 1)[1])
        self.assertAlmostEqual(ans_z(bare, len(bare) - 1)[0], z_regen)
        self.assertIsNone(assess(bare).stress)

    def test_short_baseline_gives_no_regeneration_or_stress(self):
        recs = with_beats(make_history(7))      # today + 6 earlier mornings
        a = assess(recs)
        self.assertEqual(a.status, BASELINE)
        self.assertIsNone(a.regeneration)
        self.assertIsNone(a.stress)
        self.assertIsNone(a.regeneration_change.vs_average_pct)
        self.assertIsNotNone(a.ln_change.vs_last_pct)       # "since last" works from the second morning
        self.assertIsNotNone(assess(with_beats(make_history(8))).regeneration)

    def test_comparisons_vs_average_and_last(self):
        recs = with_beats(make_history(30))
        recs = add_day(recs, ln=4.2, hr=50.0)
        recs[-1].sd2 = 80.0
        a = assess(recs)
        prev = recs[-2]
        # HRV chips are % of RMSSD, not of its log: e^Δln − 1
        self.assertAlmostEqual(a.ln_change.vs_average_pct, 100 * (math.exp(4.2 - a.ln_mean) - 1))
        self.assertAlmostEqual(a.ln_change.vs_last_pct, 100 * (math.exp(4.2 - prev.ln_rmssd) - 1))
        self.assertAlmostEqual(a.hr_change.vs_average_pct, 100 * (50.0 - a.hr_mean) / a.hr_mean)
        self.assertAlmostEqual(a.hr_change.vs_last_pct, 100 * (50.0 - prev.mean_hr) / prev.mean_hr)
        self.assertAlmostEqual(a.regeneration_change.vs_average_pct, 100 * (a.regeneration - 5.0) / 5.0)
        prev_a = assess(recs, len(recs) - 2)
        self.assertAlmostEqual(a.stress_change.vs_last_pct, 100 * (a.stress - prev_a.stress) / prev_a.stress)
        self.assertIsNone(assess(recs[:1]).ln_change.vs_last_pct)

    def test_records_from_rows_picks_best_quality_per_day(self):
        rows = [
            {"date": "2026-10-04 07:00", "ln_rmssd": "4.1", "mean_hr": "50", "rmssd_ms": "60", "sdnn_ms": "70",
             "beats": "100", "artefact_pct": "12"},
            {"date": "2026-10-04 07:05", "ln_rmssd": "4.0", "mean_hr": "51", "rmssd_ms": "55", "sdnn_ms": "60",
             "beats": "120", "artefact_pct": "2"},
            {"date": "garbage", "ln_rmssd": "4.0", "mean_hr": "51"},
        ]
        recs = records_from_rows(rows)
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0].artefact_pct, 2.0)

    def test_records_from_rows_reads_beat_derived_columns(self):
        rows = [{"date": "2026-10-04 07:00", "ln_rmssd": "4.0", "mean_hr": "51", "mean_rr_ms": "1176.5",
                 "sd1_ms": "38.9", "sd2_ms": "71.2", "stress_index": "95.3"},
                {"date": "2026-10-05 07:00", "ln_rmssd": "4.0", "mean_hr": "51"}]
        a, b = records_from_rows(rows)
        self.assertEqual((a.mean_rr, a.sd1, a.sd2, a.stress_index), (1176.5, 38.9, 71.2, 95.3))
        self.assertEqual((b.mean_rr, b.sd1, b.sd2, b.stress_index), (None, None, None, None))

    def test_append_readiness_migrates_header(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "readiness.csv"
            append_readiness(p, {"date": "2026-10-03 23:58", "mean_hr": "60", "ln_rmssd": "5.0"})
            append_readiness(p, {"date": "2026-10-04 07:00", "mean_hr": "58", "ln_rmssd": "4.8", "hf_ms2": "900"})
            rows = read_readiness(p, last=10)
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["hf_ms2"], "")
            self.assertEqual(rows[1]["hf_ms2"], "900")
            with open(p) as f:
                header = next(csv.reader(f))
            self.assertEqual(header, ["date", "mean_hr", "ln_rmssd", "hf_ms2"])


if __name__ == "__main__":
    unittest.main()
