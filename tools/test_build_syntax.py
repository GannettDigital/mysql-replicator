import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_syntax


class SyntaxLayerTests(unittest.TestCase):
    def run_build(self, failure=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'Sources/MySQLSyntax/SQLLexer.swift'
            source.parent.mkdir(parents=True)
            source.write_text('// Real syntax source\n')
            package = {'targets': [
                {'name': 'MySQLSyntax', 'type': 'regular'},
                {'name': 'ReplicatorApply', 'type': 'regular'},
                {'name': 'CSQLite', 'type': 'system'},
                {'name': 'MySQLSyntaxTests', 'type': 'test', 'path': 'tests/MySQLSyntaxTests'},
            ]}
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                if command[:2] == ['swift', 'build']:
                    self.assertEqual(source.read_text(), '// Real syntax source\n')
                    self.assertTrue((root / 'Sources/ReplicatorApply/Placeholder.swift').exists())
                    self.assertTrue((root / 'Sources/CSQLite/module.modulemap').exists())
                    if failure:
                        raise RuntimeError('compiler failure')

            with patch.object(build_syntax.Path, 'cwd', return_value=root), \
                 patch.object(build_syntax.subprocess, 'check_output', return_value=json.dumps(package)), \
                 patch.object(build_syntax.subprocess, 'run', side_effect=run), \
                 patch.object(build_syntax.sys, 'argv', ['build_syntax.py', '--configuration', 'release']):
                if failure:
                    with self.assertRaisesRegex(RuntimeError, 'compiler failure'):
                        build_syntax.main()
                else:
                    build_syntax.main()
            self.assertTrue(source.exists())
            self.assertFalse((root / 'Sources/ReplicatorApply').exists())
            self.assertFalse((root / 'Sources/CSQLite').exists())
            self.assertFalse((root / 'tests/MySQLSyntaxTests').exists())
            self.assertIn(['swift', 'build', '--target', 'MySQLSyntax', '--configuration', 'release'], commands)
            self.assertEqual(commands[-1][-3:] == ['save', '--scratch-path', '.build'], not failure)

    def test_builds_only_syntax_and_removes_placeholders(self):
        self.run_build()

    def test_failure_preserves_real_source_and_removes_placeholders(self):
        self.run_build(failure=True)
