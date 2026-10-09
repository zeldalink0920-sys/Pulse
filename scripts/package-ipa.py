"""Package an actual compiled iPhone app into an unsigned IPA. No source fallback."""
import argparse
import os
from pathlib import Path
import plistlib
import stat
import struct
import zipfile


def validate_app(app):
    app = Path(app).resolve()
    if app.suffix != '.app' or not app.is_dir():
        raise ValueError('Expected a compiled .app directory')
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable_name = info.get('CFBundleExecutable', '')
    if not executable_name or Path(executable_name).name != executable_name:
        raise ValueError('Invalid CFBundleExecutable')
    binary = (app / executable_name).read_bytes()
    if len(binary) < 32 or binary[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('App executable must be a compiled 64-bit Mach-O binary')
    _, cpu, _, file_type, commands, command_bytes, _, _ = struct.unpack_from('<8I', binary)
    if cpu != 0x0100000C or file_type != 2:
        raise ValueError('Expected an ARM64 iPhone executable')
    if 32 + command_bytes > len(binary):
        raise ValueError('Truncated Mach-O load commands')
    platform = None
    offset = 32
    for _ in range(commands):
        if offset + 8 > 32 + command_bytes:
            raise ValueError('Invalid Mach-O command table')
        command, size = struct.unpack_from('<2I', binary, offset)
        if size < 8 or offset + size > 32 + command_bytes:
            raise ValueError('Invalid Mach-O command size')
        if command == 0x32 and size >= 24:
            platform = struct.unpack_from('<I', binary, offset + 8)[0]
        offset += size
    if platform != 2:
        raise ValueError('Executable must target iOS devices, not the simulator')
    if info.get('CFBundleIdentifier') != 'com.pulse.personal':
        raise ValueError('Unexpected bundle identifier')
    for path in app.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(app):
            raise ValueError('Bundle contains an external symlink')
    return app


def package(app, destination):
    app = validate_app(app)
    destination = Path(destination)
    if destination.suffix.lower() != '.ipa':
        raise ValueError('Output must have .ipa extension')
    if destination.resolve().is_relative_to(app):
        raise ValueError('Output must be outside the app bundle')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            archive_name = (Path('Payload') / app.name / path.relative_to(app)).as_posix()
            if path.is_symlink():
                entry = zipfile.ZipInfo(archive_name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path))
            elif path.is_file():
                archive.write(path, archive_name)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app')
    parser.add_argument('output')
    args = parser.parse_args()
    output = package(args.app, args.output)
    print(f'Created {output}. Unsigned: valid signing is required before installation.')