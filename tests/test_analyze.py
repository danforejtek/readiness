import csv
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

from hrmon import analyze as an
from hrmon.readiness import DEFAULT_PARAMS, assess_all, records_from_rows

ROOT = Path(__file__).resolve().parent.parent
DEMO = ROOT / "ReadinessApp/ReadinessApp/Resources/Fixtures/demo-history.csv"


def session_beats(path: Path) -> list[tuple[float, float]]:
    with open(path, newline="") as f:
        return [(float(r["elapsed_s"]), float(r["rr_ms"])) for r in csv.DictReader(f) if r["rr_ms"]]


class StatsTests(unittest.TestCase):
    def test_spearman(self):
        self.assertAlmostEqual(an.spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1.0)
        self.assertAlmostEqual(an.spearman([1, 2, 3, 4], [4, 3, 2, 1]), -1.0)
        self.assertAlmostEqual(an.spearman([1, 2, 2, 3], [1, 2, 2, 3]), 1.0)   # ties
        self.assertIsNone(an.spearman([1, 2], [1, 2]))
        self.assertIsNone(an.spearman([1, 1, 1], [1, 2, 3]))

    def test_quantile(self):
        self.assertEqual(an.quantile([1, 2, 3, 4, 5], 0.5), 3)
        self.assertAlmostEqual(an.quantile([0, 10], 0.25), 2.5)

    def test_parse_alternative(self):
        p = an.parse_alternative("range_sd=0.75, baseline_days=30")
        self.assertEqual(p.range_sd, 0.75)
        self.assertEqual(p.baseline_days, 30)
        self.assertIsInstance(p.baseline_days, int)
        self.assertEqual(p.w_hrv, DEFAULT_PARAMS.w_hrv)
        with self.assertRaises(ValueError):
            an.parse_alternative("nonsense=1")


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.rows = an.read_rows(DEMO)

    def test_demo_rows_are_filtered_unless_asked(self):
        self.assertEqual(an.filter_rows(self.rows), [])
        self.assertEqual(len(an.filter_rows(self.rows, include_demo=True)), len(self.rows))

    def test_checkins_are_read(self):
        recs = records_from_rows(self.rows)
        self.assertTrue(all(r.feeling in range(1, 6) for r in recs))
        self.assertTrue(any("sick" in r.tags for r in recs))
        self.assertTrue(all(r.source == "demo" for r in recs))

    def test_default_params_change_nothing(self):
        recs = records_from_rows(self.rows)
        base = assess_all(recs)
        section = an.what_if(recs, base, ["range_sd=0.5"])
        self.assertEqual(section.rows[1][1], "0")

    def test_report_sections_and_markdown(self):
        sections = an.build_report(self.rows, {}, an.DEFAULT_ALTERNATIVES)
        titles = [s.title for s in sections]
        self.assertIn("Illness warning", titles)
        self.assertNotIn("Artefact filter: jump threshold", titles)      # no beats given
        illness = next(s for s in sections if s.title == "Illness warning")
        self.assertEqual(illness.rows[1][1], "–")                          # demo: no sick day missed
        md = an.to_markdown(sections)
        self.assertIn("## What if…", md)
        self.assertIn("| current settings |", md)

    def test_filter_sensitivity_on_a_real_session(self):
        beats = session_beats(ROOT / "sessions/2026-10-04_001437.csv")
        row = {"date": "2026-10-04 00:16", "ln_rmssd": "4.59", "settle_s": "15"}
        section = an.filter_sensitivity([row], {row["date"]: beats})
        current = next(r for r in section.rows if "current" in r[0])
        self.assertEqual(current[1], "1")
        self.assertLess(float(current[2]), 0.01)   # the stored value came from the same filter

    def test_beats_export_and_mac_session_matching(self):
        with tempfile.TemporaryDirectory() as tmp:
            export = Path(tmp) / "readiness-beats.csv"
            export.write_text("date,elapsed_s,rr_ms\n2026-10-05 06:40,15.2,1001.0\n2026-10-05 06:40,16.1,990.5\n"
                              "2026-10-06 06:41,15.0,980.0\nbad,row,\n")
            got = an.read_beats_export(export)
            self.assertEqual(len(got["2026-10-05 06:40"]), 2)
            self.assertEqual(got["2026-10-06 06:41"], [(15.0, 980.0)])

            start = datetime(2026, 10, 7, 6, 30, 0)
            session = Path(tmp) / "2026-10-07_063000.csv"
            with open(session, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["timestamp_iso", "elapsed_s", "hr_bpm", "rr_ms", "contact", "battery_pct"])
                for i in range(140):
                    w.writerow([(start + timedelta(seconds=i)).isoformat(), f"{i:.3f}", 60, "1000.0", "", 90])
            rows = [{"date": "2026-10-07 06:32"}, {"date": "2026-10-07 09:00"}]
            matched = an.read_mac_sessions(Path(tmp), rows)
            self.assertIn("2026-10-07 06:32", matched)
            self.assertNotIn("2026-10-07 09:00", matched)


if __name__ == "__main__":
    unittest.main()
