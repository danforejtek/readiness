"""CSV logging: one row per RR interval (or per notification without RR), plus the readiness trend file."""
from __future__ import annotations

import csv
from datetime import datetime
from pathlib import Path
from typing import Optional

COLUMNS = ["timestamp_iso", "elapsed_s", "hr_bpm", "rr_ms", "contact", "battery_pct"]


class SessionLogger:
    def __init__(self, path: Optional[Path] = None, directory: Path = Path("sessions")):
        if path is None:
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / f"{datetime.now():%Y-%m-%d_%H%M%S}.csv"
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self._file = open(path, "w", newline="")
        self._writer = csv.writer(self._file)
        self._writer.writerow(COLUMNS)
        self.rows = 0

    def log(self, elapsed_s: float, hr: int, rr_ms: Optional[float],
            contact: Optional[bool], battery: Optional[int]) -> None:
        self._writer.writerow([
            datetime.now().isoformat(timespec="milliseconds"),
            f"{elapsed_s:.3f}",
            hr,
            "" if rr_ms is None else f"{rr_ms:.1f}",
            "" if contact is None else int(contact),
            "" if battery is None else battery,
        ])
        self.rows += 1
        if self.rows % 20 == 0:
            self._file.flush()

    def close(self) -> None:
        if not self._file.closed:
            self._file.close()


def append_readiness(path: Path, row: dict) -> None:
    """Append one measurement; if the file has an older/different header, rewrite it with the union of columns."""
    path.parent.mkdir(parents=True, exist_ok=True)
    existing: list[dict] = []
    fieldnames = list(row)
    if path.exists():
        with open(path, newline="") as f:
            reader = csv.DictReader(f)
            old_fields = reader.fieldnames or []
            existing = list(reader)
        if old_fields != fieldnames:
            fieldnames = list(old_fields) + [c for c in fieldnames if c not in old_fields]
        else:
            with open(path, "a", newline="") as f:
                csv.DictWriter(f, fieldnames=fieldnames).writerow(row)
            return
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for r in existing:
            writer.writerow({k: r.get(k, "") for k in fieldnames})
        writer.writerow({k: row.get(k, "") for k in fieldnames})


def read_readiness(path: Path, last: int = 7) -> list[dict]:
    if not path.exists():
        return []
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    return rows[-last:]
