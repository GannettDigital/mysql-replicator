#!/usr/bin/env python3
"""Run inside the existing packaging builder with this repository at /work."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/"artifacts/sql-parser-evaluation"
SDK=Path("/root/.swiftpm/swift-sdks/swift-6.2.1-RELEASE_static-linux-0.0.1.artifactbundle/swift-6.2.1-RELEASE_static-linux-0.0.1/swift-linux-musl/musl-1.2.5.sdk/x86_64")
runtime=OUT/"runtime/runtime/src"
gen=OUT/"generated-patched"
objdir=OUT/"objects-linux"; objdir.mkdir(exist_ok=True)
sources=list(runtime.rglob("*.cpp"))+list(gen.glob("*.cpp"))+[ROOT/"tools/sql-parser-evaluation/probe.cpp"]
base=["clang++","--target=x86_64-unknown-linux-musl","--sysroot="+str(SDK),"-resource-dir",str(SDK/"usr/lib/swift/clang"),
      "-stdlib=libc++","-std=c++17","-O2","-DNDEBUG","-DANTLR4CPP_STATIC","-pthread"]
start=time.monotonic()
def compile(path):
    obj=objdir/(str(path.relative_to(ROOT)).replace("/","_")+".o")
    if not obj.exists() or obj.stat().st_mtime<path.stat().st_mtime:
        subprocess.run(base+["-I",str(runtime),"-I",str(gen),"-c",str(path),"-o",str(obj)],check=True)
    return str(obj)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    objects=list(pool.map(compile,sources))
binary=OUT/"probe-linux"
subprocess.run(base+["-static","-fuse-ld=lld","--rtlib=compiler-rt","--unwindlib=libunwind",*objects,
    "-Wl,--start-group","-lc++","-lc++abi","-lunwind","-Wl,--end-group","-o",str(binary)],check=True)
identity=subprocess.check_output(["file",str(binary)],text=True).strip()
report={"compileAndLinkSeconds":time.monotonic()-start,"binaryBytes":binary.stat().st_size,"file":identity}
(OUT/"build-linux.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report))
