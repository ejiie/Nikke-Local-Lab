"""Bind and transform installed native FX offline; never publish, patch or launch.

The pinned input plan supplies only reviewed local catalog/store paths and hashes.
Asset keys come from a verified previous candidate, not a filename-stem guess.
All plans, bindings and game bytes are PRIVATE outputs, never Git/CI fixtures.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fx = load("native_fx_candidate", "materialize-nll-shield-fx-candidate.py")
transform = load("native_fx_transform", "materialize-nll-shield-fx-transform-variant.py")
ROLES = ("electric", "fire", "wind", "iron")


def asset_key(payload, unity):
    # Environment.container dereferences preload dependencies and may scan the
    # working tree. Inspect only the in-bundle container table, with no dereference.
    containers = [obj.read().m_Container for obj in unity.load(payload).objects
                  if obj.type.name == "AssetBundle"]
    fx.require(len(containers) == 1 and len(containers[0]) == 1,
               "native_fx_container_ambiguous")
    key = containers[0][0][0]
    fx.require(isinstance(key, str) and (key.endswith(".prefab") or re.fullmatch("[0-9a-f]{32}", key)),
               "native_fx_key_invalid")
    return key


def validate_binding(binding, expected_keys, root, unity):
    fx.require(binding.get("contractId") == "nll/native-fx-binding/v1"
               and binding.get("statusCode") == "offline_payload_bound"
               and binding.get("nativeClientExecuted") is False
               and binding.get("runtimeAdmissionStatusCode") == "not_assessed",
               "native_fx_binding_invalid")
    rows = binding.get("bindings", [])
    fx.require(len(rows) == 4 and {r["role"] for r in rows} == set(ROLES), "native_fx_roles_invalid")
    for row in rows:
        role = row["role"]
        fx.require(row["assetKey"] == expected_keys[role], "native_fx_key_mismatch")
        dependencies = row["dependencies"]
        fx.require(all(type(d["isLocal"]) is bool for d in dependencies), "native_fx_dependency_invalid")
        remote = [d for d in dependencies if not d["isLocal"]]
        fx.require(len(remote) == 1, "native_fx_remote_ambiguous")
        path = fx.plain_path(root / (role + ".bundle"), file=True)
        payload = path.read_bytes()
        fx.require(fx.fingerprint(path) == {k: remote[0][k] for k in ("byteLength", "sha256")}
                   and asset_key(payload, unity) == expected_keys[role], "native_fx_payload_mismatch")


def stage(args, unity):
    source = fx.plain_path(args.fx_candidate_root)
    fx.inspect_or_restore(source, args.fx_manifest_sha256)
    plan_path = fx.plain_path(args.input_plan, file=True)
    tool = fx.plain_path(args.catalog_tool, file=True)
    tool_inventory = {p.name: fx.fingerprint(fx.plain_path(p, file=True)) for p in tool.parent.iterdir() if p.is_file()}
    fx.require(fx.fingerprint(plan_path)["sha256"] == args.input_plan_sha256
               and fx.fingerprint(tool)["sha256"] == args.catalog_tool_sha256, "native_fx_input_drift")
    plan = json.loads(plan_path.read_bytes())
    fx.require(plan["contractId"] == "nll/native-fx-export-plan/v1" and "assets" not in plan,
               "native_fx_plan_invalid")
    output = fx.plain_path(args.output_root)
    protected = [source, plan_path.parent, tool.parent, Path(plan["chunkRoot"]), Path(plan["localBundleRoot"])]
    protected += [Path(plan[name][kind]["path"]).parent for name in ("embedded", "inner", "outer")
                  for kind in ("body", "signature")]
    if sys.platform == "win32":
        protected += [Path("C:/NLL"), Path("C:/NIKKE")]
    fx.require(not output.exists() and output.parent.is_dir() and all(
        output != p and output not in p.parents and p not in output.parents for p in protected),
        "native_fx_output_invalid")
    originals = {role: source / ("source/electric.bundle" if role == "electric" else f"backup/{role}.bundle")
                 for role in ROLES}
    old_pins = {role: fx.fingerprint(path) for role, path in originals.items()}
    keys = {role: asset_key(fx.plain_path(path, file=True).read_bytes(), unity) for role, path in originals.items()}
    fx.require(len(set(keys.values())) == 4, "native_fx_keys_ambiguous")
    plan["assets"] = [{"role": role, "key": keys[role]} for role in ROLES]
    output.mkdir()
    encoded = fx.encoded(plan)
    private_plan = output / "export-plan.private.json"
    fx.new_file(private_plan, encoded)
    native = output / "native"
    result = subprocess.run(["dotnet", str(tool), "export-native-fx", str(private_plan), fx.digest(encoded), str(native)],
                            capture_output=True, timeout=180, check=False)
    fx.require(result.returncode == 0, "native_fx_export_rejected")
    receipt = json.loads(result.stdout)
    manifest = native / "binding.private.json"
    fx.require(receipt["manifestSha256"] == fx.fingerprint(manifest)["sha256"], "native_fx_manifest_drift")
    fx.require(receipt.get("contractId") == "nll/native-fx-export-receipt/v1"
               and receipt.get("planSha256") == fx.digest(encoded)
               and receipt.get("statusCode") == "offline_payload_bound"
               and receipt.get("nativeClientExecuted") is False
               and receipt.get("runtimeAdmissionStatusCode") == "not_assessed"
               and len(receipt.get("payloads", [])) == 4
               and {p["roleCode"] for p in receipt["payloads"]} == set(ROLES), "native_fx_export_receipt_invalid")
    for payload in receipt["payloads"]:
        fx.require(fx.fingerprint(native / (payload["roleCode"] + ".bundle")) ==
                   {k: payload[k] for k in ("byteLength", "sha256")}, "native_fx_export_payload_drift")
    binding = json.loads(manifest.read_bytes())
    fx.require(binding["planSha256"] == fx.digest(encoded), "native_fx_plan_mismatch")
    validate_binding(binding, keys, native, unity)
    rows = []
    for role in ("fire", "wind", "iron"):
        derived, evidence = transform.materialize(native / "electric.bundle", native / (role + ".bundle"), unity)
        fx.new_file(output / (role + ".bundle"), derived)
        rows.append({"roleCode": role, "original": fx.fingerprint(native / (role + ".bundle")),
                     "overlay": {"sha256": fx.digest(derived), "byteLength": len(derived)}, "evidence": evidence})
    validate_binding(binding, keys, native, unity)
    fx.inspect_or_restore(source, args.fx_manifest_sha256)
    fx.require(old_pins == {role: fx.fingerprint(path) for role, path in originals.items()}
               and fx.fingerprint(plan_path)["sha256"] == args.input_plan_sha256
               and tool_inventory == {p.name: fx.fingerprint(fx.plain_path(p, file=True))
                                      for p in tool.parent.iterdir() if p.is_file()}, "native_fx_input_drift")
    final = {"contractId": "nll/native-fx-candidate-receipt/v1", "statusCode": "offline_native_candidate_verified",
             "inputPlanSha256": args.input_plan_sha256, "exportPlanSha256": fx.digest(encoded),
             "catalogToolSha256": args.catalog_tool_sha256, "sourceCandidateManifestSha256": args.fx_manifest_sha256,
             "catalogToolInventorySha256": fx.digest(fx.encoded(tool_inventory)),
             "bindingManifestSha256": receipt["manifestSha256"], "entries": rows,
             "unchangedOriginalRoleCount": sum(old_pins[role] == fx.fingerprint(native / (role + ".bundle")) for role in ROLES),
             "runtimeAdmissionStatusCode": "not_assessed", "nativeClientExecuted": False,
             "installedFilesModified": False, "legacyHttpRouteReused": False}
    fx.new_file(output / "receipt.json", fx.encoded(final))
    return final


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("input-plan", "catalog-tool", "fx-candidate-root", "output-root", "unitypy-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("input-plan-sha256", "catalog-tool-sha256", "fx-manifest-sha256"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        sys.path.insert(0, str(fx.plain_path(args.unitypy_root)))
        import UnityPy
        print(json.dumps(stage(args, UnityPy), sort_keys=True))
        return 0
    except Exception as error:
        code = str(error)
        print(code if re.fullmatch("(native|shield)_fx_[a-z0-9_]+", code) else "native_fx_stage_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
