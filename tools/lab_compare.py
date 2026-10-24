#!/usr/bin/env python3
"""Compare local lab selections using results, named assertions, SQL and coverage."""
import argparse
from collections import Counter
import json
import hashlib
from pathlib import Path
import subprocess
import sys
import time

from ci_measurements import line_sets
from lab_sql_report import summarize as sql_summary

ROOT = Path(__file__).resolve().parents[1]


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def server_image_identity(snapshot):
    """Keep image contents and configuration; omit generated Compose labels."""
    config = dict(snapshot['Config'])
    config['Labels'] = {k: v for k, v in (config.get('Labels') or {}).items()
                        if not k.startswith('com.docker.compose.')}
    content = dict(rootfs=snapshot['RootFS'], architecture=snapshot['Architecture'],
                   os=snapshot['Os'], config=config)
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def capture_server_images(result):
    document = json.loads(result.read_text())
    images = {}
    for fixture in {row['evidence'] for row in document['scenarios'] if row['status'] == 'passed'}:
        runtime = json.loads((Path(fixture) / 'runtime.json').read_text())
        for server in runtime['servers']:
            identifier = server['image']
            if identifier not in images:
                process = subprocess.run(['docker', 'image', 'inspect', identifier],
                                         check=True, capture_output=True, text=True)
                snapshot = json.loads(process.stdout)[0]
                if snapshot['Id'] != identifier:
                    raise ValueError('server image inspection returned a different image')
                # Exclude registry tags, creation time and cache bookkeeping.
                images[identifier] = {k: snapshot[k] for k in ('Id', 'RootFS', 'Architecture', 'Os', 'Config')}
    return images


def record(command, output, root=ROOT):
    """Record one invocation after the lab and applier image builds."""
    if '--skip-build' not in command:
        raise ValueError('record requires --skip-build; prepare the matching image first')
    if output.exists():
        raise ValueError('measurement already exists: ' + str(output))
    before = set((root / 'artifacts/lab').glob('*/result.json'))
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    exit_code = None
    try:
        process = subprocess.run(command, cwd=root, stdout=sys.stderr)
        exit_code = process.returncode
    finally:
        elapsed = time.monotonic() - started
        results = sorted(set((root / 'artifacts/lab').glob('*/result.json')) - before)
        measurement = dict(schema_version=1, kind='local-lab-measurement', command=command,
                           seconds=elapsed, exit_code=exit_code, results=[str(p.resolve()) for p in results])
        write(output, measurement)
    if process.returncode or len(results) != 1:
        raise ValueError(f'lab command returned {process.returncode}; expected one result, found {len(results)}; see {output}')
    try:
        measurement['server_images'] = capture_server_images(results[0])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        measurement['image_capture_error'] = str(error)
        write(output, measurement)
        raise ValueError('server image recording failed; see ' + str(output)) from error
    write(output, measurement)
    return measurement


def identity(row, transport):
    return (row['profile'], row.get('variant', 'default'), row['suite'], transport, row['id'])


