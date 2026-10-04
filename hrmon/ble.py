"""Bluetooth LE access to a band that implements the standard Heart Rate Profile (service 0x180D)."""
from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable, Optional

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice
from bleak.exc import BleakError

HR_SERVICE = "0000180d-0000-1000-8000-00805f9b34fb"
HR_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"
BODY_SENSOR_LOCATION = "00002a38-0000-1000-8000-00805f9b34fb"
BATTERY_LEVEL = "00002a19-0000-1000-8000-00805f9b34fb"
DEVICE_INFO_CHARS = {
    "00002a29-0000-1000-8000-00805f9b34fb": "manufacturer",
    "00002a24-0000-1000-8000-00805f9b34fb": "model",
    "00002a25-0000-1000-8000-00805f9b34fb": "serial",
    "00002a26-0000-1000-8000-00805f9b34fb": "firmware",
    "00002a27-0000-1000-8000-00805f9b34fb": "hardware",
    "00002a28-0000-1000-8000-00805f9b34fb": "software",
}
SENSOR_LOCATIONS = {0: "other", 1: "chest", 2: "wrist", 3: "finger", 4: "hand", 5: "ear lobe", 6: "foot"}

CONFIG_PATH = Path(os.environ.get("HRMON_CONFIG", "~/.config/hrmon/device.json")).expanduser()

Logger = Callable[[str], None]


class BandNotFound(Exception):
    """No device advertising the Heart Rate Service was seen."""


@dataclass
class HRSample:
    hr: int
    contact: Optional[bool]  # None when the band does not report skin contact
    energy_kj: Optional[int]
    rr_ms: list[float]
    raw: bytes

    @property
    def flags(self) -> int:
        return self.raw[0]


def parse_hr_measurement(data: bytes) -> HRSample:
    """Decode a Heart Rate Measurement (0x2A37) notification per the Bluetooth HRS spec.

    flags bit0: HR is uint16 (else uint8); bit1: skin contact detected; bit2: contact supported;
    bit3: energy expended uint16 present; bit4: one or more RR intervals (uint16, 1/1024 s) present.
    """
    data = bytes(data)
    if len(data) < 2:
        raise ValueError(f"heart rate measurement too short: {data.hex()}")
    flags = data[0]
    if flags & 0x01:
        hr = int.from_bytes(data[1:3], "little")
        i = 3
    else:
        hr = data[1]
        i = 2
    contact = bool(flags & 0x02) if flags & 0x04 else None
    energy = None
    if flags & 0x08 and i + 1 < len(data):
        energy = int.from_bytes(data[i:i + 2], "little")
        i += 2
    rr: list[float] = []
    if flags & 0x10:
        while i + 1 < len(data):
            rr.append(int.from_bytes(data[i:i + 2], "little") * 1000.0 / 1024.0)
            i += 2
    return HRSample(hr=hr, contact=contact, energy_kj=energy, rr_ms=rr, raw=data)


# --- remembered device -------------------------------------------------------------

def load_saved_device() -> Optional[dict]:
    try:
        return json.loads(CONFIG_PATH.read_text())
    except (OSError, ValueError):
        return None


def save_device(address: str, name: Optional[str]) -> Path:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps({"address": address, "name": name}, indent=2) + "\n")
    return CONFIG_PATH


# --- discovery ---------------------------------------------------------------------

async def discover_hr_devices(timeout: float = 10.0, all_devices: bool = False):
    """Return [(device, advertisement, is_heart_rate)] sorted HR-first, strongest signal first."""
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    out = []
    for dev, adv in found.values():
        is_hr = HR_SERVICE in {u.lower() for u in adv.service_uuids}
        if is_hr or all_devices:
            out.append((dev, adv, is_hr))
    out.sort(key=lambda x: (not x[2], -(x[1].rssi if x[1].rssi is not None else -999)))
    return out


async def find_band(address: Optional[str] = None, name: Optional[str] = None,
                    timeout: float = 10.0, log: Optional[Logger] = None) -> BLEDevice:
    """Locate the band: by saved/explicit address first, else any Heart Rate device (optionally by name)."""
    log = log or (lambda _msg: None)
    if address:
        dev = await BleakScanner.find_device_by_address(address, timeout=timeout)
        if dev is not None:
            return dev
        log(f"Saved device {address} not seen, scanning for any heart-rate device ...")
    devices = [(d, a) for d, a, is_hr in await discover_hr_devices(timeout) if is_hr]
    if name:
        devices = [(d, a) for d, a in devices if name.lower() in (a.local_name or d.name or "").lower()]
    if not devices:
        raise BandNotFound("no device advertising the Heart Rate Service (0x180D) found")
    if len(devices) > 1:
        names = ", ".join(f"{a.local_name or d.name or '?'} ({d.address}, {a.rssi} dBm)" for d, a in devices)
        log(f"Several heart-rate devices seen: {names}. Using the strongest; pass --name or --address to choose.")
    return devices[0][0]


# --- streaming client --------------------------------------------------------------

