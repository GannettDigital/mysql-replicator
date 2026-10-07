#!/usr/bin/env python3
"""Compare runtime line sets from explicitly selected, successful lab runs.

This is an integration-test migration report, not a MySQL feature qualification
gate. Keep unit coverage separate: unit hits must not conceal lost integration
coverage. All inputs must use one runtime image and unchanged runtime sources.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from code_coverage import source_hashes


def runtime(path):
    return path.startswith("Sources/") and not path.startswith("Sources/ReplicatorLab") and path.endswith(".swift")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def line_map(points):
    files = {}
    for path, line in sorted(points, key=lambda item: (item[0], item[1])):
        files.setdefault(path, []).append(line)
    return files


def load_group(root, entries, sources, seen):
    if not entries:
        raise ValueError("empty coverage group")
    hits, mapped, origins, evidence, images = set(), set(), {}, [], set()
    for entry in entries:
        report_path = (root / entry["coverage"]).resolve()
        result_path = (root / entry["result"]).resolve()
        if report_path in seen:
            raise ValueError(f"duplicate coverage report: {report_path}")
        seen.add(report_path)
        report = json.loads(report_path.read_text())
        result = json.loads(result_path.read_text())
        if result.get("result") != "passed" or result.get("cleanup") != "passed":
            raise ValueError(f"run or cleanup did not pass: {result_path}")
        # Refuse coverage from a different run, even if its source hashes match.
        if not report_path.is_relative_to(result_path.parent):
            raise ValueError(f"coverage is outside its declared run: {report_path}")
        if report.get("version") != 1 or {p: h for p, h in report["sources"].items() if runtime(p)} != sources:
            raise ValueError(f"runtime source mismatch: {report_path}")
        image = result.get("image")
        runtime_path = result_path.with_name("runtime.json")
        if runtime_path.exists():
            metadata = json.loads(runtime_path.read_text())
            if metadata.get("code_coverage") is not True:
                raise ValueError(f"run was not instrumented: {runtime_path}")
            image = metadata["runtime_image"]
        elif result.get("code_coverage") is not True:
            raise ValueError(f"run was not instrumented: {result_path}")
        if not isinstance(image, str) or not image.startswith("sha256:"):
            raise ValueError(f"missing immutable runtime image: {result_path}")
        images.add(image)
        local_hits = set()
        for file, lines in report["files"].items():
            if not runtime(file):
                continue
            if file not in sources:
                raise ValueError(f"unknown runtime file: {file}")
            for number, count in lines.items():
                if not number.isdigit() or int(number) < 1 or type(count) is not int or count < 0:
                    raise ValueError(f"invalid line/count in {report_path}")
                point = (file, int(number))
                mapped.add(point)
                if count:
                    local_hits.add(point)
                    labels = report.get("covered_by", {}).get(file, {}).get(number, report["inputs"])
                    origins.setdefault(point, set()).update(labels)
        if not local_hits:
            raise ValueError(f"no runtime hits: {report_path}")
        hits.update(local_hits)
        status_path = report_path.parent.parent / "profile-status.json"
        statuses = json.loads(status_path.read_text()) if status_path.exists() else []
        if any(s.get("profile") == "missing" for s in statuses):
            raise ValueError(f"missing normally exited invocation profile: {status_path}")
        evidence.append(dict(entry, coverage_sha256=digest(report_path), result_sha256=digest(result_path),
                             image=image, inputs=report["inputs"], profile_status=statuses))
    return dict(hits=hits, mapped=mapped, origins=origins, evidence=evidence, images=images)


def compare(root, manifest, output):
    if manifest.get("schema_version") != 1 or not manifest.get("comparisons"):
        raise ValueError("missing version 1 comparison manifest")
    notes = manifest.get("notes", [])
    if not isinstance(notes, list) or not all(isinstance(note, str) for note in notes):
        raise ValueError("manifest notes must be a list of strings")
    sources = {p: h for p, h in source_hashes(root).items() if runtime(p)}
    groups, seen = {}, set()
    for name, entries in manifest["groups"].items():
        groups[name] = load_group(root, entries, sources, seen)
    images = set().union(*(g["images"] for g in groups.values()))
    if len(images) != 1:
        raise ValueError("comparison requires the same instrumented runtime image")
    report = {"schema_version": 1, "scope": "Swift runtime line coverage; excludes lab, Rust, dependencies and unit tests",
              "runtime_sources": sources, "image": next(iter(images)), "measurement_notes": notes,
              "group_counts": {name: {"mapped": len(g["mapped"]), "hit": len(g["hits"])} for name, g in groups.items()},
              "groups": {name: group["evidence"] for name, group in groups.items()}, "comparisons": []}
    markdown = ["# Integration coverage comparison", "", report["scope"], "",
                "A line hit is not an assertion or MySQL feature qualification. Zero lost lines alone does not authorize removing a suite.", ""]
    for note in notes:
        markdown += [note, ""]
    for name, group in groups.items():
        missing = [s["label"] for e in group["evidence"] for s in e["profile_status"] if s.get("profile") != "present"]
        if missing:
            markdown += [f"`{name}` has {len(missing)} unflushed invocation profiles: " + ", ".join(missing) + ". Crash-path coverage is incomplete.", ""]
    ids = set()
    for selection in manifest["comparisons"]:
        if selection["id"] in ids:
            raise ValueError("duplicate comparison ID")
        ids.add(selection["id"])
        before, after = groups[selection["baseline"]], groups[selection["candidate"]]
        universe = before["mapped"] | after["mapped"]
        lost, added = before["hits"] - after["hits"], after["hits"] - before["hits"]
        def counts(points):
            b, a = before["hits"] & points, after["hits"] & points
            return {"mapped": len(points), "baseline_hit": len(b), "candidate_hit": len(a),
                    "both": len(b & a), "baseline_only": len(b - a), "candidate_only": len(a - b)}
        item = dict(selection, counts=counts(universe), baseline_only=line_map(lost), candidate_only=line_map(added),
                    baseline_only_origins=[{"file": p, "line": n, "inputs": sorted(before["origins"][(p, n)])}
                                           for p, n in sorted(lost)], modules={})
        markdown += ["## " + selection["id"], "", f"Baseline: `{selection['baseline']}`; candidate: `{selection['candidate']}`.", "",
                     "| Module | Mapped | Baseline hit | Candidate hit | Both | Baseline only | Candidate only |",
                     "|---|---:|---:|---:|---:|---:|---:|"]
        for module in sorted({p.split("/")[1] for p, _ in universe}):
            c = counts({point for point in universe if point[0].split("/")[1] == module})
            item["modules"][module] = c
            markdown.append("| " + module + " | " + " | ".join(str(c[k]) for k in c) + " |")
        c = item["counts"]
        markdown += ["| **Total** | " + " | ".join(str(c[k]) for k in c) + " |", "",
                     f"Baseline: {100*c['baseline_hit']/c['mapped']:.2f}%; candidate: {100*c['candidate_hit']/c['mapped']:.2f}% on the same mapped-line denominator.", "",
                     "Exact line lists and producing invocations are in `comparison.json`.", ""]
        report["comparisons"].append(item)
    output.mkdir(parents=True, exist_ok=True)
    (output / "comparison.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    (output / "comparison.md").write_text("\n".join(markdown))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = compare(args.root.resolve(), json.loads(args.manifest.read_text()), args.output)
    for item in report["comparisons"]:
        print(item["id"], json.dumps(item["counts"], sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit(f"coverage comparison: {error}")
