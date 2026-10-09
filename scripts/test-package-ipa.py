import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('package_ipa', Path(__file__).with_name('package-ipa.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PackagingTests(unittest.TestCase):
    def fixture(self, root, platform=2):
        app = Path(root) / 'Pulse.app'
        app.mkdir()
        with (app / 'Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleExecutable': 'Pulse', 'CFBundleIdentifier': 'com.pulse.personal'}, stream)
        # Minimal format fixture for validation tests; never delivered as an application.
        header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        command = struct.pack('<6I', 0x32, 24, platform, 0x110000, 0x110000, 0)
        (app / 'Pulse').write_bytes(header + command)
        return app

    def test_payload_layout(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.fixture(root)
            output = module.package(app, Path(root) / 'format-fixture.ipa')
            with zipfile.ZipFile(output) as archive:
                self.assertIn('Payload/Pulse.app/Pulse', archive.namelist())
                self.assertIn('Payload/Pulse.app/Info.plist', archive.namelist())

    def test_sources_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.fixture(root)
            (app / 'Pulse').write_text('import SwiftUI')
            with self.assertRaises(ValueError):
                module.validate_app(app)

    def test_simulator_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                module.validate_app(self.fixture(root, platform=7))

    def test_truncated_binary_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.fixture(root)
            (app / 'Pulse').write_bytes((app / 'Pulse').read_bytes()[:40])
            with self.assertRaises(ValueError):
                module.validate_app(app)

if __name__ == '__main__':
    unittest.main()