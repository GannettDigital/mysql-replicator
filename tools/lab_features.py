"""Validate feature ownership and add it to plans without changing selection."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def load_features():
    return json.loads((ROOT / 'tools/test_features.json').read_text())


def feature_index(registry):
    from lab_selection import SUITES

    if not isinstance(registry, dict) or type(registry.get('schema_version')) is not int \
            or registry['schema_version'] != 1:
        raise ValueError('unsupported feature schema version')
    features = registry.get('features')
    if not isinstance(features, list) or not features:
        raise ValueError('features must be a nonempty list')
    definitions, owners = {}, {}
    for feature in features:
        if not isinstance(feature, dict):
            raise ValueError('invalid feature definition')
        identifier = feature.get('id')
        if not isinstance(identifier, str) or not re.fullmatch(r'[a-z][a-z0-9]*(?:-[a-z0-9]+)*', identifier):
            raise ValueError('invalid feature ID')
        if identifier in definitions:
            raise ValueError(f'duplicate feature ID: {identifier}')
        for field in ('title', 'description'):
            if not isinstance(feature.get(field), str) or not feature[field].strip():
                raise ValueError(f'missing feature {field}: {identifier}')
        reference = feature.get('reference')
        if not isinstance(reference, dict) or not isinstance(reference.get('title'), str) \
                or not reference['title'].strip() or not isinstance(reference.get('location'), str):
            raise ValueError(f'missing feature reference: {identifier}')
        location = reference['location']
        if feature.get('kind') == 'mysql':
            version = reference.get('version')
            if version not in ('5.7', '8.4') or not re.fullmatch(
                    rf'https://dev\.mysql\.com/doc/refman/{re.escape(version)}/en/[a-z0-9-]+\.html(?:#[a-z0-9-]+)?',
                    location):
                raise ValueError(f'invalid MySQL manual reference: {identifier}')
        elif feature.get('kind') == 'project':
            path = Path(location.split('#', 1)[0])
            if path.is_absolute() or '..' in path.parts or not location.startswith('docs/') \
                    or path.suffix != '.md' or not (ROOT / path).is_file():
                raise ValueError(f'invalid project documentation reference: {identifier}')
        else:
            raise ValueError(f'invalid feature kind: {identifier}')
        cases = feature.get('cases')
        if not isinstance(cases, dict) or not cases:
            raise ValueError(f'feature has no cases: {identifier}')
        for suite, identifiers in cases.items():
            if suite not in SUITES or not isinstance(identifiers, list) or not identifiers:
                raise ValueError(f'invalid feature case list: {identifier}/{suite}')
            for case in identifiers:
                if not isinstance(case, str) or not case.strip():
                    raise ValueError(f'invalid case ID: {identifier}/{suite}')
                key = (suite, case)
                if key in owners:
                    raise ValueError(f'duplicate feature assignment: {suite}/{case}')
                owners[key] = identifier
        definitions[identifier] = {key: value for key, value in feature.items() if key != 'cases'}
    return definitions, owners


def describe_features(catalogs, registry, *, complete=False):
    """Check excluded cases too. A partial catalog cannot detect stale assignments."""
    definitions, owners = feature_index(registry)
    seen = {(row['suite'], row['id']) for catalog in catalogs for row in catalog['scenarios']}
    if not seen:
        raise ValueError('empty feature catalog')
    missing = seen - owners.keys()
    if missing:
        raise ValueError(f'cases without a feature: {sorted(missing)}')
    if complete and owners.keys() - seen:
        raise ValueError(f'feature assignments absent from catalog: {sorted(owners.keys() - seen)}')
    selected = {owners[key] for key in seen}
    return dict(scope='queried_catalog',
                definitions=[definitions[key] for key in sorted(selected)],
                cases=[dict(suite=suite, id=case, feature=owners[(suite, case)])
                       for suite, case in sorted(seen)])


def with_features(plan, catalogs, registry=None, *, complete=False):
    """Return an annotated copy. Leave order, commands and applicability intact."""
    description = describe_features(catalogs, load_features() if registry is None else registry,
                                    complete=complete)
    owners = {(case['suite'], case['id']): case['feature'] for case in description['cases']}
    result = dict(plan, feature_catalog=description)
    for field in ('groups', 'include'):
        if field in plan:
            result[field] = []
            for group in plan[field]:
                keys = [(group['suite'], case) for case in group['cases']]
                missing = set(keys) - owners.keys()
                if missing:
                    raise ValueError(f'planned cases absent from feature catalog: {sorted(missing)}')
                result[field].append(dict(group, features=sorted({owners[key] for key in keys})))
    return result
