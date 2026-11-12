"""Offline tests of the deployment guard, not a CloudKit permissions simulation."""
from pathlib import Path
import importlib.util
import unittest

spec = importlib.util.spec_from_file_location('preflight', Path(__file__).with_name('cloudkit-preflight.py'))
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.container = 'iCloud.example.test'
        self.entitlements = {
            'com.apple.developer.icloud-services': ['CloudKit'],
            'com.apple.developer.icloud-container-identifiers': [self.container],
            'com.apple.developer.icloud-container-environment': 'Development',
        }

    def test_matching_configuration(self):
        self.assertEqual(preflight.inspect(self.entitlements, self.container, 'Development'), [])

    def test_missing_configuration_fails_closed(self):
        self.assertTrue(preflight.inspect({}, None, 'Development'))

    def test_wildcard_does_not_grant_access(self):
        self.entitlements['com.apple.developer.icloud-container-identifiers'] = ['iCloud.*']
        self.assertTrue(preflight.inspect(self.entitlements, self.container, 'Development'))

    def test_environment_must_match(self):
        self.assertTrue(preflight.inspect(self.entitlements, self.container, 'Production'))

    def test_other_container_cannot_pass(self):
        self.assertTrue(preflight.inspect(self.entitlements, 'iCloud.example.other', 'Development'))


if __name__ == '__main__':
    unittest.main()
