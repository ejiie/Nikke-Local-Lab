"""Synthetic acquisition lifecycle: cold export, warm reuse, drift and no shield."""
import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch

s = importlib.util.spec_from_file_location('acquisition', Path(__file__).with_name('acquire-nll-boss-fx.py'))
a = importlib.util.module_from_spec(s); s.loader.exec_module(a)


class Unity:
    @staticmethod
    def load(payload):
        value = json.loads(payload)
        return NS(objects=[NS(type=NS(name='AssetBundle'), read=lambda: NS(m_Container=[(value['key'], None)]))])


def setup(root):
    inputs = root / 'inputs'; inputs.mkdir()
    def write(name, blob=b'synthetic'):
        p = inputs / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(blob); return p
    plan = {'contractId': 'nll/native-fx-export-plan/v1', 'chunkRoot': str(inputs), 'localBundleRoot': str(inputs)}
    for role in ('embedded','inner','outer'):
        plan[role] = {k: {'path': str(write(role+k)), 'sha256': a.fx.digest(b'synthetic')} for k in ('body','signature')}
    write('chunk/store.cdb.idx'); plan['indexSha256'] = a.fx.digest(b'synthetic')
    p = write('plan.json', json.dumps(plan).encode()); tool = write('tool.dll')
    source = {'elementShield': {'modeCode': 'dynamic_affinity_linked', 'functionTypeCode': 'immune_other_element',
              'functionRecordCount': 1, 'skillBindingCount': 1, 'passiveBindingCount': 0,
              'functionSetSha256': 'f'*64, 'fxPrefabSetSha256': 'e'*64}}
    candidates = [{'fx': ['fx_synthetic_immune_barrier_'+color], 'fxPrefabSetSha256': a.fx.digest(color.encode())}
                  for color in ('red','blue','green','purple','yellow')]
    private = {'shieldFunctions': [candidates[3]], 'globalShieldFxCandidates': candidates}
    return NS(source_discovery=write('source.json',json.dumps(source).encode()),
              private_discovery=write('private.json',json.dumps(private).encode()), input_plan=p,
              input_plan_sha256=a.fx.fingerprint(p)['sha256'],catalog_tool=tool,catalog_tool_sha256=a.fx.fingerprint(tool)['sha256'],
              cache_root=root/'cache',output_root=root/'first/assets',dotnet_path='synthetic-dotnet')


def exporter(command, **_):
    plan = json.loads(Path(command[3]).read_bytes())
    key = a.fx.digest(plan['assets'][0]['prefabName'].encode())[:32]
    role = plan['assets'][0]['role']
    payload = json.dumps({'key':key,'synthetic':[2,1,3]}).encode()
    out = Path(command[5]); out.mkdir()
    (out/(role+'.bundle')).write_bytes(payload)
    binding = {'contractId':'nll/native-fx-binding/v1','statusCode':'offline_payload_bound',
               'nativeClientExecuted':False,'runtimeAdmissionStatusCode':'not_assessed','planSha256':command[4],
               'bindings':[{'role':role,'assetKey':key,'dependencies':[
                   {'key':'synthetic_'+key+'.bundle','isLocal':False,'sha256':a.fx.digest(payload),'byteLength':len(payload)}]}]}
    manifest = a.fx.encoded(binding); (out/'binding.private.json').write_bytes(manifest)
    receipt = {'contractId':'nll/native-fx-export-receipt/v1','planSha256':command[4],
               'manifestSha256':a.fx.digest(manifest),'statusCode':'offline_payload_bound','sourceMutationPerformed':False}
    return NS(returncode=0,stdout=json.dumps(receipt))


