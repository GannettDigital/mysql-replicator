#!/usr/bin/env python3
"""Measure the isolated parser and compare the static Linux build."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time
from corpus import ROOT, cases
from evaluate import wire

OUT=ROOT/"artifacts/sql-parser-evaluation"
args=argparse.ArgumentParser()
args.add_argument("--linux",action="store_true")
args=args.parse_args()
corpus=cases()
if args.linux:
    command=["docker","run","--rm","-i","--platform","linux/amd64","--entrypoint",
        "/work/artifacts/sql-parser-evaluation/probe-linux","-v",str(ROOT)+":/work:ro","ubuntu:16.04"]
    proc=subprocess.run(command,input="".join(map(wire,corpus)),capture_output=True,text=True,check=True,timeout=120)
    rows=[json.loads(line) for line in proc.stdout.splitlines()]
    reference=json.loads((OUT/"results-patched.json").read_text())
    assert len(rows)==len(reference)
    fields=["id","accepted","errors","spans","tokenSpans","modeTree"]
    mismatches=[r["id"] for r,ref in zip(rows,reference) if any(r.get(f)!=ref.get(f) for f in fields)]
    report={"cases":len(rows),"mismatches":mismatches,"environment":"static x86_64 musl executable in ubuntu:16.04, Docker on macOS arm64"}
    (OUT/"linux-results.json").write_text(json.dumps(rows,indent=2)+"\n")
    (OUT/"linux-comparison.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report))
else:
    accepted={r["id"] for r in json.loads((OUT/"results-patched.json").read_text()) if r["accepted"]}
    good=[r for r in corpus if r["group"]=="curated" and r["expected"] and r["id"] in accepted]
    batch=[good[i%len(good)] for i in range(10000)]
    start=time.monotonic()
    proc=subprocess.run(["/usr/bin/time","-l",str(OUT/"probe-patched")],input="".join(map(wire,batch)),
        capture_output=True,text=True,check=True,timeout=120)
    rows=[json.loads(line) for line in proc.stdout.splitlines()]
    times=[r["ms"] for r in rows]
    assert len(rows)==10000 and all(r["accepted"] for r in rows)
    report={"cases":len(rows),"distinctCases":len(good),"accepted":sum(r["accepted"] for r in rows),"wallSeconds":time.monotonic()-start,
        "parseMilliseconds":sum(times),"medianMilliseconds":statistics.median(times),"p99Milliseconds":sorted(times)[9899],
        "maxMilliseconds":max(times),"timeOutput":proc.stderr}
    stress=[]
    for depth in [32,128,512,1024]:
        case=dict(id=f"depth-{depth}",version=80408,mode="",sql="SELECT "+"("*depth+"1"+")"*depth)
        start=time.monotonic()
        try:
            proc=subprocess.run([str(OUT/"probe-patched")],input=wire(case),text=True,capture_output=True,timeout=10)
            result=json.loads(proc.stdout) if proc.returncode==0 else {"exitCode":proc.returncode}
        except subprocess.TimeoutExpired:
            result={"timeout":True}
        stress.append(dict(depth=depth,seconds=time.monotonic()-start,result=result))
    report["depthProbes"]=stress
    (OUT/"measurements.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2))
