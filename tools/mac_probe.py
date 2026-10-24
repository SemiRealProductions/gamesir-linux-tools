#!/usr/bin/env python3
"""Can Deadband talk to your devices on macOS? A READ-ONLY check.

Run with Deadband (and GameSir's / Logitech's own apps) closed:

    python3 tools/mac_probe.py

It lists every GameSir and Logitech HID interface the system shows, asks each
GameSir vendor interface the family's three read questions (firmware version,
active profile, one 16-byte settings read -- the same ones `deadband --doctor
--probe` asks on Linux), and asks a G502 X for its onboard-profile layout.
Nothing is written to any device's settings. Works on Linux too, for comparison.

Needs the hidapi Python package: `python3 -m pip install hidapi`. To also reach
a GameSir device whose HID interface the system left without a driver (a Cyclone
2 dongle on macOS does this), add `python3 -m pip install pyusb libusb-package`.
"""
import os
import platform
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path[:0] = [HERE, os.path.join(HERE, 'vendors', 'logitech')]

try:
    import hidcompat as hid
except Exception as e:                       # noqa: BLE001
    sys.exit(f'Could not load hidapi ({e}). Install it with: python3 -m pip install hidapi')

GAMESIR, LOGITECH = 0x3537, 0x046D
# (label, command, the reply's second byte)
READS = (('firmware (0f 09)', (0x0F, 0x09), 0x0A),
         ('active profile (0f 0b)', (0x0F, 0x0B), 0x0C),
         ('read bank 1 @0x0000 x16 (0f 04)', (0x0F, 0x04, 0x01, 0x00, 0x00, 0x10), 0x05))
HEARTBEAT = (0x0F, 0xF2)        # opens the command channel; the app sends it first


def _path(p):
    return p.decode(errors='replace') if isinstance(p, bytes) else str(p)


def list_devices():
    print('## HID interfaces')
    found = []
    for d in hid.enumerate():
        if d.get('vendor_id') not in (GAMESIR, LOGITECH):
            continue
        found.append(d)
        print(f"- {d['vendor_id']:04x}:{d['product_id']:04x} \"{d.get('product_string') or ''}\" "
              f"usage page 0x{d.get('usage_page', 0):04x} usage 0x{d.get('usage', 0):02x} "
              f"interface {d.get('interface_number')} path {_path(d.get('path'))}")
    if not found:
        print('- no GameSir or Logitech devices found')
    return found


def _send(dev, cmd):
    dev.write(list(cmd) + [0] * (64 - len(cmd)))


def _drain(dev, seconds, stats=None):
    """Every 0x10 reply that arrives within `seconds`. `stats` counts the 0x12
    input reports seen, and how many of them carried any data."""
    out, end = [], time.time() + seconds
    while time.time() < end:
        r = dev.read(64)
        if r and r[0] == 0x10:
            out.append(bytes(r[:24]))
        elif r and r[0] == 0x12 and stats is not None:
            stats['input'] += 1
            stats['live'] += any(r[1:])
        time.sleep(0.003)
    return out


def _questions(dev):
    stats = {'input': 0, 'live': 0}
    try:
        for _ in range(3):                      # spaced, like the app's own
            _send(dev, HEARTBEAT)
            _drain(dev, 0.3, stats)
    except Exception as e:                       # noqa: BLE001
        print(f'    heartbeat refused ({e}); not a command interface')
        return
    for label, cmd, kind in READS:              # one at a time: a question sent
        _send(dev, cmd)                         # right after another gets dropped
        got = [r for r in _drain(dev, 1.0, stats) if len(r) > 1 and r[1] == kind]
        print(f'    {label}: ' + (got[0].hex(' ') if got else 'no reply'))
    if stats['input'] and not stats['live']:
        print(f"    note: {stats['input']} input reports, all empty: is the "
              'controller switched on (not just its dongle plugged in)?')


def ask_gamesir(found):
    print('\n## GameSir: the three read questions, per vendor interface')
    # Linux lists a device's collections under one path; macOS gives each its
    # own. Ask each path once, if any collection on it is vendor-defined.
    paths = {}
    for d in found:
        if d['vendor_id'] == GAMESIR and d.get('usage_page', 0) >= 0xFF00:
            paths.setdefault(d['path'], []).append(d)
    for path, entries in paths.items():
        pages = ' '.join(f"0x{e['usage_page']:04x}" for e in entries)
        print(f"- {entries[0]['product_id']:04x} usage pages {pages} ({_path(path)})")
        dev = hid.device()
        try:
            dev.open_path(path)
            dev.set_nonblocking(True)
            _questions(dev)
        except Exception as e:                   # noqa: BLE001
            print(f'    could not open it: {e!r}')
        finally:
            try:
                dev.close()
            except Exception:                    # noqa: BLE001
                pass
    if not paths:
        print('- no GameSir vendor interfaces to ask')


