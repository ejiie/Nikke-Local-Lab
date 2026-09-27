"""Stage one immutable execution-local FX route; never launch or admit a boss.

The private manifest contains an exact local cache request path. It and the copied
game files must remain ignored. Cleanup is owned by ExecutionAssetOverlay, not by
this script, and never follows the runtime's shared-cache junction.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys


spec = importlib.util.spec_from_file_location(
    "onboarding_delivery", Path(__file__).with_name("verify-nll-boss-onboarding-candidate.py"))
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)
fx = candidate.fx


def request_path(value):
    candidate.require(isinstance(value, str) and len(value) <= 2048
                      and re.fullmatch(r"/(PC|prdenv)/[A-Za-z0-9_./-]+\.bundle", value)
                      and all(part not in ("", ".", "..") for part in value[1:].split("/")),
                      "execution_fx_request_path_invalid")
    return value


def stage(root, seal_sha, source_pack, cache, output, execution_code, weakness):
    candidate.require(re.fullmatch("[0-9a-f]{32}", execution_code) is not None
                      and weakness in candidate.TARGETS, "execution_fx_binding_invalid")
    root, cache, output = (fx.plain_path(path) for path in (root, cache, output))
    for protected in (root, cache, fx.plain_path(source_pack, file=True).parent):
        candidate.require(output != protected and output not in protected.parents
                          and protected not in output.parents, "execution_fx_output_overlaps_input")
    candidate.require(not os.path.lexists(output) and output.parent.is_dir(),
                      "execution_fx_output_exists_or_parent_missing")
    sealed = candidate.verify(root, seal_sha, source_pack, cache)
    target = candidate.TARGETS[weakness]
    profile = candidate.read(root / "boss-runtime-variant.profile.json")
    if profile["schemaVersion"] == 4:
        rows = candidate.recipes.verify_profile_binding(profile, root / "shield-fx-preparation")
        selected = [r for r in rows if r["bossElementCode"] == target and r["operationCode"] == "adjust_candidate"]
        candidate.require(len(selected) == 1, "execution_fx_overlay_not_required_or_mapping_not_unique")
        row = selected[0]
        original_pin, overlay_pin = row["targetBundle"], row["outputBundle"]
        overlay_path = root / "shield-fx-preparation" / (overlay_pin["sha256"] + ".bundle")
    else:
        candidate.require(target in fx.ROLES and sealed["shieldFxCandidateManifestSha256"] is not None,
                          "execution_fx_overlay_not_required")
        profile, rows = fx.load_profile(root / "boss-runtime-variant.profile.json", sealed["profileSha256"])
        row = next(row for row in rows if row["bossElementCode"] == target)
        original_pin, overlay_pin = fx.pin(row, "targetBundle"), fx.pin(row, "variantBundle")
        overlay_path = root / f"shield-fx-candidate/overlay/{target}.bundle"
    # Every hash-identical cache alias needs its own route. This first delivery
    # contract only supports one; never select an arbitrary first match.
    matches = []
    for directory, children, names in os.walk(cache, followlinks=False):
        children[:] = [name for name in children if not (
            Path(directory, name).is_symlink()
            or getattr(Path(directory, name).lstat(), "st_file_attributes", 0) & 0x400)]
        for name in names:
            path = Path(directory, name)
            if path.suffix == ".bundle" and path.stat().st_size == original_pin["byteLength"]:
                if fx.fingerprint(fx.plain_path(path, file=True)) == original_pin:
                    matches.append(path)
    candidate.require(len(matches) == 1, "execution_fx_request_path_ambiguous_or_missing")
    route = request_path("/" + matches[0].relative_to(cache).as_posix())
    original = matches[0].read_bytes()
    overlay = fx.plain_path(overlay_path, file=True).read_bytes()
    for payload, pin in ((original, original_pin), (overlay, overlay_pin)):
        candidate.require({"sha256": fx.digest(payload), "byteLength": len(payload)} == pin,
                          "execution_fx_input_drifted")
    manifest = {"schemaVersion": 1, "contractId": "nll/execution-fx-delivery/v1",
                "executionCode": execution_code, "candidateSealSha256": seal_sha,
                "profileSha256": sealed["profileSha256"], "weaknessCode": weakness,
                "bossElementCode": target, "requestPath": route,
                "original": original_pin, "overlay": overlay_pin,
                "runtimeAdmissionStatusCode": "not_assessed"}
    output.mkdir()  # Exclusive; interrupted folders cannot be reused.
    fx.new_file(output / "original.bundle", original)
    fx.new_file(output / "overlay.bundle", overlay)
    candidate.verify(root, seal_sha, source_pack, cache)
    candidate.require(fx.fingerprint(matches[0]) == original_pin, "execution_fx_input_drifted")
    raw = fx.encoded(manifest)
    fx.new_file(output / "manifest.private.json", raw)  # Last; incomplete folders never serve.
    return {"contractId": "nll/execution-fx-staging-receipt/v1", "executionCode": execution_code,
            "profileSha256": sealed["profileSha256"], "candidateSealSha256": seal_sha,
            "manifestSha256": fx.digest(raw), "weaknessCode": weakness,
            "statusCode": "staged_pending_delivery", "runtimeAdmissionStatusCode": "not_assessed",
            "sharedCacheModified": False, "clientStarted": False, "registryModified": False,
            "rawSourceIdentifiersPersisted": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("candidate-root", "source-static-pack", "asset-cache-root", "output-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("candidate-seal-sha256", "execution-code", "weakness-code"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        result = stage(args.candidate_root, args.candidate_seal_sha256, args.source_static_pack,
                       args.asset_cache_root, args.output_root, args.execution_code, args.weakness_code)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, fx.CandidateError) as error:
        code = str(error)
        print(code if re.fullmatch("[a-z0-9_]+", code) else "execution_fx_invalid_input", file=sys.stderr)
        return 1
    except Exception:
        print("execution_fx_uncontrolled_failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