class HeartRateClient:
    """Connects to the band, streams Heart Rate Measurement notifications and reconnects when dropped."""

    def __init__(self, locate: Callable[[], Awaitable[BLEDevice]],
                 on_sample: Callable[[HRSample], None],
                 on_status: Optional[Logger] = None,
                 battery_interval: float = 60.0):
        self._locate = locate
        self._on_sample = on_sample
        self._status = on_status or (lambda _msg: None)
        self.battery_interval = battery_interval
        self.device: Optional[BLEDevice] = None
        self.device_info: dict[str, str] = {}
        self.sensor_location: Optional[str] = None
        self.battery: Optional[int] = None
        self.connected = False
        self.reconnects = 0

    def _handle(self, _char, data: bytearray) -> None:
        try:
            sample = parse_hr_measurement(bytes(data))
        except ValueError as exc:
            self._status(f"bad notification: {exc}")
            return
        self._on_sample(sample)

    async def _read_static(self, client: BleakClient) -> None:
        for uuid, key in DEVICE_INFO_CHARS.items():
            if client.services.get_characteristic(uuid) is None:
                continue
            try:
                raw = bytes(await client.read_gatt_char(uuid))
                self.device_info[key] = raw.decode("utf-8", "replace").strip("\x00 ")
            except BleakError:
                pass
        if client.services.get_characteristic(BODY_SENSOR_LOCATION) is not None:
            try:
                code = bytes(await client.read_gatt_char(BODY_SENSOR_LOCATION))[0]
                self.sensor_location = SENSOR_LOCATIONS.get(code, str(code))
            except (BleakError, IndexError):
                pass

    async def _read_battery(self, client: BleakClient) -> None:
        if client.services.get_characteristic(BATTERY_LEVEL) is None:
            return
        try:
            self.battery = bytes(await client.read_gatt_char(BATTERY_LEVEL))[0]
        except (BleakError, IndexError):
            pass

    async def run(self, stop: asyncio.Event) -> None:
        backoff = 2.0
        first = True
        while not stop.is_set():
            try:
                device = await self._locate()
                self.device = device
                self._status(f"Connecting to {device.name or device.address} ...")
                disconnected = asyncio.Event()
                loop = asyncio.get_running_loop()

                def on_disconnect(_client) -> None:
                    loop.call_soon_threadsafe(disconnected.set)

                async with BleakClient(device, disconnected_callback=on_disconnect, timeout=20.0) as client:
                    self.connected = True
                    if not first:
                        self.reconnects += 1
                    first = False
                    backoff = 2.0
                    await self._read_static(client)
                    await self._read_battery(client)
                    await client.start_notify(HR_MEASUREMENT, self._handle)
                    label = device.name or self.device_info.get("model") or device.address
                    self._status(f"Connected to {label}, streaming")
                    while not stop.is_set() and not disconnected.is_set():
                        await _wait_any((stop, disconnected), timeout=self.battery_interval)
                        if not stop.is_set() and not disconnected.is_set():
                            await self._read_battery(client)
                    if not disconnected.is_set():
                        try:
                            await client.stop_notify(HR_MEASUREMENT)
                        except BleakError:
                            pass
                self.connected = False
                if stop.is_set():
                    return
                self._status("Connection lost, reconnecting ...")
            except asyncio.CancelledError:
                raise
            except (BleakError, BandNotFound, asyncio.TimeoutError, OSError) as exc:
                self.connected = False
                if isinstance(exc, BandNotFound):
                    self._status("Band not found. Is it on (blue blinking) and not connected to a phone? Retrying ...")
                else:
                    self._status(f"{exc.__class__.__name__}: {exc}. Retrying in {backoff:.0f}s")
                await _wait_any((stop,), timeout=backoff)
                backoff = min(backoff * 2, 30.0)


async def _wait_any(events: tuple[asyncio.Event, ...], timeout: float) -> None:
    tasks = [asyncio.create_task(e.wait()) for e in events]
    try:
        await asyncio.wait(tasks, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()


# --- one-off diagnostics -----------------------------------------------------------

async def dump_device(device: BLEDevice, seconds: float = 20.0, log: Logger = print) -> tuple[int, int]:
    """Print the full GATT table with readable values, then raw HR notifications. Returns (notifications, rr_count)."""
    async with BleakClient(device, timeout=20.0) as client:
        log(f"Connected to {device.name or '?'} ({device.address})")
        for svc in client.services:
            log(f"service {svc.uuid}  {svc.description}")
            for ch in svc.characteristics:
                line = f"   char {ch.uuid}  [{','.join(ch.properties)}]  {ch.description}"
                if "read" in ch.properties:
                    try:
                        val = bytes(await client.read_gatt_char(ch))
                        line += f"  = {val.hex() or '<empty>'}"
                        txt = val.decode("utf-8", "replace").strip("\x00")
                        if txt and txt.isprintable():
                            line += f"  {txt!r}"
                    except BleakError as exc:
                        line += f"  <read failed: {exc}>"
                log(line)
        if client.services.get_characteristic(HR_MEASUREMENT) is None:
            log("\nNo Heart Rate Measurement characteristic (0x2A37) on this device.")
            return 0, 0

        n = 0
        rr_count = 0

        def cb(_c, data: bytearray) -> None:
            nonlocal n, rr_count
            n += 1
            s = parse_hr_measurement(bytes(data))
            rr_count += len(s.rr_ms)
            log(f"   raw={s.raw.hex():<16} flags=0b{s.flags:08b} hr={s.hr:3d} contact={s.contact} "
                f"energy={s.energy_kj} rr_ms={[round(x) for x in s.rr_ms]}")

        log(f"\nHeart Rate Measurement notifications for {seconds:.0f} s:")
        await client.start_notify(HR_MEASUREMENT, cb)
        await asyncio.sleep(seconds)
        await client.stop_notify(HR_MEASUREMENT)
        log(f"\n{n} notifications, {rr_count} RR intervals. RR flag {'PRESENT' if rr_count else 'NEVER SET'}.")
        return n, rr_count
