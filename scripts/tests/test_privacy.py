"""Synthetic regression checks for repository privacy boundaries."""
import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import struct
import unittest
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'privacy-check.py'
spec = importlib.util.spec_from_file_location('privacy_guard', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class PrivacyTests(unittest.TestCase):
    @staticmethod
    def png(extra=b''):
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
                + extra + chunk(b'IDAT', zlib.compress(b'\0\0\0\0')) + chunk(b'IEND', b''))

    def review(self, data):
        path = 'docs/assets/screenshots/file-manager.png'
        return {path: dict(sha256=hashlib.sha256(data).hexdigest(), width=1, height=1)}

    def test_only_exact_reviewed_synthetic_png_is_allowed(self):
        data = self.png()
        reviews = self.review(data)
        path = next(iter(reviews))
        self.assertTrue(guard.scan_blob(path, data))
        self.assertEqual(guard.scan_blob(path, data, reviews=reviews), [])
        self.assertTrue(guard.scan_blob(path, data + b'extra', reviews=reviews))
        self.assertTrue(guard.scan_blob(path, data, '120000', reviews))
        self.assertTrue(guard.scan_blob('docs/other.png', data, reviews=reviews))
        wrong_dimensions = self.review(data)
        wrong_dimensions[path]['width'] = 2
        self.assertTrue(guard.scan_blob(path, data, reviews=wrong_dimensions))

    def test_even_reviewed_png_rejects_metadata(self):
        payload = b'Comment\0synthetic text'
        kind = b'tEXt'
        extra = struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
        data = self.png(extra)
        self.assertTrue(guard.scan_blob(next(iter(self.review(data))), data, reviews=self.review(data)))
        bad = dict(synthetic_only=True, images=self.review(data), note='arbitrary text')
        self.assertTrue(guard.scan_blob(guard.SCREENSHOT_REVIEW, json.dumps(bad).encode()))
        duplicate = b'{"synthetic_only":"unreviewed text","synthetic_only":true,"images":{}}'
        self.assertTrue(guard.scan_blob(guard.SCREENSHOT_REVIEW, duplicate))

    def test_screenshot_approval_uses_index_manifest(self):
        with tempfile.TemporaryDirectory(prefix='privacy-image-test-') as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', root], check=True)
            data = self.png()
            path = next(iter(self.review(data)))
            target = root / path
            target.parent.mkdir(parents=True)
            target.write_bytes(data)
            manifest = root / guard.SCREENSHOT_REVIEW
            manifest.write_text(json.dumps(dict(synthetic_only=True, images=self.review(data))))
            subprocess.run(['git', '-C', root, 'add', '.'], check=True)
            command = ['python3', str(SCRIPT), '--staged']
            self.assertEqual(subprocess.run(command, cwd=root, capture_output=True).returncode, 0)
            target.write_bytes(self.png() + b'changed')
            subprocess.run(['git', '-C', root, 'add', path], check=True)
            manifest.write_text(json.dumps(dict(synthetic_only=True, images=self.review(target.read_bytes()))))
            # A working-tree review cannot approve a different indexed image.
            self.assertEqual(subprocess.run(command, cwd=root, capture_output=True).returncode, 1)

    def rules(self, text, path='Sources/sample.swift'):
        return {rule for _, _, rule in guard.scan_blob(path, text.encode())}

    def test_home_email_and_real_network_are_rejected(self):
        home = '/' + 'Users' + '/synthetic-person/private'
        email = 'person' + '@' + 'personal.test'
        ip = '.'.join(['192', '168', '44', '12'])
        found = self.rules('\n'.join([home, email, ip]))
        self.assertTrue({'machine-home-path', 'personal-email', 'non-example-network-address'} <= found)

    def test_example_addresses_and_runtime_secrets_are_allowed(self):
        self.assertEqual(self.rules('https://192.0.2.2\n$HOME\nlet token = readFromKeychain()\ncontact@example.invalid'), set())

    def test_key_headers_provider_keys_and_literal_passwords_are_rejected(self):
        header = '-----BEGIN ' + 'PRIVATE KEY-----'
        credential = 'gh' + 'p_' + 'Q7bT9xL2' * 5
        sample = 'pass' + 'word = ' + repr('synthetic-not-an-allowed-placeholder'.replace('synthetic-', ''))
        found = self.rules('\n'.join([header, credential, sample]))
        self.assertTrue({'private-key', 'provider-credential', 'literal-credential-or-identity'} <= found)

    def test_identifiers_phone_and_device_identity_are_rejected(self):
        phone = '139' + '0000' + '0000'
        identity = '110101' + '19900101' + '001X'
        mac = ':'.join(['a1', 'b2', 'c3', 'd4', 'e5', 'f6'])
        found = self.rules('\n'.join([phone, identity, mac]))
        self.assertTrue({'phone-number', 'identity-number', 'device-mac'} <= found)

    def test_tests_do_not_have_a_blanket_fingerprint_exception(self):
        digest = ''.join('0123456789abcdef' for _ in range(4))
        self.assertIn('embedded-fingerprint-or-key', self.rules(digest, 'Tests/example.swift'))

    def test_ipv6_chinese_labels_and_signing_password_flags(self):
        address = ':'.join(['fe80', '', 'abcd'])
        label = '密' + '码：' + 'do-not-commit-example'
        flag = '--ks-' + 'pass pass:' + 'do-not-commit-example'
        found = self.rules('\n'.join([address, label, flag]))
        self.assertTrue({'non-example-network-address', 'literal-credential-or-identity', 'command-line-password'} <= found)
        self.assertEqual(self.rules('https://[2001:db8::1]'), set())

    def test_private_files_binary_and_symlinks_are_rejected(self):
        for name in ['.android-signing/identity.p12', 'docs/note.db', 'README.md']:
            with self.subTest(name=name):
                self.assertTrue(guard.scan_blob(name, b'\x00\x01'))
        self.assertTrue(guard.scan_blob('docs/link.md', b'file', '120000'))

    def test_sensitive_file_names_are_redacted(self):
        name = 'docs/' + 'person' + '@' + 'personal.test' + '.md'
        found = guard.scan_blob(name, b'innocent text')
        self.assertTrue(found)
        self.assertEqual(found[0][0], '<redacted-file-name>')

    def test_annotated_tag_messages_are_checked(self):
        with tempfile.TemporaryDirectory(prefix='privacy-tag-test-') as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', root], check=True)
            for key, value in [('user.name', 'Synthetic Contributor'), ('user.email', 'test@example.invalid'), ('commit.gpgsign', 'false')]:
                subprocess.run(['git', '-C', root, 'config', key, value], check=True)
            (root / 'README.md').write_text('Clean')
            subprocess.run(['git', '-C', root, 'add', '.'], check=True)
            subprocess.run(['git', '-C', root, 'commit', '-qm', 'Synthetic test'], check=True)
            message = 'pass' + 'word = ' + repr('never-publish-this-example')
            subprocess.run(['git', '-C', root, '-c', 'tag.gpgsign=false', 'tag', '-a', 'test', '-m', message], check=True)
            result = subprocess.run(['python3', str(SCRIPT), '--history'], cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('<tag-metadata>', result.stderr)
            self.assertNotIn('never-publish-this-example', result.stderr)

    def test_scans_staged_blob_even_if_worktree_is_cleaned(self):
        with tempfile.TemporaryDirectory(prefix='privacy-index-test-') as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', root], check=True)
            target = root / 'README.md'
            sample = 'pass' + 'word = ' + repr('do-not-commit-this-example')
            target.write_text(sample)
            subprocess.run(['git', '-C', root, 'add', 'README.md'], check=True)
            target.write_text('Clean working copy')
            result = subprocess.run(['python3', str(SCRIPT), '--staged'], cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('literal-credential-or-identity', result.stderr)
            self.assertNotIn('do-not-commit-this-example', result.stderr)

    def test_history_still_rejects_secret_removed_in_later_commit(self):
        with tempfile.TemporaryDirectory(prefix='privacy-history-test-') as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', root], check=True)
            for key, value in [('user.name', 'Synthetic Contributor'), ('user.email', 'test@example.invalid'), ('commit.gpgsign', 'false')]:
                subprocess.run(['git', '-C', root, 'config', key, value], check=True)
            for text in ['pass' + 'word = ' + repr('do-not-commit-history-example'), 'Cleaned']:
                (root / 'README.md').write_text(text)
                subprocess.run(['git', '-C', root, 'add', '.'], check=True)
                subprocess.run(['git', '-C', root, 'commit', '-qm', 'Synthetic test'], check=True)
            result = subprocess.run(['python3', str(SCRIPT), '--history'], cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('literal-credential-or-identity', result.stderr)
            self.assertNotIn('do-not-commit-history-example', result.stderr)


if __name__ == '__main__':
    unittest.main()
