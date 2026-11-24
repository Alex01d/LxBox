import argparse
import fnmatch
import plistlib
import subprocess
from pathlib import Path


def command_plist(command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.decode().strip().splitlines()[0])
    return plistlib.loads(result.stdout)


def profile_allows(value, allowed):
    if isinstance(value, list) and isinstance(allowed, list):
        return all(any(profile_allows(item, pattern) for pattern in allowed) for item in value)
    if isinstance(value, str) and isinstance(allowed, str):
        return fnmatch.fnmatchcase(value, allowed)
    return value == allowed


def check_bundle(bundle, expected_file, version):
    failures = []
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    actual_version = (info['CFBundleShortVersionString'], info['CFBundleVersion'])
    if actual_version != version:
        failures.append(f'{bundle.name}: version/build does not match the archive')
    try:
        entitlements = command_plist(['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)])
    except ValueError:
        entitlements = {}
    expected = plistlib.loads(expected_file.read_bytes())
    for key, value in expected.items():
        if entitlements.get(key) != value:
            failures.append(f'{bundle.name}: missing or incorrect entitlement {key}')
    verification = subprocess.run(
        ['codesign', '--verify', '--deep', '--strict', str(bundle)], capture_output=True
    )
    if verification.returncode:
        failures.append(f'{bundle.name}: code signature verification failed')
    profile_path = bundle / 'embedded.mobileprovision'
    if not profile_path.is_file():
        failures.append(f'{bundle.name}: embedded provisioning profile is missing')
        return failures
    profile = command_plist(['security', 'cms', '-D', '-i', str(profile_path)])
    profile_entitlements = profile.get('Entitlements', {})
    for key in expected:
        if not profile_allows(entitlements.get(key), profile_entitlements.get(key)):
            failures.append(f'{bundle.name}: provisioning profile does not allow {key}')
    team = entitlements.get('com.apple.developer.team-identifier')
    if not team or team not in profile.get('TeamIdentifier', []):
        failures.append(f'{bundle.name}: signing team does not match the provisioning profile')
    application_id = entitlements.get('application-identifier')
    if application_id != f"{team}.{info['CFBundleIdentifier']}":
        failures.append(f'{bundle.name}: signed application identifier does not match the bundle')
    if not application_id or not profile_allows(application_id, profile_entitlements.get('application-identifier')):
        failures.append(f'{bundle.name}: provisioning profile does not allow the application identifier')
    return failures


def main():
    parser = argparse.ArgumentParser(description='Verify LxBox archive signing before an Organizer handoff.')
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    try:
        info = plistlib.loads((args.archive / 'Info.plist').read_bytes())
        properties = info['ApplicationProperties']
        version = (properties['CFBundleShortVersionString'], properties['CFBundleVersion'])
        app = args.archive / 'Products' / properties['ApplicationPath']
        bundles = [
            (app, project / 'app/ios/Runner/Runner.entitlements'),
            (app / 'PlugIns/PacketTunnel.appex', project / 'app/ios/PacketTunnel/PacketTunnel.entitlements'),
        ]
        failures = []
        for bundle, expected_file in bundles:
            failures.extend(check_bundle(bundle, expected_file, version))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'FAIL: {error}\n')
    if failures:
        parser.exit(1, ''.join(f'FAIL: {failure}\n' for failure in failures))
    print(f'PASS: {version[0]} ({version[1]}), Runner and PacketTunnel signatures, entitlements and profiles verified')


if __name__ == '__main__':
    main()
