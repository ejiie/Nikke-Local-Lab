"""Synthetic cold/warm behavior acquisition, catalog drift and cache corruption checks."""
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('acquire_behavior', Path(__file__).with_name('acquire-nll-boss-behavior.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fx = module.fx


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        inputs = self.root / 'inputs'
        inputs.mkdir()
        self.plan = {'contractId': 'nll/native-fx-export-plan/v1', 'chunkRoot': str(inputs / 'chunks'),
                     'localBundleRoot': str(inputs / 'local')}
        for role in ('embedded', 'inner', 'outer'):
            self.plan[role] = {}
            for kind in ('body', 'signature'):
                path = inputs / (role + '-' + kind)
                path.write_bytes((role + kind).encode())
                self.plan[role][kind] = {'path': str(path), 'sha256': fx.fingerprint(path)['sha256']}
        index = inputs / 'chunks/chunk/store.cdb.idx'
        index.parent.mkdir(parents=True)
        index.write_bytes(b'synthetic-index')
        self.plan['indexSha256'] = fx.fingerprint(index)['sha256']
        plan = inputs / 'plan.json'
        plan.write_bytes(fx.encoded(self.plan))
        tool = inputs / 'tool.dll'
        tool.write_bytes(b'synthetic-tool')
        self.args = SimpleNamespace(input_plan=plan, input_plan_sha256=fx.fingerprint(plan)['sha256'],
            catalog_tool=tool, catalog_tool_sha256=fx.fingerprint(tool)['sha256'], dotnet_path='synthetic',
            cache_root=self.root / 'cache', output_root=self.root / 'cold/acquired-behavior')

    def export(self, argv, **kwargs):
        output = Path(argv[-1]); output.mkdir()
        payload = b'UnityFS\0synthetic-current-behavior'
        leaf = 'externalbehavior_assets_all_ab12.bundle'
        (output / leaf).write_bytes(payload)
        receipt = {'contractId': 'nll/native-behavior-export/v1', 'planSha256': argv[-2],
                   'bundle': leaf, 'statusCode': 'offline_payload_bound', 'sourceMutationPerformed': False,
                   'nativeClientExecuted': False, 'sha256': fx.digest(payload), 'byteLength': len(payload)}
        return SimpleNamespace(returncode=0, stdout=json.dumps(receipt).encode())

    def test_cold_then_warm_exports_once_and_preserves_source(self):
        with patch.object(module.subprocess, 'run', side_effect=self.export) as export:
            cold = module.acquire(self.args)
            self.args.output_root = self.root / 'warm/acquired-behavior'
            warm = module.acquire(self.args)
        self.assertEqual(1, export.call_count)
        self.assertFalse(cold['cacheHit']); self.assertTrue(warm['cacheHit'])
        self.assertEqual(cold['asset'], warm['asset'])
        module.shared.verify_inputs(self.plan)

    def test_changed_catalog_rejects_even_with_warm_cache(self):
        with patch.object(module.subprocess, 'run', side_effect=self.export): module.acquire(self.args)
        Path(self.plan['inner']['body']['path']).write_bytes(b'changed')
        self.args.output_root = self.root / 'drift/acquired-behavior'
        with patch.object(module.subprocess, 'run') as export, self.assertRaisesRegex(fx.CandidateError, 'native_fx_catalog_drift'):
            module.acquire(self.args)
        export.assert_not_called()

    def test_corrupt_cache_does_not_overwrite_or_fall_back(self):
        with patch.object(module.subprocess, 'run', side_effect=self.export): module.acquire(self.args)
        bundle = next(self.args.cache_root.rglob('*.bundle'))
        bundle.write_bytes(b'corrupt')
        self.args.output_root = self.root / 'corrupt/acquired-behavior'
        with patch.object(module.subprocess, 'run') as export, self.assertRaisesRegex(fx.CandidateError, 'native_behavior_cache_binding_changed'):
            module.acquire(self.args)
        export.assert_not_called(); self.assertEqual(b'corrupt', bundle.read_bytes())

    def test_missing_current_bundle_cannot_use_unrelated_old_bundle(self):
        self.args.cache_root.mkdir()
        (self.args.cache_root / 'externalbehavior_assets_all_ab12.bundle').write_bytes(b'old')
        with patch.object(module.subprocess, 'run', return_value=SimpleNamespace(returncode=1,
                stdout=b'{"failureCode":"resource_behavior_bundle_missing"}')):
            with self.assertRaisesRegex(ValueError, 'resource_behavior_bundle_missing'): module.acquire(self.args)
        self.assertFalse(self.args.output_root.exists())


if __name__ == '__main__': unittest.main()
