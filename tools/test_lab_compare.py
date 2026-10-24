import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from lab_compare import collect, compare, record, write, server_image_identity, capture_server_images


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def result(self, name, cases, coverage=False, hits=(1, 2)):
        directory = self.root / name
        fixture = directory / 'fixture'
        runtime = dict(profile='p', variant=dict(id='default'), runtime_image='image', binary_sha256='binary',
                       code_coverage=coverage, servers=[dict(role='target', image='server', settings='sql_mode=strict', version='5.7')])
        write(fixture / 'runtime.json', runtime)
        write(fixture / 'cases.json', [dict(id=c, status='passed', assertions=[dict(id='rows', status='passed')]) for c in cases])
        events = []
        for i, case in enumerate([None] + cases):
            events += [dict(schema_version=1, call_id=str(i), event='start', case_id=case, role='source',
                            kind='request', queries=[], sql='secret row value', profile='p', variant='default',
                            dml_transport='sql', code_coverage=coverage),
                       dict(schema_version=1, call_id=str(i), event='finish', outcome='succeeded', seconds=0.1)]
        (fixture / 'sql-trace.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
        if coverage:
            write(fixture / 'code-coverage/combined/coverage.json', dict(version=1, sources={'file': 'digest'},
                  files={'Sources/Runtime/Main.swift': {str(i): int(i in hits) for i in range(1, 4)}}))
        result = directory / 'result.json'
        write(result, dict(schema_version=1, result='passed', build_inputs_digest='inputs', image='image',
              code_coverage=coverage, dml_transport='sql', scenarios=[dict(profile='p', variant='default', suite='correctness',
              id=c, status='passed', seconds=2, evidence=str(fixture)) for c in cases]))
        measurement = directory / 'measurement.json'
        write(measurement, dict(schema_version=1, kind='local-lab-measurement', exit_code=0, seconds=10, results=[str(result)]))
        return measurement

    def edit(self, measurement, file, change):
        root = measurement.parent
        path = root / file
        content = json.loads(path.read_text())
        change(content)
        write(path, content)

    def test_dependency_repetition_counts_and_sets_are_separate(self):
        a, ab, combined = [self.result(n, c, coverage=True) for n,c in [('a',['a']), ('ab',['a','b']), ('combined',['a','b'])]]
        report = compare([a, ab], [combined])
        self.assertTrue(report['same_case_and_assertion_sets'])
        self.assertEqual(report['baseline']['case_executions'], 3)
        self.assertEqual(report['candidate']['case_executions'], 2)
        self.assertEqual(report['baseline']['elapsed_seconds'], 20)
        self.assertEqual(report['candidate']['elapsed_seconds'], 10)
        self.assertEqual(report['baseline']['sql']['outside_cases']['calls'], 2)
        self.assertEqual(report['candidate']['sql']['outside_cases']['calls'], 1)
        self.assertEqual(report['coverage']['lost'], [])
        self.assertNotIn('secret row value', json.dumps(report))
        self.assertIsNone(collect([a.parent / 'result.json'])['summary']['elapsed_seconds'])

    def test_dropped_case_assertion_or_line_is_visible(self):
        base = self.result('base', ['a','b'], coverage=True)
        candidate = self.result('candidate', ['a'], coverage=True, hits=(2,3))
        report = compare([base], [candidate])
        self.assertFalse(report['same_case_and_assertion_sets'])
        self.assertEqual(report['cases']['missing'][0][-1], 'b')
        self.assertEqual(len(report['assertions']['missing']), 2)
        self.assertEqual(report['coverage']['lost'], [['Sources/Runtime/Main.swift', '1']])
        self.assertEqual(report['coverage']['gained'], [['Sources/Runtime/Main.swift', '3']])

    def test_mixed_provenance_or_settings_fail(self):
        base = self.result('base', ['a'])
        for field, value in [('build_inputs_digest','other'), ('image','other'), ('code_coverage',True)]:
            candidate = self.result(field, ['a'])
            self.edit(candidate, 'result.json', lambda r: r.update({field: value}))
            with self.subTest(field=field), self.assertRaises(ValueError):
                compare([base],[candidate])
        changed = self.result('settings', ['a'])
        self.edit(changed, 'fixture/runtime.json', lambda r: r['servers'][0].update(settings='other'))
        with self.assertRaisesRegex(ValueError, 'settings differ'):
            compare([base], [changed])
        with self.assertRaisesRegex(ValueError, 'repeated result'):
            collect([base, base])

    def test_missing_coverage_and_failed_assertions_are_not_zero(self):
        base = self.result('base', ['a'], coverage=True)
        self.edit(base, 'fixture/cases.json', lambda r: r[0]['assertions'][0].update(status='failed'))
        with self.assertRaisesRegex(ValueError, 'non-passing named assertion'):
            collect([base])
        other = self.result('other', ['a'], coverage=True)
        (other.parent / 'fixture/code-coverage/combined/coverage.json').unlink()
        with self.assertRaises(FileNotFoundError):
            collect([other])

    def test_incomplete_results_and_source_mapping_mismatch_fail(self):
        base = self.result('base', ['a'], coverage=True)
        changed = self.result('changed', ['a'], coverage=True)
        self.edit(changed, 'fixture/code-coverage/combined/coverage.json', lambda r: r.update(sources={'file':'changed'}))
        with self.assertRaisesRegex(ValueError, 'source mappings differ'):
            compare([base], [changed])
        self.edit(base, 'result.json', lambda r: r.update(result='failed'))
        with self.assertRaisesRegex(ValueError, 'passed lab results'):
            collect([base])

    def test_different_result_files_cannot_count_the_same_fixture_twice(self):
        base = self.result('base', ['a'])
        other = self.result('other', ['a'])
        self.edit(other, 'result.json', lambda r: r['scenarios'][0].update(evidence=str(base.parent / 'fixture')))
        with self.assertRaisesRegex(ValueError, 'fixture reused'):
            collect([base, other])

    def test_stale_sql_trace_fails(self):
        base = self.result('base', ['a'])
        trace = base.parent / 'fixture/sql-trace.jsonl'
        trace.write_text(trace.read_text().replace('"profile": "p"', '"profile": "other"'))
        with self.assertRaisesRegex(ValueError, 'SQL trace provenance'):
            collect([base])

    def test_compose_labels_do_not_hide_image_content_or_config_changes(self):
        def snapshot(identifier, project):
            return dict(Id=identifier, RootFS=dict(Layers=['layer']), Architecture='amd64', Os='linux',
                        Config=dict(Env=['MYSQL_VERSION=5.7.42'], Labels={'com.docker.compose.project':project}))
        a, b = self.result('a', ['a']), self.result('b', ['a'])
        for measurement, identifier in [(a, 'image-a'), (b, 'image-b')]:
            self.edit(measurement, 'fixture/runtime.json', lambda r: r['servers'][0].update(image=identifier))
            d=json.loads(measurement.read_text())
            d['server_images']={identifier:snapshot(identifier, identifier)}
            write(measurement,d)
        self.assertTrue(compare([a],[b])['same_case_and_assertion_sets'])
        original=snapshot('id','p')
        for field, value in [('RootFS',dict(Layers=['changed'])), ('Architecture','arm64'),
                             ('Config',dict(Env=['MYSQL_VERSION=8.4']))]:
            changed=dict(original, **{field:value})
            self.assertNotEqual(server_image_identity(original), server_image_identity(changed))
        d=json.loads(b.read_text())
        d['server_images']['image-b']['RootFS']['Layers']=['changed']
        write(b,d)
        with self.assertRaisesRegex(ValueError,'settings differ'):
            compare([a],[b])

    def test_image_snapshots_are_read_and_bound_to_runtime_ids(self):
        measurement=self.result('a',['a'])
        self.edit(measurement,'fixture/runtime.json',lambda r:r['servers'][0].update(image='server'))
        snapshot=dict(Id='server',RootFS=dict(Layers=['layer']),Architecture='amd64',Os='linux',Config={})
        result=measurement.parent/'result.json'
        with patch('lab_compare.subprocess.run', return_value=subprocess.CompletedProcess([],0,json.dumps([snapshot]))):
            self.assertEqual(capture_server_images(result), {'server':snapshot})
        with patch('lab_compare.subprocess.run', return_value=subprocess.CompletedProcess([],0,json.dumps([dict(snapshot,Id='other')]))):
            with self.assertRaisesRegex(ValueError,'different image'):
                capture_server_images(result)

    def test_interrupted_record_keeps_an_incomplete_measurement(self):
        output = self.root / 'measurement.json'
        with patch('lab_compare.subprocess.run', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                record(['lab','test','--skip-build'], output, self.root)
        self.assertIsNone(json.loads(output.read_text())['exit_code'])
        with self.assertRaisesRegex(ValueError, 'failed or ambiguous'):
            collect([output])

    def test_record_excludes_builds_and_retains_failed_run_measurement(self):
        output = self.root / 'measurement.json'
        with self.assertRaisesRegex(ValueError, 'skip-build'):
            record(['lab','test'], output, self.root)
        def run(*args, **kwargs):
            write(self.root / 'artifacts/lab/new/result.json', dict(result='failed'))
            return subprocess.CompletedProcess(args[0], 1)
        with patch('lab_compare.subprocess.run', side_effect=run):
            with self.assertRaisesRegex(ValueError, 'returned 1'):
                record(['lab','test','--skip-build'], output, self.root)
        saved = json.loads(output.read_text())
        self.assertEqual(saved['exit_code'], 1)
        self.assertEqual(len(saved['results']), 1)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            record(['lab','test','--skip-build'], output, self.root)


if __name__ == '__main__':
    unittest.main()
