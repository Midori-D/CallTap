"""Check the normal-app AX package independently of the legacy test Runner."""
import plistlib
from pathlib import PurePosixPath
import struct
import sys
import zipfile

def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        roots = {name.split('/')[1] for name in names
                 if name.startswith('Payload/') and len(name.split('/')) > 2
                 and name.split('/')[1].endswith('.app')}
        if len(roots) != 1:
            raise ValueError('Expected exactly one normal app.')
        prefix = 'Payload/' + roots.pop() + '/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundleIdentifier') != 'com.calltap.prototype.ictrl':
            raise ValueError('Unexpected app identifier.')
        if info.get('CFBundleShortVersionString') != '1.1.0' or str(info.get('CFBundleVersion')) != '2':
            raise ValueError('Unexpected AX app version.')
        if any(name.endswith('embedded.mobileprovision') or '.xctest/' in name for name in names):
            raise ValueError('Profiles and XCTest plugins must not be distributed.')
        count = 0
        for name in names:
            if not name.startswith(prefix) or name.endswith('/'):
                continue
            binary = archive.read(name)
            if binary[:4] != b'\xcf\xfa\xed\xfe':
                continue
            if len(binary) < 32:
                raise ValueError('Truncated Mach-O.')
            _, cpu, _, _, commands, command_bytes, _, _ = struct.unpack_from('<8I', binary)
            if cpu != 0x100000c or commands > 4096 or command_bytes > len(binary)-32:
                raise ValueError('Unexpected architecture or invalid load commands.')
            offset, signed = 32, False
            for _ in range(commands):
                command, size = struct.unpack_from('<II', binary, offset)
                if size < 8 or offset+size > 32+command_bytes:
                    raise ValueError('Invalid Mach-O command size.')
                if command in (0xc, 0x80000018, 0x8000001f, 0x80000023):
                    name_offset = struct.unpack_from('<I', binary, offset+8)[0]
                    dependency = binary[offset+name_offset:offset+size].split(b'\0',1)[0]
                    if any(part in dependency for part in (b'XCTest',b'XCUIAutomation',b'Testing.framework')):
                        raise ValueError('An XCTest/testing library is linked.')
                if command == 0x1d:
                    signed = struct.unpack_from('<I', binary, offset+12)[0] > 0
                offset += size
            if not signed:
                raise ValueError('Unsigned embedded Mach-O: ' + PurePosixPath(name).name)
            count += 1
        if not count or prefix+info['CFBundleExecutable'] not in names:
            raise ValueError('Main executable missing.')
        print(f'PASS: normal AX app 1.1.0 (2), {count} signed arm64 binary(s), no XCTest dependency/profile.')

if __name__ == '__main__':
    verify(sys.argv[1])
