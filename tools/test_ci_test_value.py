import hashlib
import json
import unittest

from ci_matrix import SMOKE_PROFILES
from ci_test_value import analyze, markdown, repeated_cases, write


class TestValueTests(unittest.TestCase):
    def fixture(self):
        sources = {'Sources/Runtime.swift': 'hash'}
        digest = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
        shards, records, inventory = [], [], []
        for profile, area, image, hit in [
            (SMOKE_PROFILES[0], 'smoke', 'coverage', ['1']),
            (SMOKE_PROFILES[1], 'smoke', 'coverage', ['2']),
            (SMOKE_PROFILES[0], 'ddl-1', 'coverage', ['2', '3', '4']),
            (SMOKE_PROFILES[0], 'ddl-1', 'release', None),
            (SMOKE_PROFILES[0], 'reconnect', 'release', None),
        ]:
            identifier = f'{image}-{profile}-default-{area}'
            row = dict(profile=profile, variant='default', suite='correctness', id=area, status='not_run', intent='verify rows')
            inventory.append(row)
            shards.append(dict(id=identifier, profile=profile, variant='default', suite='correctness', area=area,
                               image=image, reports=int(hit is not None)))
            record = dict(id=identifier, status='passed', seconds=60, scenarios=[dict(row, status='passed')])
            if hit is not None:
                record['coverage'] = dict(collections=1, sources_digest=digest,
                    mapped=[['Sources/Runtime.swift', n] for n in ['1', '2', '3', '4']],
                    hit=[['Sources/Runtime.swift', n] for n in hit])
            records.append(record)
        unit = dict(sources=sources, files={'Sources/Runtime.swift': {'3': 1}})
        return dict(include=shards, inventory=inventory), records, unit

    def test_marginal_union_and_unmeasured_are_distinct(self):
        manifest, records, unit = self.fixture()
        result = analyze(manifest, records, unit)
        ddl = next(r for r in result['areas'] if r['area'] == 'ddl')
        self.assertEqual((ddl['extra_over_baseline'], ddl['extra_over_unit_baseline'], ddl['exclusive_integration_lines']), (2, 1, 2))
        self.assertEqual((ddl['jobs'], ddl['instrumented_jobs'], ddl['passed_catalog_keys']), (2, 1, 1))
        self.assertEqual((ddl['release_seconds'], ddl['coverage_seconds']), (60, 60))
        self.assertEqual(ddl['obligations'][0]['intent'], 'verify rows')
        reconnect = next(r for r in result['areas'] if r['area'] == 'reconnect')
        self.assertIsNone(reconnect['covered_lines'])
        self.assertIsNone(reconnect['extra_over_baseline'])
        self.assertIn('unmeasured', markdown(result))

    def test_exact_lines_distinguish_unit_coverage_from_missing_measurements(self):
        manifest, records, unit = self.fixture()
        result = analyze(manifest, records, unit)
        ddl = next(r for r in result['areas'] if r['area'] == 'ddl')
        self.assertEqual(ddl['line_details'], dict(
            extra_over_baseline={'Sources/Runtime.swift':[3,4]},
            extra_over_unit_baseline={'Sources/Runtime.swift':[4]},
            exclusive_integration={'Sources/Runtime.swift':[3,4]},
            exclusive_after_unit={'Sources/Runtime.swift':[4]}))
        self.assertEqual(ddl['exclusive_after_unit_lines'], 1)
        self.assertIn('Sources/Runtime.swift:4', markdown(result))
        reconnect = next(r for r in result['areas'] if r['area'] == 'reconnect')
        self.assertTrue(all(v is None for v in reconnect['line_details'].values()))
        without_unit = analyze(manifest, records)
        self.assertTrue(all(r['line_details']['exclusive_after_unit'] is None for r in without_unit['areas']))
        without_baseline = analyze(manifest, records[1:], unit)
        self.assertTrue(all(r['line_details']['extra_over_baseline'] is None for r in without_baseline['areas']))

    def test_exact_line_details_match_counts_and_csv_stays_scalar(self):
        import csv
        import tempfile
        from pathlib import Path
        manifest, records, unit = self.fixture()
        records[2]['coverage']['hit'].append(['Sources/Runtime.swift','10'])
        records[2]['coverage']['mapped'].append(['Sources/Runtime.swift','10'])
        report = analyze(manifest, records, unit)
        ddl = next(r for r in report['areas'] if r['area'] == 'ddl')
        self.assertEqual(ddl['line_details']['exclusive_integration']['Sources/Runtime.swift'], [3,4,10])
        for row in report['areas']:
            for metric, details in [('extra_over_baseline','extra_over_baseline'),
                                    ('extra_over_unit_baseline','extra_over_unit_baseline'),
                                    ('exclusive_integration_lines','exclusive_integration'),
                                    ('exclusive_after_unit_lines','exclusive_after_unit')]:
                locations=row['line_details'][details]
                self.assertEqual(row[metric], None if locations is None else sum(map(len,locations.values())))
        with tempfile.TemporaryDirectory() as directory:
            write(Path(directory),report)
            with (Path(directory)/'test-value.csv').open() as stream:
                rows=list(csv.DictReader(stream))
            self.assertNotIn('line_details', rows[0])
            saved=json.loads((Path(directory)/'test-value.json').read_text())
            self.assertEqual(saved,report)

    def test_mixed_integration_sources_fail_without_unit_baseline(self):
        manifest, records, _ = self.fixture()
        records[0]['coverage']['sources_digest']='different'
        with self.assertRaisesRegex(ValueError, 'integration coverage sources differ'):
            analyze(manifest,records)

    def test_grouped_jobs_do_not_change_area_times_or_line_coverage(self):
        from ci_jobs import assign_jobs
        manifest, records, unit = self.fixture()
        original = analyze(manifest, records, unit)
        plan = assign_jobs(manifest, dict(max_groups=3, group_timeout_minutes=45,
                                         setup_timeout_minutes=10, standalone_areas=[]))
        grouped = analyze(plan, records, unit)
        for old, new in zip(original['areas'], grouped['areas']):
            for key in ('release_seconds', 'coverage_seconds', 'covered_lines', 'extra_over_baseline',
                        'passed_catalog_keys', 'execution_groups', 'instrumented_groups'):
                self.assertEqual(old[key], new[key])
        self.assertIn('Groups with coverage / total', markdown(grouped))

    def test_missing_baselines_do_not_claim_zero_gains(self):
        manifest, records, _ = self.fixture()
        result = analyze(manifest, records[1:])
        self.assertFalse(result['baseline_complete'])
        self.assertTrue(all(r['extra_over_baseline'] is None for r in result['areas']))
        self.assertTrue(all(r['extra_over_unit_baseline'] is None for r in result['areas']))
        self.assertTrue(any(not r['complete'] for r in result['areas']))

    def test_case_repetitions_keep_profile_variant_transport_and_image_distinct(self):
        group = dict(id='first', area='area', profile='p', variant='default', suite='correctness',
                     image='release', cases=['case', 'setup'], requested_cases=['case'])
        groups = [group, dict(group, id='second'), dict(group, id='binlog', dml_transport='binlog'),
                  dict(group, id='coverage', image='coverage'), dict(group, id='profile', profile='q'),
                  dict(group, id='variant', variant='position'), dict(group, id='unlisted', cases=[])]
        review = repeated_cases(dict(include=groups))
        self.assertEqual(len(review['repeated']), 2)
        self.assertEqual(review['unlisted_groups'], ['unlisted'])
        for row in review['repeated']:
            self.assertEqual([e['group'] for e in row['executions']], ['first', 'second'])
            self.assertTrue(all(e['dependency'] == (row['case'] == 'setup') for e in row['executions']))

    def test_failed_smoke_and_mixed_sources_are_not_a_baseline(self):
        manifest, records, unit = self.fixture()
        records[0]['status'] = 'failed'
        self.assertFalse(analyze(manifest, records, unit)['baseline_complete'])
        unit['sources'] = {}
        with self.assertRaisesRegex(ValueError, 'sources differ'):
            analyze(manifest, records, unit)

    def test_explicit_full_baseline_reports_actual_cases(self):
        manifest, records, unit = self.fixture()
        old_id = manifest['include'][0]['id']
        new_id = old_id.replace('smoke', 'conditional-ddl')
        manifest['include'][0].update(id=new_id, area='conditional-ddl', cases=['create', 'modify'])
        records[0]['id'] = new_id
        manifest.update(scope='full', coverage_baseline_groups=[new_id, manifest['include'][1]['id']])
        report = analyze(manifest, records, unit)
        self.assertTrue(report['baseline_complete'])
        self.assertEqual(report['baseline_scope'], 'full')
        self.assertEqual(report['baseline_group_ids'], manifest['coverage_baseline_groups'])
        self.assertEqual(report['baseline_selections'][0]['cases'], ['create', 'modify'])
        text = markdown(report)
        self.assertIn('`create`, `modify`', text)
        self.assertNotIn('Baseline: the two PR case selections', text)
        manifest['coverage_baseline_groups'] = []
        self.assertFalse(analyze(manifest, records, unit)['baseline_complete'])
        for ids in [[new_id, new_id], ['missing']]:
            manifest['coverage_baseline_groups'] = ids
            with self.assertRaisesRegex(ValueError, 'unique planned groups'):
                analyze(manifest, records, unit)