class _RawHid:
    """A HID interface opened over raw USB, with hidapi's write/read shape.
    Writes use the interrupt OUT endpoint, or SET_REPORT when there is none."""

    def __init__(self, usb, dev, intf):
        self.usb, self.dev, self.num = usb, dev, intf.bInterfaceNumber
        eps = {e.bEndpointAddress & 0x80: e for e in intf
               if usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR}
        self.ep_in, self.ep_out = eps.get(0x80), eps.get(0x00)
        self.detached = False
        try:
            if dev.is_kernel_driver_active(self.num):    # never on macOS here
                dev.detach_kernel_driver(self.num)
                self.detached = True
        except (NotImplementedError, usb.core.USBError):
            pass
        usb.util.claim_interface(dev, self.num)

    def write(self, data):
        data = bytes(data)
        if self.ep_out is not None:
            return self.ep_out.write(data, timeout=200)
        return self.dev.ctrl_transfer(0x21, 0x09, 0x0200 | data[0], self.num, data, 200)

    def read(self, n):
        try:
            return list(self.ep_in.read(n, timeout=20))
        except self.usb.core.USBTimeoutError:
            return []

    def close(self):
        self.usb.util.release_interface(self.dev, self.num)
        if self.detached:
            self.dev.attach_kernel_driver(self.num)
        self.usb.util.dispose_resources(self.dev)


def ask_raw_usb(found):
    """GameSir devices with NO HID interface listed (so never one a system HID
    driver is using): find their HID-class interface and ask it directly."""
    print('\n## GameSir over raw USB (devices hidapi could not see)')
    try:
        import usb.core
        import usb.util
        import libusb_package
        backend = libusb_package.get_libusb1_backend()
    except Exception as e:                       # noqa: BLE001
        print(f'- skipped ({e}); to include it: python3 -m pip install pyusb libusb-package')
        return
    visible = {d['product_id'] for d in found if d['vendor_id'] == GAMESIR}
    asked = 0
    for dev in usb.core.find(find_all=True, idVendor=GAMESIR, backend=backend):
        if dev.idProduct in visible:
            continue
        try:
            cfg = dev.get_active_configuration()
        except Exception as e:                   # noqa: BLE001
            asked += 1
            print(f'- {dev.idProduct:04x}: could not open it ({e})')
            continue
        for intf in cfg:
            if intf.bInterfaceClass != 3:
                continue
            asked += 1
            print(f'- {dev.idProduct:04x} interface {intf.bInterfaceNumber} (HID class, no driver)')
            raw = None
            try:
                raw = _RawHid(usb, dev, intf)
                print(f"    endpoints: in {'yes' if raw.ep_in else 'NO'}, "
                      f"out {'yes' if raw.ep_out else 'no (using SET_REPORT)'}")
                if raw.ep_in is None:
                    continue
                _questions(raw)
            except Exception as e:               # noqa: BLE001
                print(f'    could not use it: {e!r}')
            finally:
                if raw is not None:
                    try:
                        raw.close()
                    except Exception:            # noqa: BLE001
                        pass
    if not asked:
        print('- none (every GameSir device present is visible to hidapi)')


def ask_mouse():
    print('\n## Logitech G502 X')
    try:
        import hidpp
    except Exception as e:                       # noqa: BLE001
        print(f'- could not load the mouse code: {e}')
        return
    try:
        dev = hidpp.find_device()
    except Exception as e:                       # noqa: BLE001
        print(f'- lookup failed: {e!r}')
        return
    if dev is None:
        print('- no G502 X answered (off, asleep, or not connected)')
        return
    with dev:
        print(f'- answered on {_path(dev.path)} as device 0x{dev.device_index:02x}')
        try:
            info = dev.onboard_info()
            print('- onboard: ' + ', '.join(f'{k} {info[k]}' for k in (
                'profile_count', 'oob_count', 'sector_count', 'sector_size')))
            print(f'- active profile sector {dev.current_profile()}, '
                  f'profile list {dev.profile_headers()}')
        except Exception as e:                   # noqa: BLE001
            print(f'- onboard profiles: unavailable ({e!r})')


if __name__ == '__main__':
    print(f'# Deadband device check: {platform.system()} {platform.release()} '
          f'{platform.machine()}, Python {platform.python_version()}, '
          f'hidapi {getattr(hid, "__version__", "?")}\n')
    devices = list_devices()
    ask_gamesir(devices)
    ask_raw_usb(devices)
    ask_mouse()
