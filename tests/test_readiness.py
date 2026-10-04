import csv
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from hrmon.log import append_readiness, read_readiness
from hrmon.readiness import (BASELINE, MODERATE, READY, REST, DayRecord, Params, ans_z, assess,
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
        self.assertIn("4 of 7", a.notes[0])

    def test_normal_day_is_ready(self):
        recs = add_day(make_history(), ln=4.02, hr=52.5)
        a = assess(recs)
        self.assertEqual(a.status, READY)
        self.assertTrue(65 <= a.score <= 85, a.score)
        self.assertFalse(a.illness)

    def test_low_hrv_is_moderate_or_rest(self):
        recs = add_day(make_history(), ln=3.85, hr=53.0)   # ~ -2 SD on HRV, HR normal-ish
        a = assess(recs)
        self.assertIn(a.status, (MODERATE, REST))
        self.assertLess(a.score, 70)

    def test_illness_pattern(self):
        recs = add_day(make_history(), ln=3.80, hr=60.0)   # HRV down, HR +8 bpm
        a = assess(recs)
        self.assertTrue(a.illness)
        self.assertEqual(a.status, REST)
        self.assertTrue(any("infection" in n for n in a.notes))

    def test_illness_by_heart_rate_alone_does_not_claim_low_hrv(self):
        recs = add_day(make_history(), ln=4.02, hr=61.0)   # HRV normal, HR +9 bpm
        a = assess(recs)
        self.assertTrue(a.illness)
        self.assertGreater(a.z_hrv, -1.0)
        self.assertFalse(any("HRV is below" in n for n in a.notes))
        self.assertTrue(any("far outside your usual range" in n for n in a.notes))

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

    def test_weekly_average_below_range_flags_fatigue(self):
        recs = make_history(30)
        for _ in range(6):
            recs = add_day(recs, ln=3.93, hr=52.0)          # each day only mildly low
        a = assess(recs)
        self.assertIn(a.status, (MODERATE, REST))
        self.assertTrue(any("7-day" in n for n in a.notes))

    def test_low_quality_flagged(self):
        recs = add_day(make_history(), ln=4.0, hr=52.0, beats=40, artefacts=25.0)
        a = assess(recs)
        self.assertTrue(a.low_confidence)

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
        # a lower SD2 alone raises Stress: SD2 enters reversed, as in Kubios' SNS index
        hi, lo = with_beats(make_history(30)), with_beats(make_history(30))
        hi[-1].sd2, lo[-1].sd2 = 90.0, 60.0
        self.assertLess(ans_z(hi, len(hi) - 1)[1], ans_z(lo, len(lo) - 1)[1])

    def test_scale_clips_to_zero_and_ten(self):
        self.assertEqual(scale_index(0.0), 5.0)
        self.assertEqual(scale_index(1.26), 7.5)
        self.assertEqual(scale_index(4.0), 10.0)
        self.assertEqual(scale_index(-3.0), 0.0)
        self.assertIsNone(scale_index(None))
        self.assertEqual(scale_index(1.0, Params(index_scale=1.0)), 6.0)

    def test_missing_components_fall_back_to_the_available_ones(self):
        # old Mac rows: no beats, so no mean RR / SD1 / SD2 / stress index; RMSSD and mean HR still count
        recs = make_history(30)
        z_regen, z_stress = ans_z(recs, len(recs) - 1)
        p = Params()
        hist = recs[:-1]
        mean_hr = sum(r.mean_hr for r in hist) / len(hist)
        import statistics
        sd_hr = max(statistics.stdev(r.mean_hr for r in hist), p.hr_sd_floor)
        self.assertAlmostEqual(z_stress, (recs[-1].mean_hr - mean_hr) / sd_hr)
        self.assertAlmostEqual(z_regen, 0.0)   # RMSSD constant in the history -> on the mean
        # a component only counts once 7 baseline days have it: SD2 on the last 3 days only is ignored
        for r in recs[-3:]:
            r.sd2 = 50.0
        self.assertAlmostEqual(ans_z(recs, len(recs) - 1)[1], z_stress)
        # nothing at all -> None
        bare = [DayRecord(day=r.day, when=r.when, ln_rmssd=r.ln_rmssd, rmssd=0.0, mean_hr=0.0, sdnn=0.0,
                          beats=0, artefact_pct=0.0) for r in recs]
        self.assertEqual(ans_z(bare, len(bare) - 1), (None, None))
        self.assertIsNone(assess(bare).regeneration)

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
        recs[-1].mean_rr, recs[-1].sd1, recs[-1].sd2, recs[-1].stress_index = 1200.0, 45.0, 80.0, 90.0
        a = assess(recs)
        prev = recs[-2]
        self.assertAlmostEqual(a.ln_change.vs_average_pct, 100 * (4.2 - a.ln_mean) / a.ln_mean)
        self.assertAlmostEqual(a.ln_change.vs_last_pct, 100 * (4.2 - prev.ln_rmssd) / prev.ln_rmssd)
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
