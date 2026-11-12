"""Read-only CloudKit entitlement check. Never logs credentials or modifies Apple services."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import subprocess


def inspect(entitlements, container, environment, provisioning=False):
    issues = []
    if not isinstance(entitlements, dict):
        return ['Entitlements must be a property-list dictionary.']
    if not container or not re.fullmatch(r'iCloud\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*', container):
        issues.append('A verified, explicit CloudKit container identifier is required.')
    services = entitlements.get('com.apple.developer.icloud-services')
    service_allowed = isinstance(services, list) and 'CloudKit' in services
    if provisioning and (services == '*' or isinstance(services, list) and '*' in services):
        service_allowed = True
    if not service_allowed:
        issues.append('CloudKit service entitlement is missing.')
    declared = entitlements.get('com.apple.developer.icloud-container-identifiers', [])
    if not isinstance(declared, list) or not container or container not in declared:
        issues.append('The verified container is not explicitly allowed by these entitlements.')
    declared_environment = entitlements.get('com.apple.developer.icloud-container-environment')
    environment_allowed = declared_environment == environment
    if provisioning and isinstance(declared_environment, list):
        environment_allowed = environment in declared_environment
    if not environment_allowed:
        issues.append('The signed container environment does not match the requested environment.')
    return issues


def load_entitlements(path, profile=False):
    raw = path.read_bytes()
    if profile:
        decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
        if decoded.returncode:
            raise ValueError('Could not decode the provisioning profile.')
        return plistlib.loads(decoded.stdout).get('Entitlements', {})
    return plistlib.loads(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--entitlements', type=Path, required=True)
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--container', help='An identifier verified in the Apple Developer account; no inferred default.')
    parser.add_argument('--environment', choices=['Development', 'Production'], default='Development')
    parser.add_argument('--strict', action='store_true', help='Exit 2 when configuration is incomplete.')
    args = parser.parse_args()
    try:
        checks = {'appEntitlements': inspect(load_entitlements(args.entitlements), args.container, args.environment)}
        if args.profile:
            checks['provisioningProfile'] = inspect(load_entitlements(args.profile, profile=True), args.container, args.environment, provisioning=True)
        else:
            checks['provisioningProfile'] = ['A matching provisioning profile has not been supplied.']
    except (OSError, ValueError, plistlib.InvalidFileException):
        print(json.dumps({'status': 'needs-configuration', 'error': 'Cannot read or decode the supplied configuration.'}))
        return 2
    ready = all(not issues for issues in checks.values())
    print(json.dumps({'status': 'entitlements-match' if ready else 'needs-configuration',
                      'environment': args.environment, 'checks': checks,
                      'liveCloudKitVerified': False,
                      'note': 'Even matching entitlements do not prove container access, roles, or two-account isolation.'}, indent=2))
    return 2 if args.strict and not ready else 0


if __name__ == '__main__':
    raise SystemExit(main())
