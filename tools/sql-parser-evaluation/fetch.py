#!/usr/bin/env python3
"""Fetch pinned inputs for an isolated parser evaluation. No app dependencies change."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "artifacts/sql-parser-evaluation"
GRAMMAR_REV = "89fd36482e8cb68a4e55df021a8adbc7541b52f2"
ORACLE_REV = "b327bda586a2fa9aa6596315a1e518f891fd2bc2"
ANTLR_VERSION = "4.13.2"
base = f"https://raw.githubusercontent.com/antlr/grammars-v4/{GRAMMAR_REV}/sql/mysql/Oracle"
files = {"grammar/" + f: base + "/" + f for f in ["MySQLParser.g4", "MySQLLexer.g4", "README.md"]}
for f in ["MySQLLexerBase.cpp", "MySQLLexerBase.h", "MySQLParserBase.cpp", "MySQLParserBase.h", "SqlMode.h", "SqlModes.cpp", "SqlModes.h", "transformGrammar.py"]:
    files["grammar/" + f] = base + "/Cpp/" + f
for f in ["MySQLParser.g4", "MySQLLexer.g4", "MySQLBaseLexer.ts", "MySQLBaseRecognizer.ts"]:
    files["oracle/" + f] = f"https://raw.githubusercontent.com/mysql/mysql-shell-plugins/{ORACLE_REV}/gui/frontend/src/parsing/mysql/{f}"
files["antlr.jar"] = f"https://www.antlr.org/download/antlr-{ANTLR_VERSION}-complete.jar"
files["runtime.zip"] = f"https://www.antlr.org/download/antlr4-cpp-runtime-{ANTLR_VERSION}-source.zip"

def fetch(item):
    name, url = item
    path = OUT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        with urllib.request.urlopen(url, timeout=90) as response:
            path.write_bytes(response.read())
    return {"path": name, "url": url, "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        manifest = list(pool.map(fetch, files.items()))
    (OUT / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    runtime = OUT / "runtime"
    if not runtime.exists():
        with zipfile.ZipFile(OUT / "runtime.zip") as archive:
            archive.extractall(runtime)
    print(f"Fetched {len(manifest)} inputs into {OUT}")
