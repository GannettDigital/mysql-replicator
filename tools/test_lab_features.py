import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import ci_lab
from lab_features import describe_features, feature_index, load_features, with_features


class FeatureTests(unittest.TestCase):
    def setUp(self):
        self.registry = dict(schema_version=1, features=[dict(
            id='generated-columns', title='Generated Columns', kind='mysql',
            description='Stored and virtual values.',
            reference=dict(title='CREATE TABLE and Generated Columns', version='8.4',
                           location='https://dev.mysql.com/doc/refman/8.4/en/create-table-generated-columns.html'),
            cases=dict(correctness=['create', 'existing']))])
        self.rows = [dict(profile='p', suite='correctness', id='create', status='not_run'),
                     dict(profile='p', suite='correctness', id='existing', status='not_applicable', reason='engine')]
        self.catalogs = [dict(scenarios=self.rows)]

    def test_same_case_across_profiles_variants_and_repeated_catalogs_has_one_owner(self):
        extra = [dict(row, profile='other', variant='minimal') for row in self.rows]
        report = describe_features(self.catalogs * 2 + [dict(scenarios=extra)], self.registry, complete=True)
        self.assertEqual(len(report['cases']), 2)
        self.assertTrue(all(c['feature'] == 'generated-columns' for c in report['cases']))

    def test_missing_excluded_case_and_stale_full_catalog_assignment_fail(self):
        with self.assertRaisesRegex(ValueError, 'without a feature'):
            describe_features([dict(scenarios=self.rows + [dict(suite='correctness', id='new',
                                                               status='not_applicable')])], self.registry)
        partial = [dict(scenarios=self.rows[:1])]
        self.assertEqual(len(describe_features(partial, self.registry)['cases']), 1)
        with self.assertRaisesRegex(ValueError, 'absent from catalog'):
            describe_features(partial, self.registry, complete=True)
        with self.assertRaisesRegex(ValueError, 'empty'):
            describe_features([dict(scenarios=[])], self.registry)

    def test_duplicate_assignments_and_definitions_fail(self):
        self.registry['features'][0]['cases']['correctness'].append('create')
        with self.assertRaisesRegex(ValueError, 'duplicate feature assignment'):
            feature_index(self.registry)
        self.registry['features'][0]['cases']['correctness'].pop()
        other = copy.deepcopy(self.registry['features'][0])
        other['id'] = 'other'
        self.registry['features'].append(other)
        with self.assertRaisesRegex(ValueError, 'duplicate feature assignment'):
            feature_index(self.registry)
        other['id'] = 'generated-columns'
        with self.assertRaisesRegex(ValueError, 'duplicate feature ID'):
            feature_index(self.registry)

    def test_suite_is_part_of_case_identity(self):
        self.registry['features'][0]['cases']['native'] = ['create']
        _, owners = feature_index(self.registry)
        self.assertEqual(len(owners), 3)

    def test_reference_version_and_definition_validation(self):
        for field, value in [('id', 'Bad Name'), ('title', ''), ('description', None),
                             ('kind', 'unknown'), ('cases', {}), ('reference', {})]:
            registry = copy.deepcopy(self.registry)
            registry['features'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                feature_index(registry)
        for version in ('9.7', '5.7'):
            registry = copy.deepcopy(self.registry)
            registry['features'][0]['reference']['version'] = version
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, 'manual reference'):
                feature_index(registry)
        with self.assertRaisesRegex(ValueError, 'schema version'):
            feature_index(dict(self.registry, schema_version=True))

    def test_project_behavior_requires_existing_project_documentation(self):
        feature = self.registry['features'][0]
        feature.update(kind='project', reference=dict(title='Test lab', location='docs/TEST_LAB.md'))
        feature_index(self.registry)
        for path in ('docs/missing.md', '/tmp/test.md', 'docs/../AGENTS.md'):
            feature['reference']['location'] = path
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'project documentation'):
                feature_index(self.registry)

    def test_annotation_does_not_change_execution_or_mutate_plan(self):
        group = dict(suite='correctness', cases=['create'], dependency_cases=[], command=['test'])
        plan = dict(groups=[group], include=[dict(group, dml_transport='binlog')], inventory=self.rows,
                    jobs=[dict(groups=['job'])], obligations=1)
        before = copy.deepcopy(plan)
        result = with_features(plan, self.catalogs, self.registry, complete=True)
        self.assertEqual(plan, before)
        self.assertEqual(result['groups'][0]['features'], ['generated-columns'])
        result.pop('feature_catalog')
        for field in ('groups', 'include'):
            for item in result[field]:
                item.pop('features')
        self.assertEqual(result, before)

    def test_unlisted_planned_case_is_not_silently_annotated(self):
        plan = dict(groups=[dict(suite='correctness', cases=['typo'])])
        with self.assertRaisesRegex(ValueError, 'planned cases absent'):
            with_features(plan, self.catalogs, self.registry)

    def test_ci_plan_checks_full_assignment_before_writing_plan(self):
        group = dict(id='fixture', profile='p', suite='correctness', cases=['create'])
        plan = dict(scope='full', inventory=self.rows, include=[group], jobs=[dict(id='job')],
                    obligations=1, coverage_reports=1)
        query = Mock(return_value='inputs')
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(ci_lab, 'ROOT', Path(directory)), \
                patch.object(ci_lab, 'select_plan', return_value=plan), \
                patch('lab_migrations.load_migrations', return_value=dict(schema_version=1, migrations=[])), \
                patch('lab_features.load_features', return_value=self.registry):
            result = ci_lab.plan(query)
            saved = json.loads((Path(directory) / 'artifacts/ci/matrix.json').read_text())
            self.assertEqual(saved, result)
            self.assertEqual(saved['include'][0]['features'], ['generated-columns'])
            plan['inventory'] = self.rows[:1]
            query.reset_mock()
            with self.assertRaisesRegex(ValueError, 'absent from catalog'):
                ci_lab.plan(query)
            query.assert_not_called()

    def test_repository_registry_has_documented_owners_for_first_migrations(self):
        definitions, owners = feature_index(load_features())
        for case in ('ddl-compat-generated', 'bootstrap-matrix-generated'):
            self.assertEqual(owners[('correctness', case)], 'generated-columns')
        for case in ('ddl-compat-fulltext', 'bootstrap-matrix-fulltext'):
            self.assertEqual(owners[('correctness', case)], 'full-text-search')
        for case in ('ddl-compat-constraints', 'bootstrap-matrix-values',
                     'ddl-compat-primary-key-row-matching', 'bootstrap-matrix-composite',
                     'bootstrap-matrix-textkey', 'ddl-compat-key-conflicts',
                     'bootstrap-matrix-upsert', 'bootstrap-matrix-replace', 'bootstrap-matrix-ignore'):
            self.assertEqual(owners[('correctness', case)], 'indexes')
        self.assertEqual(definitions['runtime-control']['kind'], 'project')


if __name__ == '__main__':
    unittest.main()
