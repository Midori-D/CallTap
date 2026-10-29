#!/usr/bin/env python3
"""Check IPA layout and device OS compatibility, not codesign or runtime behavior.

CallTap fix, 2026-10-29: MinimumOSVersion is an execution lower bound.
An Xcode-supplied runner may legitimately have a lower bound than its tests.
Compare each bundle's lower bound with the target device; never require >= SDK.
"""
import argparse
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def parse_ios_version(value: object, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError(f"{label} must be a nonempty iOS version string; got {value!r}")
    components = [int(component) for component in value.split('.')]
    if components[0] < 1:
        raise ValueError(f"{label} must have a positive major version; got {value!r}")
    return tuple(components + [0] * (3 - len(components)))


def check_minimum(metadata: dict, bundle: str, target: tuple[int, int, int],
                  target_text: str) -> None:
    actual = metadata.get('MinimumOSVersion')
    print(f"INFO: {bundle} MinimumOSVersion={actual!r}; target device iOS={target_text}")
    minimum = parse_ios_version(actual, f"{bundle} MinimumOSVersion")
    if minimum > target:
        raise ValueError(f"{bundle} requires iOS {actual}, newer than target device iOS {target_text}")


def verify(path: Path, target_ios: str = '27.0') -> None:
    target = parse_ios_version(target_ios, 'Target device iOS')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        apps = {name.split('/')[1] for name in names
                if name.startswith('Payload/') and '.app/' in name}
        if len(apps) != 1:
            raise ValueError('Expected exactly one application in Payload')
        root = f'Payload/{apps.pop()}/'
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        if not isinstance(info, dict):
            raise ValueError('Runner Info.plist must contain a dictionary')
        if info.get('CFBundleDisplayName') != 'CallTap Runner':
            raise ValueError('Unexpected runner display name')
        test_plists = [name for name in names if name.startswith(root + 'PlugIns/')
                       and name.endswith('.xctest/Info.plist')]
        if len(test_plists) != 1:
            raise ValueError('The nested .xctest bundle is missing or ambiguous')
        test = plistlib.loads(archive.read(test_plists[0]))
        if not isinstance(test, dict):
            raise ValueError('Test bundle Info.plist must contain a dictionary')

        # SDK selection is checked by build-calltap.sh. These values instead
        # describe the oldest device OS on which each existing binary can run.
        check_minimum(info, 'Runner', target, target_ios)
        check_minimum(test, 'Test bundle', target, target_ios)

        runner_id = info.get('CFBundleIdentifier')
        if not isinstance(runner_id, str) or not runner_id:
            raise ValueError('Runner bundle identifier is missing')
        if test.get('CFBundleIdentifier') != runner_id:
            raise ValueError('Runner and nested .xctest bundle identifiers differ')
        for plist_path, metadata in [(root + 'Info.plist', info), (test_plists[0], test)]:
            executable = metadata.get('CFBundleExecutable')
            if (not isinstance(executable, str) or not executable
                    or '/' in executable or '\\' in executable or executable in {'.', '..'}):
                raise ValueError(f'Invalid executable name for {plist_path}')
            executable_path = plist_path.removesuffix('Info.plist') + executable
            if executable_path not in names:
                raise ValueError(f'Missing executable for {plist_path}')
            if archive.getinfo(executable_path).file_size == 0:
                raise ValueError(f'Empty executable for {plist_path}')
        if any(name.endswith('.mobileprovision') for name in names):
            raise ValueError('Distribution IPA must not contain a development profile')
    print(f'PASS: {path.name}: runner, test bundle, executable paths, compatible with iOS {target_ios}, no profile')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--target-ios', default='27.0',
                        help='OS installed on the destination iPhone (default: 27.0)')
    arguments = parser.parse_args()
    try:
        verify(arguments.ipa, arguments.target_ios)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