class AcquisitionTests(unittest.TestCase):
    def test_existing_cache_precedes_export_and_preserves_source(self):
        with TemporaryDirectory() as directory:
            args=setup(Path(directory)); args.existing_cache_root=Path(directory)/'existing'; args.existing_cache_root.mkdir()
            name=a.requested_names(a.profile.read_json(args.source_discovery),a.profile.read_json(args.private_discovery))[0]
            p=args.existing_cache_root/('effect-spot-monster_skill_library_assets_'+name+'_abc.bundle')
            payload=json.dumps({'key':'a'*32,'synthetic':[4,5]}).encode(); p.write_bytes(payload)
            with patch.object(a.subprocess,'run',side_effect=exporter) as process:
                result=a.acquire(args,Unity)
                self.assertEqual(process.call_count,4)
            self.assertEqual(result['assets'][0]['sourceCode'],'existing_server_cache')
            self.assertEqual(p.read_bytes(),payload)
            self.assertEqual((args.output_root/p.name).read_bytes(),payload)

    def test_cold_then_warm_reuses_exact_pinned_assets_without_export(self):
        with TemporaryDirectory() as directory:
            args=setup(Path(directory))
            originals={p:p.read_bytes() for p in (Path(directory)/'inputs').rglob('*') if p.is_file()}
            with patch.object(a.subprocess,'run',side_effect=exporter) as process:
                cold=a.acquire(args,Unity); self.assertEqual(process.call_count,5)
            args.output_root=Path(directory)/'second/assets'
            with patch.object(a.subprocess,'run',side_effect=AssertionError('warm exported')):
                warm=a.acquire(args,Unity)
            self.assertTrue(all(not r['cacheHit'] for r in cold['assets']))
            self.assertTrue(all(r['cacheHit'] for r in warm['assets']))
            self.assertEqual([r['sha256'] for r in cold['assets']],[r['sha256'] for r in warm['assets']])
            self.assertEqual(originals,{p:p.read_bytes() for p in originals})

    def test_corrupt_cache_fails_without_overwrite_or_export(self):
        with TemporaryDirectory() as directory:
            args=setup(Path(directory))
            with patch.object(a.subprocess,'run',side_effect=exporter): a.acquire(args,Unity)
            p=next(args.cache_root.rglob('electric.bundle')); changed=p.read_bytes()+b' '; p.write_bytes(changed)
            args.output_root=Path(directory)/'second/assets'
            with patch.object(a.subprocess,'run',side_effect=AssertionError('repair exported')):
                with self.assertRaisesRegex(a.fx.CandidateError,'payload_mismatch'): a.acquire(args,Unity)
            self.assertEqual(p.read_bytes(),changed)
            self.assertFalse((args.output_root.parent/'fx-acquisition.receipt.json').exists())

    def test_changed_catalog_rejects_even_with_warm_cache(self):
        with TemporaryDirectory() as directory:
            args=setup(Path(directory))
            with patch.object(a.subprocess,'run',side_effect=exporter): a.acquire(args,Unity)
            (Path(directory)/'inputs/innerbody').write_bytes(b'changed')
            args.output_root=Path(directory)/'second/assets'
            with self.assertRaisesRegex(a.fx.CandidateError,'catalog_drift'): a.acquire(args,Unity)
            self.assertFalse(args.output_root.exists())

    def test_absent_shield_does_not_require_client_or_create_cache(self):
        with TemporaryDirectory() as directory:
            args=setup(Path(directory))
            args.source_discovery.write_text(json.dumps({'elementShield':{'modeCode':'none'}}))
            args.input_plan.unlink()
            with patch.object(a.subprocess,'run',side_effect=AssertionError('no shield exported')):
                self.assertEqual(a.acquire(args,Unity)['statusCode'],'not_required')
            self.assertFalse(args.cache_root.exists()); self.assertFalse(args.output_root.exists())

    def test_catalog_missing_error_is_preserved_without_sealed_output(self):
        with TemporaryDirectory() as directory:
            args=setup(Path(directory))
            with patch.object(a.subprocess,'run',return_value=NS(returncode=10,stdout=json.dumps({'failureCode':'resource_fx_asset_missing'}))):
                with self.assertRaisesRegex(ValueError,'resource_fx_asset_missing'):a.acquire(args,Unity)
            self.assertFalse((args.output_root.parent/'fx-acquisition.receipt.json').exists())
            self.assertEqual(list(args.cache_root.iterdir()),[])


if __name__ == '__main__': unittest.main()
