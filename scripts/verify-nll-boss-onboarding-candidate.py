"""Seal a fully checked offline candidate; this is never runtime admission."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys


def module(filename):
    spec = importlib.util.spec_from_file_location("onboarding_fx", Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


fx = module("materialize-nll-shield-fx-candidate.py")
TARGETS = {"fire": "wind", "water": "fire", "wind": "iron", "electric": "water", "iron": "electric"}


def require(condition, code="boss_onboarding_candidate_receipt_invalid"):
    if not condition:
        raise ValueError(code)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def read(path):
    return json.loads(fx.plain_path(path, file=True).read_bytes())


def validate_variant(profile, profile_sha, source_sha, weakness, receipt, pack):
    changed = weakness != profile["sourceAffinity"]["weaknessCode"]
    dynamic = profile["elementShield"]["modeCode"] == "dynamic_affinity_linked"
    v3 = profile["schemaVersion"] == 3
    qte_count = profile["quickTimeEventAffinity"]["recordCount"] if v3 and changed else 0
    # The closed shield set also contains FX-free functions. The materializer's
    # round-trip boundary proves their preservation; only FX-bearing rows change.
    function_count = receipt.get("modifiedFunctionRecordCount")
    require(type(function_count) is int and (
        0 < function_count <= profile["elementShield"]["functionRecordCount"]
        if dynamic and changed else function_count == 0))
    codes = (["target_monster_element_reference"] if changed else [])
    codes += ["target_dynamic_shield_fx_reference"] if function_count else []
    codes += ["target_qte_element_reference"] if qte_count else []
    expected = {
        "schemaVersion": 1, "contractId": "nll/boss-affinity-static-data-variant/v1",
        "variantProfileCode": profile["profileCode"], "variantProfileSha256": profile_sha,
        "seasonNumber": profile["seasonNumber"], "weaknessCode": weakness,
        "sourceBossElementCode": profile["sourceAffinity"]["bossElementCode"],
        "sourceBossWeaknessCode": profile["sourceAffinity"]["weaknessCode"],
        "targetBossElementCode": TARGETS[weakness], "sourceStaticDataSha256": source_sha,
        "variantRequired": changed, "modifiedMonsterRecordCount": int(changed),
        "modifiedFunctionRecordCount": function_count, "modifiedQuickTimeEventRecordCount": qte_count,
        "quickTimeEventAffinityContractVerified": v3, "modifiedElementRecordCount": 0,
        "modifiedTableCount": len(codes), "modifiedTableCodes": codes,
        "elementTablePreserved": True, "clientElementIndexInvariantVerified": True,
        "serverStaticDataModified": False, "officialInstallModified": False,
        "rawSourceIdentifierPersisted": False, "runtimeAdmissionStatusCode": "not_assessed",
        "shieldFxTransformStatusCode": "pending_isolated_asset_overlay"
            if v3 and TARGETS[weakness] in fx.ROLES else "not_required",
        "elementShieldModeCode": profile["elementShield"]["modeCode"],
    }
    for key, value in expected.items():
        require(key in receipt and type(receipt[key]) is type(value) and receipt[key] == value)
    require(pack.exists() == changed)
    if changed:
        require(receipt["variantStaticDataSha256"] == digest(fx.plain_path(pack, file=True)))
    else:
        require(receipt["variantStaticDataSha256"] is None)
    if dynamic:
        rows = [row for row in profile["elementShield"]["fxVariants"]
                if row["bossElementCode"] == TARGETS[weakness]]
        require(len(rows) == 1)
        bundles = {(b["byteLength"], b["sha256"]) for m in rows[0]["mappings"] for b in m["assetBundles"]}
        actual = [(b["byteLength"], b["sha256"]) for b in receipt["shieldFxAssetBundles"]]
        require(len(actual) == len(bundles) and set(actual) == bundles
                and receipt["shieldFxMappingSetSha256"] == rows[0]["mappingSetSha256"])
    else:
        require(receipt["shieldFxAssetBundles"] == [] and receipt["shieldFxMappingSetSha256"] is None)


def build_receipt(root, source_pack, season, profile_code, input_set_sha, cache):
    root = fx.plain_path(root)
    profile_path = root / "boss-runtime-variant.profile.json"
    profile = read(profile_path)
    profile_sha = digest(profile_path)
    require(profile["schemaVersion"] in (2, 3)
            and profile["contractId"] == f'nll/boss-runtime-variant-profile/v{profile["schemaVersion"]}'
            and profile["seasonNumber"] == season and profile["profileCode"] == profile_code)
    candidate = read(root / "onboarding-candidate.receipt.json")
    behavior = read(root / "behavior-assembly.receipt.json")
    discovery = read(root / "content-discovery.receipt.json")
    require(candidate["contractId"] == "nll/boss-onboarding-candidate/v1"
            and candidate["profileSha256"] == profile_sha
            and candidate["sourceDiscoverySha256"] == digest(root / "content-discovery.receipt.json")
            and candidate["behaviorAssemblySha256"] == digest(root / "behavior-assembly.receipt.json")
            and behavior["sourceDiscoverySha256"] == candidate["sourceDiscoverySha256"]
            and all(row["seasonNumber"] == season and row["profileCode"] == profile_code
                    for row in (candidate, behavior, discovery))
            and candidate["runtimeAdmissionStatusCode"] == "not_assessed")
    source_sha = digest(source_pack)
    # Re-resolve every original behavior/FX pin at completion, not just the three
    # transformed roles. Inputs may have drifted while five packs were generated.
    bundles = [bundle for row in profile["elementShield"]["fxVariants"]
               for mapping in row["mappings"] for bundle in mapping["assetBundles"]]
    bundles.append({"sha256": profile["behaviorAssembly"]["bundleSha256"],
                    "byteLength": profile["behaviorAssembly"]["bundleByteLength"]})
    fx.resolve_inputs(fx.plain_path(cache), [
        {prefix + suffix: bundle[key] for prefix in ("sourceBundle", "targetBundle")
         for suffix, key in (("Sha256", "sha256"), ("ByteLength", "byteLength"))} for bundle in bundles])
    artifact_names = ["boss-runtime-variant.profile.json", "onboarding-candidate.receipt.json",
                      "behavior-assembly.receipt.json", "content-discovery.receipt.json"]
    for weakness in TARGETS:
        receipt_name = f"five-affinity-variants/{weakness}.receipt.json"
        pack_name = f"five-affinity-variants/{weakness}.pack"
        validate_variant(profile, profile_sha, source_sha, weakness, read(root / receipt_name), root / pack_name)
        artifact_names.append(receipt_name)
        if (root / pack_name).exists():
            artifact_names.append(pack_name)
    manifest_sha = None
    if profile["schemaVersion"] == 3:
        manifest = root / "shield-fx-candidate/manifest.json"
        manifest_sha = digest(fx.plain_path(manifest, file=True))
        require(read(manifest)["profileSha256"] == profile_sha)
        fx.inspect_or_restore(manifest.parent, manifest_sha)
        artifact_names.append("shield-fx-candidate/manifest.json")
    else:
        require(not (root / "shield-fx-candidate").exists())
    result = {"schemaVersion": 1, "contractId": "nll/boss-onboarding-verified-candidate/v1",
              "seasonNumber": season, "profileCode": profile_code, "profileSha256": profile_sha,
              "sourceStaticDataSha256": source_sha, "inputSetSha256": input_set_sha,
              "statusCode": "verified_candidate_pending_runtime_delivery",
              "fiveAffinityVariantStatusCode": "passed", "affinityVariantCount": 5,
              "shieldFxCandidateManifestSha256": manifest_sha,
              "runtimeAdmissionStatusCode": "not_assessed", "registryModified": False,
              "sharedCacheModified": False, "clientStarted": False, "officialInstallModified": False,
              "rawSourceIdentifiersPersisted": False,
              "artifacts": [{"relativePath": name, "sha256": digest(root / name)} for name in artifact_names]}
    return result


def finalize(root, source_pack, season, profile_code, input_set_sha, cache):
    destination = fx.plain_path(root) / "onboarding-verified-candidate.receipt.json"
    require(not destination.exists(), "boss_onboarding_candidate_seal_exists")
    result = build_receipt(root, source_pack, season, profile_code, input_set_sha, cache)
    fx.new_file(destination, fx.encoded(result))
    return result


def verify(root, expected_sha, source_pack, cache):
    path = fx.plain_path(root / "onboarding-verified-candidate.receipt.json", file=True)
    require(digest(path) == expected_sha, "boss_onboarding_candidate_seal_drifted")
    sealed = read(path)
    actual = build_receipt(root, source_pack, sealed["seasonNumber"], sealed["profileCode"],
                           sealed["inputSetSha256"], cache)
    require(sealed == actual, "boss_onboarding_candidate_changed_since_seal")
    return actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--source-static-pack", type=Path, required=True)
    parser.add_argument("--season-number", type=int, required=True)
    parser.add_argument("--profile-code", required=True)
    parser.add_argument("--input-set-sha256", required=True)
    parser.add_argument("--asset-cache-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        finalize(args.output_root, args.source_static_pack, args.season_number, args.profile_code,
                 args.input_set_sha256, args.asset_cache_root)
        return 0
    except (ValueError, fx.CandidateError) as error:
        print(str(error) if not isinstance(error, json.JSONDecodeError)
              else "boss_onboarding_candidate_json_invalid", file=sys.stderr)
        return 1
    except Exception:
        print("boss_onboarding_candidate_invalid_or_uncontrolled_failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
