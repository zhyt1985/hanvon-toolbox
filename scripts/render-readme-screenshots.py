#!/usr/bin/env python3
"""Render existing SwiftUI views with synthetic data, without device/user-state access.

macOS 26 + Xcode + Apple Silicon Homebrew libusb are required. Temporary copies
of the app models disable loading preferences/history and automatic discovery.
Product sources and signing identities are never changed or used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'docs/assets/screenshots'
NAMES = ('file-manager', 'transfer-queue', 'content-export')


def replace_body(source, signature, body):
    start = source.index('{', source.index(signature))
    depth, end = 1, start + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    return source[:start + 1] + '\n' + body + '\n    }' + source[end:]


def prepare(work):
    sources = work / 'Sources'
    for name in ('ToolboxCore', 'CHanvonUSB', 'CSQLite'):
        shutil.copytree(ROOT / 'Sources' / name, sources / name)
    output = sources / 'ReadmeScreenshots'
    output.mkdir()
    for path in (ROOT / 'Sources/HanvonToolbox').glob('*.swift'):
        if path.name == 'main.swift': continue
        source = path.read_text()
        if path.name == 'ToolboxModel.swift':
            source = source.replace('private(set) var', 'var')
            source = source.replace('RememberedCompanion.load()', '[RememberedCompanion]()')
            source = source.replace('BrowserBookmark.load()', '[BrowserBookmark]()')
            source = source.replace('FileManager.default.homeDirectoryForCurrentUser',
                                    'URL(fileURLWithPath: "/示例资料/电子书")')
            source = re.sub(r'UserDefaults.standard.string\(forKey: "[^"]+"\)', 'nil as String?', source)
            source = replace_body(source, 'init(historyStore:', '        self.historyStore = historyStore')
            source = replace_body(source, 'func startBrowsingIfNeeded()', '        return')
        if path.name == 'ToolboxView.swift':
            source = source.replace('private var model = ToolboxModel()', 'private var model = ReadmeScreenshots.makeModel()')
            source = source.replace('@AppStorage("hanvon.showFileInspector")', '@State')
        if path.name == 'ContentExportModel.swift':
            source = replace_body(source, 'func load() async', '        return')
        (output / path.name).write_text(source)
    shutil.copyfile(ROOT / 'scripts/ReadmeScreenshots.swift', output / 'Render.swift')
    # Use the same core/C dependencies, without tests, app entry point or signing.
    package = (ROOT / 'Package.swift').read_text()
    package = package[:package.index('        .executableTarget(name: "ToolboxCheck"')]
    package = package.replace('.executable(name: "HanvonToolbox", targets: ["HanvonToolbox"]),',
                              '.executable(name: "ReadmeScreenshots", targets: ["ReadmeScreenshots"]),')
    package = package.replace('        .executable(name: "toolbox-check", targets: ["ToolboxCheck"]),\n', '')
    package = package.replace('.executableTarget(name: "HanvonToolbox",', '.executableTarget(name: "ReadmeScreenshots",')
    (work / 'Package.swift').write_text(package + '    ]\n)\n')


def strip_metadata(path):
    data, position = path.read_bytes(), 8
    if data[:8] != b'\x89PNG\r\n\x1a\n': raise ValueError('not PNG')
    clean = bytearray(data[:8])
    while position < len(data):
        size = struct.unpack('>I', data[position:position + 4])[0]
        end = position + size + 12
        if end > len(data): raise ValueError('truncated PNG')
        if data[position + 4:position + 8] in {b'IHDR', b'IDAT', b'IEND', b'sRGB', b'gAMA', b'cHRM', b'pHYs'}:
            clean.extend(data[position:end])
        position = end
    path.write_bytes(clean)  # Pixel payload is unchanged; discard metadata only.


def record_review():
    import importlib.util
    spec = importlib.util.spec_from_file_location('guard', ROOT / 'scripts/privacy-check.py')
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    images = {}
    for name in NAMES:
        path = ASSETS / (name + '.png')
        data = path.read_bytes()
        width, height = struct.unpack('>II', data[16:24])
        review = dict(sha256=hashlib.sha256(data).hexdigest(), width=width, height=height)
        if not guard.reviewed_png(data, review): raise ValueError('unsafe PNG: ' + name)
        images[path.relative_to(ROOT).as_posix()] = review
    (ASSETS / 'reviewed.json').write_text(json.dumps(dict(synthetic_only=True, images=images), indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record-review', action='store_true',
                        help='After visually reviewing all three synthetic images, record their exact digests; does not render.')
    args = parser.parse_args()
    if args.record_review:
        record_review()
        return
    ASSETS.mkdir(parents=True, exist_ok=True)
    (ROOT / '.build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='readme-render-', dir=ROOT / '.build') as temporary:
        work = Path(temporary)
        prepare(work)
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / 'clang-cache'))
        command = ['swift', 'build', '--package-path', str(work), '--disable-sandbox',
                   '--cache-path', str(work / 'cache'), '--config-path', str(work / 'config'),
                   '--security-path', str(work / 'security'), '--product', 'ReadmeScreenshots']
        subprocess.run(command, cwd=ROOT, env=env, check=True)
        binary = subprocess.check_output(command[:-2] + ['--show-bin-path'], cwd=ROOT, env=env, text=True).strip()
        subprocess.run([str(Path(binary) / 'ReadmeScreenshots')], cwd=ROOT, check=True)
    for name in NAMES: strip_metadata(ASSETS / (name + '.png'))
    print('Inspect all three images for layout and privacy, then run with --record-review.')


if __name__ == '__main__':
    main()
