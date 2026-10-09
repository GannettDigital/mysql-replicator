"""Exercise downloads, integrity failures and non-destructive binary upgrades."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

from release_image import checked_asset, update_checksum
from release_version import ROOT


class ChecksumTests(unittest.TestCase):
    def test_image_checksum_update_tolerates_blank_lines_and_preserves_other_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'binary.tar.gz'
            binary.write_bytes(b'binary archive')
            image = root / 'image.tar.gz'
            image.write_bytes(b'image archive')
            binary_record = hashlib.sha256(binary.read_bytes()).hexdigest() + '  ' + binary.name
            sums = root / 'SHA256SUMS'
            sums.write_text('\n' + binary_record + '\n \t\n' + '0' * 64 + '  ' + image.name + '\n\n')
            update_checksum(root, image)
            updated = sums.read_text()
            self.assertEqual(checked_asset(root, binary.name), binary)
            self.assertEqual(checked_asset(root, image.name), image)
            self.assertEqual(len(updated.splitlines()), 2)
            self.assertIn(binary_record, updated)
            update_checksum(root, image)
            self.assertEqual(sums.read_text(), updated)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.downloads = self.root / 'downloads'
        self.downloads.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.prefix = self.root / 'prefix with spaces'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        DOWNLOADS=str(self.downloads), TEST_ARCH='x86_64', TEST_OS='Linux')
        self.script('uname', '#!/bin/sh\ncase "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_ARCH";; esac\n')
        self.script('curl', '''#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in
    https://github.com/GannettDigital/mysql-replicator/releases/download/v*) url=$1; shift ;;
    https://api.github.com/repos/GannettDigital/mysql-replicator/releases*) url=$1; shift ;;
    --output) output=$2; shift 2 ;;
    --retry) shift 2 ;;
    --fail|--show-error|--location) shift ;;
    *) exit 2 ;;
  esac
done
printf '%s\\n' "$url" >> "$DOWNLOADS/requests.log"
case "$url" in
  https://api.github.com/*)
    [ "${TEST_API_FAIL:-0}" = 0 ] || exit 22
    cp "$DOWNLOADS/releases-${url##*&page=}.json" "$output" ;;
  *) cp "$DOWNLOADS/${url##*/}" "$output" ;;
esac
''')
        # macOS runs these tests too; production installer is Linux/coreutils only.
        if not any((Path(p) / 'sha256sum').exists() for p in os.environ['PATH'].split(os.pathsep)):
            self.script('sha256sum', '#!/bin/sh\nexec shasum -a 256 "$@"\n')
        self.package('0.1.0-beta.2')

    def script(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def package(self, version, binary_version=None):
        name = f'mysql-replicator-{version}-linux-x86_64'
        path = self.downloads / (name + '.tar.gz')
        with tarfile.open(path, 'w:gz') as archive:
            for filename, content in {
                'mysql-replicator': f'#!/bin/sh\necho "mysql-replicator {binary_version or version} (test)"\n',
                'third-party/manifest.json': '[]', 'apply.example.yaml': 'example: true\n',
            }.items():
                entry = tarfile.TarInfo(name + '/' + filename)
                entry.mode = 0o755 if filename == 'mysql-replicator' else 0o644
                data = content.encode()
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        (self.downloads / 'SHA256SUMS').write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n')
        return path

    def install(self, version='0.1.0-beta.2', success=True):
        selected = [] if version is None else ['--version', version]
        result = subprocess.run(['sh', str(ROOT / 'packaging/install.sh')] + selected + [
                                 '--prefix', str(self.prefix)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def releases(self, releases, page=1):
        (self.downloads / f'releases-{page}.json').write_text(json.dumps(releases))

    def test_latest_includes_beta_excludes_drafts_and_pins_downloads(self):
        self.releases([
            dict(tag_name='v9.0.0', draft=True, published_at='2030-01-01T00:00:00Z'),
            dict(tag_name='v0.1.0-beta.2', draft=False, prerelease=True, published_at='2026-10-08T00:00:00Z'),
            dict(tag_name='v0.0.1', draft=False, prerelease=False, published_at='2026-09-01T00:00:00Z'),
        ])
        result = self.install(None)
        self.assertIn('Selected newest published release: v0.1.0-beta.2', result.stderr)
        requests = (self.downloads / 'requests.log').read_text().splitlines()
        self.assertEqual(len(requests), 3)
        self.assertTrue(all('/download/v0.1.0-beta.2/' in url for url in requests[1:]))

    def test_latest_checks_all_pages_and_uses_publication_date(self):
        self.releases([dict(tag_name='v0.0.1', draft=False, published_at='2026-01-01T00:00:00Z')] * 100)
        self.releases([dict(tag_name='v0.1.0-beta.2', draft=False, published_at='2026-10-08T00:00:00Z')], page=2)
        self.install('latest')
        self.assertIn('page=2', (self.downloads / 'requests.log').read_text())

    def test_latest_discovery_errors_do_not_create_install_prefix(self):
        for releases in [[], [dict(tag_name='v1.0.0', draft=True, published_at=None)],
                         {'message': 'API error'},
                         [dict(tag_name='v../unsafe', draft=False, published_at='2026-10-08T00:00:00Z')]]:
            with self.subTest(releases=releases):
                self.releases(releases)
                self.install(None, success=False)
                self.assertFalse(self.prefix.exists())
        self.env['TEST_API_FAIL'] = '1'
        self.install(None, success=False)
        self.assertFalse(self.prefix.exists())

    def test_explicit_version_does_not_use_discovery_or_jq(self):
        self.script('jq', '#!/bin/sh\nexit 99\n')
        self.env['TEST_API_FAIL'] = '1'
        self.install()
        self.assertNotIn('api.github.com', (self.downloads / 'requests.log').read_text())

    def test_install_upgrade_preserves_state_config_and_old_version(self):
        self.prefix.mkdir()
        for name in ['apply.yaml', 'state.sqlite']:
            (self.prefix / name).write_text('operator-owned')
        self.install()
        self.assertTrue((self.prefix / 'bin/mysql-replicator').is_symlink())
        self.assertTrue((self.prefix / 'lib/mysql-replicator/0.1.0-beta.2/third-party/manifest.json').exists())
        self.install(success=False)  # Existing version is never overwritten.
        self.package('0.1.0-beta.3')
        self.install('0.1.0-beta.3')
        self.assertIn('beta.3', os.readlink(self.prefix / 'bin/mysql-replicator'))
        self.assertTrue((self.prefix / 'lib/mysql-replicator/0.1.0-beta.2/mysql-replicator').exists())
        for name in ['apply.yaml', 'state.sqlite']:
            self.assertEqual((self.prefix / name).read_text(), 'operator-owned')

    def test_corruption_and_missing_or_duplicate_checksum_fail_before_install(self):
        for kind in ['corrupt', 'missing', 'duplicate']:
            with self.subTest(kind=kind):
                archive = self.package('0.1.0-beta.2')
                sums = self.downloads / 'SHA256SUMS'
                if kind == 'corrupt':
                    archive.write_bytes(b'corrupted')
                elif kind == 'missing':
                    sums.write_text('')
                else:
                    sums.write_text(sums.read_text() * 2)
                self.install(success=False)
                self.assertFalse((self.prefix / 'bin/mysql-replicator').exists())
                with self.assertRaises(ValueError):
                    checked_asset(self.downloads, archive.name)

    def test_wrong_binary_version_and_unmanaged_binary_are_rejected(self):
        self.package('0.1.0-beta.2', binary_version='0.1.0-beta.1')
        self.install(success=False)
        (self.prefix / 'bin').mkdir()
        binary = self.prefix / 'bin/mysql-replicator'
        binary.write_text('unmanaged')
        self.package('0.1.0-beta.2')
        self.install(success=False)
        self.assertEqual(binary.read_text(), 'unmanaged')

    def test_unsupported_platform_and_unsafe_versions_are_rejected(self):
        for value in ['', '../x', 'v0.1.0-beta.2', '0.1.0-beta.2\nevil', '01.0.0', '1.0.0-01']:
            with self.subTest(version=value):
                self.install(value, success=False)
        self.env['TEST_ARCH'] = 'aarch64'
        self.install(success=False)
        self.env.update(TEST_ARCH='x86_64', TEST_OS='Darwin')
        self.install(success=False)
        self.assertFalse(self.prefix.exists())


if __name__ == '__main__':
    unittest.main()
