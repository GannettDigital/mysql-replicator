"""Check retired cases against replacement assertions and original test scopes."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_migrations():
    return json.loads((ROOT / 'tools/test_case_migrations.json').read_text())


def entries(document):
    if not isinstance(document, dict) or type(document.get('schema_version')) is not int \
            or document['schema_version'] != 1 or not isinstance(document.get('migrations'), list):
        raise ValueError('invalid case migration document')
    seen = set()
    for item in document['migrations']:
        if not isinstance(item, dict):
            raise ValueError('invalid case migration')
        for field in ('suite', 'retired', 'replacement', 'review'):
            if not isinstance(item.get(field), str) or not item[field].strip():
                raise ValueError(f'missing migration {field}')
        key = (item['suite'], item['retired'])
        if key in seen or item['retired'] == item['replacement']:
            raise ValueError('duplicate or self-referencing case migration')
        seen.add(key)
        conditions = item.get('conditions')
        if not isinstance(conditions, list) or not conditions:
            raise ValueError('migration needs retained conditions')
        assertions = set()
        for condition in conditions:
            if not isinstance(condition, dict) or any(not isinstance(condition.get(k), str)
                    or not condition[k].strip() for k in ('condition', 'assertion')):
                raise ValueError('migration needs a condition and replacement assertion')
            assertions.add(condition['assertion'])
        scopes = item.get('scopes')
        if not isinstance(scopes, list) or not scopes:
            raise ValueError('migration needs original scopes')
        scope_keys = set()
        for scope in scopes:
            if not isinstance(scope, dict) or any(not isinstance(scope.get(k), str)
                    or not scope[k] for k in ('profile', 'variant', 'transport')):
                raise ValueError('invalid migration scope')
            value = (scope['profile'], scope['variant'], scope['transport'])
            if value in scope_keys:
                raise ValueError('duplicate migration scope')
            scope_keys.add(value)
        yield item, assertions


def retired_hint(identifiers, document=None):
    hints = [f"{item['retired']} was replaced by {item['replacement']}"
             for item, _ in entries(load_migrations() if document is None else document)
             if item['retired'] in identifiers]
    return '; '.join(hints)


def validate_migrations(catalogs, document=None, *, complete=False, groups=None, selection_only=False):
    rows = {(r['profile'], r.get('variant', 'default'), r['suite'], r['id']): r
            for c in catalogs for r in c['scenarios']}
    scopes = {k[:3] for k in rows}
    planned = None if groups is None else {
        (g['profile'], g.get('variant', 'default'), g['suite'], g.get('dml_transport', 'sql'), case)
        for g in groups for case in g['cases']}
    migrations = list(entries(load_migrations() if document is None else document))
    declarations = {(item['suite'], item['retired'], item['replacement']) for item, _ in migrations}
    for key, row in rows.items():
        for old in row.get('replaces', []):
            if (row['suite'], old, row['id']) not in declarations:
                raise ValueError(f'case replacement has no migration: {old}')
    for item, required in migrations:
        if any(k[2:] == (item['suite'], item['retired']) for k in rows):
            raise ValueError(f"retired case is still in catalog: {item['retired']}")
        for scope in item['scopes']:
            context = (scope['profile'], scope['variant'], item['suite'])
            if not complete and context not in scopes:
                continue
            key = (*context, item['replacement'])
            if selection_only and not complete and key not in rows:
                continue
            replacement = rows.get(key)
            if replacement is None or replacement['status'] != 'not_run':
                raise ValueError(f'missing applicable replacement: {key}')
            if item['retired'] not in replacement.get('replaces', []):
                raise ValueError(f'missing replacement declaration: {key}')
            if not required <= set(replacement.get('assertions', [])):
                raise ValueError(f'missing replacement assertions: {key}')
            if complete and planned is not None and (*context, scope['transport'], item['replacement']) not in planned:
                raise ValueError(f'missing replacement execution: {key}/{scope["transport"]}')


def validate_results(cases, item):
    """Validate one fixture's case records, including each required assertion."""
    records = [case for case in cases if case['id'] == item['replacement']]
    if len(records) != 1 or records[0]['status'] != 'passed':
        raise ValueError('replacement case did not pass exactly once')
    required = {condition['assertion'] for condition in item['conditions']}
    assertions = records[0].get('assertions', [])
    for identifier in required:
        matches = [a for a in assertions if a['id'] == identifier]
        if len(matches) != 1 or matches[0]['status'] != 'passed' or not matches[0].get('evidence'):
            raise ValueError(f'missing passing replacement assertion: {identifier}')
