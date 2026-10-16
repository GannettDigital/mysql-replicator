#!/usr/bin/env python3
"""Check useful parse-tree output, mode changes and native comparison scope."""
import json
from corpus import ROOT
OUT=ROOT/"artifacts/sql-parser-evaluation"
rows={r["id"]:r for r in json.loads((OUT/"results-patched.json").read_text())}
def selected(name,rule,version):
    return [s["text"] for s in rows[f"{name}-{version}"]["spans"] if s["rule"]==rule]
for version in [50742,80408]:
    assert selected("unicode","tableRef",version)==["`café`.`表`"]
    assert selected("rename","tableRef",version)==["t","t2"]
    assert selected("rename","tableName",version)==["old_t","t"]
    assert selected("compound-alter","alterListItem",version)==[
        "ADD c VARCHAR(30)","CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"]
    assert len(selected("generated","exprWithParentheses",version))==4
    for first,second in [("mode-pipes","mode-or"),("mode-not-high","mode-not-low")]:
        a,b=[rows[f"{key}-{version}"] for key in [first,second]]
        assert a["accepted"] and b["accepted"] and a["modeTree"]!=b["modeTree"]
    for name in ["latin1","sjis"]:
        assert rows[f"{name}-{version}"]["originalEncodingSpans"]
    # Use a grammar range to edit only the charset name. Preserve every other byte.
    row=rows[f"compound-alter-{version}"]
    span=next(s for s in row["spans"] if s["rule"]=="charsetName")
    sql=row["sql"].encode()
    edited=sql[:span["start"]]+b"latin1"+sql[span["end"]:]
    assert edited.decode()==row["sql"].replace("CHARACTER SET utf8mb4","CHARACTER SET latin1")
    # This tests edit boundaries only. The changed collation is not executable SQL.
native=json.loads((OUT/"native.json").read_text())
assert len(native)==126
assert all(n["syntaxAccepted"]==rows[n["id"]]["expected"] for n in native)
report={"curatedNativeCases":len(native),"nativeSuccessfulStatements":sum(n["success"] for n in native),
    "nativeSyntaxDifferences":[n["id"] for n in native if n["syntaxAccepted"]!=rows[n["id"]]["accepted"]],
    "structureAndEncodingChecks":"passed"}
(OUT/"native-comparison.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report,indent=2))
