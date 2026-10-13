#!/usr/bin/env python3
"""Select isolated GHCR caches and transfer CI images by immutable digest."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

TAGS = {'release': 'mysql-replicator-packaging:lab', 'coverage': 'mysql-replicator:coverage'}


def namespace(repository):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid repository')
    return 'ghcr.io/' + repository.lower() + '-ci'


def cache_ref(repository, image, branch):
    suffix = 'main' if branch == 'main' else hashlib.sha256(branch.encode()).hexdigest()[:20]
    return f'{namespace(repository)}:cache-v2-{image}-{suffix}'


def plan(env, event, image):
    repository = env['GITHUB_REPOSITORY']
    pr = event.get('pull_request')
    # GitHub can omit the source repository after a fork is deleted.
    # An unknown source must use the same restricted path as an external fork.
    source_repo = (pr['head'].get('repo') or {}) if pr else {}
    publish = not pr or source_repo.get('full_name') == repository
    branch = pr['head']['ref'] if pr else env['GITHUB_REF_NAME']
    base = pr['base']['ref'] if pr else 'main'
    own = cache_ref(repository, image, branch)
    refs = [own] if publish else []
    refs += [cache_ref(repository, image, base), cache_ref(repository, image, 'main')]
    imports = ['type=registry,ref=' + ref for ref in dict.fromkeys(refs)]
    # Forks use only their isolated Actions cache for writes. Private GHCR reads
    # can miss; a cache miss must leave a valid cold build available.
    fallback = f'type=gha,scope=layers-v2-{image}'
    if not publish:
        imports.insert(0, fallback)
    run, attempt = env['GITHUB_RUN_ID'], env['GITHUB_RUN_ATTEMPT']
    if not run.isdigit() or not attempt.isdigit():
        raise ValueError('invalid run identity')
    return dict(publish=str(publish).lower(), cache_from='\n'.join(imports),
                cache_to=(f'type=registry,ref={own},mode=max' if publish else fallback + ',mode=max'),
                runtime=f'{namespace(repository)}:run-{run}-{attempt}-{image}',
                source='https://github.com/' + repository)


def receipt(repository, image, reference, digest, commit):
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('missing or invalid image digest')
    if not reference.startswith(namespace(repository) + ':run-'):
        raise ValueError('runtime image is outside this repository')
    return dict(image=image, reference=namespace(repository) + '@' + digest, commit=commit)


def load_receipt(value, repository, image, commit):
    if value['image'] != image or value['commit'] != commit:
        raise ValueError('image receipt does not match this job')
    reference = value['reference']
    prefix = namespace(repository) + '@'
    if not reference.startswith(prefix) or not re.fullmatch(r'sha256:[0-9a-f]{64}', reference[len(prefix):]):
        raise ValueError('invalid immutable runtime reference')
    subprocess.run(['docker', 'pull', '--platform', 'linux/amd64', reference], check=True)
    subprocess.run(['docker', 'tag', reference, TAGS[image]], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'record', 'load'])
    parser.add_argument('--image', choices=TAGS, required=True)
    args = parser.parse_args()
    env = os.environ
    if args.action == 'plan':
        value = plan(env, json.loads(Path(env['GITHUB_EVENT_PATH']).read_text()), args.image)
        with open(env['GITHUB_OUTPUT'], 'a') as output:
            for key, text in value.items():
                output.write(f'{key}<<REGISTRY_OUTPUT\n{text}\nREGISTRY_OUTPUT\n')
    else:
        path = Path('artifacts/ci/image/image.json')
        if args.action == 'record':
            value = receipt(env['GITHUB_REPOSITORY'], args.image, env['IMAGE_REFERENCE'],
                            env['IMAGE_DIGEST'], env['GITHUB_SHA'])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value) + '\n')
        else:
            load_receipt(json.loads(path.read_text()), env['GITHUB_REPOSITORY'], args.image, env['GITHUB_SHA'])


if __name__ == '__main__':
    main()
