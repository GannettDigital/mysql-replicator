#!/usr/bin/env python3
"""Compile locked Rust dependencies before copying either crate's real sources."""
import argparse
from pathlib import Path
import shutil
import subprocess


def build(manifest, target, target_dir):
    sources = manifest.parent / 'src'
    if sources.exists():
        raise ValueError('dependency build requires absent crate sources: ' + str(sources))
    sources.mkdir()
    (sources / 'lib.rs').write_text('// Dependency-layer placeholder. Never shipped.\n')
    common = ['--manifest-path', str(manifest), '--target', target, '--target-dir', str(target_dir)]
    try:
        metadata = subprocess.check_output(['cargo', 'metadata', '--locked', '--no-deps', '--format-version', '1',
                                           '--manifest-path', str(manifest)], text=True)
        import json
        packages = json.loads(metadata)['packages']
        package = next(p['name'] for p in packages if Path(p['manifest_path']).resolve() == manifest.resolve())
        subprocess.run(['cargo', 'build', *common, '--locked', '--release', '-j', '2'], check=True)
        # Cargo uses mtimes. A later COPY can have older source timestamps than
        # the stub build. Remove only this crate, preserving dependency outputs.
        subprocess.run(['cargo', 'clean', *common, '--release', '--package', package], check=True)
    finally:
        shutil.rmtree(sources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True)
    parser.add_argument('--target-dir', type=Path, required=True)
    parser.add_argument('manifests', nargs='+', type=Path)
    args = parser.parse_args()
    for manifest in args.manifests:
        build(manifest, args.target, args.target_dir)


if __name__ == '__main__':
    main()
