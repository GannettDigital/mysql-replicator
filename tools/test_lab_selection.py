import contextlib
import io
import json
import unittest
from unittest.mock import patch

from lab_selection import command, main, resolve_cases, select_catalog


def row(identifier, family='database', **changes):
    return dict(dict(id=identifier, family=family, profile='forward', variant='default', suite='correctness',
                     status='not_run', dependencies=[]), **changes)


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.rows = [row('create'), row('alter', dependencies=['create']),
                     row('index', family='indexes', dependencies=['alter']), row('other', family='rows')]

    def test_family_and_case_union_keeps_catalog_order_and_dependency_reasons(self):
        selection = resolve_cases(self.rows, families=['indexes'], cases=['other'])
        self.assertEqual(selection['requested_cases'], ['index', 'other'])
        self.assertEqual(selection['cases'], ['create', 'alter', 'index', 'other'])
        self.assertEqual(selection['dependency_cases'], ['create', 'alter'])
        self.assertEqual(selection['required_by'], {'create': ['alter'], 'alter': ['index']})

    def test_multiple_families_share_cases_without_duplicate_execution(self):
        result = resolve_cases(self.rows, families=['database', 'indexes'], cases=['alter'])
        self.assertEqual(result['cases'], ['create', 'alter', 'index'])
        self.assertEqual(result['dependency_cases'], [])
        self.assertEqual(resolve_cases(self.rows)['cases'], ['create', 'alter', 'index', 'other'])
        self.assertEqual(resolve_cases(self.rows, cases=[])['cases'], [])

    def test_missing_unknown_inapplicable_and_cyclic_dependencies_fail(self):
        for rows in ([row('index', dependencies=['missing'])],
                     [row('index', dependencies=['index'])],
                     [row('index', dependencies=['create']), row('create', dependencies=['index'])],
                     [row('index', dependencies=['create']), row('create', status='not_applicable', reason='engine')]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                resolve_cases(rows, cases=['index'])
        for filters in [dict(cases=['typo']), dict(families=['typo']), dict(cases=['create', 'create']),
                        dict(cases=''), dict(cases='create'), dict(cases=[None])]:
            with self.subTest(filters=filters), self.assertRaises(ValueError):
                resolve_cases(self.rows, **filters)

    def test_inapplicable_requested_cases_keep_the_reason(self):
        result = resolve_cases([row('fk', status='not_applicable', reason='requires InnoDB')], families=['database'])
        self.assertEqual(result['cases'], [])
        self.assertEqual(result['excluded'], [dict(id='fk', reason='requires InnoDB')])

    def test_duplicate_invalid_status_and_mixed_contexts_fail(self):
        for rows in ([self.rows[0], self.rows[0]], [row('x', status='passed')],
                     [row('x'), row('y', profile='reverse')]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                resolve_cases(rows)

    def test_catalog_filters_and_reasons_do_not_cross_profiles_or_suites(self):
        rows = self.rows + [row('reconnect', family='lifecycle', suite='lifecycle')]
        rows += [dict(r, profile='reverse') for r in self.rows]
        rows.append(row('foreign-key', family='foreign-keys', status='not_applicable', reason='engine limit'))
        selected = select_catalog([dict(scenarios=rows)], families=['indexes', 'foreign-keys'])
        self.assertEqual(len(selected['groups']), 2)
        self.assertEqual(selected['requested_cases'], 2)
        self.assertEqual(selected['selected_cases'], 6)
        self.assertTrue(all(g['cases'] == ['create', 'alter', 'index'] for g in selected['groups']))
        self.assertEqual(selected['excluded'][0]['reason'], 'engine limit')
        self.assertEqual(selected['excluded'][0]['profile'], 'forward')
        narrowed = select_catalog([dict(scenarios=rows)], profiles=['reverse'], cases=['alter'])
        self.assertEqual(len(narrowed['groups']), 1)
        self.assertEqual(narrowed['groups'][0]['cases'], ['create', 'alter'])

    def test_complete_adapter_groups_only(self):
        rows = [row('a', suite='native'), row('b', suite='native')]
        plan = select_catalog([dict(scenarios=rows)])
        self.assertEqual(command(plan['groups'][0]), ['test', '--profile', 'forward', '--suite', 'native'])
        with self.assertRaisesRegex(ValueError, 'complete case group'):
            select_catalog([dict(scenarios=rows)], cases=['a'])

    def test_command_preserves_cases_variant_and_coverage(self):
        group = select_catalog([dict(scenarios=self.rows)], cases=['alter'])['groups'][0]
        self.assertEqual(command(group, skip_build=True, coverage=True), [
            'test', '--profile', 'forward', '--suite', 'correctness', '--skip-build', '--coverage',
            '--variant', 'default', '--tier', 'full', '--case', 'create', '--case', 'alter'])

    def test_conflicting_catalogs_and_unknown_filters_fail(self):
        catalog = dict(scenarios=self.rows)
        self.assertEqual(select_catalog([catalog, catalog])['selected_cases'], 4)
        with self.assertRaisesRegex(ValueError, 'conflicting'):
            select_catalog([catalog, dict(scenarios=[dict(self.rows[0], dependencies=['other'])])])
        with self.assertRaisesRegex(ValueError, 'empty'):
            select_catalog([dict(scenarios=[])])
        for filters in [dict(profiles=['typo']), dict(variants=['typo']), dict(suites=['typo']),
                        dict(cases=['typo']), dict(families=['typo'])]:
            with self.subTest(filters=filters), self.assertRaises(ValueError):
                select_catalog([catalog], **filters)

    def test_all_uses_canonical_catalog_instead_of_adding_recovery_aliases(self):
        output = io.StringIO()
        def query(args, **kwargs):
            suite = args[args.index('--suite') + 1]
            if suite == 'recovery':
                self.fail('standalone recovery catalog would add aliases')
            rows = self.rows if suite in ('all', 'correctness') else [row('reconnect', suite='lifecycle')]
            if suite == 'all':
                rows = rows + [row(s, suite=s, status='not_applicable') for s in ('native', 'demo', 'recovery')]
            return json.dumps(dict(scenarios=rows))
        with patch('sys.argv', ['lab_selection.py', '--lab', '/tmp/lab', '--suite', 'all']), \
                patch('lab_selection.subprocess.check_output', side_effect=query), \
                contextlib.redirect_stdout(output):
            main()
        self.assertEqual(json.loads(output.getvalue())['selected_cases'], 5)

    def test_cli_only_queries_inventory_and_emits_json(self):
        output = io.StringIO()
        with patch('sys.argv', ['lab_selection.py', '--lab', '/tmp/lab', '--family', 'indexes']), \
                patch('lab_selection.subprocess.check_output', return_value=json.dumps(dict(scenarios=self.rows))) as query, \
                contextlib.redirect_stdout(output):
            main()
        self.assertEqual(query.call_count, 1)
        self.assertIn('--list', query.call_args.args[0])
        self.assertEqual(json.loads(output.getvalue())['groups'][0]['cases'], ['create', 'alter', 'index'])


if __name__ == '__main__':
    unittest.main()
