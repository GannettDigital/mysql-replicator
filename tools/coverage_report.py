#!/usr/bin/env python3
"""Publish scoped Swift reports from explicit, source-validated collections."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import sys

from code_coverage import combine, load_reports, render, source_hashes

SCOPES = {
    "runtime": "Swift runtime — unit + selected integration",
    "runtime-unit": "Swift runtime — unit only",
    "runtime-integration": "Swift runtime — selected integration only",
    "harness": "Swift test harness — unit only",
}


def lab(path):
    return path.startswith("Sources/ReplicatorLab")


def select(report, harness):
    files = {p: lines for p, lines in report["files"].items() if lab(p) == harness}
    return dict(report, files=files, covered_by={p: report["covered_by"].get(p, {}) for p in files})


def counts(report):
    lines = [n for lines in report["files"].values() for n in lines.values()]
    return {"covered": sum(n > 0 for n in lines), "total": len(lines)}


def percentage(count):
    return f'{100 * count["covered"] / count["total"]:.2f}%' if count["total"] else "unavailable"


def badge(count, complete):
    value = percentage(count) if complete else "partial"
    label = "Swift runtime coverage"
    color = "#007ec6" if complete else "#9f9f9f"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="224" height="20" role="img" '
            f'aria-label="{label}: {value}"><title>{label}: {value}</title>'
            '<rect width="160" height="20" fill="#555"/>'
            f'<rect x="160" width="64" height="20" fill="{color}"/>'
            '<g fill="#fff" text-anchor="middle" font-family="Verdana,sans-serif" font-size="11">'
            f'<text x="80" y="14">{label}</text><text x="192" y="14">{value}</text></g></svg>\n')


def policy_hash(root):
    # Baseline deltas require identical test/toolchain/reporting inputs. Runtime
    # changes are intentionally excluded; tests and their selection are not.
    paths = [root / ".github/workflows/ci.yml", root / "Package.swift", root / "Package.resolved"]
    for directory in ["tests", "tools", "docker/coverage", "Sources/ReplicatorLab", "Sources/ReplicatorLabCore"]:
        paths.extend(p for p in (root / directory).rglob("*")
                     if p.is_file() and "__pycache__" not in p.parts)
    digest = hashlib.sha256()
    for path in sorted(set(paths)):
        if path.exists():
            digest.update(path.relative_to(root).as_posix().encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def write_reports(root, output, inputs, unit_result="unknown", integration_result="unknown",
                  expected_integration=None, metadata=None):
    reports = load_reports(root, inputs)
    unit, integration = [], []
    for report in reports:
        if "unit" in report["inputs"]:
            if report["inputs"] != ["unit"]:
                raise ValueError("use original unit and integration collections, not an already mixed report")
            unit.append(report)
        else:
            integration.append(report)
    complete = (unit_result == integration_result == "success" and len(unit) == 1 and bool(integration)
                and (expected_integration is None or len(integration) == expected_integration))
    sources = source_hashes(root)
    scoped = {
        "runtime": [select(r, False) for r in reports],
        "runtime-unit": [select(r, False) for r in unit],
        "runtime-integration": [select(r, False) for r in integration],
        "harness": [select(r, True) for r in unit],
    }
    metrics = {"version": 1, "complete": complete, "policy": policy_hash(root),
               "unit_result": unit_result, "integration_result": integration_result,
               "integration_reports": len(integration), "scopes": {}, **(metadata or {})}
    output.mkdir(parents=True, exist_ok=True)
    rows, links = [], []
    for name, selections in scoped.items():
        report = combine(selections, sources, SCOPES[name])
        render(report, root, output / name)
        metrics["scopes"][name] = counts(report)
        count = metrics["scopes"][name]
        rows.append(f'| {SCOPES[name]} | {count["covered"]}/{count["total"]} | {percentage(count)} |')
        links.append(f'<li><a href="{name}/index.html">{html.escape(SCOPES[name])}</a>: '
                     f'{count["covered"]}/{count["total"]} ({percentage(count)})</li>')
    # Missing mappings cannot be advertised as a complete measurement.
    metrics["complete"] = complete = complete and all(c["total"] > 0 for c in metrics["scopes"].values())
    status = "Complete selected suites" if complete else "PARTIAL / unverified suite completion"
    note = ("First-party Swift line coverage only; excludes Rust and dependencies. "
            "Harness coverage uses unit tests only. Runtime combined coverage is a union, not a sum. "
            "Each view uses its own mapped executable lines; unmapped code is not measured. "
            "The CI integration selection is smoke coverage, not full qualification or MySQL catalog coverage.")
    provenance = "\n".join(f'{key}: {metrics[key]}' for key in ["commit", "run_id", "run_attempt"] if metrics.get(key))
    summary = (f'{status}\n\n| Scope | Covered / mapped lines | Coverage |\n|---|---:|---:|\n'
               + '\n'.join(rows) + '\n\n' + note + '\n\n' + provenance + '\n')
    (output / "summary.md").write_text(summary)
    (output / "metrics.json").write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n")
    (output / "runtime.svg").write_text(badge(metrics["scopes"]["runtime"], complete))
    (output / "index.html").write_text('<!doctype html><meta charset="utf-8"><title>Swift coverage</title>'
                                       f'<h1>{status}</h1><ul>{"".join(links)}</ul><p>{html.escape(note)}</p>'
                                       f'<pre>{html.escape(provenance)}</pre>')
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=Path("artifacts/coverage/combined"))
    parser.add_argument("--unit-result", default="unknown")
    parser.add_argument("--integration-result", default="unknown")
    parser.add_argument("--expected-integration", type=int)
    parser.add_argument("--ci", action="store_true")
    parser.add_argument("inputs", type=Path, nargs="+")
    args = parser.parse_args()
    metadata = {}
    if args.ci:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        pr = event.get("pull_request", {})
        metadata = dict(commit=os.environ["GITHUB_SHA"], head_sha=pr.get("head", {}).get("sha", os.environ["GITHUB_SHA"]),
                        base_sha=pr.get("base", {}).get("sha"), run_id=os.environ["GITHUB_RUN_ID"],
                        run_attempt=os.environ["GITHUB_RUN_ATTEMPT"])
    write_reports(args.root.resolve(), args.output, args.inputs, args.unit_result,
                  args.integration_result, args.expected_integration, metadata)
    if args.ci:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write((args.output / "summary.md").read_text())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit(f"coverage report: {error}")
