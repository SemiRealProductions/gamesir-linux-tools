"""A HID interface reached over raw USB, for one the system left without a driver.

On macOS a Cyclone 2 dongle with its pad connected (3537:100b) exposes two
interfaces: the Xbox 360 gamepad one (class 255, which macOS has no driver for)
and a HID one (class 3) carrying the configuration channel. macOS attaches no
driver to that HID interface either, so hidapi can't list it -- but nothing
holds it, so libusb can claim it directly and nothing has to be detached.

This module finds such interfaces and gives them hidapi's shape (open_path /
read / write / set_nonblocking / close), so the reader, control and backup code
use them unchanged. Paths look like ``usb:<bus>-<port.port>:<interface>``; the
middle part matches the controller ids Linux's ``find_controllers`` uses.

Needs PyUSB and libusb-package (``pip install pyusb libusb-package``), which
bundles the libusb library, so nothing else has to be installed on the Mac.
Linux never takes this path: there every HID interface has a hidraw node.
"""

PREFIX = 'usb:'

_backend = []


def _usb():
    """(usb.core, usb.util, backend), or None when PyUSB / libusb is missing."""
    try:
        import usb.core
        import usb.util
        if not _backend:
            import libusb_package
            _backend.append(libusb_package.get_libusb1_backend())
        return usb.core, usb.util, _backend[0]
    except Exception:
        return None


def available():
    return _usb() is not None


def port_of(dev):
    """`bus-port.port`, the same shape as Linux's `busnum-devpath`."""
    ports = getattr(dev, 'port_numbers', None) or ()
    return f'{dev.bus}-' + ('.'.join(str(p) for p in ports) or str(dev.address))


def _string(dev, index):
    try:
        import usb.util
        return usb.util.get_string(dev, index) or '' if index else ''
    except Exception:
        return ''


def devices(vendor):
    """Every USB device from `vendor`, whether or not hidapi can see it:
    [{port, pid, product, bcd, hid_interfaces}]. [] when PyUSB is missing."""
    lib = _usb()
    if lib is None:
        return []
    core, _util, backend = lib
    out = []
    try:
        found = list(core.find(find_all=True, idVendor=vendor, backend=backend))
    except Exception:
        return []
    for dev in found:
        try:
            ifaces = sorted({i.bInterfaceNumber for i in dev.get_active_configuration()
                             if i.bInterfaceClass == 3})
        except Exception:
            ifaces = []                   # can't read its configuration: not ours to use
        out.append({'port': port_of(dev), 'pid': dev.idProduct,
                    'product': _string(dev, dev.iProduct), 'bcd': dev.bcdDevice,
                    'hid_interfaces': ifaces})
    return out


def path_for(port, interface):
    return f'{PREFIX}{port}:{interface}'


class Device:
    """hidapi's device shape over one claimed USB interface."""

    def __init__(self):
        self._dev = None
        self._num = None
        self._in = self._out = None
        self._nonblocking = False

    def open_path(self, path):
        path = path.decode() if isinstance(path, bytes) else path
        lib = _usb()
        if lib is None:
            raise OSError('opening this controller needs PyUSB and libusb-package '
                          '(pip install pyusb libusb-package)')
        core, util, backend = lib
        try:
            port, num = path[len(PREFIX):].rsplit(':', 1)
            num = int(num)
        except ValueError:
            raise OSError(f'not a raw USB path: {path}') from None
        dev = next((d for d in core.find(find_all=True, backend=backend)
                    if port_of(d) == port), None)
        if dev is None:
            raise OSError(f'no USB device at {port}')
        try:
            intf = next(i for i in dev.get_active_configuration()
                        if i.bInterfaceNumber == num)
        except StopIteration:
            raise OSError(f'{port} has no interface {num}') from None
        eps = {e.bEndpointAddress & 0x80: e for e in intf
               if util.endpoint_type(e.bmAttributes) == util.ENDPOINT_TYPE_INTR}
        if 0x80 not in eps:
            raise OSError(f'{port} interface {num} has no input endpoint')
        try:
            util.claim_interface(dev, num)
        except core.USBError as e:
            raise OSError(f'could not claim {port} interface {num}: {e}') from None
        self._dev, self._num = dev, num
        self._in, self._out = eps[0x80], eps.get(0x00)

    def set_nonblocking(self, value):
        self._nonblocking = bool(value)
        return 0

    def read(self, max_length, timeout_ms=0):
        """A list of ints, or [] when nothing arrived in time (as hidapi)."""
        import usb.core
        if timeout_ms <= 0:
            timeout_ms = 1 if self._nonblocking else 0       # 0 = wait for ever
        try:
            return list(self._in.read(max_length, timeout=timeout_ms))
        except usb.core.USBTimeoutError:
            return []
        except usb.core.USBError as e:
            raise OSError(f'USB read failed: {e}') from None

    def write(self, data):
        import usb.core
        data = bytes(data)
        try:
            if self._out is not None:
                return self._out.write(data, timeout=1000)
            # no OUT endpoint: SET_REPORT(output, report id = first byte)
            return self._dev.ctrl_transfer(0x21, 0x09, 0x0200 | data[0], self._num,
                                           data, 1000)
        except usb.core.USBError as e:
            raise OSError(f'USB write failed: {e}') from None

    def get_product_string(self):
        return _string(self._dev, self._dev.iProduct) if self._dev is not None else ''

    def close(self):
        if self._dev is None:
            return
        import usb.util
        try:
            usb.util.release_interface(self._dev, self._num)
        except Exception:
            pass
        try:
            usb.util.dispose_resources(self._dev)
        except Exception:
            pass
        self._dev = None
