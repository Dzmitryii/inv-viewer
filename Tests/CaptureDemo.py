"""The release capture must reject other builds before writing or launching them."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CaptureVersionTests(unittest.TestCase):
    def test_other_release_or_build_is_rejected_before_output(self):
        (ROOT / '.build').mkdir(exist_ok=True)
        for version, build in [('1.13.1', '20'), ('1.14.0', '99')]:
            with self.subTest(version=version, build=build), tempfile.TemporaryDirectory(dir=ROOT / '.build') as folder:
                root = Path(folder)
                app = root / 'Different.app'
                (app / 'Contents').mkdir(parents=True)
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleShortVersionString': version, 'CFBundleVersion': build}))
                output = root / 'capture'
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/capture-demo.py'),
                    '--app', str(app), '--out', str(output), '--demo-is-open'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Expected INV Viewer 1.14.0 (21)', result.stderr)
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
