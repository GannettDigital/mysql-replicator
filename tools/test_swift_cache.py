import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import swift_cache


class SwiftCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.scratch = self.root / '.build'
        self.scratch.mkdir()
        (self.root / 'Sources').mkdir()
        self.source = self.root / 'Sources/main.c'
        self.source.write_text('old')

    def save(self):
        with contextlib.redirect_stdout(io.StringIO()):
            swift_cache.save(self.root, self.scratch)

    def restore(self):
        with contextlib.redirect_stdout(io.StringIO()):
            swift_cache.restore(self.root, self.scratch)

    def test_restores_exact_nanoseconds_for_unchanged_inputs_and_outputs(self):
        output = self.scratch / 'main.o'
        output.write_bytes(b'object')
        stamp = 1_700_000_000_123_456_789
        for path in (self.source, output):
            os.utime(path, ns=(stamp, stamp))
        self.save()
        for path in (self.source, output):
            os.utime(path, ns=(stamp, stamp // 1_000_000_000 * 1_000_000_000))
        self.restore()
        for path in (self.source, output):
            self.assertEqual(path.stat().st_mtime_ns, stamp)

    def test_same_size_edits_preserving_mtime_still_invalidate(self):
        self.save()
        stamp = self.source.stat().st_mtime_ns
        self.source.write_text('new')
        os.utime(self.source, ns=(stamp, stamp))
        self.restore()
        self.assertNotEqual(self.source.stat().st_mtime_ns, stamp)
        self.assertEqual(self.source.read_text(), 'new')

    def test_new_deleted_and_changed_mode_files_are_not_restored(self):
        self.save()
        self.source.unlink()
        new = self.root / 'Sources/new.c'
        new.write_text('new')
        stamp = new.stat().st_mtime_ns
        self.restore()
        self.assertFalse(self.source.exists())
        self.assertEqual(new.stat().st_mtime_ns, stamp)
        self.source.write_text('old')
        self.save()
        self.source.chmod(0o755)
        self.restore()
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o755)

    def test_symlink_escape_and_unknown_manifest_paths_are_ignored(self):
        with tempfile.TemporaryDirectory() as external:
            outside = Path(external) / 'main.c'
            outside.write_text('old')
            self.save()
            stamp = outside.stat().st_mtime_ns
            shutil.rmtree(self.root / 'Sources')
            (self.root / 'Sources').symlink_to(external, target_is_directory=True)
            self.restore()
            self.assertEqual(outside.stat().st_mtime_ns, stamp)

    def test_missing_manifest_is_a_normal_cold_build(self):
        self.restore()

    @unittest.skipUnless(os.environ.get('SWIFT_CACHE_INTEGRATION') == '1',
                         'opt-in real Swift compiler round trip')
    def test_compiler_reuses_transport_cache_and_rebuilds_changed_code(self):
        self.source.unlink()
        (self.root / 'Package.swift').write_text('''// swift-tools-version:6.1
import PackageDescription
let package = Package(name: "Probe", targets: [.executableTarget(name: "Probe"), .executableTarget(name: "SwiftProbe")])
''')
        sources = self.root / 'Sources/Probe'
        sources.mkdir()
        source = sources / 'main.c'
        header = sources / 'value.h'
        source.write_text('#include <stdio.h>\n#include "value.h"\nint main(void) { puts(VALUE); }\n')
        header.write_text('#define VALUE "one"\n')

        swift_source = self.root / 'Sources/SwiftProbe/main.swift'
        swift_source.parent.mkdir()
        swift_source.write_text('print("one")\n')

        def build():
            return subprocess.run(['swift', 'build', '--package-path', str(self.root)],
                                  check=True, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT).stdout

        def run():
            return subprocess.check_output([str(self.scratch / 'debug/Probe')], text=True).strip()

        self.assertIn('Compiling', build())
        self.assertEqual(run(), 'one')
        self.save()
        # Reproduce a fresh checkout plus transport that truncates timestamps.
        for path in swift_cache.files(self.root, self.scratch):
            info = path.stat()
            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns // 1_000_000_000 * 1_000_000_000))
        self.restore()
        self.assertNotIn('Compiling', build())
        self.assertEqual(run(), 'one')
        for path, text, expected in [
            (header, '#define VALUE "two"\n', 'two'),
            (source, '#include <stdio.h>\nint main(void) { puts("new"); }\n', 'new'),
        ]:
            self.save()
            stamp = path.stat().st_mtime_ns
            path.write_text(text)
            os.utime(path, ns=(stamp, stamp))
            self.restore()
            self.assertIn('Compiling', build())
            self.assertEqual(run(), expected)
        self.save()
        stamp = swift_source.stat().st_mtime_ns
        swift_source.write_text('print("two")\n')
        os.utime(swift_source, ns=(stamp, stamp))
        self.restore()
        self.assertIn('Compiling', build())
        self.assertEqual(subprocess.check_output([str(self.scratch / 'debug/SwiftProbe')],
                                                text=True).strip(), 'two')


if __name__ == '__main__':
    unittest.main()
