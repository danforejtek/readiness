"""hrmon command line: scan | dump | monitor | measure | readiness."""
from __future__ import annotations

import argparse
import asyncio
import signal
import sys
import time
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

from rich.console import Console, Group
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from . import ble
from .hrv import RRBuffer, poincare, stress_index
from .log import SessionLogger, append_readiness, read_readiness
from .readiness import BASELINE, MODERATE, READY, REST, TAGS, Assessment, assess_all, records_from_rows

console = Console()
SPARK = "▁▂▃▄▅▆▇█"
READINESS_FILE = Path("sessions/readiness.csv")
STATUS_STYLE = {READY: "bold green", MODERATE: "bold yellow", REST: "bold red", BASELINE: "bold cyan"}
STATUS_LABEL = {READY: "READY – go for it", MODERATE: "MODERATE – easy to medium day",
                REST: "REST – recovery day", BASELINE: "BUILDING BASELINE"}


def _fmt(value, digits: int = 0, unit: str = "") -> str:
    if value is None or value != value:  # None or NaN
        return "–"
    return f"{value:.{digits}f}{unit}"


def _sparkline(values, width: int = 48) -> str:
    vals = list(values)[-width:]
    if len(vals) < 2:
        return ""
    lo, hi = min(vals), max(vals)
    span = (hi - lo) or 1
    return "".join(SPARK[min(7, int((v - lo) / span * 7.999))] for v in vals)


def _mmss(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 60:02d}:{s % 60:02d}"


class Session:
    """Collects samples from the client, feeds the RR buffer and the CSV logger."""

    def __init__(self, window_s: float, logger: SessionLogger, settle_s: float = 0.0):
        self.window_s = window_s
        self.logger = logger
        self.settle_s = settle_s
        self.buffer = RRBuffer()
        self.client: Optional[ble.HeartRateClient] = None
        self.hr: Optional[int] = None
        self.last_rr: Optional[float] = None
        self.contact: Optional[bool] = None
        self.beats = 0
        self.notifications = 0
        self.rr_notifications = 0
        self.hr_history: deque[int] = deque(maxlen=240)
        self.t0: Optional[float] = None          # set at first sample
        self.last_sample_at: Optional[float] = None
        self.status = "starting"
        self.feeling: Optional[int] = None       # morning check-in, written to readiness.csv
        self.tags: tuple[str, ...] = ()

    def elapsed(self) -> float:
        return 0.0 if self.t0 is None else time.monotonic() - self.t0

    @property
    def settling(self) -> bool:
        return self.t0 is None or self.elapsed() < self.settle_s

    def on_status(self, msg: str) -> None:
        self.status = msg

    def on_sample(self, s: ble.HRSample) -> None:
        now = time.monotonic()
        if self.t0 is None:
            self.t0 = now
        el = now - self.t0
        self.notifications += 1
        self.last_sample_at = now
        self.hr = s.hr
        self.contact = s.contact
        if s.hr:
            self.hr_history.append(s.hr)
        battery = self.client.battery if self.client else None
        if s.rr_ms:
            self.rr_notifications += 1
            for rr in s.rr_ms:
                self.beats += 1
                self.last_rr = rr
                if el >= self.settle_s:
                    self.buffer.add(rr, el)
                self.logger.log(el, s.hr, rr, s.contact, battery)
        else:
            self.logger.log(el, s.hr, None, s.contact, battery)


