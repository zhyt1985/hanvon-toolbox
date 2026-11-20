#!/usr/bin/env python3
"""Local-only index/history guard. Findings never include matched values."""
import argparse
import hashlib
import ipaddress
import json
import math
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import struct
import zlib
from collections import Counter

ROOT_FILES = {'.gitignore', '.gitattributes', 'AGENTS.md', 'README.md', 'CONTRIBUTING.md',
              'SECURITY.md', 'CHANGELOG.md', 'Package.swift', 'LICENSE', 'LICENSE.md'}
ROOT_DIRS = {'Sources', 'Tests', 'android', 'scripts', 'docs', 'fixtures', '.githooks', '.github'}
DENIED_PARTS = {'.build', '.swiftpm', '.android-signing', '.mac-signing', '.aws', '.ssh', '.codex',
                '.agents', 'private', 'local-data', 'device-dumps', 'xcuserdata', '__pycache__'}
DENIED_SUFFIXES = {'.apk', '.aab', '.app', '.ipa', '.dmg', '.zip', '.p12', '.pfx', '.pem', '.key',
                   '.jks', '.keystore', '.cer', '.der', '.mobileprovision', '.db', '.sqlite', '.sqlite3',
                   '.psl', '.bin', '.log', '.pdf', '.png', '.jpg', '.jpeg', '.wav', '.mp3', '.m4a', '.hanvonexport'}
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
IPV4 = re.compile(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
IPV6 = re.compile(r'(?<![0-9A-Za-z:])(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:]*(?:%[0-9A-Za-z_.-]+)?')
CHINESE = re.compile(r'''(?:账号|帐号|用户名|密码|口令|设备序列号|设备指纹|设备地址|本机用户名)\s*[:=：]\s*["']?([^\s"']+)''')
HOME = re.compile(r'/(?:Users|home)/[^/\s<>]+|[A-Za-z]:[\\/][Uu]sers[\\/][^\\/\s<>]+')
RULES = {
    'command-line-password': re.compile(r'''(?:--ks-pass|--key-pass)\s+pass:[^\s"']+|(?<![\w-])-(?:storepass|keypass)\s+(?!["']?\$)[A-Za-z0-9_+=/-]{4,}'''),
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----'),
    'provider-credential': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|(?:AKIA|ASIA)[A-Z0-9]{16}|sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,})\b'),
    'authorization-value': re.compile(r'(?i)\bBearer\s+[A-Za-z0-9_./+=-]{16,}'),
    'phone-number': re.compile(r'(?<!\d)1[3-9]\d{9}(?!\d)'),
    'identity-number': re.compile(r'(?<!\d)[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9Xx](?!\d)'),
    'device-mac': re.compile(r'(?i)(?<![\w:])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![\w:])'),
    'literal-pairing-code': re.compile(r'(?i)(?:配对码|pairing[_ ]?code)\s*[=:：]\s*["\x27]?\d{6,8}\b'),
    'raw-device-uri': re.compile(r'content://(?:com\.android\.|com\.hanvon\.)[^\s"\x27]*'),
}
LITERAL = re.compile(r'''(?ix)\b(?:password|passwd|secret|token|api_key|apikey|access_key|private_key|serial|device_id|deviceid|fingerprint|pairingcode|pin|account)\s*[:=]\s*["']([^"'\n]+)["']''')
QUOTED = re.compile(r'''["']([A-Za-z0-9_+/=-]{32,})["']''')
FAKE = {'token', 'secret', 'identity', 'device', 'device-1', 'device-A', 'device-B', 'id', 'N10', 'snapshot-device'}
SCREENSHOT_REVIEW = 'docs/assets/screenshots/reviewed.json'
SCREENSHOTS = {f'docs/assets/screenshots/{name}.png' for name in
               ('file-manager', 'transfer-queue', 'content-export')}


