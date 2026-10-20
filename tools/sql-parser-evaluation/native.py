#!/usr/bin/env python3
"""Check curated SQL against disposable native servers. Uses only antlr_eval DB."""
import argparse
import json
import re
import subprocess
from corpus import ROOT, cases

parser=argparse.ArgumentParser()
parser.add_argument("--mysql57",required=True,help="Disposable MySQL 5.7 container; root has no password")
parser.add_argument("--mysql84",required=True,help="Disposable MySQL 8.4 container; root has no password")
args=parser.parse_args()
rows=[]
for case in cases():
    if case["group"]!="curated" or case["id"].startswith("two-statements"): continue
    container=args.mysql57 if case["version"]==50742 else args.mysql84
    setup="""DROP DATABASE IF EXISTS antlr_eval;
CREATE DATABASE antlr_eval CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
USE antlr_eval;
SET SESSION sql_mode='';
CREATE TABLE t(id INT PRIMARY KEY,v VARCHAR(30),n INT);
CREATE TABLE parent(id INT PRIMARY KEY);
CREATE TABLE t2 LIKE t;
"""
    # CREATE TABLE cases must get a free name. Other cases need baseline tables.
    if re.match(r"CREATE(?: /\*.*?\*/)? TABLE t\b",case["sql"]): setup+="DROP TABLE t;\n"
    sql=setup+f"SET SESSION sql_mode='{case['mode']}';\nDELIMITER $$\n"+case["sql"]+"$$\n"
    charset={"latin1":"latin1","shift_jis":"sjis"}.get(case.get("encoding"),"utf8mb4")
    data=sql.encode(case.get("encoding","utf8"))
    command=["docker","exec","-i",container,"mysql","-uroot","--comments","--batch","--raw","--default-character-set="+charset]
    proc=subprocess.run(command,input=data,capture_output=True,timeout=15)
    error=proc.stderr.decode("utf8",errors="replace")
    match=re.search(r"ERROR (\d+)",error)
    code=int(match[1]) if match else None
    if proc.returncode and code is None: raise RuntimeError(error)
    rows.append(dict(id=case["id"],sql=case["sql"],version=case["version"],
        success=proc.returncode==0,errorCode=code,error=error,output=proc.stdout.decode("utf8",errors="replace"),
        syntaxAccepted=code!=1064))
out=ROOT/"artifacts/sql-parser-evaluation/native.json"
out.write_text(json.dumps(rows,indent=2,ensure_ascii=False)+"\n")
print(f"Saved {len(rows)} native results to {out}")