def collect(paths):
    cases, assertions, case_seconds = Counter(), Counter(), 0.0
    fixtures, seen_results, conditions, traces = set(), set(), {}, {}
    fixture_owners = {}
    inputs, images, modes, coverage, sources, reports = set(), set(), set(), [], None, []
    elapsed = 0.0
    for path in paths:
        document = json.loads(path.read_text())
        image_snapshots = {}
        if document.get('kind') == 'local-lab-measurement':
            if document.get('schema_version') != 1 or document['exit_code'] != 0 or len(document['results']) != 1:
                raise ValueError('failed or ambiguous measurement: ' + str(path))
            if document.get('image_capture_error'):
                raise ValueError('server image recording failed: ' + str(path))
            image_snapshots = document.get('server_images', {})
            if document['seconds'] < 0:
                raise ValueError('negative elapsed time')
            if elapsed is not None:
                elapsed += document['seconds']
            path = Path(document['results'][0])
            document = json.loads(path.read_text())
        else:
            elapsed = None  # Older results do not record complete invocation time.
        if path.resolve() in seen_results:
            raise ValueError('repeated result: ' + str(path))
        seen_results.add(path.resolve())
        if document.get('schema_version') != 1 or document.get('result') != 'passed':
            raise ValueError('comparison requires passed lab results: ' + str(path))
        inputs.add(document['build_inputs_digest'])
        images.add(document['image'])
        modes.add(document['code_coverage'])
        transport = document['dml_transport']
        reports.append(str(path.resolve()))
        for row in document['scenarios']:
            if row['status'] == 'not_applicable':
                continue
            if row['status'] != 'passed':
                raise ValueError('non-passing selected case: ' + row['id'])
            case = identity(row, transport)
            cases[case] += 1
            case_seconds += row.get('seconds', 0)
            fixture = Path(row['evidence']).resolve()
            context = case[:4]
            owner = fixture_owners.setdefault(fixture, path.resolve())
            if owner != path.resolve():
                raise ValueError('fixture reused by different result files: ' + str(fixture))
            if (fixture, context) in fixtures:
                continue
            fixtures.add((fixture, context))
            runtime = json.loads((fixture / 'runtime.json').read_text())
            if (runtime['profile'] != context[0] or runtime['variant']['id'] != context[1]
                    or runtime['runtime_image'] != document['image']
                    or runtime['code_coverage'] != document['code_coverage']):
                raise ValueError('fixture provenance differs from result')
            # Compose puts its unique project name in image labels. Compare saved
            # filesystem layers/configuration when available, otherwise exact IDs.
            servers = []
            for server in runtime['servers']:
                server = dict(server)
                snapshot = image_snapshots.get(server['image'])
                if snapshot is not None:
                    if snapshot['Id'] != server['image']:
                        raise ValueError('server image snapshot ID differs from runtime')
                    server['image'] = 'content:' + server_image_identity(snapshot)
                servers.append(server)
            setting = json.dumps(dict(servers=sorted(servers, key=lambda r: r['role']),
                                      variant=runtime['variant'], binary_sha256=runtime['binary_sha256']), sort_keys=True)
            if context in conditions and conditions[context] != setting:
                raise ValueError('runtime settings differ within selection: ' + str(context))
            conditions[context] = setting
            trace = fixture / 'sql-trace.jsonl'
            if not trace.is_file():
                raise ValueError('missing SQL trace: ' + str(trace))
            traces[trace] = context
            for item in json.loads((fixture / 'cases.json').read_text()):
                if item['status'] != 'passed':
                    raise ValueError('non-passing case assertion record: ' + item['id'])
                # Case IDs also include child checks with no separate assertion IDs.
                assertions[context + (item['id'], '(case)')] += 1
                for assertion in item.get('assertions', []):
                    if assertion['status'] != 'passed':
                        raise ValueError('non-passing named assertion: ' + assertion['id'])
                    assertions[context + (item['id'], assertion['id'])] += 1
            if document['code_coverage']:
                report = json.loads((fixture / 'code-coverage/combined/coverage.json').read_text())
                if report.get('version') != 1 or (sources is not None and sources != report['sources']):
                    raise ValueError('coverage source mappings differ')
                sources = report['sources']
                coverage.append(report)
    if not cases or any(len(values) != 1 for values in (inputs, images, modes)):
        raise ValueError('empty selection or mixed build inputs, images or coverage modes')
    sql = sql_summary(traces)
    for group in sql['groups']:
        context = traces[Path(group['trace'])]
        if ((group['profile'], group['variant'], group['dml_transport']) != (context[0], context[1], context[3])
                or group['code_coverage'] != next(iter(modes))):
            raise ValueError('SQL trace provenance differs from result')
    if sql['unfinished_calls']:
        raise ValueError('unfinished SQL calls in comparison')
    by_scope = {}
    for name, test in [('outside_cases', lambda g: g['case_id'] is None), ('inside_cases', lambda g: g['case_id'] is not None)]:
        groups = [g for g in sql['groups'] if test(g)]
        by_scope[name] = dict(calls=sum(g['calls'] for g in groups), seconds=sum(g['seconds'] for g in groups),
                              batch_queries=sum(g['batch_queries'] for g in groups))
    mapped, hit = line_sets(coverage)
    summary = dict(results=reports, build_inputs_digest=next(iter(inputs)), image=next(iter(images)),
                   code_coverage=next(iter(modes)), elapsed_seconds=elapsed, case_seconds=case_seconds,
                   fixtures=len(fixtures), unique_cases=len(cases), case_executions=sum(cases.values()),
                   unique_assertions=len(assertions), assertion_executions=sum(assertions.values()),
                   sql_calls=sql['calls'], sql_seconds=sum(g['seconds'] for g in sql['groups']), sql=by_scope,
                   mapped_lines=len(mapped) if coverage else None, hit_lines=len(hit) if coverage else None)
    return dict(summary=summary, cases=cases, assertions=assertions, conditions=conditions,
                mapped=mapped, hit=hit, sources=sources, sql=sql)