def screenshot_reviews(data):
    """Only exact synthetic assets; no free-form fields or directory exceptions."""
    if len(data) > 4096: raise ValueError('oversized screenshot review')
    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise ValueError('duplicate screenshot field')
            result[key] = value
        return result
    value = json.loads(data, object_pairs_hook=unique_fields)
    if set(value) != {'synthetic_only', 'images'} or value['synthetic_only'] is not True:
        raise ValueError('invalid screenshot review')
    images = value['images']
    if not isinstance(images, dict) or not images or not set(images) <= SCREENSHOTS:
        raise ValueError('invalid screenshot paths')
    for entry in images.values():
        if not isinstance(entry, dict) or set(entry) != {'sha256', 'width', 'height'}:
            raise ValueError('invalid screenshot fields')
        if not isinstance(entry['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', entry['sha256']):
            raise ValueError('invalid image digest')
        if any(type(entry[k]) is not int or not 1 <= entry[k] <= 4096 for k in ('width', 'height')):
            raise ValueError('invalid image dimensions')
    return images


def reviewed_png(data, review):
    """Reject changed pixels and metadata; visual review is still required."""
    if len(data) > 3 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != review['sha256']:
        return False
    if data[:8] != b'\x89PNG\r\n\x1a\n': return False
    position, chunks = 8, []
    while position + 12 <= len(data):
        length = struct.unpack('>I', data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        end = position + 12 + length
        if end > len(data) or kind not in {b'IHDR', b'IDAT', b'IEND', b'sRGB', b'gAMA', b'cHRM', b'pHYs'}:
            return False
        payload = data[position + 8:end - 4]
        if zlib.crc32(kind + payload) != struct.unpack('>I', data[end - 4:end])[0]: return False
        if kind == b'IHDR':
            if chunks or length != 13: return False
            if struct.unpack('>II', payload[:8]) != (review['width'], review['height']): return False
        chunks.append(kind)
        position = end
        if kind == b'IEND':
            return length == 0 and position == len(data) and chunks[0] == b'IHDR' and b'IDAT' in chunks
    return False


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL)


def safe_email(value):
    domain = value.rsplit('@', 1)[-1].lower()
    return domain.endswith(('.invalid', '.example')) or domain in {'example.com', 'example.org', 'example.net'}


def text_findings(path, text):
    result = []
    for number, line in enumerate(text.splitlines(), 1):
        found = set()
        if HOME.search(line): found.add('machine-home-path')
        if any(not safe_email(m.group()) for m in EMAIL.finditer(line)): found.add('personal-email')
        for m in IPV4.finditer(line):
            try:
                address = ipaddress.IPv4Address(m.group())
                allowed = address.is_loopback or str(address) in {'0.0.0.0', '255.255.255.255'} or any(address in ipaddress.IPv4Network(n) for n in ['192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24'])
                if not allowed: found.add('non-example-network-address')
            except ValueError: pass
        for m in IPV6.finditer(line):
            try:
                address = ipaddress.IPv6Address(m.group().split('%')[0])
                if address not in {ipaddress.IPv6Address('::'), ipaddress.IPv6Address('::1')} and address not in ipaddress.IPv6Network('2001:db8::/32'):
                    found.add('non-example-network-address')
            except ValueError: pass
        for m in CHINESE.finditer(line):
            if not m.group(1).startswith(('<', '$')): found.add('literal-credential-or-identity')
        for rule, pattern in RULES.items():
            if pattern.search(line): found.add(rule)
        for m in LITERAL.finditer(line):
            value = m.group(1)
            if (path.startswith(("Tests/", "android/tests/", "tests/", "fixtures/")) and value in FAKE) or value.startswith(('synthetic-', 'example-', 'fixture-', 'test-', '$', '\\(', '<')): continue
            found.add('literal-credential-or-identity')
        for m in re.finditer(r'\b[0-9a-fA-F]{32,}\b', line):
            if path.startswith('.github/workflows/') and re.search(r'uses:\s*actions/(checkout|setup-java)@[0-9a-f]{40}\s', line + ' '): continue
            found.add('embedded-fingerprint-or-key')
        for m in QUOTED.finditer(line):
            value = m.group(1)
            entropy = -sum((n / len(value)) * math.log2(n / len(value)) for n in Counter(value).values())
            if entropy > 4.2: found.add('opaque-high-entropy-literal')
        result.extend((path, number, rule) for rule in sorted(found))
    return result


def scan_blob(path, data, mode='100644', reviews=None):
    name_findings = text_findings('<redacted-file-name>', path)
    if name_findings: return name_findings
    if mode in {'100644', '100755'} and path == SCREENSHOT_REVIEW:
        try: screenshot_reviews(data)
        except (ValueError, TypeError, UnicodeError): return [(path, 0, 'invalid-screenshot-review')]
        return []
    if mode == '100644' and path in SCREENSHOTS and reviews and path in reviews:
        return [] if reviewed_png(data, reviews[path]) else [(path, 0, 'unreviewed-or-unsafe-screenshot')]
    parts = PurePosixPath(path).parts
    if not parts or (len(parts) == 1 and path not in ROOT_FILES) or (len(parts) > 1 and parts[0] not in ROOT_DIRS):
        return [(path, 0, 'unreviewed-repository-path')]
    if any(p in DENIED_PARTS or p.startswith('.env') or p.endswith('.hanvonexport') for p in parts) or PurePosixPath(path).suffix.lower() in DENIED_SUFFIXES:
        return [(path, 0, 'private-or-generated-file')]
    if mode not in {'100644', '100755'}: return [(path, 0, 'symlink-or-submodule')]
    if len(data) > 1024 * 1024 or b'\0' in data: return [(path, 0, 'binary-or-large-file')]
    try: text = data.decode('utf-8')
    except UnicodeError: return [(path, 0, 'non-text-file')]
    return text_findings(path, text)


def entries(ref=None):
    raw = git('ls-tree', '-r', '-z', ref) if ref else git('ls-files', '--stage', '-z')
    for row in raw.split(b'\0'):
        if not row: continue
        meta, path = row.split(b'\t', 1)
        mode, second, third = meta.decode().split()
        if ref: oid = third
        else:
            oid = second
            if third != '0': raise ValueError('index has unresolved entries')
        yield mode, oid, path.decode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true')
    parser.add_argument('--history', action='store_true')
    parser.add_argument('--identity', action='store_true')
    parser.add_argument('--message', type=Path)
    args = parser.parse_args()
    findings, seen, cache = [], set(), {}
    if not any([args.staged, args.history, args.message]): parser.error('choose --staged, --history or --message')
    try:
        if args.message: findings += text_findings('<commit-message>', args.message.read_text())
        refs = git('rev-list', '--all').decode().splitlines() if args.history else []
        for ref in ([None] if args.staged else []) + refs:
            tree = list(entries(ref))
            reviews, review_oid = {}, None
            for mode, oid, path in tree:
                if path == SCREENSHOT_REVIEW and mode == '100644':
                    review_oid = oid
                    try: reviews = screenshot_reviews(git('cat-file', 'blob', oid))
                    except (ValueError, TypeError, UnicodeError): pass
            if not set(reviews) <= {path for _, _, path in tree}:
                findings.append((SCREENSHOT_REVIEW, 0, 'missing-reviewed-screenshot'))
            for mode, oid, path in tree:
                version = (mode, oid, path, review_oid if path in SCREENSHOTS else None)
                if version in seen: continue
                seen.add(version)
                if oid not in cache: cache[oid] = git('cat-file', 'blob', oid) if mode in {'100644', '100755'} else b''
                findings += scan_blob(path, cache[oid], mode, reviews)
            if ref:
                metadata = git('show', '-s', '--format=%an%n%ae%n%cn%n%ce%n%B', ref).decode()
                findings += text_findings('<commit-metadata>', metadata)
        if args.history:
            for row in git('for-each-ref', '--format=%(objecttype) %(objectname)', 'refs/tags').decode().splitlines():
                kind, oid = row.split()
                if kind != 'tag': continue
                header, _, body = git('cat-file', 'tag', oid).decode().partition('\n\n')
                metadata = '\n'.join(line for line in header.splitlines() if line.startswith(('tag ', 'tagger ')))
                findings += text_findings('<tag-metadata>', metadata + '\n' + body)
        if args.identity:
            for kind in ['GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT']:
                findings += text_findings('<commit-identity>', git('var', kind).decode())
    except (subprocess.CalledProcessError, UnicodeError, ValueError, OSError):
        print('Privacy check could not inspect all requested data; refusing to pass.', file=sys.stderr)
        return 2
    for path, line, rule in sorted(set(findings)):
        # repr escapes untrusted file names without printing any matching content.
        print(f'{path!r}:{line}: {rule}', file=sys.stderr)
    if findings:
        print('Privacy check FAILED. Remove sensitive content; do not bypass the hook.', file=sys.stderr)
        return 1
    print(f'Privacy check passed ({len(seen)} file versions checked).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
