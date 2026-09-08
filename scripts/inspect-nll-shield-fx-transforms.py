"""Inspect source-free Transform evidence for boss elemental-shield FX bundles.

Raw Unity object names and paths are written only to the optional private output.
The normal receipt contains counts and hashes so it is safe to retain with Local Lab.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import traceback
from typing import Any


class InspectionError(Exception):
    pass


def require(condition: bool, code: str) -> None:
    if not condition:
        raise InspectionError(code)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def vector(value: Any, fields: tuple[str, ...]) -> list[float]:
    return [float(getattr(value, field)) for field in fields]


def pointer_path_id(value: Any) -> int:
    return int(getattr(value, "path_id", getattr(value, "m_PathID", 0)))


def write_atomic(path: Path, value: dict[str, Any]) -> None:
    require(path.is_absolute() and not path.exists(), "shield_fx_output_exists")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def inspect_bundle(role: str, path: Path, unitypy: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    require(path.is_file(), "shield_fx_bundle_missing")
    environment = unitypy.load(str(path))
    type_counts: dict[str, int] = {}
    transforms: dict[int, dict[str, Any]] = {}
    for obj in environment.objects:
        type_counts[obj.type.name] = type_counts.get(obj.type.name, 0) + 1
        if obj.type.name not in ("Transform", "RectTransform"):
            continue
        data = obj.read()
        try:
            game_object = data.m_GameObject.read()
            name = str(game_object.m_Name)
        except Exception:
            name = ""
        transforms[int(obj.path_id)] = {
            "pathId": int(obj.path_id),
            "name": name,
            "parentPathId": pointer_path_id(data.m_Father),
            "localPosition": vector(data.m_LocalPosition, ("x", "y", "z")),
            "localRotation": vector(data.m_LocalRotation, ("x", "y", "z", "w")),
            "localScale": vector(data.m_LocalScale, ("x", "y", "z")),
            "childPathIds": [pointer_path_id(child) for child in data.m_Children],
        }

    require(transforms, "shield_fx_transform_missing")

    def hierarchy_path(path_id: int, visiting: set[int] | None = None) -> str:
        visiting = set() if visiting is None else visiting
        require(path_id not in visiting, "shield_fx_transform_cycle")
        visiting.add(path_id)
        item = transforms[path_id]
        parent_id = item["parentPathId"]
        if parent_id == 0 or parent_id not in transforms:
            return item["name"]
        return hierarchy_path(parent_id, visiting) + "/" + item["name"]

    rows: list[dict[str, Any]] = []
    for path_id, transform in transforms.items():
        row = dict(transform)
        row["hierarchyPath"] = hierarchy_path(path_id)
        rows.append(row)
    rows.sort(key=lambda row: (row["hierarchyPath"], row["pathId"]))

    canonical_rows = [
        {
            "pathHash": sha256_bytes(row["hierarchyPath"].encode("utf-8")),
            "parentPathHash": (
                sha256_bytes(
                    hierarchy_path(row["parentPathId"]).encode("utf-8")
                )
                if row["parentPathId"] in transforms
                else None
            ),
            "localPosition": row["localPosition"],
            "localRotation": row["localRotation"],
            "localScale": row["localScale"],
            "childCount": len(row["childPathIds"]),
        }
        for row in rows
    ]
    roots = [row for row in rows if row["parentPathId"] not in transforms]
    root_values = [
        {
            "localPosition": row["localPosition"],
            "localRotation": row["localRotation"],
            "localScale": row["localScale"],
            "childCount": len(row["childPathIds"]),
        }
        for row in roots
    ]
    public = {
        "roleCode": role,
        "bundleByteLength": path.stat().st_size,
        "bundleSha256": sha256_file(path),
        "objectTypeCountSha256": sha256_bytes(canonical_json(type_counts)),
        "transformCount": len(rows),
        "rootTransformCount": len(roots),
        "rootTransformSha256": sha256_bytes(canonical_json(root_values)),
        "transformGraphSha256": sha256_bytes(canonical_json(canonical_rows)),
    }
    private = {
        **public,
        "bundlePath": str(path),
        "objectTypeCounts": dict(sorted(type_counts.items())),
        "transforms": rows,
    }
    return public, private


def run(args: argparse.Namespace) -> None:
    if args.unitypy_root:
        sys.path.insert(0, str(args.unitypy_root.resolve()))
    try:
        import UnityPy  # type: ignore
    except Exception as exception:
        raise InspectionError("shield_fx_unitypy_unavailable") from exception

    bundles: list[tuple[str, Path]] = []
    for item in args.bundle:
        role, separator, raw_path = item.partition("=")
        require(
            bool(separator)
            and role in {"fire", "water", "wind", "electric", "iron"},
            "shield_fx_bundle_argument_invalid",
        )
        bundles.append((role, Path(raw_path).resolve()))
    require(
        len(bundles) == 5 and len({role for role, _ in bundles}) == 5,
        "shield_fx_bundle_set_invalid",
    )

    public_rows: list[dict[str, Any]] = []
    private_rows: list[dict[str, Any]] = []
    for role, path in sorted(bundles):
        public, private = inspect_bundle(role, path, UnityPy)
        public_rows.append(public)
        private_rows.append(private)

    source = next(row for row in public_rows if row["roleCode"] == "electric")
    comparison = [
        {
            "roleCode": row["roleCode"],
            "rootTransformMatchesElectric": (
                row["rootTransformSha256"] == source["rootTransformSha256"]
            ),
            "transformGraphMatchesElectric": (
                row["transformGraphSha256"] == source["transformGraphSha256"]
            ),
        }
        for row in public_rows
        if row["roleCode"] != "electric"
    ]
    receipt = {
        "schemaVersion": 1,
        "contractId": "nll/boss-shield-fx-transform-inspection/v1",
        "sourceRoleCode": "electric",
        "bundles": public_rows,
        "comparisons": comparison,
        "rawSourceIdentifiersPersisted": False,
        "sourceAssetsModified": False,
    }
    write_atomic(args.output.resolve(), receipt)
    if args.private_output:
        write_atomic(
            args.private_output.resolve(),
            {
                "schemaVersion": 1,
                "contractId": "nll/private-boss-shield-fx-transform-inspection/v1",
                "bundles": private_rows,
            },
        )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--bundle", action="append", required=True)
    result.add_argument("--unitypy-root", type=Path)
    result.add_argument("--output", required=True, type=Path)
    result.add_argument("--private-output", type=Path)
    return result


def main() -> int:
    try:
        run(parser().parse_args())
        return 0
    except InspectionError as exception:
        print(str(exception), file=sys.stderr)
        return 1
    except Exception:
        if os.environ.get("NLL_PRIVATE_DIAGNOSTIC") == "1":
            traceback.print_exc()
        print("shield_fx_uncontrolled_failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