def compare(baseline, candidate):
    left, right = collect(baseline), collect(candidate)
    for field in ('build_inputs_digest', 'image', 'code_coverage'):
        if left['summary'][field] != right['summary'][field]:
            raise ValueError('cannot compare different ' + field)
    if left['conditions'] != right['conditions']:
        raise ValueError('runtime profiles, variants or server settings differ')
    if left['sources'] != right['sources'] or left['mapped'] != right['mapped']:
        raise ValueError('coverage source mappings differ')
    def difference(field):
        return dict(missing=[list(k) for k in sorted(set(left[field]) - set(right[field]))],
                    added=[list(k) for k in sorted(set(right[field]) - set(left[field]))])
    cases, assertions = difference('cases'), difference('assertions')
    coverage = dict(measured=left['summary']['code_coverage'],
                    lost=[list(k) for k in sorted(left['hit'] - right['hit'])],
                    gained=[list(k) for k in sorted(right['hit'] - left['hit'])])
    return dict(schema_version=1, baseline=left['summary'], candidate=right['summary'],
                cases=cases, assertions=assertions, coverage=coverage,
                same_case_and_assertion_sets=not any([cases['missing'], cases['added'], assertions['missing'], assertions['added']]),
                sql_by_case=dict(baseline=left['sql']['groups'], candidate=right['sql']['groups']))


def markdown(report):
    left, right = report['baseline'], report['candidate']
    text = ['# Local test comparison', '',
            'Elapsed time excludes lab and applier image builds. It includes MySQL fixture setup, cached Compose builds, tests, cleanup and any coverage export.', '',
            '| Measurement | Separate/baseline runs | Combined/candidate runs |', '|---|---:|---:|']
    for field in ('elapsed_seconds', 'fixtures', 'unique_cases', 'case_executions', 'unique_assertions',
                  'assertion_executions', 'sql_calls', 'sql_seconds', 'mapped_lines', 'hit_lines'):
        def value(v):
            return 'unmeasured' if v is None else (f'{v:.2f}' if isinstance(v, float) else str(v))
        text.append(f'| {field} | {value(left[field])} | {value(right[field])} |')
    text += ['', f"Same case and named assertion sets: {report['same_case_and_assertion_sets']}.",
             f"Missing cases: {len(report['cases']['missing'])}; missing assertions: {len(report['assertions']['missing'])}."]
    if report['coverage']['measured']:
        text.append(f"Runtime lines lost: {len(report['coverage']['lost'])}; gained: {len(report['coverage']['gained'])}.")
    text += ['', 'Equal names and line sets do not prove equivalent behavior. Review SQL, expected results, '
             'isolation and restart boundaries before changing the suite. SQL times include Docker/client startup. '
             'Named assertion counts include case records. This report contains no SQL text or row values. '
             'Instrumented times measure test cost; they are not applier performance results.']
    return '\n'.join(text) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    run = commands.add_parser('record', help='time one lab test with an already-built image')
    run.add_argument('--output', required=True, type=Path)
    run.add_argument('command', nargs=argparse.REMAINDER)
    diff = commands.add_parser('compare', help='compare explicit measurements or top-level lab result.json files')
    diff.add_argument('--baseline', nargs='+', required=True, type=Path)
    diff.add_argument('--candidate', nargs='+', required=True, type=Path)
    diff.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'record':
            command = args.command[1:] if args.command[:1] == ['--'] else args.command
            print(json.dumps(record(command, args.output), indent=2))
        else:
            report = compare(args.baseline, args.candidate)
            write(args.output / 'comparison.json', report)
            (args.output / 'comparison.md').write_text(markdown(report))
            print(markdown(report))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Local comparison failed: {error}\n')


if __name__ == '__main__':
    main()
