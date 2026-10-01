"""Exercise the real C# profile decoder with synthetic common preparation inputs."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def synthetic():
    h = sha("synthetic")
    profile = {
        "schemaVersion": 4, "contractId": "nll/boss-runtime-variant-profile/v4",
        "profileCode": "synthetic-boss", "seasonNumber": 9, "displayNameCode": "synthetic-boss",
        "selectedManagerObservation": {"contractId": "synthetic/v1", "canonicalizationCode": "synthetic/v1",
            "sourceObservationSha256": h, "roleLineCounts": [3, 13, 13, 1, 1, 1],
            "canonicalLineCount": 33, "canonicalByteLength": 64, "trustedSha256": h},
        "challengeSelector": {"difficultyTypeCode": "challenge", "waveOrder": 1, "targetCardinality": 1},
        "sourceAffinity": {"bossElementCode": "water", "weaknessCode": "electric"},
        "skillClosure": {"monsterSkillRelationCount": 1, "monsterSkillRecordCount": 1,
            "passiveStateEffectRecordCount": 1, "rootFunctionRecordCount": 1, "closedFunctionRecordCount": 1,
            "missingReferenceCount": 0, "canonicalSha256": h},
        "behaviorAssembly": {"modeCode": "preserve_exact_external_behavior_tree", "rootReferenceCount": 1,
            "rootReferenceSetSha256": h, "assetClosureStatusCode": "resolved", "bundleByteLength": 64,
            "bundleSha256": h, "graphMatchCount": 1, "nodeCount": 1,
            **{k: h for k in ("canonicalGraphSha256", "taskTypeSetSha256", "skillAnimationReferenceSetSha256",
                              "partReferenceSetSha256", "pointReferenceSetSha256")}},
        "elementShield": {"modeCode": "dynamic_affinity_linked", "functionTypeCode": "immune_other_element",
            "functionRecordCount": 1, "skillBindingCount": 1, "passiveBindingCount": 0,
            "functionSetSha256": h, "sourceFxPrefabSetSha256": sha(h), "fxVariantRequired": True,
            "fxVariantStatusCode": "resolved", "fxVariants": []},
        "quickTimeEventAffinity": {"modeCode": "target_monster_linked_element_only", "recordCount": 2,
            "monsterReferenceCount": 1, "recordSetSha256": h, "immutablePayloadSetSha256": h,
            "sourceElementSetSha256": h, "sourceElementCodes": ["water"]},
        "shieldFxPreparation": {"contractId": "nll/boss-shield-fx-preparation/v1",
            "policyCode": "source_shield_size_candidate/v2", "sourceBossElementCode": "water",
            "recipeManifestSha256": h, "variants": []},
        "transformation": {"modeCode": "target_monster_element_dynamic_shield_fx_and_qte_element",
            "allowedTableCodes": ["monster", "function", "quick_time_event"], "preserveElementTable": True,
            "restrictToTargetMonsterElementIds": True, "rawSourceIdentifiersPersisted": False},
    }
    for element in ("iron", "water", "electric", "fire", "wind"):
        target = h if element == "water" else sha(element)
        bundle = {"sha256": sha(element + "-bundle"), "byteLength": 64}
        bundle_set = sha("64\t" + bundle["sha256"])
        kind = "boss_specific" if element in ("water", "iron") else "common"
        profile["elementShield"]["fxVariants"].append({"bossElementCode": element,
            "mappingSetSha256": sha("\t".join((h, target, bundle_set, kind))), "mappings": [{
                "sourceFxPrefabSetSha256": h, "targetFxPrefabSetSha256": target,
                "assetBundleSetSha256": bundle_set, "assetBundles": [bundle], "sourceKindCode": kind}]})
        reuse = element in ("water", "iron")
        profile["shieldFxPreparation"]["variants"].append({"bossElementCode": element,
            "sourceFxPrefabSetSha256": h, "targetFxPrefabSetSha256": target,
            "operationCode": "reuse" if reuse else "adjust_candidate",
            "sourceBundle": {"sha256": sha("water-bundle"), "byteLength": 64}, "targetBundle": bundle,
            "outputBundle": bundle if reuse else {"sha256": sha(element + "-sized"), "byteLength": 67}})
    return profile


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--materializer", type=Path, required=True)
    args = parser.parse_args(); cases = []
    value = synthetic(); cases.append(("non_electric_source", value, True))
    v3 = copy.deepcopy(value); v3["shieldFxPreparation"]["policyCode"] = "source_shield_size_candidate/v3"
    cases.append(("animated_size_policy", v3, True))
    no_qte = copy.deepcopy(value); no_qte.pop("quickTimeEventAffinity")
    no_qte["transformation"].update(modeCode="target_monster_element_and_dynamic_shield_fx", allowedTableCodes=["monster", "function"])
    cases.append(("shield_without_qte", no_qte, True))
    qte_only = copy.deepcopy(value); qte_only.pop("shieldFxPreparation")
    qte_only["elementShield"].update(modeCode="none", functionTypeCode="not_applicable", functionRecordCount=0,
        skillBindingCount=0, passiveBindingCount=0, fxVariantRequired=False, fxVariantStatusCode="not_required", fxVariants=[])
    qte_only["transformation"].update(modeCode="target_monster_element_and_qte_element", allowedTableCodes=["monster", "quick_time_event"])
    cases.append(("qte_without_shield", qte_only, True))
    # Linked QTE rows may keep other original elements; the variant handles each row.
    for codes in (["electric"], ["electric", "water"]):
        mixed = copy.deepcopy(value); mixed["quickTimeEventAffinity"]["sourceElementCodes"] = codes
        cases.append(("qte_source_" + "_".join(codes), mixed, True))
    def row(p): return p["shieldFxPreparation"]["variants"][0]
    mutations = [
        lambda p: p["shieldFxPreparation"].update(policyCode="source_shield_size_candidate/v99"),
        lambda p: p.update(schemaVersion=3),
        lambda p: p.update(unrecognizedField=True),
        lambda p: p.pop("shieldFxPreparation"),
        lambda p: p["shieldFxPreparation"].update(recipeManifestSha256="bad"),
        lambda p: p["shieldFxPreparation"].update(sourceBossElementCode="electric"),
        lambda p: p["shieldFxPreparation"]["variants"].pop(),
        lambda p: p["shieldFxPreparation"]["variants"].append(copy.deepcopy(row(p))),
        lambda p: p["shieldFxPreparation"]["variants"].__setitem__(0, copy.deepcopy(p["shieldFxPreparation"]["variants"][1])),
        lambda p: p["shieldFxPreparation"]["variants"][1].update(operationCode="adjust_candidate",
            outputBundle={"sha256": sha("changed-original"), "byteLength": 67}),
        lambda p: p["shieldFxPreparation"]["variants"][2].update(outputBundle={"sha256": sha("sized"), "byteLength": 0}),
        lambda p: row(p).update(operationCode="automatic"),
        lambda p: row(p).update(outputBundle={"sha256": sha("wrong"), "byteLength": 64}),
        lambda p: row(p).update(targetBundle={"sha256": sha("wrong"), "byteLength": 64}),
        lambda p: row(p).update(sourceBundle={"sha256": sha("wrong"), "byteLength": 64}),
        lambda p: row(p).update(targetFxPrefabSetSha256=sha("wrong")),
        *(lambda p, codes=codes: p["quickTimeEventAffinity"].update(sourceElementCodes=codes)
          for codes in ([], ["water", "electric"], ["water", "water"], ["unresolved"], None,
                        ["electric", "fire", "water"])),
        lambda p: p["transformation"].update(allowedTableCodes=["monster", "function"]),
        lambda p: p.update(shieldFxTransformNormalization={}),
    ]
    for i, mutate in enumerate(mutations):
        changed = copy.deepcopy(value); mutate(changed); cases.append(("reject_" + str(i), changed, False))
    with tempfile.TemporaryDirectory(prefix="nll-profile-binding-") as directory:
        path = Path(directory) / "synthetic.json"
        for name, profile, expected in cases:
            path.write_text(json.dumps(profile), encoding="utf-8")
            result = subprocess.run([str(args.materializer.resolve()), "--validate-boss-variant-profile", str(path)], capture_output=True)
            if (result.returncode == 0) != expected:
                raise AssertionError("profile_binding_case_failed:" + name)
    print(json.dumps({"contractId": "nll/boss-profile-binding-check/v1", "syntheticOnly": True,
                      "passed": len(cases), "failed": 0, "gameStarted": False}))


if __name__ == "__main__": main()
