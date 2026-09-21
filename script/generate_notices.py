#!/usr/bin/env python3
"""Collect verbatim upstream notices from the locked, selected dependency graph."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
os.chdir(root)
os.environ['PATH'] = str(Path.home() / '.cargo/bin') + os.pathsep + os.environ['PATH']
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--manifest-path', 'Vendor/gifski/Cargo.toml', '--locked',
    '--format-version', '1', '--no-default-features', '--features', 'gifsicle',
    '--filter-platform', 'aarch64-apple-darwin'], text=True))
parts = ['X Media Assist third-party notices\nGenerated from the locked gifski 1.34.0 dependency graph (including test dependencies).\nUpstream copyright and license terms remain in effect.\n']
for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
    folder = Path(package['manifest_path']).parent
    files = sorted(p for p in folder.iterdir() if p.is_file() and p.name.lower().startswith(('license', 'copying', 'notice', 'copyright')))
    parts.append('\n' + '=' * 72 + '\n' + package['name'] + ' ' + package['version'] + '\nLicense: ' + (package['license'] or 'see source') + '\nRepository: ' + (package['repository'] or '') + '\n')
    if not files:
        if package['name'] != 'gif-dispose' or package['license'] != 'MIT OR Apache-2.0':
            raise SystemExit('Missing license text: ' + package['name'])
        # This crate declares Apache-2.0 OR MIT but ships no license file.
        # Select Apache-2.0 and include its unmodified standard text. Do not invent a MIT copyright notice.
        parts.append('Authors (Cargo metadata): ' + ', '.join(package['authors']) + '\nDistributed under the Apache-2.0 option declared in Cargo.toml. Upstream does not ship a separate license/NOTICE file.\n')
        parts.append((root / 'Licenses/Apache-2.0.txt').read_text())
    for path in files:
        parts.append('\n--- ' + path.name + ' ---\n' + path.read_text())
(root / 'Licenses/THIRD_PARTY_NOTICES.txt').write_text('\n'.join(parts))

# Rust's static library includes the standard library; preserve its full notices too.
import shutil
sysroot = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True).strip())
shutil.copyfile(sysroot / 'share/doc/rust/COPYRIGHT-library.html', root / 'Licenses/Rust-standard-library.html')
