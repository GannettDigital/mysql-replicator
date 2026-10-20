#!/usr/bin/env python3
import collections
import argparse
import json
from pathlib import Path
import statistics
import subprocess
from corpus import ROOT, cases

OUT=ROOT/"artifacts/sql-parser-evaluation"
def wire(case):
    # Transcode at the boundary. Production integration must retain an offset map
    # from this UTF-8 parser input back to the original source-encoding bytes.
    sql=case["sql"]
    if "encoding" in case:
        sql=sql.encode(case["encoding"]).decode(case["encoding"])
    return f'{case["id"]}\t{case["version"]}\t{case["mode"]}\t{sql.encode().hex()}\n'

if __name__=="__main__":
    args=argparse.ArgumentParser()
    args.add_argument("--patched",action="store_true")
    args=args.parse_args()
    suffix="-patched" if args.patched else ""
    corpus=cases()
    (OUT/"corpus.json").write_text(json.dumps(corpus,indent=2,ensure_ascii=False)+"\n")
    process=subprocess.run([str(OUT/("probe"+suffix))],input="".join(map(wire,corpus)),text=True,
        capture_output=True,timeout=120,check=True)
    rows=[json.loads(line) for line in process.stdout.splitlines()]
    assert len(rows)==len(corpus)
    for case,row in zip(corpus,rows):
        assert case["id"]==row["id"]
        row.update(case)
        raw=case["sql"].encode()
        row["selectedSpansValid"]=all(raw[s["start"]:s["end"]].decode()==s["text"] for s in row["spans"])
        if "encoding" in case:
            encoding=case["encoding"]
            source=case["sql"].encode(encoding)
            row["originalEncodingSpans"]=[]
            for span in row["spans"]:
                start=len(raw[:span["start"]].decode().encode(encoding))
                end=len(raw[:span["end"]].decode().encode(encoding))
                assert source[start:end].decode(encoding)==span["text"]
                row["originalEncodingSpans"].append(dict(start=start,end=end,text=span["text"]))
    (OUT/("results"+suffix+".json")).write_text(json.dumps(rows,indent=2,ensure_ascii=False)+"\n")
    groups={}
    for group in ["curated","fixture"]:
        subset=[r for r in rows if r["group"]==group]
        groups[group]={"cases":len(subset),"accepted":sum(r["accepted"] for r in subset),
            "expectationMismatches":[r["id"] for r in subset if r["expected"] is not None and r["accepted"]!=r["expected"]],
            "badTokenSpans":[r["id"] for r in subset if not r["tokenSpans"]],
            "badSelectedSpans":[r["id"] for r in subset if not r["selectedSpansValid"]]}
    timings=[r["ms"] for r in rows]
    summary={"groups":groups,"milliseconds":{"sum":sum(timings),"median":statistics.median(timings),"max":max(timings)},
             "slowest":[dict(id=r["id"],ms=r["ms"],sql=r["sql"]) for r in sorted(rows,key=lambda r:r["ms"],reverse=True)[:5]]}
    (OUT/("summary"+suffix+".json")).write_text(json.dumps(summary,indent=2)+"\n")
    print(json.dumps(summary,indent=2))
