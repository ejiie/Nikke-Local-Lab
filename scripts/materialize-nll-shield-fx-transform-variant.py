"""Create a per-run shield FX bundle whose Transform values match a source FX.

The source and target bundles remain untouched. Only Transform objects in the
derived bundle may change; all other serialized Unity objects are verified
byte-for-byte before a source-free receipt is emitted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
from typing import Any


class MaterializationError(Exception):
    pass


def require(condition: bool, code: str) -> None:
    if not condition:
        raise MaterializationError(code)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def pointer_path_id(value: Any) -> int:
    return int(getattr(value, "path_id", getattr(value, "m_PathID", 0)))


def vector(value: Any, fields: tuple[str, ...]) -> list[float]:
    result: list[float] = []
    for field in fields:
        number = float(getattr(value, field))
        result.append(0.0 if number == 0.0 else number)
    return result


def assign_vector(target: Any, source: Any, fields: tuple[str, ...]) -> None:
    for field in fields:
        setattr(target, field, getattr(source, field))


def write_atomic(path: Path, payload: bytes) -> None:
    require(path.is_absolute() and not path.exists(), "shield_fx_variant_output_exists")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_bytes(payload)
    os.replace(temporary, path)


def write_atomic_json(path: Path, value: dict[str, Any]) -> None:
    write_atomic(
        path,
        (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
    )


def descendants(path_id: int, transforms: dict[int, dict[str, Any]]) -> set[int]:
    result: set[int] = set()
    pending = list(transforms[path_id]["children"])
    while pending:
        child = pending.pop()
        if child in result or child not in transforms:
            continue
        result.add(child)
        pending.extend(transforms[child]["children"])
    return result


def transform_graph(environment: Any) -> dict[int, dict[str, Any]]:
    result: dict[int, dict[str, Any]] = {}
    for obj in environment.objects:
        if obj.type.name not in ("Transform", "RectTransform"):
            continue
        data = obj.read()
        try:
            name = str(data.m_GameObject.read().m_Name)
        except Exception:
            name = ""
        result[int(obj.path_id)] = {
            "reader": obj,
            "data": data,
            "name": name,
            "parent": pointer_path_id(data.m_Father),
            "children": [pointer_path_id(item) for item in data.m_Children],
        }
    require(result, "shield_fx_transform_missing")
    return result


def unique_root(transforms: dict[int, dict[str, Any]]) -> int:
    roots = [key for key, row in transforms.items() if row["parent"] not in transforms]
    require(len(roots) == 1, "shield_fx_root_transform_not_unique")
    return roots[0]


def scale_anchor(root: int, transforms: dict[int, dict[str, Any]]) -> int:
    candidates = [
        child
        for child in transforms[root]["children"]
        if child in transforms and len(descendants(child, transforms)) >= 10
    ]
    require(len(candidates) == 1, "shield_fx_scale_anchor_not_unique")
    return candidates[0]


def branch_roots(anchor: int, transforms: dict[int, dict[str, Any]]) -> dict[str, tuple[int, int]]:
    result: dict[str, tuple[int, int]] = {}
    for state in transforms[anchor]["children"]:
        if state not in transforms or len(transforms[state]["children"]) != 1:
            continue
        branch = transforms[state]["children"][0]
        if branch not in transforms:
            continue
        leaf_count = len(transforms[branch]["children"])
        if leaf_count == 3:
            result["loop"] = (state, branch)
        elif leaf_count >= 4:
            result["broken"] = (state, branch)
    require(set(result) == {"loop", "broken"}, "shield_fx_branch_shape_invalid")
    return result


def transform_values(row: dict[str, Any]) -> dict[str, list[float]]:
    data = row["data"]
    return {
        "localPosition": vector(data.m_LocalPosition, ("x", "y", "z")),
        "localRotation": vector(data.m_LocalRotation, ("x", "y", "z", "w")),
        "localScale": vector(data.m_LocalScale, ("x", "y", "z")),
    }


def copy_transform(source: dict[str, Any], target: dict[str, Any]) -> bool:
    before = transform_values(target)
    assign_vector(target["data"].m_LocalPosition, source["data"].m_LocalPosition, ("x", "y", "z"))
    assign_vector(target["data"].m_LocalRotation, source["data"].m_LocalRotation, ("x", "y", "z", "w"))
    assign_vector(target["data"].m_LocalScale, source["data"].m_LocalScale, ("x", "y", "z"))
    after = transform_values(target)
    if before != after:
        target["data"].save()
        return True
    return False


def non_transform_fingerprint(environment: Any) -> str:
    rows = []
    for obj in environment.objects:
        if obj.type.name in ("Transform", "RectTransform"):
            continue
        rows.append(
            (
                obj.type.name,
                int(obj.path_id),
                sha256_bytes(obj.get_raw_data()),
            )
        )
    return sha256_bytes(canonical_json(sorted(rows)))


def materialize(source_path: Path, target_path: Path, unitypy: Any) -> tuple[bytes, dict[str, Any]]:
    source_environment = unitypy.load(str(source_path))
    target_environment = unitypy.load(str(target_path))
    source_transforms = transform_graph(source_environment)
    target_transforms = transform_graph(target_environment)
    source_root = unique_root(source_transforms)
    target_root = unique_root(target_transforms)
    source_anchor = scale_anchor(source_root, source_transforms)
    target_anchor = scale_anchor(target_root, target_transforms)
    source_branches = branch_roots(source_anchor, source_transforms)
    target_branches = branch_roots(target_anchor, target_transforms)

    pairs: list[tuple[dict[str, Any], dict[str, Any]]] = [
        (source_transforms[source_root], target_transforms[target_root]),
        (source_transforms[source_anchor], target_transforms[target_anchor]),
    ]
    for branch_code in ("loop", "broken"):
        source_state, source_branch = source_branches[branch_code]
        target_state, target_branch = target_branches[branch_code]
        pairs.extend(
            [
                (source_transforms[source_state], target_transforms[target_state]),
                (source_transforms[source_branch], target_transforms[target_branch]),
            ]
        )
        source_leaves = {
            source_transforms[item]["name"]: source_transforms[item]
            for item in source_transforms[source_branch]["children"]
        }
        target_leaves = {
            target_transforms[item]["name"]: target_transforms[item]
            for item in target_transforms[target_branch]["children"]
        }
        for name in sorted(source_leaves.keys() & target_leaves.keys()):
            pairs.append((source_leaves[name], target_leaves[name]))

    require(len(pairs) >= 10, "shield_fx_transform_correspondence_incomplete")
    source_value_hash = sha256_bytes(
        canonical_json([transform_values(source) for source, _ in pairs])
    )
    non_transform_before = non_transform_fingerprint(target_environment)
    changed_count = sum(copy_transform(source, target) for source, target in pairs)
    require(changed_count > 0, "shield_fx_transform_variant_not_required")

    top_files = list(target_environment.files.values())
    require(len(top_files) == 1, "shield_fx_bundle_container_not_unique")
    derived = top_files[0].save(packer="original")
    require(isinstance(derived, bytes) and derived, "shield_fx_variant_save_failed")

    round_trip = unitypy.load(derived)
    round_trip_transforms = transform_graph(round_trip)
    round_trip_root = unique_root(round_trip_transforms)
    round_trip_anchor = scale_anchor(round_trip_root, round_trip_transforms)
    round_trip_branches = branch_roots(round_trip_anchor, round_trip_transforms)
    round_trip_pairs: list[dict[str, Any]] = [
        round_trip_transforms[round_trip_root],
        round_trip_transforms[round_trip_anchor],
    ]
    for branch_code in ("loop", "broken"):
        state, branch = round_trip_branches[branch_code]
        round_trip_pairs.extend([round_trip_transforms[state], round_trip_transforms[branch]])
        expected_names = {
            target["name"] for _, target in pairs if target["parent"] == target_branches[branch_code][1]
        }
        round_trip_pairs.extend(sorted(
            (
                round_trip_transforms[item]
                for item in round_trip_transforms[branch]["children"]
                if round_trip_transforms[item]["name"] in expected_names
            ),
            key=lambda row: row["name"],
        ))
    round_trip_value_hash = sha256_bytes(
        canonical_json([transform_values(row) for row in round_trip_pairs])
    )
    if os.environ.get("NLL_PRIVATE_DIAGNOSTIC") == "1" and round_trip_value_hash != source_value_hash:
        print(json.dumps({
            "source": [transform_values(source) for source, _ in pairs],
            "roundTrip": [transform_values(row) for row in round_trip_pairs],
        }, indent=2), file=sys.stderr)
    require(
        round_trip_value_hash == source_value_hash,
        "shield_fx_variant_transform_roundtrip_invalid",
    )
    require(
        non_transform_fingerprint(round_trip) == non_transform_before,
        "shield_fx_variant_non_transform_boundary_invalid",
    )
    return derived, {
        "sourceTransformCount": len(source_transforms),
        "targetTransformCount": len(target_transforms),
        "matchedTransformCount": len(pairs),
        "modifiedTransformCount": changed_count,
        "matchedTransformValueSetSha256": source_value_hash,
        "nonTransformObjectSetSha256": non_transform_before,
    }


def run(args: argparse.Namespace) -> None:
    source_path = args.source.resolve()
    target_path = args.target.resolve()
    output_path = args.output.resolve()
    receipt_path = args.receipt.resolve()
    require(source_path.is_file() and target_path.is_file(), "shield_fx_variant_input_missing")
    require(
        args.target_role in {"fire", "wind", "iron"},
        "shield_fx_variant_target_role_invalid",
    )
    if args.unitypy_root:
        sys.path.insert(0, str(args.unitypy_root.resolve()))
    try:
        import UnityPy  # type: ignore
    except Exception as exception:
        raise MaterializationError("shield_fx_unitypy_unavailable") from exception

    derived, evidence = materialize(source_path, target_path, UnityPy)
    write_atomic(output_path, derived)
    receipt = {
        "schemaVersion": 1,
        "contractId": "nll/boss-shield-fx-transform-variant/v1",
        "sourceRoleCode": "electric",
        "targetRoleCode": args.target_role,
        "sourceBundleSha256": sha256_file(source_path),
        "sourceBundleByteLength": source_path.stat().st_size,
        "targetBundleSha256": sha256_file(target_path),
        "targetBundleByteLength": target_path.stat().st_size,
        "variantBundleSha256": sha256_bytes(derived),
        "variantBundleByteLength": len(derived),
        **evidence,
        "modifiedObjectTypeCodes": ["Transform"],
        "sourceAssetModified": False,
        "targetAssetModified": False,
        "rawSourceIdentifiersPersisted": False,
    }
    write_atomic_json(receipt_path, receipt)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--source", required=True, type=Path)
    result.add_argument("--target", required=True, type=Path)
    result.add_argument("--target-role", required=True)
    result.add_argument("--unitypy-root", type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--receipt", required=True, type=Path)
    return result


def main() -> int:
    try:
        run(parser().parse_args())
        return 0
    except MaterializationError as exception:
        print(str(exception), file=sys.stderr)
        return 1
    except Exception:
        print("shield_fx_variant_uncontrolled_failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
