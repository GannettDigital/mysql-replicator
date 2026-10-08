#!/usr/bin/env python3
"""Build, smoke-test and save an amd64 image from the checksummed release archive."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

from release_version import ROOT, versions


def checked_asset(directory, name):
    matches = [line.split()[0] for line in (directory / 'SHA256SUMS').read_text().splitlines()
               if len(line.split()) == 2 and line.split()[1] == name]
    if len(matches) != 1:
        raise ValueError(f'missing or duplicated checksum: {name}')
    path = directory / name
    if hashlib.sha256(path.read_bytes()).hexdigest() != matches[0]:
        raise ValueError(f'checksum mismatch: {name}')
    return path


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    version, _ = versions((ROOT / 'VERSION').read_text().strip())
    release = ROOT / 'artifacts/release'
    name = f'mysql-replicator-{version}-linux-x86_64'
    archive = checked_asset(release, name + '.tar.gz')
    image = f'mysql-replicator-release:{version}'
    revision = command('git', '-C', str(ROOT), 'rev-parse', 'HEAD')
    with tempfile.TemporaryDirectory(prefix='replicator-image-') as temporary:
        context = Path(temporary)
        shutil.copyfile(archive, context / 'release.tar.gz')
        (context / 'rootfs/var/lib/mysql-replicator').mkdir(mode=0o750, parents=True)
        (context / 'rootfs/tmp').mkdir()
        (context / 'rootfs/tmp').chmod(0o1777)
        subprocess.run(['docker', 'build', '--platform', 'linux/amd64',
                        '--file', str(ROOT / 'docker/release/Dockerfile'),
                        '--build-arg', f'VERSION={version}', '--build-arg', f'REVISION={revision}',
                        '--tag', image, str(context)], check=True)
        config = json.loads(command('docker', 'image', 'inspect', image))[0]
        assert config['Architecture'] == 'amd64' and config['Os'] == 'linux'
        assert config['Config']['User'] == '65532:65532'
        assert config['Config']['StopSignal'] == 'SIGTERM'
        run = ['docker', 'run', '--rm', '--platform', 'linux/amd64', '--read-only', '--network', 'none']
        assert command(*run, image, '--version').startswith(f'mysql-replicator {version} (')
        assert 'ctl status|stop|reload' in command(*run, image, '--help')
        # Copy from the image rather than running a shell: the production image has none.
        container = command('docker', 'create', '--platform', 'linux/amd64', image)
        try:
            subprocess.run(['docker', 'cp', container + ':/opt/mysql-replicator/mysql-replicator',
                            str(context / 'binary')], check=True)
            with tarfile.open(archive) as package:
                expected = hashlib.sha256(package.extractfile(name + '/mysql-replicator').read()).hexdigest()
            assert hashlib.sha256((context / 'binary').read_bytes()).hexdigest() == expected
            # Docker initializes a fresh named volume from this directory. It
            # must be owned by the runtime UID, with no preinitialized state child.
            state_tar = subprocess.check_output(['docker', 'cp', container + ':/var/lib/mysql-replicator', '-'])
            with tarfile.open(fileobj=io.BytesIO(state_tar)) as state:
                members = state.getmembers()
                assert len(members) == 1 and members[0].isdir()
                assert members[0].uid == 65532 and members[0].mode & 0o700 == 0o700
            tmp_tar = subprocess.check_output(['docker', 'cp', container + ':/tmp', '-'])
            with tarfile.open(fileobj=io.BytesIO(tmp_tar)) as temporary_dir:
                assert temporary_dir.getmembers()[0].mode == 0o1777
        finally:
            subprocess.run(['docker', 'rm', container], check=True)
        fixture = ROOT / 'tests/ReplicatorLabTests/Fixtures/source-positive.binlog'
        schema = ROOT / 'tests/ReplicatorCodecTests/Schema/source-positive.json'
        output = command(*run, '--mount', f'type=bind,src={fixture},dst=/fixture.binlog,readonly',
                         '--mount', f'type=bind,src={schema},dst=/schema.json,readonly', image,
                         'inspect', '/fixture.binlog', '--schema', '/schema.json')
        events = [json.loads(line) for line in output.splitlines()]
        def values(row, key):
            return [value['value'] for value in row[key]] if key in row else None
        operations = [(row['operation'], values(row, 'before'), values(row, 'after'))
                      for event in events if 1589 <= int(event['offset']) < 2841
                      for row in event.get('rows', [])]
        inserted = ['3', 'inserted', '18446744073709551615']
        assert operations == [
            ('insert', None, inserted),
            ('update', ['1', 'seed-one', '1'], ['1', 'updated', '1']),
            ('delete', ['2', 'seed-two', '2'], None),
            ('update', inserted, ['3', 'final-three', '18446744073709551615']),
        ], operations
        # Save tested image bytes for release promotion; no registry writes here.
        image_archive = release / (name + '-image.tar.gz')
        subprocess.run(['docker', 'save', '--output', str(context / 'image.tar'), image], check=True)
        with image_archive.open('wb') as output_file:
            subprocess.run(['gzip', '-n', '-c', str(context / 'image.tar')], stdout=output_file, check=True)
        checksum = hashlib.sha256(image_archive.read_bytes()).hexdigest()
        sums = release / 'SHA256SUMS'
        lines = [line for line in sums.read_text().splitlines()
                 if line.split()[-1] != image_archive.name]
        sums.write_text('\n'.join(lines + [f'{checksum}  {image_archive.name}']) + '\n')
        print(f'Verified {image}: archive binary {expected}; saved {image_archive.name}')


if __name__ == '__main__':
    main()
