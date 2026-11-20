"""Synthetic regression checks for repository privacy boundaries."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'privacy-check.py'
spec = importlib.util.spec_from_file_location('privacy_guard', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class PrivacyTests(unittest.TestCase):
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
