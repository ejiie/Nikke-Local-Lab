"""Acquire the current catalog's behavior bundle once, without stale-cache fallback."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('behavior_acquisition_fx', Path(__file__).with_name('acquire-nll-boss-fx.py'))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
fx = shared.fx


def verify_entry(root, plan_sha):
    receipt = json.loads(fx.plain_path(root / 'receipt.json', file=True).read_bytes())
    fx.require(receipt['contractId'] == 'nll/native-behavior-export/v1'
               and receipt['planSha256'] == plan_sha and receipt['statusCode'] == 'offline_payload_bound'
               and receipt['sourceMutationPerformed'] is False and receipt['nativeClientExecuted'] is False
               and re.fullmatch(r'externalbehavior_assets_all_[0-9a-f]+\.bundle', receipt['bundle']),
               'native_behavior_cache_binding_changed')
    bundle = fx.plain_path(root / 'native' / receipt['bundle'], file=True)
    fx.require(fx.fingerprint(bundle) == {k: receipt[k] for k in ('sha256', 'byteLength')},
               'native_behavior_cache_binding_changed')
    return receipt, bundle


def acquire(args):
    plan_path = fx.plain_path(args.input_plan, file=True)
    tool = fx.plain_path(args.catalog_tool, file=True)
    def pins():
        fx.require(fx.fingerprint(plan_path)['sha256'] == args.input_plan_sha256
                   and fx.fingerprint(tool)['sha256'] == args.catalog_tool_sha256, 'native_behavior_input_drift')
    pins()
    plan = json.loads(plan_path.read_bytes())
    fx.require(plan['contractId'] == 'nll/native-fx-export-plan/v1' and 'assets' not in plan,
               'native_behavior_plan_invalid')
    shared.verify_inputs(plan)
    cache, output = (fx.plain_path(p) for p in (args.cache_root, args.output_root))
    protected = [tool.parent, plan_path.parent, Path(plan['chunkRoot']), Path(plan['localBundleRoot'])]
    protected += [Path(plan[r][k]['path']).parent for r in ('embedded', 'inner', 'outer') for k in ('body', 'signature')]
    if sys.platform == 'win32': protected += [Path('C:/NLL'), Path('C:/NIKKE')]
    for target in (cache, output):
        fx.require(all(target != p and target not in p.parents and p not in target.parents for p in protected),
                   'native_behavior_output_invalid')
    fx.require(not output.exists() and cache != output and cache not in output.parents and output not in cache.parents,
               'native_behavior_output_invalid')
    cache.mkdir(parents=True, exist_ok=True)
    entry = fx.plain_path(cache / args.input_plan_sha256)
    hit = entry.is_dir()
    if not hit:
        with tempfile.TemporaryDirectory(prefix='behavior-', dir=cache) as temporary:
            work = Path(temporary)
            result = subprocess.run([args.dotnet_path, str(tool), 'export-native-behavior', str(plan_path),
                                     args.input_plan_sha256, str(work / 'native')],
                                    capture_output=True, timeout=180, check=False)
            if result.returncode:
                try: code = json.loads(result.stdout).get('failureCode', '')
                except (ValueError, AttributeError): code = ''
                raise ValueError(code if re.fullmatch(r'resource_(behavior|fx)_[a-z_]+', code)
                                 else 'native_behavior_acquisition_failed')
            fx.new_file(work / 'receipt.json', fx.encoded(json.loads(result.stdout)))
            verify_entry(work, args.input_plan_sha256)
            try: work.rename(entry)
            except OSError:
                if not entry.is_dir(): raise
    receipt, original = verify_entry(entry, args.input_plan_sha256)
    output.mkdir(parents=True)
    target = output / original.name
    shutil.copyfile(original, target)
    pin = {k: receipt[k] for k in ('sha256', 'byteLength')}
    fx.require(fx.fingerprint(target) == pin and fx.fingerprint(original) == pin, 'native_behavior_output_drift')
    shared.verify_inputs(plan)
    pins()
    evidence = {'contractId': 'nll/boss-behavior-acquisition/v1', 'statusCode': 'acquired',
                'inputPlanSha256': args.input_plan_sha256, 'cacheHit': hit, 'asset': pin,
                'sourceCode': 'catalog_bound_cache' if hit else 'native_client',
                'nativeClientExecuted': False, 'sourceMutationPerformed': False}
    fx.new_file(output.parent / 'behavior-acquisition.receipt.json', fx.encoded(evidence))
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('input-plan', 'catalog-tool', 'cache-root', 'output-root'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('input-plan-sha256', 'catalog-tool-sha256', 'dotnet-path'):
        parser.add_argument('--' + name, required=True)
    try:
        print(json.dumps(acquire(parser.parse_args())))
        return 0
    except Exception as error:
        code = str(error)
        print(code if re.fullmatch(r'(native_(behavior|fx)|resource_(behavior|fx))_[a-z_]+', code)
              else 'native_behavior_acquisition_failed', file=sys.stderr)
        return 1


if __name__ == '__main__': raise SystemExit(main())
