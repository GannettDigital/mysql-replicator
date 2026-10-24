import hashlib
import json
import unittest

from ci_matrix import SMOKE_PROFILES
from ci_test_value import analyze, markdown


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
        self.assertEqual((ddl['extra_over_smoke'], ddl['extra_over_unit_smoke'], ddl['exclusive_integration_lines']), (2, 1, 2))
        self.assertEqual((ddl['jobs'], ddl['instrumented_jobs'], ddl['passed_catalog_keys']), (2, 1, 1))
        self.assertEqual((ddl['release_seconds'], ddl['coverage_seconds']), (60, 60))
        self.assertEqual(ddl['obligations'][0]['intent'], 'verify rows')
        reconnect = next(r for r in result['areas'] if r['area'] == 'reconnect')
        self.assertIsNone(reconnect['covered_lines'])
        self.assertIsNone(reconnect['extra_over_smoke'])
        self.assertIn('unmeasured', markdown(result))

    def test_grouped_jobs_do_not_change_area_times_or_line_coverage(self):
        from ci_jobs import assign_jobs
        manifest, records, unit = self.fixture()
        original = analyze(manifest, records, unit)
        plan = assign_jobs(manifest, dict(max_groups=3, group_timeout_minutes=45,
                                         setup_timeout_minutes=10, standalone_areas=[]))
        grouped = analyze(plan, records, unit)
        for old, new in zip(original['areas'], grouped['areas']):
            for key in ('release_seconds', 'coverage_seconds', 'covered_lines', 'extra_over_smoke',
                        'passed_catalog_keys', 'execution_groups', 'instrumented_groups'):
                self.assertEqual(old[key], new[key])
        self.assertIn('Groups with coverage / total', markdown(grouped))

    def test_missing_baselines_do_not_claim_zero_gains(self):
        manifest, records, _ = self.fixture()
        result = analyze(manifest, records[1:])
        self.assertFalse(result['baseline_complete'])
        self.assertTrue(all(r['extra_over_smoke'] is None for r in result['areas']))
        self.assertTrue(all(r['extra_over_unit_smoke'] is None for r in result['areas']))
        self.assertTrue(any(not r['complete'] for r in result['areas']))

    def test_failed_smoke_and_mixed_sources_are_not_a_baseline(self):
        manifest, records, unit = self.fixture()
        records[0]['status'] = 'failed'
        self.assertFalse(analyze(manifest, records, unit)['baseline_complete'])
        unit['sources'] = {}
        with self.assertRaisesRegex(ValueError, 'sources differ'):
            analyze(manifest, records, unit)
