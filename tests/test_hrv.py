import math
import random
import statistics
import unittest

from hrmon.ble import parse_hr_measurement
from hrmon.hrv import RRBuffer, compute_metrics, poincare, spectral_metrics, stress_index


class ParserTests(unittest.TestCase):
    def test_uint8_hr_with_contact_and_two_rr(self):
        s = parse_hr_measurement(bytes([0x16, 72, 0x00, 0x04, 0x34, 0x03]))
        self.assertEqual((s.hr, s.contact, s.energy_kj), (72, True, None))
        self.assertEqual([round(x, 1) for x in s.rr_ms], [1000.0, 800.8])

    def test_uint16_hr_with_energy(self):
        s = parse_hr_measurement(bytes([0x09, 0x2C, 0x01, 0x10, 0x00]))
        self.assertEqual((s.hr, s.energy_kj, s.rr_ms, s.contact), (300, 16, [], None))

    def test_real_band_packets(self):
        self.assertEqual(parse_hr_measurement(bytes.fromhex("0038")).rr_ms, [])
        s = parse_hr_measurement(bytes.fromhex("103a3804d803"))
        self.assertEqual(s.hr, 58)
        self.assertEqual([round(x) for x in s.rr_ms], [1055, 961])


class MetricTests(unittest.TestCase):
    def test_time_domain(self):
        m = compute_metrics([1000, 1050, 950, 1000, 1100, 900])
        self.assertAlmostEqual(m.mean_rr, 1000)
        self.assertAlmostEqual(m.mean_hr, 60)
        diffs = [50, -100, 50, 100, -200]
        self.assertAlmostEqual(m.rmssd, math.sqrt(sum(d * d for d in diffs) / 5))
        self.assertEqual(m.pnn50, 60.0)

    def test_poincare_descriptors(self):
        rr = [1000, 1050, 950, 1000, 1100, 900]
        sd1, sd2 = poincare(rr)
        diffs = [50, -100, 50, 100, -200]
        self.assertAlmostEqual(sd1 ** 2, statistics.variance(diffs) / 2)
        self.assertAlmostEqual(sd1 ** 2 + sd2 ** 2, 2 * statistics.variance(rr))
        self.assertIsNone(poincare([1000, 1000]))
        # a perfectly regular rhythm has no spread at all
        self.assertEqual(poincare([800.0] * 10), (0.0, 0.0))

    def test_stress_index_by_hand(self):
        # 50 ms bins on a fixed grid: 18 × 1010 in [1000, 1050) (centre 1025), 8 × 960 in [950, 1000),
        # 4 × 1100 in [1100, 1150). Mo = 1.025 s, AMo = 60 %, MxDMn = 1.100 − 0.960 = 0.140 s.
        rr = [1010.0] * 18 + [960.0] * 8 + [1100.0] * 4
        self.assertAlmostEqual(stress_index(rr), 60.0 / (2 * 1.025 * 0.140))
        # on a tie the lower bin is the mode: 15 × 960 and 15 × 1010 -> Mo = 0.975 s, AMo = 50 %
        self.assertAlmostEqual(stress_index([960.0] * 15 + [1010.0] * 15), 50.0 / (2 * 0.975 * 0.050))
        # a flat rhythm has no spread, and too few beats give nothing
        self.assertIsNone(stress_index([1000.0] * 40))
        self.assertIsNone(stress_index(rr[:29]))
        # a rigid rhythm (narrow histogram) scores higher than a variable one
        self.assertGreater(stress_index([1000.0, 1010.0] * 20), stress_index([900.0, 1000.0, 1100.0] * 14))

    def test_artefact_filter_and_window(self):
        b = RRBuffer()
        t = 0.0
        for v in [1000, 1010, 990, 1000, 2500, 1400, 1150, 1000]:
            t += v / 1000
            b.add(v, t)
        self.assertEqual(b.artefacts, 2)
        self.assertEqual(len(b.values), 6)
        self.assertEqual(b.window(2.5), [1150, 1000])

    def test_beat_clock_follows_cumulative_rr(self):
        b = RRBuffer()
        # two RR intervals arriving in the same packet at t=2.0
        b.add(1000, 1.0)
        b.add(500, 2.0)
        b.add(500, 2.0)
        self.assertEqual(b.beat_times, [1.0, 1.5, 2.0])

    def test_spectral_recovers_sine_power_in_lf_band(self):
        # 120 s of beats at ~1 s with a 0.1 Hz (LF) oscillation of amplitude 50 ms -> variance 1250 ms²
        t, rr, clock = [], [], 0.0
        while clock < 120:
            v = 1000 + 50 * math.sin(2 * math.pi * 0.1 * clock)
            clock += v / 1000
            t.append(clock)
            rr.append(v)
        sp = spectral_metrics(t, rr)
        self.assertIsNotNone(sp)
        self.assertAlmostEqual(sp.lf_ms2, 1250, delta=250)
        self.assertLess(sp.hf_ms2, 100)
        self.assertGreater(sp.lf_nu, 90)

    def test_spectral_breathing_rate_from_hf_peak(self):
        # 15 breaths/min = 0.25 Hz modulation
        t, rr, clock = [], [], 0.0
        rng = random.Random(1)
        while clock < 150:
            v = 900 + 40 * math.sin(2 * math.pi * 0.25 * clock) + rng.gauss(0, 3)
            clock += v / 1000
            t.append(clock)
            rr.append(v)
        sp = spectral_metrics(t, rr)
        self.assertAlmostEqual(sp.breathing_rate_bpm, 15, delta=1.0)
        self.assertGreater(sp.hf_nu, 80)

    def test_spectral_needs_enough_data(self):
        self.assertIsNone(spectral_metrics([0, 1, 2], [1000, 1000, 1000]))


if __name__ == "__main__":
    unittest.main()
