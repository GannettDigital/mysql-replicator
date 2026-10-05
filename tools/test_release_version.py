import unittest
from pathlib import Path
from release_version import ROOT, SWIFT, swift_source, versions


class ReleaseVersionTests(unittest.TestCase):
    def test_prerelease_debian_ordering_syntax(self):
        self.assertEqual(versions('0.1.0-beta.1'), ('0.1.0-beta.1', '0.1.0~beta.1-1'))
        self.assertEqual(versions('1.2.3'), ('1.2.3', '1.2.3-1'))
        self.assertEqual(versions('1.2.3-rc-hotfix.2')[1], '1.2.3~rc-hotfix.2-1')

    def test_invalid_or_ambiguous_versions(self):
        for value in ('v1.2.3', '01.2.3', '1.2', '1.2.3\n', '1.2.3+build.1',
                      '1.2.3-01', '1.2.3-', '../1.2.3', '1.2.3;echo bad'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                versions(value)

    def test_committed_constant_matches_canonical_version(self):
        self.assertEqual((ROOT / SWIFT).read_text(), swift_source((ROOT / 'VERSION').read_text().strip()))


if __name__ == '__main__':
    unittest.main()
