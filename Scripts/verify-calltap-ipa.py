#!/usr/bin/env python3
"""Check runner packaging. This does not replace codesign or on-device tests."""
import plistlib
import sys
import zipfile
from pathlib import Path


def verify(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        apps = {name.split('/')[1] for name in names
                if name.startswith('Payload/') and '.app/' in name}
        if len(apps) != 1:
            raise ValueError('Expected exactly one application in Payload')
        root = f'Payload/{apps.pop()}/'
        info = plistlib.loads(archive.read(root + 'Info.plist'))
        if info.get('CFBundleDisplayName') != 'CallTap Runner':
            raise ValueError('Unexpected runner display name')
        version = tuple(int(part) for part in str(info.get('MinimumOSVersion', '0')).split('.'))
        if not version or version[0] < 27:
            raise ValueError('This prototype must target iOS 27 or later')
        test_plists = [name for name in names if name.startswith(root + 'PlugIns/')
                       and name.endswith('.xctest/Info.plist')]
        if len(test_plists) != 1:
            raise ValueError('The nested .xctest bundle is missing or ambiguous')
        test = plistlib.loads(archive.read(test_plists[0]))
        if test.get('CFBundleIdentifier') != info.get('CFBundleIdentifier'):
            raise ValueError('Runner and nested .xctest bundle identifiers differ')
        for plist_path, metadata in [(root + 'Info.plist', info), (test_plists[0], test)]:
            executable = metadata.get('CFBundleExecutable')
            executable_path = plist_path.removesuffix('Info.plist') + str(executable)
            if not executable or executable_path not in names:
                raise ValueError(f'Missing executable for {plist_path}')
            if archive.getinfo(executable_path).file_size == 0:
                raise ValueError(f'Empty executable for {plist_path}')
        if any(name.endswith('.mobileprovision') for name in names):
            raise ValueError('Distribution IPA must not contain a development profile')
    print(f'PASS: {path.name}: runner, test bundle, executable paths, iOS target, no profile')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: verify-calltap-ipa.py path/to/CallTap-Runner-unsigned.ipa')
    try:
        verify(Path(sys.argv[1]))
    except (ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise SystemExit(f'FAIL: {error}') from error
