"""Assemble a source-free boss runtime profile from closed discovery receipts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any


class PipelineError(Exception):
    pass


COLORS_BY_ELEMENT = {
    "fire": "red",
    "water": "blue",
    "wind": "green",
    "electric": "purple",
    "iron": "yellow",
}
ELEMENTS = tuple(COLORS_BY_ELEMENT)
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


def require(condition: bool, code: str) -> None:
    if not condition:
        raise PipelineError(code)


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def hash_lines(values: list[str]) -> str:
    return hashlib.sha256("\n".join(sorted(values)).encode("utf-8")).hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    require(path.is_file(), "boss_profile_input_missing")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exception:
        raise PipelineError("boss_profile_input_invalid") from exception
    require(isinstance(value, dict), "boss_profile_input_invalid")
    return value


def write_atomic(path: Path, value: dict[str, Any]) -> None:
    require(path.is_absolute() and not path.exists(), "boss_profile_output_exists")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def strip_color(value: str) -> tuple[str, str] | None:
    match = re.fullmatch(r"(.+)_(red|blue|green|purple|yellow)", value)
    return None if match is None else (match.group(1), match.group(2))


def fx_identity(candidate: dict[str, Any]) -> tuple[str, tuple[str, ...]] | None:
    names = tuple(candidate.get("fx") or ())
    if not names or not all(isinstance(value, str) for value in names):
        return None
    parsed = [strip_color(value) for value in names]
    if any(value is None for value in parsed):
        return None
    colors = {value[1] for value in parsed if value is not None}
    if len(colors) != 1:
        return None
    return next(iter(colors)), tuple(value[0] for value in parsed if value is not None)


def semantic_stems(stems: tuple[str, ...]) -> tuple[str, ...] | None:
    result: list[str] = []
    for stem in stems:
        match = re.fullmatch(r"fx_[a-z0-9]+_(.+)", stem)
        if match is None:
            return None
        result.append(match.group(1))
    return tuple(result)


def qualified_semantics(source: tuple[str, ...], common: tuple[str, ...] | None) -> bool:
    # A boss FX may add whole qualifier segments before the shared effect name
    # (fx_<owner>_<qualifier>_<effect>). Partial-segment suffixes never match.
    return common is not None and len(common) == len(source) and all(
        value.endswith("_" + effect) for value, effect in zip(source, common))


def unique_candidates(
    candidates: list[dict[str, Any]], predicate: Any
) -> list[dict[str, Any]]:
    selected: dict[str, dict[str, Any]] = {}
    for candidate in candidates:
        digest = candidate.get("fxPrefabSetSha256")
        if isinstance(digest, str) and predicate(candidate):
            selected.setdefault(digest, candidate)
    return list(selected.values())


def resolve_bundles(asset_root: Path, prefab_names: tuple[str, ...]) -> dict[str, Any]:
    identities: dict[tuple[int, str], Path] = {}
    for prefab_name in prefab_names:
        escaped = re.escape(prefab_name)
        pattern = re.compile(
            rf"^effect-spot-monster_skill_library_assets_{escaped}_[0-9a-f]+\.bundle$",
            re.IGNORECASE,
        )
        matches = [
            path for path in asset_root.rglob("*.bundle")
            if pattern.fullmatch(path.name)
        ]
        prefab_identities: dict[tuple[int, str], Path] = {}
        for path in matches:
            prefab_identities.setdefault((path.stat().st_size, hash_file(path)), path)
        require(
            len(prefab_identities) == 1,
            "boss_profile_shield_fx_asset_not_unique",
        )
        identities.update(prefab_identities)
    bundles = [
        {"sha256": digest, "byteLength": length}
        for length, digest in sorted(identities)
    ]
    return {
        "assetBundleSetSha256": hash_lines(
            [f"{item['byteLength']}\t{item['sha256']}" for item in bundles]
        ),
        "assetBundles": bundles,
    }


def resolve_shield(
    source: dict[str, Any], private: dict[str, Any], asset_root: Path, bundle_resolver=resolve_bundles
) -> dict[str, Any]:
    shield = source.get("elementShield") or {}
    if shield.get("modeCode") == "none":
        return {
            "modeCode": "none",
            "functionTypeCode": "not_applicable",
            "functionRecordCount": 0,
            "skillBindingCount": 0,
            "passiveBindingCount": 0,
            "functionSetSha256": EMPTY_SHA256,
            "sourceFxPrefabSetSha256": EMPTY_SHA256,
            "fxVariantRequired": False,
            "fxVariantStatusCode": "not_required",
            "fxVariants": [],
        }
    require(
        shield.get("modeCode") == "dynamic_affinity_linked"
        and shield.get("functionTypeCode") == "immune_other_element",
        "boss_profile_shield_mode_unsupported",
    )
    source_rows = [row for row in private.get("shieldFunctions") or [] if row.get("fx")]
    source_groups: dict[str, tuple[str, ...]] = {}
    for row in source_rows:
        digest = row.get("fxPrefabSetSha256")
        names = tuple(row.get("fx") or ())
        require(
            isinstance(digest, str)
            and names
            and (digest not in source_groups or source_groups[digest] == names),
            "boss_profile_source_shield_fx_ambiguous",
        )
        source_groups[digest] = names
    require(source_groups, "boss_profile_source_shield_fx_ambiguous")
    candidates = list(private.get("globalShieldFxCandidates") or [])
    variants: list[dict[str, Any]] = []
    for element in ELEMENTS:
        color = COLORS_BY_ELEMENT[element]
        mappings: list[dict[str, Any]] = []
        for source_digest, source_names in sorted(source_groups.items()):
            parsed_source = [strip_color(value) for value in source_names]
            require(
                all(value is not None for value in parsed_source),
                "boss_profile_source_shield_fx_color_unresolved",
            )
            source_stems = tuple(
                value[0] for value in parsed_source if value is not None
            )
            source_semantics = semantic_stems(source_stems)
            selected = unique_candidates(
                candidates,
                lambda item: (
                    (identity := fx_identity(item)) is not None
                    and identity[0] == color
                    and identity[1] == source_stems
                ),
            )
            source_kind = "boss_specific"
            if not selected and source_semantics is not None:
                selected = unique_candidates(
                    candidates,
                    lambda item: (
                        (identity := fx_identity(item)) is not None
                        and identity[0] == color
                        and all(stem.startswith("fx_m_") for stem in identity[1])
                        and semantic_stems(identity[1]) == source_semantics
                    ),
                )
                source_kind = "common"
            if not selected and source_semantics is not None:
                # Only when no exact family exists; several qualified matches stay ambiguous.
                selected = unique_candidates(
                    candidates,
                    lambda item: (
                        (identity := fx_identity(item)) is not None
                        and identity[0] == color
                        and all(stem.startswith("fx_m_") for stem in identity[1])
                        and qualified_semantics(source_semantics, semantic_stems(identity[1]))
                    ),
                )
            require(
                len(selected) == 1,
                "boss_profile_shield_fx_variant_not_unique",
            )
            candidate = selected[0]
            names = tuple(candidate["fx"])
            bundles = bundle_resolver(asset_root, names)
            mappings.append(
                {
                    "sourceFxPrefabSetSha256": source_digest,
                    "targetFxPrefabSetSha256": candidate["fxPrefabSetSha256"],
                    **bundles,
                    "sourceKindCode": source_kind,
                }
            )
        mapping_lines = [
            "\t".join(
                (
                    item["sourceFxPrefabSetSha256"],
                    item["targetFxPrefabSetSha256"],
                    item["assetBundleSetSha256"],
                    item["sourceKindCode"],
                )
            )
            for item in mappings
        ]
        variants.append(
            {
                "bossElementCode": element,
                "mappingSetSha256": hash_lines(mapping_lines),
                "mappings": mappings,
            }
        )
    return {
        "modeCode": "dynamic_affinity_linked",
        "functionTypeCode": "immune_other_element",
        "functionRecordCount": shield["functionRecordCount"],
        "skillBindingCount": shield["skillBindingCount"],
        "passiveBindingCount": shield["passiveBindingCount"],
        "functionSetSha256": shield["functionSetSha256"],
        "sourceFxPrefabSetSha256": shield["fxPrefabSetSha256"],
        "fxVariantRequired": True,
        "fxVariantStatusCode": "resolved",
        "fxVariants": variants,
    }


def require_v2_qte_compatibility(source: dict[str, Any]) -> None:
    # The default/publication lane still emits v2. Never discard elemental QTE.
    qte = source.get("quickTimeEventAffinity")
    require(isinstance(qte, dict), "boss_profile_qte_discovery_missing")
    require(
        qte.get("modeCode") == "not_applicable"
        and type(qte.get("recordCount")) is int
        and qte["recordCount"] == 0
        and type(qte.get("monsterReferenceCount")) is int
        and qte["monsterReferenceCount"] == 0
        and qte.get("sourceElementCodes") == []
        and qte.get("recordSetSha256") == EMPTY_SHA256
        and qte.get("immutablePayloadSetSha256") == EMPTY_SHA256
        and qte.get("sourceElementSetSha256") == EMPTY_SHA256,
        "boss_profile_qte_v3_pipeline_required",
    )


def local_module(name: str, filename: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_v3_qte(source: dict[str, Any]) -> dict[str, Any]:
    qte = source.get("quickTimeEventAffinity")
    require(isinstance(qte, dict), "boss_profile_qte_discovery_missing")
    codes = qte.get("sourceElementCodes")
    # Linked rows may keep different original elements. The variant leaves every
    # row as authored for the original boss element and otherwise converts each
    # linked row, counting only rows that actually differ; no single source is assumed.
    require(qte.get("modeCode") == "target_monster_linked_element_only"
            and all(type(qte.get(key)) is int and qte[key] > 0
                    for key in ("recordCount", "monsterReferenceCount"))
            and isinstance(codes, list) and 0 < len(codes) <= qte["recordCount"]
            and all(code in ELEMENTS for code in codes) and codes == sorted(set(codes))
            and all(isinstance(qte.get(key), str)
                    and re.fullmatch("[0-9a-f]{64}", qte[key]) is not None
                    and qte[key] != EMPTY_SHA256 for key in (
                        "recordSetSha256", "immutablePayloadSetSha256", "sourceElementSetSha256")),
            "boss_profile_qte_v3_discovery_invalid")
    return {key: qte[key] for key in (
        "modeCode", "recordCount", "monsterReferenceCount", "sourceElementCodes",
        "recordSetSha256", "immutablePayloadSetSha256", "sourceElementSetSha256")}


def assemble_normalization(source: dict[str, Any], shield: dict[str, Any], cache: Path,
                           materialize: Any, unitypy: Any) -> dict[str, Any]:
    # Only the currently proved source/common family is supported. Do not guess
    # geometry for other bosses, multi-bundle mappings or another source element.
    fx = local_module("boss_fx_candidate", "materialize-nll-shield-fx-candidate.py")
    require(source["sourceAffinity"]["bossElementCode"] == "electric"
            and shield["modeCode"] == "dynamic_affinity_linked"
            and [row["bossElementCode"] for row in shield["fxVariants"]] == list(ELEMENTS),
            "boss_profile_v3_fx_family_unsupported")
    bundles = {}
    for row in shield["fxVariants"]:
        mappings = row["mappings"]
        expected_kind = "common" if row["bossElementCode"] in fx.ROLES else "boss_specific"
        require(len(mappings) == 1 and mappings[0]["sourceKindCode"] == expected_kind
                and len(mappings[0]["assetBundles"]) == 1,
                "boss_profile_v3_fx_family_unsupported")
        bundles[row["bossElementCode"]] = mappings[0]["assetBundles"][0]
    rows = [{"bossElementCode": role,
             **{prefix + "Sha256": bundles[element]["sha256"]
                for prefix, element in (("sourceBundle", "electric"), ("targetBundle", role))},
             **{prefix + "ByteLength": bundles[element]["byteLength"]
                for prefix, element in (("sourceBundle", "electric"), ("targetBundle", role))}}
            for role in fx.ROLES]
    inputs = fx.resolve_inputs(fx.plain_path(cache), rows)
    before = {key: fx.fingerprint(path) for key, path in inputs.items()}
    # Probe owned copies, never the input cache. The subsequent FX candidate
    # stage independently regenerates and verifies these freshly derived pins.
    with tempfile.TemporaryDirectory(prefix="nll-fx-profile-") as directory:
        owned = Path(directory)
        for row in rows:
            for prefix in ("sourceBundle", "targetBundle"):
                path = owned / (prefix + ".bundle")
                path.write_bytes(inputs[row[prefix + "Sha256"]].read_bytes())
                require(fx.fingerprint(path) == fx.pin(row, prefix), "boss_profile_fx_input_drifted")
            derived, evidence = materialize(owned / "sourceBundle.bundle", owned / "targetBundle.bundle", unitypy)
            row.update({"variantBundleSha256": fx.digest(derived), "variantBundleByteLength": len(derived),
                        **{key: evidence[key] for key in fx.EVIDENCE_FIELDS}})
    require(before == {key: fx.fingerprint(path) for key, path in inputs.items()},
            "boss_profile_fx_input_drifted")
    return {"modeCode": "per_execution_target_bundle_overlay", "sourceBossElementCode": "electric",
            "targetBossElementCodes": list(fx.ROLES), "variants": rows}


def assess_shield_patterns(source: dict[str, Any], shield: dict[str, Any],
                          cache: Path, unitypy: Any) -> dict[str, Any]:
    patterns = source.get("shieldPatterns")
    dynamic = shield["modeCode"] != "none"
    reasons = []
    if not isinstance(patterns, dict) or patterns.get("contractId") != "nll/boss-shield-pattern-discovery/v1":
        reasons.append("shield_pattern_discovery_refresh_required")
    elif (patterns.get("staticReferenceStatusCode") != "resolved"
          or type(patterns.get("missingReferenceCount")) is not int or patterns["missingReferenceCount"] != 0
          or any(not isinstance(patterns.get(field), list) for field in
                 ("entryPoints", "partTargets", "conditions", "normalInterrupts", "quickTimeEvents"))
          or len(patterns["conditions"]) != shield.get("functionRecordCount")
          or len(patterns["quickTimeEvents"]) != (source.get("quickTimeEventAffinity") or {}).get("recordCount")):
        reasons.append("shield_pattern_reference_unresolved")
    assessment = {"contractId": "nll/boss-shield-preparation-assessment/v1",
                  "sourceBossElementCode": source["sourceAffinity"]["bossElementCode"],
                  "patterns": patterns, "reasonCodes": reasons,
                  "runtimeAdmissionStatusCode": "not_assessed", "assetWrites": 0}
    if dynamic:
        if unitypy is None:
            reasons.append("shield_fx_inspector_unavailable")
        else:
            inspector = local_module("shield_fx_assessment", "nll-shield-fx-assessment.py")
            try:
                assessment["fx"] = inspector.assess(assessment["sourceBossElementCode"],
                                                   shield["fxVariants"], cache, unitypy)
            except (ValueError, KeyError, TypeError, OSError):
                reasons.append("shield_fx_inputs_unresolved")
            if "fx" in assessment:
                if any(row["statusCode"] not in {"source_reuse", "reuse_candidate"}
                       for row in assessment["fx"]["variants"]):
                    reasons.append("shield_fx_fit_review_required")
                else:
                    # Preparation recipes deliver unchanged pins directly. The installed
                    # runtime profile wire still needs the separate P2-3 binding work.
                    reasons.append("shield_fx_runtime_binding_required")
    assessment["preparationStatusCode"] = "review_required" if reasons else "not_required"
    return assessment


def run(args: argparse.Namespace) -> None:
    source_path = args.source_discovery.resolve()
    private_path = args.private_discovery.resolve()
    behavior_path = args.behavior_receipt.resolve()
    asset_root = args.asset_cache_root.resolve()
    require(asset_root.is_dir(), "boss_profile_asset_cache_missing")
    source = read_json(source_path)
    private = read_json(private_path)
    behavior = read_json(behavior_path)
    require(
        source.get("contractId") == "nll/boss-content-discovery/v1"
        and source.get("discoveryStatusCode") == "static_graph_resolved"
        and not source.get("unresolvedReasonCodes")
        and private.get("contractId") == "nll/private-boss-content-diagnostic/v1"
        and behavior.get("contractId") == "nll/boss-behavior-assembly/v1"
        and source.get("seasonNumber") == private.get("seasonNumber")
        == behavior.get("seasonNumber")
        and source.get("profileCode") == behavior.get("profileCode")
        and behavior.get("sourceDiscoverySha256") == hash_file(source_path),
        "boss_profile_discovery_closure_invalid",
    )
    behavior_source = source.get("behaviorAssembly") or {}
    require(
        behavior.get("rootReferenceCount")
        == behavior_source.get("rootReferenceCount")
        and behavior.get("rootReferenceSetSha256")
        == behavior_source.get("rootReferenceSetSha256")
        and behavior.get("graphMatchCount") == behavior.get("rootReferenceCount")
        and type(behavior.get("disabledNodeCount")) is int
        and behavior["disabledNodeCount"] >= 0,
        "boss_profile_behavior_closure_invalid",
    )
    shield = resolve_shield(source, private, asset_root)
    unitypy = None
    if shield["modeCode"] != "none" and args.unitypy_root is not None and args.unitypy_root.is_dir():
        sys.path.insert(0, str(args.unitypy_root.resolve()))
        import UnityPy
        unitypy = UnityPy
    assessment = assess_shield_patterns(source, shield, asset_root, unitypy)
    assessment.update({"sourceDiscoverySha256": hash_file(source_path),
                       "behaviorAssemblySha256": hash_file(behavior_path)})
    fx_binding = None
    if "fx" in assessment and unitypy is not None:
        recipes = local_module("shield_fx_recipes", "nll-shield-fx-recipes.py")
        manifest, outputs = recipes.prepare(assessment["sourceBossElementCode"], shield["fxVariants"], asset_root, unitypy)
        recipe_root = args.profile_output.absolute().parent / "shield-fx-preparation"
        recipes.plain_path(recipe_root)
        recipe_root = recipe_root.resolve()
        require(not recipe_root.is_relative_to(asset_root) and not asset_root.is_relative_to(recipe_root),
                "boss_profile_shield_output_overlaps_input")
        recipes.deliver(recipe_root, manifest, outputs)
        # Consume the portable recipes again against pinned originals before reporting
        # delivery. These preparation candidates do not change the installed profile wire.
        recipes.verify_delivery(recipe_root, assessment["sourceBossElementCode"], shield["fxVariants"], asset_root, unitypy)
        assessment.update(shieldFxRecipesSha256=hash_file(recipe_root / "recipes.receipt.json"),
                          shieldFxRecipeDeliveryStatusCode="verified_preparation_candidates",
                          assetWrites=len(outputs))
        if manifest["preparationStatusCode"] in {"reuse_ready", "size_candidates_ready"}:
            fx_binding = recipes.profile_binding(manifest, assessment["shieldFxRecipesSha256"])
            assessment["reasonCodes"] = [code for code in assessment["reasonCodes"] if code not in
                                         {"shield_fx_fit_review_required", "shield_fx_runtime_binding_required"}]
            assessment["preparationStatusCode"] = "review_required" if assessment["reasonCodes"] else "prepared"
    assessment_path = (getattr(args, "shield_assessment_output", None)
                       or args.profile_output.with_name("shield-pattern-fx-assessment.receipt.json")).resolve()
    write_atomic(assessment_path, assessment)
    require(assessment["preparationStatusCode"] in {"not_required", "prepared"},
            "boss_profile_shield_assessment_review_required")
    has_qte = (source.get("quickTimeEventAffinity") or {}).get("modeCode") == "target_monster_linked_element_only"
    if has_qte:
        qte = require_v3_qte(source)
    else:
        require_v2_qte_compatibility(source)
    dynamic = shield["modeCode"] == "dynamic_affinity_linked"
    profile = {
        "schemaVersion": 2,
        "contractId": "nll/boss-runtime-variant-profile/v2",
        "profileCode": source["profileCode"],
        "seasonNumber": source["seasonNumber"],
        "displayNameCode": source["displayNameCode"],
        "selectedManagerObservation": source["selectedManagerObservation"],
        "challengeSelector": source["challengeSelector"],
        "sourceAffinity": source["sourceAffinity"],
        "skillClosure": source["skillClosure"],
        "behaviorAssembly": {
            "modeCode": behavior["modeCode"],
            "rootReferenceCount": behavior["rootReferenceCount"],
            "rootReferenceSetSha256": behavior["rootReferenceSetSha256"],
            "assetClosureStatusCode": behavior["assetClosureStatusCode"],
            "bundleByteLength": behavior["bundleByteLength"],
            "bundleSha256": behavior["bundleSha256"],
            "graphMatchCount": behavior["graphMatchCount"],
            "nodeCount": behavior["nodeCount"],
            "canonicalGraphSha256": behavior["canonicalGraphSha256"],
            "taskTypeSetSha256": behavior["taskTypeSetSha256"],
            "skillAnimationReferenceSetSha256": behavior[
                "skillAnimationReferenceSetSha256"
            ],
            "partReferenceSetSha256": behavior["partReferenceSetSha256"],
            "pointReferenceSetSha256": behavior["pointReferenceSetSha256"],
        },
        "elementShield": shield,
        "transformation": {
            "modeCode": (
                "target_monster_element_and_dynamic_shield_fx"
                if dynamic
                else "target_monster_element_reference"
            ),
            "allowedTableCodes": ["monster", "function"] if dynamic else ["monster"],
            "preserveElementTable": True,
            "restrictToTargetMonsterElementIds": True,
            "rawSourceIdentifiersPersisted": False,
        },
    }
    if dynamic or has_qte:
        profile.update({"schemaVersion": 4, "contractId": "nll/boss-runtime-variant-profile/v4"})
    if dynamic:
        require(fx_binding is not None, "boss_profile_shield_recipe_binding_missing")
        profile["shieldFxPreparation"] = fx_binding
        recipes.verify_profile_binding(profile, recipe_root)
    if has_qte:
        profile["quickTimeEventAffinity"] = qte
        profile["transformation"].update({
            "modeCode": ("target_monster_element_dynamic_shield_fx_and_qte_element" if dynamic
                         else "target_monster_element_and_qte_element"),
            "allowedTableCodes": ["monster", *(["function"] if dynamic else []), "quick_time_event"]})
    profile_path = args.profile_output.resolve()
    write_atomic(profile_path, profile)
    receipt = {
        "schemaVersion": 1,
        "contractId": "nll/boss-onboarding-candidate/v1",
        "profileCode": profile["profileCode"],
        "seasonNumber": profile["seasonNumber"],
        "profileSha256": hash_file(profile_path),
        "sourceDiscoverySha256": hash_file(source_path),
        "behaviorAssemblySha256": hash_file(behavior_path),
        "shieldPreparationAssessmentSha256": hash_file(assessment_path),
        "skillClosureStatusCode": "resolved",
        "behaviorClosureStatusCode": "resolved",
        "elementShieldModeCode": shield["modeCode"],
        "elementShieldFxVariantCount": len(shield["fxVariants"]),
        "admissionStatusCode": "candidate_pending_five_affinity_variants",
        "runtimeAdmissionStatusCode": "not_assessed",
        "rawSourceIdentifiersPersisted": False,
        "officialInstallModified": False,
    }
    write_atomic(args.receipt_output.resolve(), receipt)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--source-discovery", required=True, type=Path)
    result.add_argument("--private-discovery", required=True, type=Path)
    result.add_argument("--behavior-receipt", required=True, type=Path)
    result.add_argument("--asset-cache-root", required=True, type=Path)
    result.add_argument("--profile-output", required=True, type=Path)
    result.add_argument("--receipt-output", required=True, type=Path)
    result.add_argument("--shield-assessment-output", type=Path)
    result.add_argument("--allow-v3-candidate", action="store_true")
    result.add_argument("--unitypy-root", type=Path)
    return result


def main() -> int:
    try:
        run(parser().parse_args())
        return 0
    except PipelineError as exception:
        print(str(exception), file=sys.stderr)
        return 1
    except Exception as exception:
        print("boss_profile_uncontrolled_failure", file=sys.stderr)
        # Source-free code location only: no exception text, locals or raw IDs.
        trace = exception.__traceback__
        while trace is not None:
            if trace.tb_frame.f_code.co_filename == __file__:
                print(f"boss_profile_failure_line_{trace.tb_lineno}", file=sys.stderr)
            trace = trace.tb_next
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