def _render(sess: Session, title: str, remaining: Optional[float] = None) -> Panel:
    win = sess.buffer.metrics(sess.window_s)
    tot = sess.buffer.metrics()
    client = sess.client
    stale = sess.last_sample_at is not None and time.monotonic() - sess.last_sample_at > 5

    t = Table.grid(padding=(0, 2))
    t.add_column(justify="right", style="bold")
    t.add_column()
    hr_style = "bold red" if not stale else "bold dim"
    t.add_row("Heart rate", Text(f"{_fmt(sess.hr)} bpm", style=hr_style))
    t.add_row("Last RR", _fmt(sess.last_rr, 0, " ms"))
    t.add_row("Skin contact", {True: "yes", False: "no", None: "not reported"}[sess.contact])
    t.add_row("Battery", _fmt(client.battery if client else None, 0, " %"))
    t.add_row("", "")
    t.add_row(f"RMSSD (last {int(sess.window_s)} s)", _fmt(win.rmssd if win else None, 1, " ms"))
    t.add_row("RMSSD (session)", _fmt(tot.rmssd if tot else None, 1, " ms"))
    t.add_row("lnRMSSD (session)", _fmt(tot.ln_rmssd if tot else None, 2))
    t.add_row("SDNN (session)", _fmt(tot.sdnn if tot else None, 1, " ms"))
    t.add_row("pNN50 (session)", _fmt(tot.pnn50 if tot else None, 0, " %"))
    mean_rr = _fmt(tot.mean_rr if tot else None, 0, " ms")
    mean_hr = _fmt(tot.mean_hr if tot else None, 0, " bpm")
    t.add_row("Mean RR / HR", f"{mean_rr} / {mean_hr}")
    art = sess.buffer.artefacts
    pct = 100.0 * art / sess.buffer.total if sess.buffer.total else 0.0
    t.add_row("Beats / artefacts", f"{sess.beats} / {art} ({pct:.0f} %)")
    if sess.settle_s and sess.settling and sess.t0 is not None:
        phase = f"settling {_mmss(sess.settle_s - sess.elapsed())}"
    else:
        phase = _mmss(max(0.0, sess.elapsed() - sess.settle_s))
        if remaining is not None:
            phase += f"   remaining {_mmss(remaining)}"
    t.add_row("Elapsed", phase)

    parts = [t, Text("")]
    spark = _sparkline(sess.hr_history)
    if spark:
        parts += [Text(spark, style="red"), Text("")]
    if client and client.device_info:
        info = client.device_info
        parts.append(Text(" · ".join(f"{k} {v}" for k, v in info.items() if v), style="dim"))
    parts.append(Text(sess.status, style="cyan"))
    if sess.notifications >= 10 and sess.rr_notifications == 0:
        parts.append(Text("No RR intervals in the notifications so far, so HRV cannot be computed.", style="yellow"))
    return Panel(Group(*parts), title=title, border_style="red" if not stale else "dim")


def _status_line(sess: Session) -> str:
    win = sess.buffer.metrics(sess.window_s)
    return (f"{_mmss(sess.elapsed())}  HR {_fmt(sess.hr):>3} bpm  RR {_fmt(sess.last_rr):>4} ms  "
            f"RMSSD({int(sess.window_s)}s) {_fmt(win.rmssd if win else None, 1):>5} ms  "
            f"beats {sess.beats}  artefacts {sess.buffer.artefacts}  "
            f"batt {_fmt(sess.client.battery if sess.client else None)} %")


