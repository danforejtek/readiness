import math
import random
import statistics
import unittest

from hrmon.ble import parse_hr_measurement
from hrmon.hrv import RRBuffer, breathing_limit_hz, compute_metrics, poincare, spectral_metrics, stress_index


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

    @staticmethod
    def _feed(values):
        b, t = RRBuffer(), 0.0
        for v in values:
            t += v / 1000
            b.add(v, t)
        return b

    def test_artefact_filter_recovers_after_a_level_shift(self):
        # a genuine, sustained drop from 1200 to 950 ms (> 20 %): the first five new beats are rejected,
        # then they become the new reference and the rest is accepted
        b = self._feed([1200] * 10 + [950] * 60)
        self.assertEqual(b.artefacts, 5)
        self.assertEqual(b.values, [1200] * 10 + [950] * 55)

    def test_isolated_artefacts_are_still_rejected(self):
        b = self._feed([1000] * 10 + [1400] + [1000] * 5 + [650] * 3 + [1000] * 5 + [1500, 700] * 2 + [1000] * 5)
        self.assertEqual(b.artefacts, 1 + 3 + 4)
        self.assertEqual(set(b.values), {1000})

    def test_out_of_range_beats_do_not_count_towards_recovery(self):
        # four deviating beats with range rejections in between are not five in a row: no recovery yet
        b = self._feed([1000] * 10 + [700, 2500, 700, 250, 700, 2600, 700])
        self.assertEqual(b.artefacts, 7)
        self.assertEqual(b.values, [1000] * 10)
        # inconsistent deviations (ectopic pairs) never become the reference
        b = self._feed([1000] * 10 + [700, 1300] * 5 + [1000])
        self.assertEqual(b.values, [1000] * 11)

    def test_differences_across_a_rejected_beat_are_skipped(self):
        # 1500 ms is rejected; the difference 1005 − 1010 spans it and must not enter RMSSD, pNN50 or SD1
        seq = [1000, 1020, 990, 1010, 1500, 1005, 940, 1015, 995, 1060, 1000]
        b = self._feed(seq)
        self.assertEqual(b.artefacts, 1)
        self.assertEqual(b.breaks, [4])
        clean = [1000, 1020, 990, 1010, 1005, 940, 1015, 995, 1060, 1000]
        self.assertEqual(b.values, clean)
        diffs = [20, -30, 20, -65, 75, -20, 65, -60]          # every difference except 1005 − 1010
        m = b.metrics()
        self.assertAlmostEqual(m.rmssd, math.sqrt(sum(d * d for d in diffs) / len(diffs)))
        self.assertAlmostEqual(m.pnn50, 100.0 * 4 / 8)        # denominator: the 8 differences used
        # the same as the sequence with the beat and its neighbour difference removed by hand
        self.assertAlmostEqual(m.rmssd, compute_metrics(clean, breaks=[4]).rmssd)
        self.assertAlmostEqual(compute_metrics(clean).rmssd,
                               math.sqrt(sum(d * d for d in diffs + [-5]) / 9))  # what it was before
        # SDNN and mean RR use every accepted beat
        self.assertAlmostEqual(m.sdnn, statistics.stdev(clean))
        self.assertAlmostEqual(m.mean_rr, statistics.fmean(clean))
        sd1, sd2 = poincare(b.values, b.breaks)
        self.assertAlmostEqual(sd1 ** 2, statistics.variance(diffs) / 2)
        self.assertAlmostEqual(sd2 ** 2, 2 * statistics.variance(clean) - sd1 ** 2)

    def test_breaks_after_several_rejections_and_in_windows(self):
        # two rejections in a row give one break; rejections before the first accepted beat give none
        b = self._feed([250, 1000, 1010, 990, 1000, 2500, 1400, 1150, 1000, 1005])
        self.assertEqual(b.values, [1000, 1010, 990, 1000, 1150, 1000, 1005])
        self.assertEqual(b.breaks, [4])
        # windowed metrics see the breaks relative to the window start
        self.assertEqual(b.window_breaks(), [4])
        self.assertEqual(b.window(1.5), [1000, 1005])
        self.assertEqual(b.window_breaks(1.5), [])
        self.assertEqual(b.window(2.5), [1150, 1000, 1005])
        self.assertEqual(b.window_breaks(2.5), [])     # a break on the window's first beat has no difference
        self.assertEqual(b.window(7.5), [1000, 1150, 1000, 1005])
        self.assertEqual(b.window_breaks(7.5), [1])
        self.assertAlmostEqual(b.metrics(7.5).rmssd, math.sqrt((150 ** 2 + 5 ** 2) / 2))
        # a level shift: the beat after the five rejected ones follows a gap
        shift = self._feed([1200] * 10 + [950] * 10)
        self.assertEqual(shift.breaks, [10])

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

    @staticmethod
    def _breathing(freq, seconds=150, base=900):
        t, rr, clock = [], [], 0.0
        rng = random.Random(1)
        while clock < seconds:
            v = base + 40 * math.sin(2 * math.pi * freq * clock) + rng.gauss(0, 3)
            clock += v / 1000
            t.append(clock)
            rr.append(v)
        return spectral_metrics(t, rr)

    def test_spectral_breathing_rate_from_spectral_peak(self):
        # 15 breaths/min = 0.25 Hz modulation
        sp = self._breathing(0.25)
        self.assertAlmostEqual(sp.breathing_rate_bpm, 15, delta=1.0)
        self.assertAlmostEqual(sp.hf_peak_hz, 0.25, delta=0.01)
        self.assertGreater(sp.hf_nu, 80)

    def test_slow_breathing_below_the_hf_band(self):
        # 7 breaths/min = 0.117 Hz lies in LF: the breathing window (0.10–0.50 Hz) still finds it
        sp = self._breathing(7 / 60)
        self.assertAlmostEqual(sp.breathing_rate_bpm, 7, delta=0.5)
        self.assertGreater(sp.lf_hf, 10)

    def test_breathing_window_stops_at_the_mean_nyquist_frequency(self):
        # at 50 bpm one sample per beat resolves at most 50 / 120 = 0.417 Hz (Laguna 1998)
        self.assertAlmostEqual(breathing_limit_hz([1200.0] * 40), 50 / 120)
        self.assertEqual(breathing_limit_hz([800.0] * 40), 0.50)          # 75 bpm: the 0.50 Hz limit applies
        # 24 breaths/min (0.40 Hz) at 50 bpm is found; with the window open to 0.50 Hz its mirror image above the
        # Nyquist frequency won and it read 26/min
        sp = self._breathing(0.40, base=1200)
        self.assertAlmostEqual(sp.breathing_rate_bpm, 24, delta=0.5)
        # a peak in the last bin below the capped edge is unresolved
        sp = self._breathing(0.415, base=1200)
        self.assertIsNone(sp.breathing_rate_bpm)

    def test_breathing_peak_on_the_window_edge_is_unresolved(self):
        # 5.9 breaths/min = 0.098 Hz: the strongest bin of the window is its first one -> None
        sp = self._breathing(0.098)
        self.assertIsNone(sp.breathing_rate_bpm)
        self.assertIsNotNone(sp.hf_peak_hz)

    def test_spectral_needs_enough_data(self):
        self.assertIsNone(spectral_metrics([0, 1, 2], [1000, 1000, 1000]))


if __name__ == "__main__":
    unittest.main()
