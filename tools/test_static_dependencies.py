import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_rust_dependencies', ROOT / 'packaging/build_rust_dependencies.py')
deps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deps)


class RustDependencyTests(unittest.TestCase):
    def test_existing_sources_are_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'src').mkdir()
            source = root / 'src/lib.rs'
            source.write_text('real code')
            with self.assertRaisesRegex(ValueError, 'absent crate sources'):
                deps.build(root / 'Cargo.toml', 'target', root / 'target')
            self.assertEqual(source.read_text(), 'real code')

    def test_placeholder_write_failure_removes_created_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(Path, 'write_text', side_effect=PermissionError('write denied')), \
                    patch.object(deps.subprocess, 'check_output') as metadata:
                with self.assertRaisesRegex(PermissionError, 'write denied'):
                    deps.build(root / 'Cargo.toml', 'target', root / 'target')
                metadata.assert_not_called()
            self.assertFalse((root / 'src').exists())

    def test_failure_removes_placeholder_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(deps.subprocess, 'check_output', side_effect=RuntimeError('failed')):
                with self.assertRaisesRegex(RuntimeError, 'failed'):
                    deps.build(root / 'Cargo.toml', 'target', root / 'target')
            self.assertFalse((root / 'src').exists())

    @unittest.skipUnless(shutil.which('cargo') and shutil.which('rustc'), 'Rust toolchain required')
    def test_dependencies_survive_but_old_timestamp_real_crate_replaces_stub(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dependency = root / 'dependency'
            (dependency / 'src').mkdir(parents=True)
            (dependency / 'Cargo.toml').write_text('[package]\nname="cache_dependency"\nversion="0.1.0"\nedition="2021"\n')
            (dependency / 'src/lib.rs').write_text('pub fn answer() -> u32 { 42 }\n')
            crate = root / 'crate'
            crate.mkdir()
            manifest = crate / 'Cargo.toml'
            manifest.write_text('[package]\nname="cache_consumer"\nversion="0.1.0"\nedition="2021"\n'
                                '[dependencies]\ncache_dependency={path="../dependency"}\n')
            # Cargo needs a target even to generate a lockfile.
            (crate / 'src').mkdir()
            (crate / 'src/lib.rs').touch()
            subprocess.run(['cargo', 'generate-lockfile', '--offline', '--manifest-path', str(manifest)],
                           check=True, capture_output=True)
            shutil.rmtree(crate / 'src')
            host = next(line.split(': ', 1)[1] for line in subprocess.check_output(['rustc', '-vV'], text=True).splitlines()
                        if line.startswith('host: '))
            target_dir = root / 'target'
            deps.build(manifest, host, target_dir)
            outputs = target_dir / host / 'release/deps'
            libraries = list(outputs.glob('libcache_dependency-*.rlib'))
            self.assertTrue(libraries)
            before = {p: p.stat().st_mtime_ns for p in libraries}
            self.assertFalse(list(outputs.glob('libcache_consumer-*.rlib')))
            (crate / 'src').mkdir()
            source = crate / 'src/lib.rs'
            source.write_text('pub fn answer() -> u32 { cache_dependency::answer() }\n'
                              '#[test] fn actual_source_ran() { assert_eq!(answer(), 42); }\n')
            os.utime(source, (1, 1))
            result = subprocess.run(['cargo', 'test', '--locked', '--release', '--target', host,
                                     '--target-dir', str(target_dir), '--manifest-path', str(manifest)],
                                    check=True, capture_output=True, text=True)
            self.assertIn('actual_source_ran ... ok', result.stdout)
            self.assertNotIn('Compiling cache_dependency', result.stderr)
            self.assertEqual(before, {p: p.stat().st_mtime_ns for p in libraries})
