#!/usr/bin/env python3
"""Build the C++ probe on macOS. Keep generated code outside product sources."""
import concurrent.futures
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT / "artifacts/sql-parser-evaluation"
def run(args, **kw):
    subprocess.run([str(a) for a in args],check=True,**kw)
if __name__ == "__main__":
    args=argparse.ArgumentParser()
    args.add_argument("--patched",action="store_true",help="Test two isolated C++ lexer support fixes")
    args=args.parse_args()
    suffix="-patched" if args.patched else ""
    start=time.monotonic()
    gen=OUT / ("generated"+suffix)
    gen.mkdir(exist_ok=True)
    for path in (OUT / "grammar").iterdir():
        shutil.copy2(path,gen/path.name)
    if args.patched:
        path=gen/"MySQLLexerBase.cpp"
        text=path.read_text()
        before="bool MySQLLexerBase::isVersionComment() { return inVersionComment; }"
        assert before in text
        text=text.replace(before,"bool MySQLLexerBase::isVersionComment() { return checkMySQLVersion(getText()); }")
        text=text.replace("this->inVersionComment = false;","this->inVersionComment = false;\n    this->justEmittedDot = false;")
        path.write_text(text)
    run(["python3","transformGrammar.py"],cwd=gen)
    run(["java","-jar",OUT/"antlr.jar","-Dlanguage=Cpp","-no-listener","MySQLLexer.g4","MySQLParser.g4"],cwd=gen)
    generated=time.monotonic()
    runtime=OUT/"runtime/runtime/src"
    objects=OUT/"objects"; objects.mkdir(exist_ok=True)
    paths=list(runtime.rglob("*.cpp"))+list(gen.glob("*.cpp"))+[ROOT/"tools/sql-parser-evaluation/probe.cpp"]
    flags=["clang++","-std=c++17","-O2","-DNDEBUG","-DANTLR4CPP_STATIC","-pthread","-I",runtime,"-I",gen]
    def compile(path):
        obj=objects/(str(path.relative_to(ROOT)).replace("/","_")+".o")
        if not obj.exists() or obj.stat().st_mtime < path.stat().st_mtime:
            run(flags+["-c",path,"-o",obj])
        return obj
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        objs=list(pool.map(compile,paths))
    run(["clang++","-pthread",*objs,"-o",OUT/("probe"+suffix)])
    report={"generationSeconds":generated-start,"compileAndLinkSeconds":time.monotonic()-generated,
            "binaryBytes":(OUT/("probe"+suffix)).stat().st_size,"sourceFiles":len(paths)}
    (OUT/("build"+suffix+".json")).write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report))
