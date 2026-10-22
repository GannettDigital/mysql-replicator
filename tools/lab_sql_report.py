#!/usr/bin/env python3
"""Summarize harness SQL calls. SQL text stays in the input trace files."""
import argparse
from collections import Counter
import json
from pathlib import Path


def summarize(paths):
    files = sorted({file for path in paths for file in
                    (path.rglob("sql-trace.jsonl") if path.is_dir() else [path])})
    if not files:
        raise ValueError("No sql-trace.jsonl files found")
    groups = {}
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
                    })
                    group["calls"] += 1
                    group["batch_queries"] += len(record["queries"])
                    group["kinds"][record["kind"]] += 1
                    if record.get("assertion_id"):
                        group["assertions"][record["assertion_id"]] += 1
                    pending[call] = group
                elif record["event"] == "finish":
                    if call not in pending:
                        raise ValueError(f"{file}:{number}: finish without start: {call}")
                    group = pending.pop(call)
                    group["outcomes"][record["outcome"]] += 1
                    group["seconds"] += record["seconds"]
                else:
                    raise ValueError(f"{file}:{number}: unknown trace event")
        for group in pending.values():
            group["outcomes"]["unfinished"] += 1
    values = list(groups.values())
    return {
        "schema_version": 1, "trace_files": len(files),
        "calls": sum(g["calls"] for g in values),
        "unfinished_calls": sum(g["outcomes"]["unfinished"] for g in values),
        "groups": values,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path, help="Trace files or artifact directories")
    args = parser.parse_args()
    try:
        report = summarize(args.paths)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"SQL trace report failed: {error}\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
