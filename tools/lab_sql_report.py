#!/usr/bin/env python3
"""Summarize harness SQL calls. SQL text stays in the input trace files."""
import argparse
from collections import Counter
import json
import hashlib
from pathlib import Path
import re


def category(record):
    """Conservative call classification, not a SQL parser or a redundancy test."""
    if record.get('case_id') is None:
        return 'outside_case'
    names = {q['name'] for q in record.get('queries', [])}
    if {'database', 'tables', 'columns', 'foreignKeys'} <= names:
        return 'schema_comparison'
    sql = record.get('sql', '').strip()
    # Recognize only the fixed session prefix used by comparison helpers.
    sql = re.sub(r'(?is)^SET NAMES (utf8mb4|binary);\s*', '', sql).rstrip(';').strip()
    if ';' in sql:
        return 'mixed_or_unclassified'
    if re.match(r'(?is)^(SHOW (MASTER|BINARY LOG|SLAVE|REPLICA) STATUS\b|SELECT (GTID_SUBSET|GTID_SUBTRACT)\s*\()', sql):
        return 'position_or_wait'
    if re.match(r'(?is)^SELECT\b', sql) and 'information_schema.' in sql.lower():
        return 'metadata_read'
    if re.match(r'(?is)^(SELECT|SHOW)\b', sql):
        return 'result_or_status_read'
    if record['role'] == 'source' and re.match(r'(?is)^(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|RENAME|TRUNCATE|LOAD)\b', sql):
        return 'source_statement'
    # Session prefixes and multi-statement calls can mix setup and workload SQL.
    return 'mixed_or_unclassified'


def fingerprint(record):
    # Batch framing contains a random token. Compare the actual ordered queries.
    # Preserve every other byte, including literals, case, and identifiers.
    value = ([q['sql'] for q in record['queries']] if record.get('queries')
             else record.get('sql', ''))
    return hashlib.sha256(json.dumps(value, ensure_ascii=False).encode()).hexdigest()


def summarize(paths):
    files = sorted({file for path in paths for file in
                    (path.rglob("sql-trace.jsonl") if path.is_dir() else [path])
                    if not path.is_dir() or 'evidence' not in file.relative_to(path).parts})
    if not files:
        raise ValueError("No sql-trace.jsonl files found")
    groups, repeated = {}, {}
    for file in files:
        pending, seen = {}, set()
        with file.open() as stream:
            for number, line in enumerate(stream, 1):
                record = json.loads(line)
                if record.get("schema_version") != 1:
                    raise ValueError(f"{file}:{number}: unsupported SQL trace schema")
                call = record["call_id"]
                if record["event"] == "start":
                    if call in seen:
                        raise ValueError(f"{file}:{number}: duplicate start: {call}")
                    seen.add(call)
                    key = (str(file), record.get("case_id"), record["role"])
                    group = groups.setdefault(key, {
                        "trace": str(file), "profile": record.get("profile"),
                        "variant": record.get("variant"), "dml_transport": record.get("dml_transport"),
                        "code_coverage": record.get("code_coverage"),
                        "case_id": record.get("case_id"), "role": record["role"],
                        "calls": 0, "seconds": 0.0, "batch_queries": 0,
                        "kinds": Counter(), "outcomes": Counter(), "assertions": Counter(),
                        "categories": {},
                    })
                    group["calls"] += 1
                    group["batch_queries"] += len(record["queries"])
                    group["kinds"][record["kind"]] += 1
                    if record.get("assertion_id"):
                        group["assertions"][record["assertion_id"]] += 1
                    cost = group['categories'].setdefault(category(record), dict(calls=0, seconds=0.0))
                    cost['calls'] += 1
                    signature = fingerprint(record)
                    duplicate = repeated.setdefault((str(file), record['role'], signature), dict(
                        trace=str(file), role=record['role'], fingerprint=signature,
                        calls=0, seconds=0.0, cases=Counter()))
                    duplicate['calls'] += 1
                    duplicate['cases'][record.get('case_id') or '(outside-case)'] += 1
                    pending[call] = (group, cost, duplicate)
                elif record["event"] == "finish":
                    if call not in pending:
                        raise ValueError(f"{file}:{number}: finish without start: {call}")
                    group, cost, duplicate = pending.pop(call)
                    group["outcomes"][record["outcome"]] += 1
                    group["seconds"] += record["seconds"]
                    cost['seconds'] += record['seconds']
                    duplicate['seconds'] += record['seconds']
                else:
                    raise ValueError(f"{file}:{number}: unknown trace event")
        for group, _, _ in pending.values():
            group["outcomes"]["unfinished"] += 1
    values = list(groups.values())
    return {
        "schema_version": 1, "trace_files": len(files),
        "calls": sum(g["calls"] for g in values),
        "unfinished_calls": sum(g["outcomes"]["unfinished"] for g in values),
        "groups": values,
        "repeated_calls": sorted((r for r in repeated.values() if r['calls'] > 1),
                                 key=lambda r: (-r['seconds'], r['trace'], r['fingerprint'])),
    }


def markdown(report):
    cases = {}
    for group in report['groups']:
        key = (group['trace'], group['case_id'] or '(outside-case)')
        row = cases.setdefault(key, dict(calls=0, seconds=0.0, categories=Counter()))
        row['calls'] += group['calls']
        row['seconds'] += group['seconds']
        for name, cost in group['categories'].items():
            row['categories'][name] += cost['seconds']
    lines = ['# Harness SQL cost by case', '',
             'Times include client startup. They do not measure applier SQL time. '
             'Categories are conservative hints. Mixed calls remain unclassified. '
             'Coverage belongs to complete fixtures, not these individual cases.', '',
             '| Trace / case | Calls | Client seconds | Largest category (seconds) |',
             '|---|---:|---:|---|']
    for (trace, case), row in sorted(cases.items(), key=lambda item: -item[1]['seconds']):
        name, seconds = row['categories'].most_common(1)[0]
        lines.append(f"| {trace} / {case} | {row['calls']} | {row['seconds']:.2f} | {name} ({seconds:.2f}) |")
    lines += ['', 'The JSON report lists exact repeated-call fingerprints, roles, cases and cost. '
              'Only batch framing is omitted from the fingerprint. SQL values and identifiers remain '
              'significant. Repeated SQL can be a required wait or assertion; it is not proof of redundancy.']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path, help="Trace files or artifact directories")
    parser.add_argument('--output', type=Path, help='Write report.json and report.md in this directory')
    args = parser.parse_args()
    try:
        report = summarize(args.paths)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"SQL trace report failed: {error}\n")
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / 'report.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
        (args.output / 'report.md').write_text(markdown(report))
    else:
        print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
