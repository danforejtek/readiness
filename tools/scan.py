"""Step 0: discover the band, dump its GATT table and print raw heart-rate notifications.

Usage:  python tools/scan.py [--all] [--seconds 20] [--name SUBSTR]
  --all       list every BLE device seen, not only those advertising Heart Rate (0x180D)
  --seconds   how long to listen to heart-rate notifications (default 20)
  --name      pick the device whose name contains this text (default: first HR device)
"""
import argparse
import asyncio
import sys

from bleak import BleakClient, BleakScanner

HR_SERVICE = "0000180d-0000-1000-8000-00805f9b34fb"
HR_MEAS = "00002a37-0000-1000-8000-00805f9b34fb"
BATTERY = "00002a19-0000-1000-8000-00805f9b34fb"
DEVINFO = {
    "00002a29-0000-1000-8000-00805f9b34fb": "manufacturer",
    "00002a24-0000-1000-8000-00805f9b34fb": "model",
    "00002a25-0000-1000-8000-00805f9b34fb": "serial",
    "00002a26-0000-1000-8000-00805f9b34fb": "firmware",
    "00002a27-0000-1000-8000-00805f9b34fb": "hardware",
    "00002a28-0000-1000-8000-00805f9b34fb": "software",
}


def parse_hr(data: bytes):
    flags = data[0]
    i = 1
    if flags & 0x01:
        hr = int.from_bytes(data[i:i + 2], "little"); i += 2
    else:
        hr = data[i]; i += 1
    contact = None
    if flags & 0x04:
        contact = bool(flags & 0x02)
    energy = None
    if flags & 0x08:
        energy = int.from_bytes(data[i:i + 2], "little"); i += 2
    rr = []
    if flags & 0x10:
        while i + 1 < len(data):
            rr.append(int.from_bytes(data[i:i + 2], "little") * 1000 / 1024); i += 2
    return hr, contact, energy, rr


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--name")
    ap.add_argument("--scan", type=float, default=10)
    args = ap.parse_args()

    print(f"Scanning {args.scan:.0f} s ...", flush=True)
    found = await BleakScanner.discover(timeout=args.scan, return_adv=True)
    hr_devices = []
    for dev, adv in found.values():
        is_hr = HR_SERVICE in [u.lower() for u in adv.service_uuids]
        if is_hr or args.all:
            tag = "HR " if is_hr else "   "
            mfr = {k: v.hex() for k, v in adv.manufacturer_data.items()}
            print(f"{tag}{adv.local_name or dev.name!s:24} {dev.address}  rssi={adv.rssi}  svc={adv.service_uuids}  mfr={mfr}")
        if is_hr:
            hr_devices.append((dev, adv))
    if not hr_devices:
        print("\nNo device advertising Heart Rate Service 0x180D found. Is the band on (blue blinking) and not connected to a phone/watch?")
        sys.exit(1)

    target = hr_devices[0][0]
    if args.name:
        for dev, adv in hr_devices:
            if args.name.lower() in ((adv.local_name or dev.name or "").lower()):
                target = dev
    print(f"\nConnecting to {target.name} ({target.address}) ...", flush=True)

    async with BleakClient(target, timeout=20) as client:
        print("Connected. GATT table:")
        info = {}
        for svc in client.services:
            print(f"  service {svc.uuid}  {svc.description}")
            for ch in svc.characteristics:
                print(f"    char {ch.uuid}  props={','.join(ch.properties)}  {ch.description}")
                if ch.uuid.lower() in DEVINFO and "read" in ch.properties:
                    try:
                        info[DEVINFO[ch.uuid.lower()]] = (await client.read_gatt_char(ch)).decode(errors="replace")
                    except Exception as e:  # noqa: BLE001
                        info[DEVINFO[ch.uuid.lower()]] = f"<read failed: {e}>"
                if ch.uuid.lower() == BATTERY and "read" in ch.properties:
                    try:
                        info["battery_pct"] = (await client.read_gatt_char(ch))[0]
                    except Exception as e:  # noqa: BLE001
                        info["battery_pct"] = f"<read failed: {e}>"
        print("\nDevice info:", info)

        n = 0
        rr_seen = 0

        def cb(_, data: bytearray):
            nonlocal n, rr_seen
            n += 1
            hr, contact, energy, rr = parse_hr(bytes(data))
            rr_seen += len(rr)
            print(f"  raw={bytes(data).hex():16} flags=0b{data[0]:08b} hr={hr:3d} contact={contact} energy={energy} rr_ms={[round(x) for x in rr]}")

        print(f"\nListening to Heart Rate Measurement for {args.seconds:.0f} s ...")
        await client.start_notify(HR_MEAS, cb)
        await asyncio.sleep(args.seconds)
        await client.stop_notify(HR_MEAS)
        print(f"\n{n} notifications, {rr_seen} RR intervals. RR flag {'PRESENT' if rr_seen else 'NEVER SET'}.")


if __name__ == "__main__":
    asyncio.run(main())
