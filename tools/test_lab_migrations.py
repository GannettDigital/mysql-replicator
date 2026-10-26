import copy
import unittest

from lab_migrations import entries, retired_hint, validate_migrations, validate_results


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.item = dict(suite='correctness', retired='old', replacement='new', review='PLAN/review.md',
                         conditions=[dict(condition='Keep a NULL row', assertion='retain-null')],
                         scopes=[dict(profile='p', variant='default', transport='sql')])
        self.document = dict(schema_version=1, migrations=[self.item])
        self.rows = [dict(profile='p', variant='default', suite='correctness', id='new', status='not_run',
                          assertions=['retain-null'], replaces=['old'])]
        self.groups = [dict(profile='p', variant='default', suite='correctness', cases=['new'])]

    def test_complete_plan_requires_scope_assertion_and_execution(self):
        validate_migrations([dict(scenarios=self.rows)], self.document, complete=True, groups=self.groups)
        for change in [dict(status='not_applicable'), dict(assertions=[]), dict(replaces=[]), dict(id='other')]:
            rows = [dict(self.rows[0], **change)]
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_migrations([dict(scenarios=rows)], self.document, complete=True)
        with self.assertRaisesRegex(ValueError, 'execution'):
            validate_migrations([dict(scenarios=self.rows)], self.document, complete=True, groups=[])
        self.item['scopes'][0]['transport'] = 'binlog'
        with self.assertRaisesRegex(ValueError, 'execution'):
            validate_migrations([dict(scenarios=self.rows)], self.document, complete=True, groups=self.groups)

    def test_retired_case_cannot_remain_or_replacement_go_undeclared(self):
        with self.assertRaisesRegex(ValueError, 'still in catalog'):
            validate_migrations([dict(scenarios=self.rows + [dict(self.rows[0], id='old', replaces=[])])], self.document)
        with self.assertRaisesRegex(ValueError, 'no migration'):
            validate_migrations([dict(scenarios=self.rows)], dict(schema_version=1, migrations=[]))

    def test_partial_catalog_skips_only_contexts_not_queried(self):
        validate_migrations([dict(scenarios=[dict(self.rows[0], profile='other', replaces=[])])], self.document)
        with self.assertRaisesRegex(ValueError, 'applicable replacement'):
            validate_migrations([dict(scenarios=[dict(self.rows[0], id='other', replaces=[])])], self.document)

    def test_pr_selection_does_not_require_unselected_replacements(self):
        catalogs = [dict(scenarios=[dict(self.rows[0], id='other', replaces=[])])]
        validate_migrations(catalogs, self.document, selection_only=True)
        with self.assertRaises(ValueError):
            validate_migrations(catalogs, self.document, selection_only=True, complete=True)

    def test_invalid_or_ambiguous_migrations_fail(self):
        for change in [dict(conditions=[]), dict(scopes=[]), dict(replacement='old'), dict(retired='')]:
            item = dict(self.item, **change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                list(entries(dict(schema_version=1, migrations=[item])))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            list(entries(dict(schema_version=1, migrations=[self.item, self.item])))
        self.item['scopes'] *= 2
        with self.assertRaisesRegex(ValueError, 'duplicate migration scope'):
            list(entries(self.document))

    def test_result_needs_case_and_each_named_assertion_to_pass(self):
        record = dict(id='new', status='passed', assertions=[dict(id='retain-null', status='passed', evidence='a.json')])
        validate_results([record], self.item)
        for change in [dict(status='failed'), dict(assertions=[]),
                       dict(assertions=[dict(id='retain-null', status='failed')])]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_results([dict(record, **change)], self.item)
        with self.assertRaises(ValueError):
            validate_results([record, copy.deepcopy(record)], self.item)

    def test_retired_selector_reports_replacement_without_enabling_alias(self):
        self.assertEqual(retired_hint(['old'], self.document), 'old was replaced by new')
        self.assertEqual(retired_hint(['other'], self.document), '')
