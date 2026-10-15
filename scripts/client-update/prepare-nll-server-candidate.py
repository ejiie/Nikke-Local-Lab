"""CLIENT_UPDATE step 5: a new EpinelPS server candidate from the deployed NLL candidate.

The upstream version commit's gameconfig.json/gameversion.json are taken as-is (the 152 and 152.8.13 rule). Optional
upstream feature commits are only trial-merged per file on a separate branch and reported; nothing is built,
installed or activated. The candidate is its own local git repository under the repository's ignored .external.
"""
import argparse
import json
import shutil
import subprocess
from pathlib import Path

SKIP_DIRS = {'bin', 'obj', '.vs', 'TestResults', 'artifacts', '.git'}
VERSION_FILES = ('EpinelPS/gameconfig.json', 'EpinelPS/gameversion.json')


def run(args, check=True):
    return subprocess.run(args, capture_output=True, check=check)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--source', required=True, help='deployed NLL server candidate (e.g. .external/EpinelPS-152-candidate)')
    p.add_argument('--upstream', required=True, help='local clone of the public upstream EpinelPS repository')
    p.add_argument('--target', required=True, help='new candidate folder under .external (must not exist)')
    p.add_argument('--version-commit', required=True)
    p.add_argument('--trial-commit', action='append', default=[])
    p.add_argument('--deployed-manifest', required=True, help='server-source.manifest.tsv of the selected runtime bundle')
    p.add_argument('--evidence', required=True, help='staging folder for receipts')
    a = p.parse_args()
    source, target, evidence = Path(a.source), Path(a.target), Path(a.evidence)
    if target.exists():
        raise SystemExit('candidate_already_exists')

    def upstream(*args):
        return run(['git', '-C', a.upstream, *args]).stdout

    def candidate(*args, check=True):
        return run(['git', '-C', str(target), '-c', 'user.name=nll-client-update', '-c', 'user.email=nll-client-update@localhost', *args], check=check)

    copied = 0
    for path in sorted(source.rglob('*')):
        relative = path.relative_to(source)
        if any(part in SKIP_DIRS for part in relative.parts) or not path.is_file():
            continue
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        copied += 1
    candidate('init', '-q', '-b', 'nll-deployed-baseline')
    candidate('config', 'core.autocrlf', 'false')
    candidate('add', '-A')
    candidate('commit', '-q', '-m', 'baseline: deployed NLL server source')
    baseline = candidate('rev-parse', 'HEAD').stdout.decode().strip()

    candidate('checkout', '-q', '-b', 'nll-update')
    version = []
    for name in VERSION_FILES:
        parent = upstream('show', f'{a.version_commit}^:{name}').replace(b'\r\n', b'\n')
        version.append({'file': name, 'candidateEqualedUpstreamParent': (target / name).read_bytes().replace(b'\r\n', b'\n') == parent})
        (target / name).write_bytes(upstream('show', f'{a.version_commit}:{name}'))
    candidate('add', '-A')
    candidate('commit', '-q', '-m', f'upstream {a.version_commit[:7]}: version files only')
    version_head = candidate('rev-parse', 'HEAD').stdout.decode().strip()

    deployed = {line.split('\t')[0] for line in Path(a.deployed_manifest).read_text().splitlines() if line}
    trials = []
    for commit in a.trial_commit:
        branch = f'trial-upstream-{commit[:7]}'
        candidate('checkout', '-q', '-b', branch, version_head)
        merge_dir = evidence / f'merge-{commit[:7]}'
        merge_dir.mkdir(parents=True, exist_ok=True)
        results = []
        for row in upstream('diff-tree', '--no-commit-id', '--name-status', '-r', commit).decode().splitlines():
            status, name = row.split('\t')[0], row.split('\t')[-1]
            destination = target / name
            if status == 'A' and not destination.exists():
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(upstream('show', f'{commit}:{name}'))
                results.append({'file': name, 'result': 'added'})
                continue
            if not destination.exists():
                results.append({'file': name, 'result': 'missing_in_nll'})
                continue
            (merge_dir / 'base').write_bytes(upstream('show', f'{commit}^:{name}').replace(b'\r\n', b'\n'))
            (merge_dir / 'incoming').write_bytes(upstream('show', f'{commit}:{name}').replace(b'\r\n', b'\n'))
            destination.write_bytes(destination.read_bytes().replace(b'\r\n', b'\n'))
            merged = subprocess.run(['git', 'merge-file', str(destination), str(merge_dir / 'base'), str(merge_dir / 'incoming')], capture_output=True)
            results.append({'file': name, 'result': 'clean' if merged.returncode == 0 else f'conflicts:{merged.returncode}',
                            'nllModifiedFile': name in deployed})
        candidate('add', '-A')
        candidate('commit', '-q', '-m', f'trial: 3-way merge of upstream {commit[:7]}')
        trials.append({'commit': commit, 'branch': branch, 'files': len(results),
                       'conflicts': [r['file'] for r in results if r['result'].startswith('conflicts')], 'results': results})
    candidate('checkout', '-q', 'nll-update')
    receipt = {'contractId': 'nll/server-candidate-preparation/v1', 'source': str(source), 'candidate': str(target),
               'copiedSourceFiles': copied, 'baselineCommit': baseline, 'versionCommit': a.version_commit,
               'versionHead': version_head, 'versionFiles': version, 'trials': trials, 'activated': False}
    (evidence / 'server-preparation.receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(json.dumps({k: receipt[k] for k in ('copiedSourceFiles', 'versionFiles')} |
                     {'trials': [{'commit': t['commit'], 'conflicts': t['conflicts']} for t in trials]}, indent=1))


if __name__ == '__main__':
    main()
