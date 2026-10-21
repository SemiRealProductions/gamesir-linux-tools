"""hidcompat picks the hidraw-backed module when a distro ships both (#36)."""
import importlib
import sys
import types
import unittest


class HidcompatTests(unittest.TestCase):
    def _load(self, modules):
        saved = {k: sys.modules.get(k) for k in ('hid', 'hidraw', 'hidcompat')}
        try:
            for k in ('hid', 'hidraw', 'hidcompat'):
                sys.modules.pop(k, None)
            sys.modules.update(modules)
            return importlib.import_module('hidcompat')
        finally:
            for k, v in saved.items():
                if v is None:
                    sys.modules.pop(k, None)
                else:
                    sys.modules[k] = v

    @staticmethod
    def _fake(name):
        m = types.ModuleType(name)
        m.device = object
        m.enumerate = lambda *a: [{'path': name.encode()}]
        return m

    def test_prefers_the_hidraw_module_when_both_exist(self):
        hc = self._load({'hid': self._fake('hid'), 'hidraw': self._fake('hidraw')})
        self.assertEqual(hc.enumerate()[0]['path'], b'hidraw')

    def test_uses_hid_when_there_is_no_hidraw_module(self):
        hc = self._load({'hid': self._fake('hid'), 'hidraw': None})
        self.assertEqual(hc.enumerate()[0]['path'], b'hid')


if __name__ == '__main__':
    unittest.main()
