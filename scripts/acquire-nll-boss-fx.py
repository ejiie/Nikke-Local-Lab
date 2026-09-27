"""Acquire discovered shield FX once into a catalog-bound private cache.

Only boss onboarding calls this tool. Existing server FX are considered first;
their exact pins are rechecked during assembly and native composition. A warm entry reads small pinned metadata
and the selected FX; it never exports again or hashes the complete client store.
An unsealed/changed cache entry is an error, not permission to overwrite it.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent))
import importlib.util


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


profile = module('acquire_profile', 'materialize-nll-boss-runtime-profile.py')
native = module('acquire_native', 'stage-nll-native-fx.py')
fx = native.fx


def requested_names(source, private):
    names = set()
    def collect(_, prefabs):
        names.update(prefabs)
        return {'assetBundleSetSha256': '0' * 64, 'assetBundles': []}
    profile.resolve_shield(source, private, Path('.'), collect)
    fx.require(all(re.fullmatch('[A-Za-z0-9_-]{1,256}', n) for n in names), 'native_fx_name_invalid')
    return sorted(names)


def verify_inputs(plan):
    for role in ('embedded', 'inner', 'outer'):
        for kind in ('body', 'signature'):
            pin = plan[role][kind]
            fx.require(fx.fingerprint(fx.plain_path(Path(pin['path']), file=True))['sha256'] == pin['sha256'],
                       'native_fx_catalog_drift')
    index = fx.plain_path(Path(plan['chunkRoot']) / 'chunk/store.cdb.idx', file=True)
    fx.require(fx.fingerprint(index)['sha256'] == plan['indexSha256'], 'native_fx_index_drift')


def verify_entry(root, plan_sha, unity):
    receipt = json.loads(fx.plain_path(root / 'receipt.json', file=True).read_bytes())
    manifest = fx.plain_path(root / 'native/binding.private.json', file=True)
    fx.require(receipt['contractId'] == 'nll/native-fx-export-receipt/v1'
               and receipt['planSha256'] == plan_sha and receipt['manifestSha256'] == fx.fingerprint(manifest)['sha256']
               and receipt['statusCode'] == 'offline_payload_bound' and receipt['sourceMutationPerformed'] is False,
               'native_fx_cache_binding_changed')
    binding = json.loads(manifest.read_bytes())
    fx.require(binding['planSha256'] == plan_sha and len(binding['bindings']) == 1,
               'native_fx_cache_binding_changed')
    row = binding['bindings'][0]
    fx.require(row['role'] in profile.ELEMENTS, 'native_fx_cache_binding_changed')
    native.validate_binding(binding, {row['role']: row['assetKey']}, root / 'native', unity)
    remote = [d for d in row['dependencies'] if not d['isLocal']]
    fx.require(len(remote) == 1 and re.fullmatch('[A-Za-z0-9_-]{1,512}\\.bundle', remote[0]['key']),
               'native_fx_cache_binding_changed')
    return dict(remote[0], role=row['role'])


def acquire(args, unity):
    source = profile.read_json(args.source_discovery)
    private = profile.read_json(args.private_discovery)
    names = requested_names(source, private)
    if not names:
        return {'contractId': 'nll/boss-fx-acquisition/v1', 'statusCode': 'not_required', 'assetCount': 0}
    plan_path = fx.plain_path(args.input_plan, file=True)
    tool = fx.plain_path(args.catalog_tool, file=True)
    fx.require(fx.fingerprint(plan_path)['sha256'] == args.input_plan_sha256
               and fx.fingerprint(tool)['sha256'] == args.catalog_tool_sha256, 'native_fx_input_drift')
    plan = json.loads(plan_path.read_bytes())
    fx.require(plan['contractId'] == 'nll/native-fx-export-plan/v1' and 'assets' not in plan, 'native_fx_plan_invalid')
    verify_inputs(plan)
    cache = fx.plain_path(args.cache_root)
    output = fx.plain_path(args.output_root)
    protected = [tool.parent, plan_path.parent, Path(plan['chunkRoot']), Path(plan['localBundleRoot'])]
    protected += [Path(plan[r][k]['path']).parent for r in ('embedded','inner','outer') for k in ('body','signature')]
    if sys.platform == 'win32': protected += [Path('C:/NLL'), Path('C:/NIKKE')]
    for target in (cache, output):
        fx.require(all(target != p and target not in p.parents and p not in target.parents for p in protected),
                   'native_fx_output_invalid')
    fx.require(not output.exists() and cache != output and cache not in output.parents and output not in cache.parents,
               'native_fx_output_invalid')
    cache.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True)
    rows = []
    for name in names:
        existing = getattr(args, 'existing_cache_root', None)
        if existing is not None:
            existing = fx.plain_path(existing)
            pattern = re.compile(r'^effect-spot-monster_skill_library_assets_' + re.escape(name) + r'_[0-9a-f]+\.bundle$', re.I)
            matches = [fx.plain_path(p, file=True) for p in existing.rglob('*.bundle') if pattern.fullmatch(p.name)]
            if matches:
                identities = {(fx.fingerprint(p)['sha256'], p.stat().st_size) for p in matches}
                fx.require(len(identities) == 1, 'native_fx_existing_cache_ambiguous')
                original = matches[0]; pin = fx.fingerprint(original)
                # Reading the actual container rejects opaque or malformed files.
                native.asset_key(original.read_bytes(), unity)
                target = output / original.name
                if not target.exists(): shutil.copyfile(original, target)
                fx.require(fx.fingerprint(target) == pin and fx.fingerprint(original) == pin, 'native_fx_input_drift')
                rows.append({'prefabNameSha256': fx.digest(name.encode()), 'cacheHit': True,
                             'sourceCode': 'existing_server_cache', **pin})
                continue
        color = profile.strip_color(name)[1]
        role = next(element for element, value in profile.COLORS_BY_ELEMENT.items() if value == color)
        request = dict(plan, assets=[{'role': role, 'prefabName': name}])
        encoded = fx.encoded(request); request_sha = fx.digest(encoded)
        entry = cache / request_sha
        fx.plain_path(entry)
        hit = entry.is_dir()
        if not hit:
            with tempfile.TemporaryDirectory(prefix='acquire-', dir=cache) as temporary:
                work = Path(temporary)
                fx.new_file(work / 'plan.private.json', encoded)
                result = subprocess.run([args.dotnet_path, str(tool), 'export-native-fx',
                                         str(work / 'plan.private.json'), request_sha, str(work / 'native')],
                                        capture_output=True, timeout=180, check=False)
                if result.returncode:
                    # Only controlled codes, never native parser messages or identifiers.
                    try: code = json.loads(result.stdout).get('failureCode', '')
                    except (ValueError, AttributeError): code = ''
                    raise ValueError(code if re.fullmatch('resource_fx_[a-z_]+', code) else 'native_fx_acquisition_failed')
                receipt = json.loads(result.stdout)
                fx.new_file(work / 'receipt.json', fx.encoded(receipt))
                verify_entry(work, request_sha, unity)
                # Publish the complete cache entry atomically; a concurrent winner
                # is revalidated below. Never replace existing cache bytes.
                try: work.rename(entry)
                except OSError:
                    if not entry.is_dir(): raise
        remote = verify_entry(entry, request_sha, unity)
        target = output / remote['key']
        pin = {k: remote[k] for k in ('sha256', 'byteLength')}
        if target.exists(): fx.require(fx.fingerprint(target) == pin, 'native_fx_asset_ambiguous')
        else: shutil.copyfile(entry / 'native' / (role + '.bundle'), target)
        fx.require(fx.fingerprint(target) == pin, 'native_fx_output_drift')
        rows.append({'prefabNameSha256': fx.digest(name.encode()), 'cacheHit': hit,
                     'sourceCode': 'catalog_bound_cache' if hit else 'native_client', **pin})
    verify_inputs(plan)
    fx.require(fx.fingerprint(plan_path)['sha256'] == args.input_plan_sha256
               and fx.fingerprint(tool)['sha256'] == args.catalog_tool_sha256, 'native_fx_input_drift')
    receipt = {'contractId': 'nll/boss-fx-acquisition/v1', 'statusCode': 'acquired',
               'inputPlanSha256': args.input_plan_sha256, 'assetCount': len(rows), 'assets': rows,
               'nativeClientExecuted': False, 'sourceMutationPerformed': False}
    fx.new_file(output.parent / 'fx-acquisition.receipt.json', fx.encoded(receipt))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source-discovery','private-discovery','input-plan','catalog-tool','cache-root','output-root','unitypy-root'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('input-plan-sha256','catalog-tool-sha256','dotnet-path'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--existing-cache-root', type=Path)
    args = parser.parse_args()
    try:
        sys.path.insert(0, str(fx.plain_path(args.unitypy_root))); import UnityPy
        print(json.dumps(acquire(args, UnityPy))); return 0
    except Exception as error:
        code = str(error)
        print(code if re.fullmatch('(native_fx|resource_fx|boss_profile)_[a-z_]+', code)
              else 'native_fx_acquisition_failed', file=sys.stderr)
        return 1


if __name__ == '__main__': raise SystemExit(main())
