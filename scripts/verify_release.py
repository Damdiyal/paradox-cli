"""Verify a standalone release archive before native smoke testing."""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import zipfile


def verify(directory, target, destination, tag, snapshot_file):
    directory = Path(directory)
    destination = Path(destination)
    expected = {
        'paradoxcli-linux-arm64.tar.gz',
        'paradoxcli-linux-x64.tar.gz',
        'paradoxcli-win-x64.zip',
    }
    checksums = {}
    for line in (directory / 'SHA256SUMS').read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'([a-fA-F0-9]{64})  ([A-Za-z0-9.-]+)', line)
        if not match or match[2] in checksums:
            raise ValueError('Invalid or duplicate checksum entry')
        checksums[match[2]] = match[1].lower()
    if set(checksums) != expected:
        raise ValueError('Unexpected release asset set')
    extension = 'zip' if target == 'win-x64' else 'tar.gz'
    archive = directory / f'paradoxcli-{target}.{extension}'
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != checksums[archive.name]:
        raise ValueError('Archive checksum mismatch')
    snapshot = json.loads(Path(snapshot_file).read_text(encoding='utf-8'))
    if snapshot['tag'] != tag:
        raise ValueError('Snapshot tag mismatch')
    assets = {asset['name']: asset for asset in snapshot['assets']}
    actual = {
        archive.name: digest.hexdigest(),
        'SHA256SUMS': hashlib.sha256((directory / 'SHA256SUMS').read_bytes()).hexdigest(),
    }
    for filename, checksum in actual.items():
        if assets[filename]['digest'] != f'sha256:{checksum}':
            raise ValueError('Downloaded bytes do not match the verified release snapshot')

    def check_name(name):
        path = PurePosixPath(name)
        if (path.is_absolute() or '..' in path.parts or '\\' in name
                or ':' in name or not path.parts or path.parts[0] != 'paradoxcli'):
            raise ValueError('Unsafe archive path')
        public_root = {
            'bin', 'lib', 'node', 'manifest.json', 'package.json',
            'LICENSE', 'NOTICE', 'NOTICES.txt', 'README.md',
        }
        if len(path.parts) > 1 and path.parts[1] not in public_root:
            raise ValueError('Unexpected top-level release content')
        private = {'.git', '.paradox', '.qwen', 'fix.md', 'plan.md', '.env', 'oauth_creds.json'}
        if private.intersection(path.parts):
            raise ValueError('Private file in release archive')
        if any(part.startswith('.env.') for part in path.parts):
            raise ValueError('Environment configuration in release archive')
        # Third-party Node runtime packages may carry their own source maps.
        # Application source maps and workspace source must never be shipped.
        if path.parts[:2] == ('paradoxcli', 'lib') and path.parts[2:3] != ('node_modules',):
            public_helper_sources = {
                'paradoxcli/lib/vendor/landlock-run/src',
                'paradoxcli/lib/vendor/landlock-run/src/qwen-landlock-run.c',
                'paradoxcli/lib/vendor/landlock-run/src/stdio-relay.h',
            }
            if (path.suffix == '.map' or 'packages' in path.parts
                    or ('src' in path.parts and str(path) not in public_helper_sources)):
                raise ValueError('Application source or source map in release archive')

    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as bundle:
            for entry in bundle.infolist():
                check_name(entry.filename)
                mode = (entry.external_attr >> 16) & 0o170000
                if mode not in (0, 0o100000, 0o040000):
                    raise ValueError('Unsupported archive entry type')
            bundle.extractall(destination)
    else:
        with tarfile.open(archive) as bundle:
            for entry in bundle.getmembers():
                check_name(entry.name)
                if not (entry.isfile() or entry.isdir()):
                    raise ValueError('Unsupported archive entry type')
            bundle.extractall(destination, filter='data')

    root = destination / 'paradoxcli'
    for name in ('LICENSE', 'NOTICE', 'NOTICES.txt', 'README.md'):
        if not (root / name).is_file():
            raise ValueError(f'Missing {name}')
    if 'License text not found.' in (root / 'NOTICES.txt').read_text(encoding='utf-8'):
        raise ValueError('Unresolved dependency license text in release')
    launcher = root / 'bin' / ('paradox.cmd' if os.name == 'nt' else 'paradox')
    command = ['cmd', '/d', '/c', str(launcher)] if os.name == 'nt' else [str(launcher)]
    version = subprocess.check_output(command + ['--version'], text=True, timeout=60)
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[\w.-]+)?', version.strip()):
        raise ValueError('Unexpected CLI version output')
    if version.strip() != tag.removeprefix('v'):
        raise ValueError('CLI version does not match the release tag')
    help_text = subprocess.check_output(command + ['--help'], text=True, timeout=60)
    if 'paradox' not in help_text.lower():
        raise ValueError('Missing Paradox branding')
    native = list((root / 'lib/node_modules/@paradoxlab/audio-capture/prebuilds').rglob('*.node'))
    if len(native) != 1:
        raise ValueError('Expected exactly one native microphone prebuild')
    runtime = root / 'node' / ('node.exe' if os.name == 'nt' else 'bin/node')
    probe = "const a=require(process.argv[1]);for(const k of ['startRecording','stopRecording','isRecording','silenceDetected','drainAudio','audioLevel','microphoneAuthorizationStatus'])if(typeof a[k]!=='function')throw Error('Missing native API: '+k)"
    subprocess.run([str(runtime), '-e', probe, str(native[0].resolve())], check=True, timeout=30)
    print(f'Checksum, archive privacy, CLI, and native API smoke passed: {target} {version.strip()}')


if __name__ == '__main__':
    verify(*sys.argv[1:])
