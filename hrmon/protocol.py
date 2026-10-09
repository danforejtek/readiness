"""Morning measurement protocol: nominal timing and the auto-extension rule.

The iOS app mirrors these values in `AppSettings` (ReadinessApp/ReadinessApp/App/AppSettings.swift);
change both together.
"""
from __future__ import annotations

SETTLE_S = 15.0          # discarded at the start so the heart settles after lying down
DURATION_S = 120.0       # nominal measurement, Elonga's duration

# When the nominal time is up with fewer than MIN_CLEAN_BEATS accepted beats (too many rejected),
# keep measuring until that many are in or MAX_EXTENSION_S extra seconds have passed, whichever first.
MIN_CLEAN_BEATS = 80
MAX_EXTENSION_S = 60.0


def beats_needed(clean_beats: int) -> int:
    """Clean beats still missing for the extension rule (0 when enough)."""
    return max(0, MIN_CLEAN_BEATS - clean_beats)


def measurement_done(measured_s: float, duration_s: float, clean_beats: int) -> bool:
    """Whether a measurement that has run `measured_s` seconds past the settle phase may stop."""
    if measured_s < duration_s:
        return False
    return clean_beats >= MIN_CLEAN_BEATS or measured_s >= duration_s + MAX_EXTENSION_S


def extending(measured_s: float, duration_s: float, clean_beats: int) -> bool:
    """True while the measurement runs past its nominal duration to collect clean beats."""
    return measured_s >= duration_s and not measurement_done(measured_s, duration_s, clean_beats)
