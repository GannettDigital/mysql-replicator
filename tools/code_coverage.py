#!/usr/bin/env python3
"""Swift line coverage: export with the producing LLVM, merge portable reports.

Only first-party Sources/**/*.swift files are included. Raw LLVM profiles never
cross toolchain boundaries. Combined coverage is a union of executable lines;
function/branch identities are deliberately not merged across builds/platforms.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def source_hashes(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((root / "Sources").rglob("*.swift"))}


def llvm_tool(name):
    # Swift's LLVM must read Swift's profiles, not the system LLVM installation.
    if sys.platform == "darwin":
        return subprocess.check_output(["xcrun", "--find", name], text=True).strip()
    path = Path(shutil.which("swift") or "/missing/swift").resolve().parent / name
    if not path.exists():
        raise ValueError(f"missing {name} beside Swift: {path}")
    return str(path)


def parse_lcov(text, root):
    files = {}
    current = None
    for line in text.splitlines():
        if line.startswith("SF:"):
            path = Path(line[3:])
            try:
                relative = path.resolve().relative_to(root.resolve()).as_posix()
            except ValueError:
                current = None
                continue
            current = files.setdefault(relative, {}) if relative.startswith("Sources/") and relative.endswith(".swift") else None
        elif line.startswith("DA:") and current is not None:
            number, count, *_ = line[3:].split(",")
            # Multiple object files may contain the same generic function.
            current[number] = max(current.get(number, 0), int(count))
    return files


def lcov_text(files):
    records = []
    for path, lines in sorted(files.items()):
        records.extend(["TN:", "SF:" + path])
        records.extend(f"DA:{n},{lines[n]}" for n in sorted(lines, key=int))
        records.extend([f"LF:{len(lines)}", f"LH:{sum(n > 0 for n in lines.values())}", "end_of_record"])
    return "\n".join(records) + "\n"


def render(report, root, output):
    output.mkdir(parents=True, exist_ok=True)
    (output / "coverage.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    (output / "coverage.lcov").write_text(lcov_text(report["files"]))
    covered = sum(n > 0 for lines in report["files"].values() for n in lines.values())
    total = sum(len(lines) for lines in report["files"].values())
    percent = f"{100 * covered / total:.2f}%" if total else "unavailable"
    summary = f"{report.get('scope', 'Swift line coverage')}: {covered}/{total} ({percent})"
    modules = {}
    runtime = []
    for path, lines in report["files"].items():
        parts = Path(path).parts
        modules.setdefault(parts[1] if len(parts) > 2 else "Sources", []).extend(lines.values())
        if not path.startswith("Sources/ReplicatorLab"):
            runtime.extend(lines.values())
    if runtime:
        modules["Runtime (excluding lab)"] = runtime
    module_rows, markdown = [], ["| Scope | Covered lines | Coverage |", "|---|---:|---:|"]
    for name, counts in sorted(modules.items()):
        hits, size = sum(n > 0 for n in counts), len(counts)
        percent = f"{100 * hits / size if size else 0:.2f}%"
        markdown.append(f"| {name} | {hits}/{size} | {percent} |")
        module_rows.append(f"<tr><td>{html.escape(name)}</td><td>{hits}/{size}</td><td>{percent}</td></tr>")
    (output / "summary.md").write_text(summary + "\n\n" + "\n".join(markdown) + "\n\nInputs: " + ", ".join(report["inputs"]) + "\n")
    style = "<style>body{font:15px system-ui;margin:2em}td,th{padding:.2em .7em;text-align:left}pre{margin:0;white-space:pre-wrap}.hit{background:#dfeddf}.miss{background:#ffdfdf}a{color:#174d96}</style>"
    rows = []
    for index, (path, lines) in enumerate(sorted(report["files"].items())):
        hits = sum(n > 0 for n in lines.values())
        page = f"file-{index}.html"
        rows.append(f'<tr><td><a href="{page}">{html.escape(path)}</a></td><td>{hits}/{len(lines)}</td></tr>')
        code = []
        for number, source in enumerate((root / path).read_text().splitlines(), 1):
            count = lines.get(str(number))
            css = "" if count is None else "hit" if count else "miss"
            labels = report.get("covered_by", {}).get(path, {}).get(str(number), [])
            code.append(f'<tr class="{css}" id="L{number}"><td>{number}</td><td>{"" if count is None else count}</td><td><pre>{html.escape(source)}</pre></td><td>{html.escape(", ".join(labels))}</td></tr>')
        (output / page).write_text('<!doctype html><meta charset="utf-8">' + style + f'<a href="index.html">Index</a><h2>{html.escape(path)}</h2><table><tr><th>Line</th><th>Hits</th><th>Source</th><th>Covered by</th></tr>' + "".join(code) + "</table>")
    (output / "index.html").write_text('<!doctype html><meta charset="utf-8">' + style + f"<h1>{summary}</h1><p>" + html.escape(", ".join(report["inputs"])) + "</p><p>First-party Swift only. Counts are diagnostic; combined reports union line coverage across builds. Blank lines have no coverage mapping. Rust and dependencies are excluded.</p><h2>Modules</h2><table>" + "".join(module_rows) + "</table><h2>Files</h2><table>" + "".join(rows) + "</table>")
    print(summary + " — " + str(output / "index.html"))


def export(root, output, label, binaries, profiles):
    raw = sorted({p for directory in profiles for p in directory.rglob("*.profraw") if p.stat().st_size})
    if not raw:
        raise ValueError(f"no nonempty profiles for {label}; was the binary instrumented and did it exit normally?")
    output.mkdir(parents=True, exist_ok=True)
    profdata = output / "coverage.profdata"
    run([llvm_tool("llvm-profdata"), "merge", "-sparse", *raw, "-o", profdata])
    args = [llvm_tool("llvm-cov"), "export", "-format=lcov", "-instr-profile=" + str(profdata), binaries[0]]
    for binary in binaries[1:]:
        args.extend(["-object", binary])
    data = subprocess.check_output([str(a) for a in args], text=True)
    files = parse_lcov(data, root)
    if not files or not any(n > 0 for lines in files.values() for n in lines.values()):
        raise ValueError("profile contains no executed first-party Swift lines")
    report = {"version": 1, "inputs": [label], "sources": source_hashes(root), "files": files,
              "covered_by": {p: {n: [label] for n, count in lines.items() if count > 0} for p, lines in files.items()},
              "producer": subprocess.check_output([llvm_tool("llvm-cov"), "--version"], text=True).strip()}
    render(report, root, output)


def load_reports(root, inputs):
    sources = source_hashes(root)
    reports = []
    seen = set()
    labels = set()
    for path in inputs:
        path = path / "coverage.json" if path.is_dir() else path
        if path.resolve() in seen:
            raise ValueError(f"duplicate report: {path}")
        seen.add(path.resolve())
        report = json.loads(path.read_text())
        if report.get("version") != 1 or report["sources"] != sources:
            raise ValueError(f"source mismatch or unsupported report: {path}; rerun coverage for this checkout")
        overlap = labels & set(report["inputs"])
        if overlap:
            raise ValueError(f"duplicate coverage inputs: {sorted(overlap)}")
        labels.update(report["inputs"])
        reports.append(report)
    if not reports:
        raise ValueError("no coverage inputs")
    return reports


def combine(reports, sources, scope=None):
    merged = {"version": 1, "inputs": [], "sources": sources, "files": {}, "covered_by": {}}
    if scope:
        merged["scope"] = scope
    for report in reports:
        merged["inputs"].extend(report["inputs"])
        for file, lines in report["files"].items():
            dest = merged["files"].setdefault(file, {})
            attribution = merged["covered_by"].setdefault(file, {})
            for number, count in lines.items():
                dest[number] = dest.get(number, 0) + count
                if count > 0:
                    attribution.setdefault(number, []).extend(report["covered_by"][file][number])
    return merged


def merge(root, output, inputs):
    merged = combine(load_reports(root, inputs), source_hashes(root))
    if not merged["files"]:
        raise ValueError("no coverage inputs")
    render(merged, root, output)


def unit(root, output):
    if not output.is_relative_to(root / "artifacts/coverage") or output == root / "artifacts/coverage":
        raise ValueError("unit output must be a subdirectory of artifacts/coverage")
    sources = source_hashes(root)
    scratch = root / ".build/code-coverage"
    run(["cargo", "build", "--manifest-path", "rust/Cargo.toml", "--locked"], cwd=root)
    run(["cargo", "test", "--manifest-path", "rust/Cargo.toml", "--locked"], cwd=root)
    # Keep compiler caches, but never old counters. Force relinking because
    # SwiftPM cannot detect changes to the externally linked Rust archive.
    for raw in scratch.rglob("*.profraw"):
        raw.unlink()
    products = [scratch / "debug/mysql-replicator", scratch / "debug/replicator-lab"]
    products.extend(p / "Contents/MacOS" / p.stem if p.is_dir() else p
                    for p in (scratch / "debug").glob("*.xctest"))
    for product in products:
        if product.exists():
            product.unlink()
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    environment = dict(os.environ, REPLICATOR_TEST_BINARY_DIR=str(scratch / "debug"),
                       LLVM_PROFILE_FILE=str(output / "raw/%p-%m.profraw"))
    command = ["swift", "test", "--scratch-path", scratch, "--enable-code-coverage", "--enable-index-store",
               "--force-resolved-versions"]
    status = subprocess.run([str(a) for a in command], cwd=root, env=environment).returncode
    # swift test chooses its own profile directory; include CLI subprocess profiles too.
    binaries = [scratch / "debug/mysql-replicator", scratch / "debug/replicator-lab"]
    tests = list((scratch / "debug").glob("*.xctest"))
    binaries.extend(p / "Contents/MacOS" / p.stem if p.is_dir() else p for p in tests)
    if not tests:
        raise ValueError("Swift test executable missing; inspect the build failure")
    if sources != source_hashes(root):
        raise ValueError("sources changed during coverage build/test; rerun against a stable checkout")
    export(root, output, "unit", binaries, [scratch, output / "raw"])
    if status:
        raise SystemExit(status)


def harness(root, profiles, label, allow_empty=False):
    reports = []
    invocations = profiles.parent / "code-coverage-invocations.json"
    statuses = []
    missing = []
    if invocations.exists():
        for item in json.loads(invocations.read_text()):
            present = any(p.stat().st_size for p in (profiles / item["label"]).glob("*.profraw"))
            # SIGKILL, abort and similar exits cannot flush LLVM counters.
            abrupt = item["exit_code"] < 0 or item["exit_code"] >= 128
            statuses.append(dict(item, profile="present" if present else "missing-abrupt-exit" if abrupt else "missing"))
            if not present and not abrupt:
                missing.append(item["label"])
    profiles.mkdir(parents=True, exist_ok=True)
    (profiles / "profile-status.json").write_text(json.dumps(statuses, indent=2) + "\n")
    # Each process invocation has its own directory, including resume attempts.
    for directory in sorted(profiles.iterdir()):
        if not directory.is_dir():
            continue
        if not list(directory.glob("*.profraw")):
            continue
        output = directory / "report"
        export(root, output, label + "/" + directory.name,
               [Path("/usr/local/bin/mysql-replicator")], [directory])
        reports.append(output)
    if not reports:
        if allow_empty and not missing:
            print("No applier profiles available; no coverage report emitted (writer may never have started or exited abruptly).")
            return
        raise ValueError("harness produced no profiles")
    merge(root, profiles / "combined", reports)
    if missing:
        raise ValueError("missing profiles from normally exited invocations: " + ", ".join(missing))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    commands = parser.add_subparsers(dest="command", required=True)
    unit_parser = commands.add_parser("unit")
    unit_parser.add_argument("--output", type=Path, default=Path("artifacts/coverage/unit"))
    merge_parser = commands.add_parser("merge")
    merge_parser.add_argument("--output", type=Path, default=Path("artifacts/coverage/combined"))
    merge_parser.add_argument("inputs", nargs="+", type=Path)
    harness_parser = commands.add_parser("harness")
    harness_parser.add_argument("--profiles", type=Path, required=True)
    harness_parser.add_argument("--label", required=True)
    harness_parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "unit":
        unit(root, args.output.resolve())
    elif args.command == "harness":
        harness(root, args.profiles, args.label, args.allow_empty)
    else:
        merge(root, args.output.resolve(), args.inputs)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"coverage: {error}")
