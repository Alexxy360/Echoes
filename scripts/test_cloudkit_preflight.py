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

    def test_apple_profile_can_allow_multiple_environments_and_services(self):
        self.entitlements['com.apple.developer.icloud-services'] = '*'
        self.entitlements['com.apple.developer.icloud-container-environment'] = ['Development', 'Production']
        self.assertEqual(preflight.inspect(self.entitlements, self.container, 'Development', provisioning=True), [])
        self.assertTrue(preflight.inspect(self.entitlements, self.container, 'Development'))

    def test_profile_still_requires_the_explicit_container(self):
        self.entitlements['com.apple.developer.icloud-services'] = '*'
        self.entitlements['com.apple.developer.icloud-container-identifiers'] = ['iCloud.*']
        self.assertTrue(preflight.inspect(self.entitlements, self.container, 'Development', provisioning=True))

    def test_profile_cannot_allow_an_unlisted_environment(self):
        self.entitlements['com.apple.developer.icloud-container-environment'] = ['Production']
        self.assertTrue(preflight.inspect(self.entitlements, self.container, 'Development', provisioning=True))

    def test_other_container_cannot_pass(self):
        self.assertTrue(preflight.inspect(self.entitlements, 'iCloud.example.other', 'Development'))


if __name__ == '__main__':
    unittest.main()
