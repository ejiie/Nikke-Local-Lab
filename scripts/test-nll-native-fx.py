"""Synthetic native-binding orchestration checks; no original assets or UnityPy."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("native_stage", Path(__file__).with_name("stage-nll-native-fx.py"))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class SyntheticUnity:
    @staticmethod
    def load(payload):
        key = json.loads(payload)["key"]
        obj = SimpleNamespace(type=SimpleNamespace(name="AssetBundle"),
                              read=lambda: SimpleNamespace(m_Container=[(key, None)]))
        return SimpleNamespace(objects=[obj])  # Deliberately no dependency-loading container API.


class NativeFxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "old"
        (self.source / "source").mkdir(parents=True)
        (self.source / "backup").mkdir()
        self.keys = {role: str(i + 1) * 32 for i, role in enumerate(stage.ROLES)}
        for role, key in self.keys.items():
            name = "source/electric.bundle" if role == "electric" else f"backup/{role}.bundle"
            (self.source / name).write_bytes(json.dumps({"key": key, "old": True}).encode())
        inputs = self.root / "inputs"
        inputs.mkdir()
        self.plan = inputs / "plan.json"
        self.tool = inputs / "tool.dll"
        self.tool.write_bytes(b"synthetic tool")
        plan = {"contractId": "nll/native-fx-export-plan/v1", "chunkRoot": str(inputs), "localBundleRoot": str(inputs)}
        for name in ("embedded", "inner", "outer"):
            plan[name] = {kind: {"path": str(inputs / (name + kind)), "sha256": "a" * 64} for kind in ("body", "signature")}
        self.plan.write_bytes(stage.fx.encoded(plan))
        self.args = SimpleNamespace(input_plan=self.plan, input_plan_sha256=stage.fx.fingerprint(self.plan)["sha256"],
                                    catalog_tool=self.tool, catalog_tool_sha256=stage.fx.fingerprint(self.tool)["sha256"],
                                    fx_candidate_root=self.source, fx_manifest_sha256="a" * 64, output_root=self.root / "output")

    def export(self, command, **kwargs):
        self.assertTrue(kwargs["capture_output"])
        self.assertEqual(kwargs["timeout"], 180)
        plan = json.loads(Path(command[3]).read_bytes())
        native = Path(command[5])
        native.mkdir()
        rows = []
        for item in plan["assets"]:
            file = native / (item["role"] + ".bundle")
            file.write_bytes(json.dumps({"key": item["key"], "old": False}).encode())
            rows.append({"role": item["role"], "assetKey": item["key"], "dependencies": [
                {"key": "synthetic.bundle", "isLocal": False, **stage.fx.fingerprint(file)}]})
        binding = {"contractId": "nll/native-fx-binding/v1", "planSha256": command[4], "bindings": rows,
                   "statusCode": "offline_payload_bound", "nativeClientExecuted": False,
                   "runtimeAdmissionStatusCode": "not_assessed"}
        manifest = native / "binding.private.json"
        manifest.write_bytes(stage.fx.encoded(binding))
        return SimpleNamespace(returncode=0, stdout=json.dumps({
            "contractId": "nll/native-fx-export-receipt/v1", "planSha256": command[4],
            "statusCode": "offline_payload_bound", "nativeClientExecuted": False, "runtimeAdmissionStatusCode": "not_assessed",
            "manifestSha256": stage.fx.fingerprint(manifest)["sha256"],
            "payloads": [{"roleCode": role, **stage.fx.fingerprint(native / (role + ".bundle"))} for role in stage.ROLES]}).encode())

    def run_stage(self, export=None, transform=None):
        with patch.object(stage.fx, "inspect_or_restore"), patch.object(stage.subprocess, "run", side_effect=export or self.export), \
                patch.object(stage.transform, "materialize", side_effect=transform or (lambda *args: (b"synthetic derived", {}))):
            return stage.stage(self.args, SyntheticUnity)

    def test_exact_container_keys_bind_new_bytes_without_http_or_admission(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = self.run_stage()
        self.assertEqual(result["statusCode"], "offline_native_candidate_verified")
        self.assertEqual(result["unchangedOriginalRoleCount"], 0)
        self.assertFalse(result["nativeClientExecuted"])
        self.assertFalse(result["legacyHttpRouteReused"])
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertTrue((self.args.output_root / "receipt.json").exists())
        self.assertTrue(all(key not in json.dumps(result) for key in self.keys.values()))

    def test_export_failure_never_seals_and_retry_requires_new_folder(self):
        with self.assertRaisesRegex(stage.fx.CandidateError, "native_fx_export_rejected"):
            self.run_stage(export=lambda *a, **kw: SimpleNamespace(returncode=10))
        self.assertFalse((self.args.output_root / "receipt.json").exists())
        with self.assertRaisesRegex(stage.fx.CandidateError, "native_fx_output_invalid"):
            self.run_stage()

    def test_export_receipt_cannot_hash_cleared_buffers_or_claim_admission(self):
        def bad_hash(*args, **kwargs):
            result = self.export(*args, **kwargs)
            receipt = json.loads(result.stdout)
            receipt["payloads"][0]["sha256"] = "f" * 64
            result.stdout = json.dumps(receipt).encode()
            return result
        with self.assertRaisesRegex(stage.fx.CandidateError, "native_fx_export_payload_drift"):
            self.run_stage(export=bad_hash)
        self.assertFalse((self.args.output_root / "receipt.json").exists())

    def test_transform_failure_keeps_private_diagnostic_without_success(self):
        def fail(*args):
            raise ValueError("synthetic transform failed")
        with self.assertRaises(ValueError):
            self.run_stage(transform=fail)
        self.assertTrue((self.args.output_root / "native/binding.private.json").exists())
        self.assertFalse((self.args.output_root / "receipt.json").exists())

    def test_old_source_or_plan_drift_before_final_seal_rejected(self):
        def drift(*args):
            self.plan.write_bytes(b"synthetic drift")
            return b"derived", {}
        with self.assertRaisesRegex(stage.fx.CandidateError, "native_fx_input_drift"):
            self.run_stage(transform=drift)
        self.assertFalse((self.args.output_root / "receipt.json").exists())

    def test_binding_rejects_key_hash_duplicate_role_and_false_admission(self):
        self.run_stage()
        native = self.args.output_root / "native"
        binding = json.loads((native / "binding.private.json").read_bytes())
        mutations = [lambda b: b.update(nativeClientExecuted=True),
                     lambda b: b.update(runtimeAdmissionStatusCode="ready"),
                     lambda b: b["bindings"][0].update(assetKey="wrong.prefab"),
                     lambda b: b["bindings"][0].update(role="fire"),
                     lambda b: b["bindings"][0]["dependencies"][0].update(sha256="f" * 64),
                     lambda b: b["bindings"][0]["dependencies"].append(b["bindings"][0]["dependencies"][0]),
                     lambda b: b["bindings"][0]["dependencies"][0].update(isLocal=0)]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                bad = copy.deepcopy(binding)
                mutation(bad)
                with self.assertRaises(stage.fx.CandidateError):
                    stage.validate_binding(bad, self.keys, native, SyntheticUnity)

    def test_original_bundle_key_mismatch_is_rejected_even_with_matching_file_hash(self):
        self.run_stage()
        native = self.args.output_root / "native"
        binding = json.loads((native / "binding.private.json").read_bytes())
        target = native / "electric.bundle"
        target.write_bytes(json.dumps({"key": "different.prefab"}).encode())
        binding["bindings"][0]["dependencies"][0].update(stage.fx.fingerprint(target))
        with self.assertRaisesRegex(stage.fx.CandidateError, "native_fx_payload_mismatch"):
            stage.validate_binding(binding, self.keys, native, SyntheticUnity)

    def test_container_without_unique_internal_key_is_rejected(self):
        for rows in ([], [("x.prefab", None), ("y.prefab", None)], [("wrong", None)]):
            unity = SimpleNamespace(load=lambda _: SimpleNamespace(objects=[SimpleNamespace(
                type=SimpleNamespace(name="AssetBundle"), read=lambda: SimpleNamespace(m_Container=rows))]))
            with self.assertRaises(stage.fx.CandidateError):
                stage.asset_key(b"synthetic", unity)


if __name__ == "__main__":
    unittest.main()