async def _run_session(args, duration: Optional[float], settle: float, title: str,
                       on_finish: Callable[[Session], None]) -> None:
    saved = ble.load_saved_device() or {}
    address = args.address or saved.get("address")
    name = args.name or saved.get("name")
    logger = SessionLogger(Path(args.out) if args.out else None)
    sess = Session(args.window, logger, settle_s=settle)
    sess.feeling = getattr(args, "feeling", None)
    sess.tags = _parse_tags(getattr(args, "tags", ""))
    total = None if duration is None else duration + settle

    async def locate():
        return await ble.find_band(address=address, name=name, timeout=args.scan_timeout, log=sess.on_status)

    client = ble.HeartRateClient(locate, sess.on_sample, sess.on_status)
    sess.client = client
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    runner = asyncio.create_task(client.run(stop))
    console.print(f"Logging to [bold]{logger.path}[/]  (Ctrl-C to stop)")

    def done() -> bool:
        return total is not None and sess.t0 is not None and sess.elapsed() >= total

    def remaining() -> Optional[float]:
        if total is None:
            return None
        return max(0.0, total - sess.elapsed()) if not sess.settling else duration

    try:
        if console.is_terminal:
            with Live(_render(sess, title), console=console, refresh_per_second=2) as live:
                while not stop.is_set() and not done():
                    live.update(_render(sess, title, remaining()))
                    try:
                        await asyncio.wait_for(stop.wait(), timeout=0.25)
                    except asyncio.TimeoutError:
                        pass
                live.update(_render(sess, title, 0.0 if total is not None else None))
        else:  # piped or a terminal without cursor control: one status line every 2 s
            last_status = None
            while not stop.is_set() and not done():
                if sess.status != last_status:
                    console.print(sess.status, markup=False, highlight=False)
                    last_status = sess.status
                if sess.t0 is not None:
                    console.print(_status_line(sess), markup=False, highlight=False)
                try:
                    await asyncio.wait_for(stop.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    pass
    finally:
        stop.set()
        try:
            await asyncio.wait_for(runner, timeout=10)
        except (asyncio.TimeoutError, Exception):  # noqa: BLE001
            runner.cancel()
        logger.close()
    on_finish(sess)


def _finish_monitor(sess: Session) -> None:
    m = sess.buffer.metrics()
    console.print(f"Saved {sess.logger.rows} rows to [bold]{sess.logger.path}[/]")
    if m:
        console.print(f"Session: {m.n} clean beats over {_mmss(m.duration_s)}, mean HR {m.mean_hr:.0f} bpm, "
                      f"RMSSD {m.rmssd:.1f} ms, SDNN {m.sdnn:.1f} ms, artefacts {m.artefact_pct:.0f} %")
    sp = sess.buffer.spectral()
    if sp:
        console.print(f"Spectral: LF {sp.lf_ms2:.0f} ms², HF {sp.hf_ms2:.0f} ms², LF/HF {sp.lf_hf:.2f}, "
                      f"breathing ≈ {sp.breathing_rate_bpm:.0f}/min")


def _finish_measure(sess: Session) -> None:
    m = sess.buffer.metrics()
    console.print(f"Raw beats saved to [bold]{sess.logger.path}[/]")
    if m is None or m.n < 30:
        console.print("[red]Not enough clean RR intervals for a reliable result. "
                      "Check that the sensor sits snugly with good skin contact and try again.[/]")
        return
    sp = sess.buffer.spectral()
    pc = poincare(sess.buffer.values)
    si = stress_index(sess.buffer.values)
    quality = "good" if m.artefact_pct < 5 else "fair" if m.artefact_pct < 15 else "poor"
    row = {
        "date": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "duration_s": f"{m.duration_s:.0f}",
        "beats": m.n,
        "mean_hr": f"{m.mean_hr:.1f}",
        "mean_rr_ms": f"{m.mean_rr:.1f}",
        "rmssd_ms": f"{m.rmssd:.1f}",
        "ln_rmssd": f"{m.ln_rmssd:.2f}",
        "sdnn_ms": f"{m.sdnn:.1f}",
        "pnn50_pct": f"{m.pnn50:.1f}",
        "artefact_pct": f"{m.artefact_pct:.1f}",
        "quality": quality,
        "lf_ms2": f"{sp.lf_ms2:.0f}" if sp else "",
        "hf_ms2": f"{sp.hf_ms2:.0f}" if sp else "",
        "lf_hf": f"{sp.lf_hf:.2f}" if sp and sp.lf_hf != float("inf") else "",
        "breathing_bpm": f"{sp.breathing_rate_bpm:.1f}" if sp else "",
        "settle_s": f"{sess.settle_s:.0f}",
        "feeling": str(sess.feeling) if sess.feeling else "",
        "tags": ";".join(sess.tags),
        "source": "band",
        "sd1_ms": f"{pc[0]:.1f}" if pc else "",
        "sd2_ms": f"{pc[1]:.1f}" if pc else "",
        "stress_index": f"{si:.1f}" if si is not None else "",
    }
    append_readiness(READINESS_FILE, row)

    table = Table(title="Resting HRV measurement", show_header=True)
    table.add_column("Metric", style="bold")
    table.add_column("Value", justify="right")
    table.add_row("Mean HR", f"{m.mean_hr:.0f} bpm")
    table.add_row("Mean RR", f"{m.mean_rr:.0f} ms")
    table.add_row("RMSSD", f"{m.rmssd:.1f} ms")
    table.add_row("lnRMSSD", f"{m.ln_rmssd:.2f}")
    table.add_row("SDNN", f"{m.sdnn:.1f} ms")
    table.add_row("pNN50", f"{m.pnn50:.0f} %")
    if sp:
        table.add_row("LF / HF power", f"{sp.lf_ms2:.0f} / {sp.hf_ms2:.0f} ms²")
        table.add_row("LF/HF ratio", f"{sp.lf_hf:.2f}  (LF {sp.lf_nu:.0f} nu)")
        table.add_row("Breathing (from HF peak)", f"≈ {sp.breathing_rate_bpm:.0f} /min")
    if pc:
        table.add_row("Poincaré SD1 / SD2", f"{pc[0]:.1f} / {pc[1]:.1f} ms")
    if si is not None:
        table.add_row("Stress index (Baevsky)", f"{si:.0f}")
    table.add_row("Clean beats", f"{m.n} ({m.artefact_pct:.0f} % artefacts, {quality})")
    console.print(table)
    console.print(f"Appended to [bold]{READINESS_FILE}[/]")
    _print_readiness(days=14)


# --- readiness report ---------------------------------------------------------------

def _print_readiness(days: int = 14) -> int:
    rows = read_readiness(READINESS_FILE, last=10_000)
    records = records_from_rows(rows)
    if not records:
        console.print(f"[yellow]No measurements yet in {READINESS_FILE}. Run `hrmon measure` after waking up.[/]")
        return 1
    assessments = assess_all(records)
    a = assessments[-1]
    console.print(_readiness_panel(a))

    trend = Table(title=f"Last {days} mornings", show_header=True)
    for col, just in (("date", "left"), ("HR", "right"), ("lnRMSSD", "right"), ("7-day", "right"),
                      ("RMSSD", "right"), ("score", "right"), ("verdict", "left")):
        trend.add_column(col, justify=just)
    for x in assessments[-days:]:
        r = x.record
        flag = " ⚠ illness" if x.illness else ""
        trend.add_row(r.day.isoformat(), f"{r.mean_hr:.0f}", f"{r.ln_rmssd:.2f}",
                      _fmt(x.ln_week, 2), f"{r.rmssd:.0f}", _fmt(x.score),
                      Text(x.status + flag, style=STATUS_STYLE[x.status]))
    console.print(trend)
    return 0


def _readiness_panel(a: Assessment) -> Panel:
    r = a.record
    head = Text(STATUS_LABEL[a.status], style=STATUS_STYLE[a.status])
    if a.score is not None:
        head.append(f"   score {a.score}/100", style="bold")
    if a.illness:
        head.append("   ⚠ possible illness", style="bold red")
    if a.low_confidence:
        head.append("   (low confidence)", style="yellow")
    t = Table.grid(padding=(0, 2))
    t.add_column(justify="right", style="bold")
    t.add_column()
    t.add_row("Measured", r.when.strftime("%Y-%m-%d %H:%M"))
    ln_rng = a.ln_range
    hr_rng = a.hr_range
    t.add_row("lnRMSSD today", f"{r.ln_rmssd:.2f}  (RMSSD {r.rmssd:.0f} ms)"
              + (f"   normal {ln_rng[0]:.2f}–{ln_rng[1]:.2f}" if ln_rng else ""))
    if a.ln_week is not None:
        t.add_row("lnRMSSD 7-day avg", f"{a.ln_week:.2f}")
    t.add_row("Resting HR today", f"{r.mean_hr:.0f} bpm"
              + (f"   normal {hr_rng[0]:.0f}–{hr_rng[1]:.0f}" if hr_rng else ""))
    if a.z_hrv is not None:
        t.add_row("Deviation", f"HRV {a.z_hrv:+.1f} SD, HR {a.z_hr:+.1f} SD vs {a.baseline_n}-day baseline")
    if a.regeneration is not None or a.stress is not None:
        t.add_row("Regeneration / Stress", f"{_fmt(a.regeneration, 1)} / {_fmt(a.stress, 1)} of 10   (5 = your normal)")
    if r.hf_ms2 is not None:
        t.add_row("HF / LF power", f"{r.hf_ms2:.0f} / {_fmt(r.lf_ms2)} ms²"
                  + (f", breathing ≈ {r.breathing_rate:.0f}/min" if r.breathing_rate else ""))
    parts = [head, Text(""), t, Text("")]
    for note in a.notes:
        parts.append(Text("• " + note))
    return Panel(Group(*parts), title="Readiness", border_style=STATUS_STYLE[a.status].split()[-1])


# --- commands -----------------------------------------------------------------------

async def _wait_for_band(args) -> ble.BLEDevice:
    saved = ble.load_saved_device() or {}
    address = args.address or saved.get("address")
    name = args.name or saved.get("name")
    deadline = time.monotonic() + args.wait * 60 if args.wait else None
    while True:
        try:
            return await ble.find_band(address=address, name=name, timeout=args.scan_timeout, log=console.print)
        except ble.BandNotFound:
            if deadline is None or time.monotonic() > deadline:
                raise
            console.print("[yellow]No heart-rate band seen. Switch it on (short press, blue blinking), "
                          "make sure no phone app holds it. Scanning again ...[/]")


async def cmd_scan(args) -> int:
    console.print(f"Scanning for {args.scan_timeout:.0f} s ...")
    deadline = time.monotonic() + args.wait * 60 if args.wait else None
    while True:
        devices = await ble.discover_hr_devices(args.scan_timeout, all_devices=args.all)
        hr = [(d, a) for d, a, is_hr in devices if is_hr]
        if hr or deadline is None or time.monotonic() > deadline:
            break
        console.print("[yellow]No heart-rate band yet, scanning again ...[/]")
    table = Table(show_header=True)
    for col in ("HR", "Name", "Address (CoreBluetooth UUID)", "RSSI", "Services"):
        table.add_column(col)
    for d, a, is_hr in devices:
        table.add_row("✓" if is_hr else "", a.local_name or d.name or "", d.address, str(a.rssi),
                      ", ".join(u[4:8] if u.endswith("-0000-1000-8000-00805f9b34fb") else u for u in a.service_uuids))
    console.print(table)
    if not hr:
        console.print("[red]No device advertising the Heart Rate Service (0x180D). Is the band on and free?[/]")
        return 1
    d, a = hr[0]
    if not args.no_save:
        path = ble.save_device(d.address, a.local_name or d.name)
        console.print(f"Remembered [bold]{a.local_name or d.name or d.address}[/] in {path}; "
                      "monitor/measure will connect to it directly.")
    return 0


async def cmd_dump(args) -> int:
    device = await _wait_for_band(args)
    n, rr = await ble.dump_device(device, seconds=args.seconds,
                                  log=lambda msg: console.print(msg, markup=False, highlight=False))
    if n and not args.no_save:
        ble.save_device(device.address, device.name)
    return 0 if n else 1


async def cmd_monitor(args) -> int:
    await _run_session(args, args.duration, 0.0, "hrmon · live", _finish_monitor)
    return 0


def _parse_tags(text: str) -> tuple[str, ...]:
    tags = tuple(t.strip().replace("-", "_") for t in (text or "").replace(";", ",").split(",") if t.strip())
    unknown = [t for t in tags if t not in TAGS]
    if unknown:
        raise SystemExit(f"unknown tag(s) {', '.join(unknown)}; use: {', '.join(TAGS)}")
    return tags


async def cmd_measure(args) -> int:
    _parse_tags(args.tags)   # fail before connecting, not after two minutes
    console.print(Panel(
        "Do this right after waking, before coffee, phone or getting up.\n"
        "Lie still on your back, breathe normally, heart-rate sensor on with good skin contact.\n"
        f"{_mmss(args.settle)} to settle, then {_mmss(args.duration)} of measurement; "
        "the clock starts with the first heartbeat received.",
        title="Morning readiness measurement", border_style="cyan"))
    await _run_session(args, args.duration, args.settle, "hrmon · morning measurement", _finish_measure)
    return 0


async def cmd_readiness(args) -> int:
    return _print_readiness(days=args.days)


async def cmd_analyze(args) -> int:
    from . import analyze as an
    path = Path(args.readiness)
    if not path.exists():
        console.print(f"[red]{path} not found.[/] Export it from the iPhone (Settings › Prepare CSV export) "
                      "or measure on the Mac first.")
        return 1
    all_rows = an.read_rows(path)
    rows = an.filter_rows(all_rows, include_demo=args.include_demo)
    if len(rows) < len(all_rows):
        console.print(f"[dim]Ignoring {len(all_rows) - len(rows)} replay/demo rows (use --include-demo to keep them).[/]")
    beats: dict = {}
    if args.beats:
        beats.update(an.read_beats_export(Path(args.beats)))
    if args.sessions:
        beats.update(an.read_mac_sessions(Path(args.sessions), rows))
    alternatives = args.alt or an.DEFAULT_ALTERNATIVES
    sections = an.build_report(rows, beats, alternatives)
    for s in sections:
        table = Table(title=s.title, show_header=any(s.columns), title_justify="left")
        for c in (s.columns if any(s.columns) else ["", ""]):
            table.add_column(c)
        for r in s.rows:
            table.add_row(*r)
        console.print(table)
        if s.note:
            console.print(Text(s.note, style="dim"))
        console.print()
    if args.markdown:
        Path(args.markdown).write_text(an.to_markdown(sections))
        console.print(f"Report written to [bold]{args.markdown}[/]")
    return 0


def main(argv: Optional[list[str]] = None) -> None:
    p = argparse.ArgumentParser(prog="hrmon", description="Live heart rate, HRV and morning readiness from a Bluetooth LE heart-rate band.")
    p.add_argument("--address", help="CoreBluetooth UUID of the band (default: the one saved by `hrmon scan`)")
    p.add_argument("--name", help="pick the band whose advertised name contains this text")
    p.add_argument("--scan-timeout", type=float, default=10.0, help="seconds per scan (default 10)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="list heart-rate bands in range and remember the strongest one")
    s.add_argument("--all", action="store_true", help="list every BLE device, not only heart-rate ones")
    s.add_argument("--wait", type=float, metavar="MIN", help="keep scanning up to MIN minutes until a band appears")
    s.add_argument("--no-save", action="store_true")
    s.set_defaults(func=cmd_scan)

    d = sub.add_parser("dump", help="connect and print the full GATT table plus raw heart-rate notifications")
    d.add_argument("--seconds", type=float, default=20.0)
    d.add_argument("--wait", type=float, metavar="MIN", help="keep scanning up to MIN minutes until a band appears")
    d.add_argument("--no-save", action="store_true")
    d.set_defaults(func=cmd_dump)

    m = sub.add_parser("monitor", help="live HR + HRV panel with CSV logging")
    m.add_argument("--duration", type=float, default=None, help="seconds to run (unlimited by default)")
    m.add_argument("--out", help="CSV path (default sessions/<timestamp>.csv)")
    m.add_argument("--window", type=float, default=60.0, help="rolling window for live RMSSD, seconds")
    m.set_defaults(func=cmd_monitor)

    e = sub.add_parser("measure", help="morning readiness measurement (15 s settle + 120 s), then the verdict")
    e.add_argument("--duration", type=float, default=120.0, help="measurement seconds (default 120)")
    e.add_argument("--settle", type=float, default=15.0, help="seconds discarded at the start (default 15)")
    e.add_argument("--out", help="CSV path (default sessions/<timestamp>.csv)")
    e.add_argument("--window", type=float, default=60.0, help="rolling window for live RMSSD, seconds")
    e.add_argument("--feeling", type=int, choices=range(1, 6), metavar="1-5",
                   help="how you feel this morning (1 awful … 5 great); stored for tuning, not used by the verdict")
    e.add_argument("--tags", default="", help=f"comma-separated context tags: {', '.join(TAGS)}")
    e.set_defaults(func=cmd_measure)

    r = sub.add_parser("readiness", help="today's readiness / illness verdict and the recent trend")
    r.add_argument("--days", type=int, default=14)
    r.set_defaults(func=cmd_readiness)

    z = sub.add_parser("analyze", help="tuning report: data quality, verdicts vs check-ins, what-if settings")
    z.add_argument("--readiness", default=str(READINESS_FILE),
                   help="readiness CSV from the Mac or the iPhone export (default sessions/readiness.csv)")
    z.add_argument("--beats", help="readiness-beats.csv from the iPhone export (enables the artefact-filter check)")
    z.add_argument("--sessions", help="folder with the Mac's per-session CSVs, e.g. sessions/")
    z.add_argument("--alt", action="append", metavar="KEY=VAL[,KEY=VAL]",
                   help="alternative settings to compare (repeatable); default: a built-in set of one-knob changes")
    z.add_argument("--include-demo", action="store_true", help="keep replay and demo rows")
    z.add_argument("--markdown", metavar="PATH", help="also write the report as Markdown")
    z.set_defaults(func=cmd_analyze)

    args = p.parse_args(argv)
    try:
        code = asyncio.run(args.func(args))
    except KeyboardInterrupt:
        code = 130
    except ble.BandNotFound as exc:
        console.print(f"[red]{exc}[/]")
        code = 1
    sys.exit(code)


if __name__ == "__main__":
    main()
