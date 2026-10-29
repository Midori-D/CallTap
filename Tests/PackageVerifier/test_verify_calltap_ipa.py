"""Regression tests for IPA metadata validation, using synthetic ZIP fixtures.

The fixture executable bytes are intentionally not Mach-O binaries. These tests
exercise package layout and OS-version rules, not signing or device execution.
"""
import contextlib
import importlib.util
import io
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / 'Scripts' / 'verify-calltap-ipa.py'
SPEC = importlib.util.spec_from_file_location('calltap_package_verifier', CHECKER)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)

APP = 'Payload/iCTRLUITests-Runner.app/'
TEST = APP + 'PlugIns/iCTRLUITests.xctest/'
MISSING = object()


class PackageVerifierTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'fixture.ipa'

    def fixture(self, runner_updates=None, test_updates=None, *, omitted=(), extra=None):
        runner = {
            'CFBundleDisplayName': 'CallTap Runner',
            'CFBundleIdentifier': 'com.example.calltap.runner',
            'CFBundleExecutable': 'runner',
            'MinimumOSVersion': '15.0',
        }
        test = {
            'CFBundleIdentifier': 'com.example.calltap.runner',
            'CFBundleExecutable': 'test',
            'MinimumOSVersion': '27.0',
        }
        for metadata, updates in ((runner, runner_updates), (test, test_updates)):
            for key, value in (updates or {}).items():
                if value is MISSING:
                    metadata.pop(key, None)
                else:
                    metadata[key] = value
        entries = {
            APP + 'Info.plist': plistlib.dumps(runner),
            APP + 'runner': b'synthetic-runner-executable',
            TEST + 'Info.plist': plistlib.dumps(test),
            TEST + 'test': b'synthetic-test-executable',
        }
        entries.update(extra or {})
        with zipfile.ZipFile(self.path, 'w') as archive:
            for name, content in entries.items():
                if name not in omitted:
                    archive.writestr(name, content)
        return self.path

    def verify(self, path=None, target='27.0'):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            VERIFIER.verify(path or self.path, target_ios=target)
        return output.getvalue()

    def test_lower_runner_minimum_and_ios27_test_bundle_are_compatible(self):
        self.fixture()
        output = self.verify()
        self.assertIn('15.0', output)
        self.assertIn('27.0', output)
        self.assertIn('PASS:', output)

    def test_equivalent_version_spellings(self):
        for text in ('27', '27.0', '27.0.0'):
            with self.subTest(version=text):
                self.assertEqual(VERIFIER.parse_ios_version(text, 'version'), (27, 0, 0))
                self.fixture({'MinimumOSVersion': text}, {'MinimumOSVersion': text})
                self.verify(target='27.0')

    def test_older_test_bundle_is_also_compatible(self):
        self.fixture({'MinimumOSVersion': '16.0'}, {'MinimumOSVersion': '26.1'})
        self.verify()

    def test_target_device_version_argument_is_respected(self):
        self.fixture({'MinimumOSVersion': '27.1'}, {'MinimumOSVersion': '27.1'})
        self.verify(target='27.1')
        with self.assertRaises(ValueError):
            self.verify(target='27.0')

    def test_newer_runner_minimum_is_rejected(self):
        for text in ('27.0.1', '27.1', '28.0'):
            with self.subTest(version=text):
                self.fixture({'MinimumOSVersion': text})
                with self.assertRaisesRegex(ValueError, 'Runner.*newer than target'):
                    self.verify()

    def test_newer_test_bundle_minimum_is_rejected(self):
        for text in ('27.0.1', '27.1', '28.0'):
            with self.subTest(version=text):
                self.fixture(test_updates={'MinimumOSVersion': text})
                with self.assertRaisesRegex(ValueError, 'Test bundle.*newer than target'):
                    self.verify()

    def test_version_ordering_is_numeric(self):
        self.assertGreater(VERIFIER.parse_ios_version('27.10', 'version'),
                           VERIFIER.parse_ios_version('27.2', 'version'))
        self.fixture(test_updates={'MinimumOSVersion': '27.10'})
        with self.assertRaises(ValueError):
            self.verify(target='27.2')

    def test_missing_minimum_is_rejected_in_each_bundle(self):
        for bundle in ('runner', 'test'):
            with self.subTest(bundle=bundle):
                updates = {'MinimumOSVersion': MISSING}
                self.fixture(updates if bundle == 'runner' else None,
                             updates if bundle == 'test' else None)
                with self.assertRaisesRegex(ValueError, 'MinimumOSVersion'):
                    self.verify()

    def test_invalid_minimum_is_rejected_in_each_bundle(self):
        invalid = ('', ' ', '27.x', '27.0beta', '27..0', '27.0.0.1',
                   '-27.0', '0.0', 27, 27.0, True, ['27.0'], {'version': '27.0'})
        for bundle in ('runner', 'test'):
            for value in invalid:
                with self.subTest(bundle=bundle, value=value):
                    updates = {'MinimumOSVersion': value}
                    self.fixture(updates if bundle == 'runner' else None,
                                 updates if bundle == 'test' else None)
                    with self.assertRaisesRegex(ValueError, 'MinimumOSVersion'):
                        self.verify()

    def test_parser_rejects_none_and_invalid_target_versions(self):
        for value in (None, '', '27.x', 27, True):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    VERIFIER.parse_ios_version(value, 'Target device iOS')
        self.fixture()
        with self.assertRaises(ValueError):
            self.verify(target='not-a-version')

    def test_bundle_identifier_mismatch_is_rejected(self):
        self.fixture(test_updates={'CFBundleIdentifier': 'com.example.other'})
        with self.assertRaisesRegex(ValueError, 'identifiers differ'):
            self.verify()

    def test_missing_runner_identifier_is_rejected(self):
        self.fixture({'CFBundleIdentifier': MISSING})
        with self.assertRaisesRegex(ValueError, 'identifier is missing'):
            self.verify()

    def test_development_profiles_are_rejected_anywhere(self):
        for path in (APP + 'embedded.mobileprovision', TEST + 'embedded.mobileprovision'):
            with self.subTest(path=path):
                self.fixture(extra={path: b'synthetic-development-profile'})
                with self.assertRaisesRegex(ValueError, 'development profile'):
                    self.verify()

    def test_missing_nested_test_bundle_is_rejected(self):
        self.fixture(omitted=(TEST + 'Info.plist', TEST + 'test'))
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.verify()

    def test_multiple_nested_test_bundles_are_rejected(self):
        self.fixture(extra={APP + 'PlugIns/Other.xctest/Info.plist': plistlib.dumps({})})
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.verify()

    def test_missing_executables_are_rejected(self):
        for path in (APP + 'runner', TEST + 'test'):
            with self.subTest(path=path):
                self.fixture(omitted=(path,))
                with self.assertRaisesRegex(ValueError, 'Missing executable'):
                    self.verify()

    def test_empty_executables_are_rejected(self):
        for path in (APP + 'runner', TEST + 'test'):
            with self.subTest(path=path):
                self.fixture(extra={path: b''})
                with self.assertRaisesRegex(ValueError, 'Empty executable'):
                    self.verify()

    def test_invalid_executable_names_are_rejected(self):
        for bundle in ('runner', 'test'):
            for name in (MISSING, '', '../escape', 'sub/file', 'sub\\file', '.', '..', 7):
                with self.subTest(bundle=bundle, name=str(name)):
                    updates = {'CFBundleExecutable': name}
                    self.fixture(updates if bundle == 'runner' else None,
                                 updates if bundle == 'test' else None)
                    with self.assertRaisesRegex(ValueError, 'Invalid executable name'):
                        self.verify()

    def test_unexpected_display_name_is_rejected(self):
        self.fixture({'CFBundleDisplayName': 'Another Runner'})
        with self.assertRaisesRegex(ValueError, 'Unexpected runner display name'):
            self.verify()

    def test_multiple_payload_apps_are_rejected(self):
        self.fixture(extra={'Payload/Other.app/Info.plist': plistlib.dumps({})})
        with self.assertRaisesRegex(ValueError, 'exactly one application'):
            self.verify()

    def test_cli_returns_success_for_original_regression_fixture(self):
        self.fixture()
        result = subprocess.run([sys.executable, str(CHECKER), str(self.path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS:', result.stdout)

    def test_cli_returns_failure_for_incompatible_test_bundle(self):
        self.fixture(test_updates={'MinimumOSVersion': '27.1'})
        result = subprocess.run([sys.executable, str(CHECKER), str(self.path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('FAIL:', result.stderr)
        self.assertIn('Test bundle requires iOS 27.1', result.stderr)


if __name__ == '__main__':
    unittest.main()
