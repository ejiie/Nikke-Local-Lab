"""Publish five original Union Hard boss behavior closures as one immutable unit."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, code):
    if not condition:
        raise ValueError('boss_union_' + code)


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def write(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)


def assemble(args):
    config_path, output = args.configuration.resolve(), args.output.resolve()
    require(digest(config_path) == args.configuration_sha256, 'configuration_changed')
    config = read(config_path)
    settings = config['unionRaid']
    catalog_path = Path(settings['catalogPath'])
    require(digest(catalog_path) == settings['catalogSha256'], 'catalog_changed')
    request = read(output / 'request.json')
    require(request['catalogSha256'] == settings['catalogSha256'], 'catalog_changed')
    season = request['seasonNumber']
    require(type(season) is int and 0 < season < 1000, 'season_invalid')
    catalog = read(catalog_path)
    require(catalog['contractId'] == 'nll/union-raid-hard-catalog/v1', 'catalog_invalid')
    rows = [s for s in catalog['seasons'] if s['seasonNumber'] == season]
    require(len(rows) == 1 and rows[0]['statusCode'] == 'available', 'hard_unavailable')
    require([b['order'] for b in rows[0]['bosses']] == list(range(1, 6)), 'five_bosses_unresolved')
    # Verify executable source pins before any private input is supplied.
    for pin in settings['inputPins']:
        require(digest(Path(pin['path'])) == pin['sha256'], 'input_changed')
    repo = Path(config['repositoryRoot'])
    native = config['nativePipeline']
    subprocess.run([config['pythonPath'], str(repo / 'scripts/acquire-nll-boss-behavior.py'),
        '--input-plan', native['inputPlanPath'], '--input-plan-sha256', native['inputPlanSha256'],
        '--catalog-tool', native['catalogToolPath'], '--catalog-tool-sha256', native['catalogToolSha256'],
        '--dotnet-path', native['dotnetPath'], '--cache-root', settings['behaviorCacheRoot'],
        '--output-root', str(output / 'behavior')], check=True, capture_output=True, timeout=240)
    bundles = list((output / 'behavior').glob('*.bundle'))
    require(len(bundles) == 1, 'behavior_bundle_missing')
    source = catalog_path.parent / f'season-{season}'
    runtime = source / 'runtime.private.json'
    source_pins = {str(p.relative_to(source)): digest(p) for p in source.rglob('*.json')}
    source_set = '\n'.join(sorted(p.replace('\\', '/') + ' ' + sha for p, sha in source_pins.items()))
    require(hashlib.sha256(source_set.encode()).hexdigest() == rows[0]['sourceSetSha256'], 'source_changed')
    results = []
    for order in range(1, 6):
        boss = source / f'boss-{order}'
        receipt = output / f'boss-{order}.json'
        subprocess.run([config['pythonPath'], str(repo / 'scripts/inspect-nll-boss-behavior-assets.py'),
            '--private-discovery', str(boss / 'discovery.private.json'),
            '--source-discovery', str(boss / 'discovery.json'), '--behavior-bundle', str(bundles[0]),
            '--output', str(receipt), '--unitypy-root', config['unityPyRoot']],
            check=True, capture_output=True, timeout=240)
        evidence = read(receipt)
        require(evidence['assetClosureStatusCode'] == 'resolved' and not evidence['sourceAssetModified'], 'behavior_unresolved')
        results.append({'order': order, 'receiptSha256': digest(receipt),
                        'graphSha256': evidence['canonicalGraphSha256']})
    require(all(digest(source / p) == sha for p, sha in source_pins.items()), 'source_changed')
    require(digest(catalog_path) == settings['catalogSha256'] and digest(config_path) == args.configuration_sha256, 'input_changed')
    receipt = {'schemaVersion': 1, 'contractId': 'nll/union-raid-hard-assembly/v1',
        'seasonNumber': season, 'catalogSha256': settings['catalogSha256'], 'bosses': results,
        'runtimeSha256': digest(runtime), 'behaviorBundleSha256': digest(bundles[0]),
        'elementModified': False, 'fxModified': False, 'nativeClientExecuted': False}
    registry = Path(settings['registryRoot']).resolve()
    require(not registry.is_relative_to(Path('C:/NIKKE').resolve()) and registry != registry.parent, 'registry_invalid')
    registry.mkdir(parents=True, exist_ok=True)
    destination = registry / f"{season}-{settings['catalogSha256']}"
    # No partial season becomes visible. Duplicate work must agree byte-for-byte.
    if destination.exists():
        require(read(destination / 'receipt.json') == receipt and digest(destination / 'runtime.private.json') == receipt['runtimeSha256'], 'publication_conflict')
    else:
        with tempfile.TemporaryDirectory(prefix='.union-', dir=registry) as temporary:
            staging = Path(temporary) / 'ready'
            staging.mkdir()
            shutil.copyfile(runtime, staging / 'runtime.private.json')
            for order in range(1, 6):
                shutil.copyfile(output / f'boss-{order}.json', staging / f'boss-{order}.json')
            write(staging / 'receipt.json', receipt)
            staging.rename(destination)
    write(output / 'assembly.json', receipt)
    # Retain the shared source cache, not another bundle for every season.
    bundles[0].unlink()
    (output / 'behavior').rmdir()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, required=True)
    parser.add_argument('--configuration-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        assemble(args)
    except Exception as error:
        code = str(error)
        if not code.startswith('boss_union_') or not code.replace('_', '').isalnum():
            code = 'boss_union_assembly_failed'
        (args.output / 'failure-code.txt').write_text(code, encoding='utf-8')
        raise SystemExit(1)
