"""Assemble a source-free boss runtime profile from closed discovery receipts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
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
    source: dict[str, Any], private: dict[str, Any], asset_root: Path
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
            require(
                len(selected) == 1,
                "boss_profile_shield_fx_variant_not_unique",
            )
            candidate = selected[0]
            names = tuple(candidate["fx"])
            bundles = resolve_bundles(asset_root, names)
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
        and behavior.get("disabledNodeCount") == 0,
        "boss_profile_behavior_closure_invalid",
    )
    shield = resolve_shield(source, private, asset_root)
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
        "skillClosureStatusCode": "resolved",
        "behaviorClosureStatusCode": "resolved",
        "elementShieldModeCode": shield["modeCode"],
        "elementShieldFxVariantCount": len(shield["fxVariants"]),
        "admissionStatusCode": "candidate_pending_five_affinity_variants",
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
    return result


def main() -> int:
    try:
        run(parser().parse_args())
        return 0
    except PipelineError as exception:
        print(str(exception), file=sys.stderr)
        return 1
    except Exception:
        print("boss_profile_uncontrolled_failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
