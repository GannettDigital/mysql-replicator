#!/usr/bin/env python3
"""Update a coverage PR comment from a completed CI run.

Run only from the default branch in workflow_run. Downloaded artifacts are data:
read one bounded JSON member in memory, never extract or execute their contents.
"""
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

MARKER = "<!-- mysql-replicator-swift-coverage -->"
SCOPES = {"runtime": "Runtime: unit + integration smoke", "runtime-unit": "Runtime: unit only",
          "runtime-integration": "Runtime: integration smoke only", "harness": "Harness: unit only"}


def api(path, method="GET", body=None, binary=False):
    command = ["gh", "api", path, "--method", method]
    if body is not None:
        command += ["--input", "-"]
    data = subprocess.check_output(command, input=json.dumps(body).encode() if body is not None else None)
    return data if binary else json.loads(data)


def pages(path, key=None):
    for page in range(1, 101):
        data = api(f'{path}{"&" if "?" in path else "?"}per_page=100&page={page}')
        items = data[key] if key else data
        yield from items
        if len(items) < 100:
            return
    raise ValueError("GitHub pagination limit exceeded")


def validate(metrics):
    if metrics.get("version") != 1 or type(metrics.get("complete")) is not bool:
        raise ValueError("unsupported coverage metrics")
    for key in ["commit", "head_sha", "policy"]:
        pattern = r"[0-9a-f]{64}" if key == "policy" else r"[0-9a-f]{40}"
        if not isinstance(metrics.get(key), str) or not re.fullmatch(pattern, metrics[key]):
            raise ValueError(f"invalid {key}")
    if metrics.get("base_sha") is not None and not re.fullmatch(r"[0-9a-f]{40}", str(metrics["base_sha"])):
        raise ValueError("invalid base_sha")
    for key in ["run_id", "run_attempt"]:
        if not re.fullmatch(r"[1-9][0-9]{0,19}", str(metrics.get(key, ""))):
            raise ValueError(f"invalid {key}")
    for name in SCOPES:
        count = metrics["scopes"][name]
        if any(type(count.get(k)) is not int for k in ["covered", "total"]):
            raise ValueError("invalid coverage counts")
        if not 0 <= count["covered"] <= count["total"] <= 10**8:
            raise ValueError("invalid coverage counts")
        if metrics["complete"] and count["total"] == 0:
            raise ValueError("complete report has missing coverage")
    return metrics


def read_archive(data):
    if len(data) > 1024 * 1024:
        raise ValueError("oversized coverage artifact")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        if len(members) != 1 or members[0].filename != "metrics.json" or members[0].file_size > 65536:
            raise ValueError("expected one bounded metrics.json member")
        return validate(json.loads(archive.read(members[0])))


def metrics_for(repo, run):
    artifacts = list(pages(f'repos/{repo}/actions/runs/{run["id"]}/artifacts', "artifacts"))
    matches = [a for a in artifacts if a["name"] == "coverage-summary" and not a["expired"]]
    if not matches:
        return None
    if len(matches) != 1 or matches[0]["size_in_bytes"] > 1024 * 1024:
        raise ValueError("ambiguous or oversized coverage artifact")
    metrics = read_archive(api(f'repos/{repo}/actions/artifacts/{matches[0]["id"]}/zip', binary=True))
    if (str(metrics["run_id"]) != str(run["id"]) or str(metrics["run_attempt"]) != str(run["run_attempt"])
            or metrics["head_sha"] != run["head_sha"]):
        raise ValueError("coverage artifact does not match the triggering run/attempt")
    return metrics


def comparable(current, baseline):
    return bool(baseline and current["complete"] and baseline["complete"]
                and current["policy"] == baseline["policy"]
                and current["base_sha"] == baseline["commit"])


def comment(metrics, run, repo, baseline=None):
    run_url = f'https://github.com/{repo}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}'
    lines = [MARKER, f'<!-- coverage-run:{run["id"]}:{run["run_attempt"]} -->',
             "**Swift line coverage**", ""]
    if metrics is None:
        lines += ["Coverage report unavailable for this run."]
    else:
        lines += ["Complete selected CI suites." if metrics["complete"] else "**PARTIAL — selected coverage suites did not all complete.**",
                  "", "| Scope | Covered / mapped lines | Coverage | Change vs base |", "|---|---:|---:|---:|"]
        compare = comparable(metrics, baseline)
        for name, label in SCOPES.items():
            count = metrics["scopes"][name]
            value = 100 * count["covered"] / count["total"] if count["total"] else None
            percent = f"{value:.2f}%" if value is not None else "unavailable"
            delta = "—"
            if compare:
                base = baseline["scopes"][name]
                if base["total"] and value is not None:
                    delta = f'{value - 100 * base["covered"] / base["total"]:+.2f} pp'
            lines.append(f'| {label} | {count["covered"]}/{count["total"]} | {percent} | {delta} |')
        if not compare:
            lines += ["", "Base comparison unavailable: requires complete reports for the exact base commit and identical test/reporting inputs."]
        lines += ["", f'Tested commit: `{metrics["commit"]}`.']
    lines += ["", "First-party Swift only; Rust and dependencies excluded. Integration measures selected smoke suites, "
              "not full qualification or MySQL catalog coverage. Harness uses unit tests only.", "",
              f'[CI run and downloadable HTML/LCOV reports (`combined-swift-coverage`)]({run_url})']
    return "\n".join(lines)


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    run = event["workflow_run"]
    repo = os.environ["GITHUB_REPOSITORY"]
    if (run["event"] != "pull_request" or run["path"] != ".github/workflows/ci.yml"
            or run["repository"]["full_name"] != repo):
        return
    # Resolve PR identity from GitHub, never from uploaded metadata. This also
    # works when workflow_run.pull_requests is empty for a fork run.
    prs = [pr for pr in pages(f'repos/{repo}/commits/{run["head_sha"]}/pulls')
           if pr["state"] == "open" and pr["head"]["sha"] == run["head_sha"]
           and pr["head"]["repo"] and pr["head"]["repo"]["full_name"] == run["head_repository"]["full_name"]
           and pr["base"]["repo"]["full_name"] == repo]
    if not prs:
        return
    metrics = metrics_for(repo, run)
    baseline = None
    # Exact base push, never an arbitrary latest-main report or a weekly suite.
    if metrics and metrics["complete"] and metrics["base_sha"]:
        candidates = api(f'repos/{repo}/actions/workflows/ci.yml/runs?event=push&status=success&head_sha={metrics["base_sha"]}&per_page=100')["workflow_runs"]
        for candidate in candidates:
            baseline = metrics_for(repo, candidate)
            if comparable(metrics, baseline):
                break
    for pr in prs:
        number = pr["number"]
        comments = list(pages(f'repos/{repo}/issues/{number}/comments'))
        prior = next((c for c in comments if c["user"]["login"] == "github-actions[bot]" and c["body"].startswith(MARKER)), None)
        if prior:
            previous = re.search(r"<!-- coverage-run:(\d+):(\d+) -->", prior["body"])
            if previous and tuple(map(int, previous.groups())) > (int(run["id"]), int(run["run_attempt"])):
                continue
        current = api(f'repos/{repo}/pulls/{number}')
        if current["state"] != "open" or current["head"]["sha"] != run["head_sha"]:
            continue
        body = comment(metrics, run, repo, baseline)
        if prior:
            api(f'repos/{repo}/issues/comments/{prior["id"]}', "PATCH", {"body": body})
        else:
            api(f'repos/{repo}/issues/{number}/comments', "POST", {"body": body})


if __name__ == "__main__":
    main()
