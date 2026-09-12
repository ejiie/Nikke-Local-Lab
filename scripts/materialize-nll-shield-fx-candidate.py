"""Offline, profile-pinned FX candidates. Never an installed cache or admission writer.

Create requires a new independent directory. A manifest is published last; failures
leave an unsealed directory for diagnosis, not a usable candidate. Verify and restore
require the caller's manifest hash. Restore only replaces this candidate's three
overlay files with its pinned backup bytes; it never writes to the input cache.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any


ROLES = ("fire", "wind", "iron")
EVIDENCE_FIELDS = (
    "sourceTransformCount", "targetTransformCount", "matchedTransformCount",
    "modifiedTransformCount", "matchedTransformValueSetSha256", "nonTransformObjectSetSha256",
)
CONTRACT = "nll/boss-shield-fx-isolated-candidate/v1"


class CandidateError(Exception):
    pass


def require(condition: bool, code: str) -> None:
    if not condition:
        raise CandidateError(code)


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def encoded(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def fingerprint(path: Path) -> dict[str, Any]:
    payload = path.read_bytes()
    return {"sha256": digest(payload), "byteLength": len(payload)}


def pin(row: dict[str, Any], prefix: str) -> dict[str, Any]:
    value = {"sha256": row[prefix + "Sha256"], "byteLength": row[prefix + "ByteLength"]}
    require(isinstance(value["sha256"], str) and re.fullmatch("[0-9a-f]{64}", value["sha256"])
            is not None and type(value["byteLength"]) is int and value["byteLength"] > 0,
            "shield_fx_candidate_pin_invalid")
    return value


def plain_path(path: Path, *, file: bool = False) -> Path:
    """Check lexical ancestors before resolve, including Windows junctions."""
    path = Path(os.path.abspath(path))
    for part in [*reversed(path.parents), path]:
        if not os.path.lexists(part):
            continue
        info = part.lstat()
        require(not stat.S_ISLNK(info.st_mode)
                and not (getattr(info, "st_file_attributes", 0) & 0x400),
                "shield_fx_candidate_reparse_forbidden")
        if part != path or not file:
            require(stat.S_ISDIR(info.st_mode), "shield_fx_candidate_directory_invalid")
        else:
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                    "shield_fx_candidate_file_not_owned")
    if file:
        require(path.is_file(), "shield_fx_candidate_file_missing")
    return path


def new_file(path: Path, payload: bytes) -> None:
    plain_path(path.parent)
    with path.open("xb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


def load_profile(path: Path, expected: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    raw = path.read_bytes()
    require(digest(raw) == expected, "shield_fx_candidate_profile_drifted")
    profile = json.loads(raw)
    require(profile["schemaVersion"] == 3
            and profile["contractId"] == "nll/boss-runtime-variant-profile/v3",
            "shield_fx_candidate_profile_version_invalid")
    plan = profile["shieldFxTransformNormalization"]
    rows = plan["variants"]
    require(plan["modeCode"] == "per_execution_target_bundle_overlay"
            and plan["sourceBossElementCode"] == "electric"
            and plan["targetBossElementCodes"] == list(ROLES)
            and [row["bossElementCode"] for row in rows] == list(ROLES),
            "shield_fx_candidate_plan_unsupported")
    variants = profile["elementShield"]["fxVariants"]
    require([row["bossElementCode"] for row in variants]
            == ["fire", "water", "wind", "electric", "iron"],
            "shield_fx_candidate_mapping_invalid")
    bundles = {row["bossElementCode"]: [bundle for mapping in row["mappings"]
               for bundle in mapping["assetBundles"]] for row in variants}
    for row in rows:
        require(bundles["electric"] == [pin(row, "sourceBundle")]
                and bundles[row["bossElementCode"]] == [pin(row, "targetBundle")],
                "shield_fx_candidate_mapping_drifted")
        require(pin(row, "variantBundle") != pin(row, "targetBundle"),
                "shield_fx_candidate_variant_invalid")
        counts = [row[field] for field in EVIDENCE_FIELDS[:4]]
        require(all(type(count) is int and count > 0 for count in counts)
                and counts[3] <= counts[2] <= min(counts[:2]),
                "shield_fx_candidate_evidence_invalid")
        require(all(isinstance(row[field], str) and re.fullmatch("[0-9a-f]{64}", row[field])
                    for field in EVIDENCE_FIELDS[4:]), "shield_fx_candidate_evidence_invalid")
    return profile, rows


def resolve_inputs(cache: Path, rows: list[dict[str, Any]]) -> dict[str, Path]:
    wanted = {row[prefix + "Sha256"]: row[prefix + "ByteLength"]
              for row in rows for prefix in ("sourceBundle", "targetBundle")}
    found: dict[str, Path] = {}
    for directory, children, names in os.walk(cache, followlinks=False):
        # Reparse directories are not searched, even if they point inside the cache.
        children[:] = [name for name in children if not (
            stat.S_ISLNK(Path(directory, name).lstat().st_mode)
            or getattr(Path(directory, name).lstat(), "st_file_attributes", 0) & 0x400)]
        for name in sorted(names):
            path = Path(directory, name)
            if path.suffix != ".bundle" or path.stat().st_size not in wanted.values():
                continue
            plain_path(path, file=True)
            actual = fingerprint(path)
            if wanted.get(actual["sha256"]) == actual["byteLength"]:
                found.setdefault(actual["sha256"], path)
    require(set(found) == set(wanted), "shield_fx_candidate_input_missing")
    return found


def expected_entries(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [{"roleCode": row["bossElementCode"],
             "backup": pin(row, "targetBundle"), "overlay": pin(row, "variantBundle"),
             "evidence": {field: row[field] for field in EVIDENCE_FIELDS}} for row in rows]


def create(profile_path: Path, profile_sha: str, cache: Path, output: Path,
           materialize: Any, unitypy: Any) -> dict[str, Any]:
    _, rows = load_profile(profile_path, profile_sha)
    cache = plain_path(cache)
    require(cache.is_dir(), "shield_fx_candidate_cache_missing")
    output = plain_path(output)
    require(cache != output and cache not in output.parents and output not in cache.parents,
            "shield_fx_candidate_output_overlaps_input")
    require(not os.path.lexists(output) and output.parent.is_dir(),
            "shield_fx_candidate_output_exists_or_parent_missing")
    inputs = resolve_inputs(cache, rows)
    before = {key: fingerprint(path) for key, path in inputs.items()}
    output.mkdir()  # Exclusive reservation; no reuse of failed or existing candidates.
    for name in ("source", "backup", "overlay"):
        (output / name).mkdir()
    source = output / "source/electric.bundle"
    new_file(source, inputs[rows[0]["sourceBundleSha256"]].read_bytes())
    require(fingerprint(source) == pin(rows[0], "sourceBundle"),
            "shield_fx_candidate_input_drifted")
    new_file(output / "profile.json", profile_path.read_bytes())
    require(fingerprint(output / "profile.json")["sha256"] == profile_sha,
            "shield_fx_candidate_profile_drifted")
    for row in rows:
        role = row["bossElementCode"]
        backup = output / f"backup/{role}.bundle"
        overlay = output / f"overlay/{role}.bundle"
        new_file(backup, inputs[row["targetBundleSha256"]].read_bytes())
        require(fingerprint(backup) == pin(row, "targetBundle"), "shield_fx_candidate_input_drifted")
        derived, evidence = materialize(source, backup, unitypy)
        require({field: evidence[field] for field in EVIDENCE_FIELDS}
                == {field: row[field] for field in EVIDENCE_FIELDS},
                "shield_fx_candidate_transform_evidence_drifted")
        require({"sha256": digest(derived), "byteLength": len(derived)} == pin(row, "variantBundle"),
                "shield_fx_candidate_derived_drifted")
        new_file(overlay, derived)
    require(before == {key: fingerprint(path) for key, path in inputs.items()},
            "shield_fx_candidate_input_drifted")
    manifest = {"schemaVersion": 1, "contractId": CONTRACT, "profileSha256": profile_sha,
                "source": pin(rows[0], "sourceBundle"), "entries": expected_entries(rows),
                "statusCode": "isolated_candidate_verified", "runtimeAdmissionStatusCode": "not_assessed",
                "sharedCacheModified": False, "clientStarted": False,
                "rawSourceIdentifiersPersisted": False}
    validate_files(output, manifest, restored_allowed=False)
    new_file(output / "manifest.json", encoded(manifest))  # Completion marker, always last.
    return {"statusCode": manifest["statusCode"], "manifestSha256": digest(encoded(manifest)),
            "variantCount": len(rows), "runtimeAdmissionStatusCode": "not_assessed"}


def validate_files(root: Path, manifest: dict[str, Any], *, restored_allowed: bool) -> list[str]:
    source = plain_path(root / "source/electric.bundle", file=True)
    require(fingerprint(source) == manifest["source"], "shield_fx_candidate_source_drifted")
    states = []
    for entry in manifest["entries"]:
        role = entry["roleCode"]
        backup = plain_path(root / f"backup/{role}.bundle", file=True)
        overlay = plain_path(root / f"overlay/{role}.bundle", file=True)
        require(fingerprint(backup) == entry["backup"], "shield_fx_candidate_backup_drifted")
        actual = fingerprint(overlay)
        if actual == entry["overlay"]:
            states.append("derived")
        elif restored_allowed and actual == entry["backup"]:
            states.append("restored")
        else:
            raise CandidateError("shield_fx_candidate_overlay_drifted")
    return states


@contextmanager
def locked(root: Path):
    path = root / ".operation.lock"
    try:
        new_file(path, b"exclusive candidate operation\n")
    except FileExistsError as exception:
        raise CandidateError("shield_fx_candidate_busy") from exception
    try:
        yield
    finally:
        path.unlink()


def inspect_or_restore(root: Path, expected_sha: str, *, restore: bool = False) -> dict[str, Any]:
    root = plain_path(root)
    manifest_path = plain_path(root / "manifest.json", file=True)
    raw = manifest_path.read_bytes()
    require(digest(raw) == expected_sha, "shield_fx_candidate_manifest_drifted")
    manifest = json.loads(raw)
    require(manifest["schemaVersion"] == 1 and manifest["contractId"] == CONTRACT,
            "shield_fx_candidate_manifest_invalid")
    profile_path = plain_path(root / "profile.json", file=True)
    _, rows = load_profile(profile_path, manifest["profileSha256"])
    require(manifest["entries"] == expected_entries(rows)
            and manifest["source"] == pin(rows[0], "sourceBundle")
            and manifest["statusCode"] == "isolated_candidate_verified"
            and manifest["runtimeAdmissionStatusCode"] == "not_assessed"
            and all(manifest[field] is False for field in (
                "sharedCacheModified", "clientStarted", "rawSourceIdentifiersPersisted")),
            "shield_fx_candidate_manifest_invalid")
    with locked(root):
        # Preflight every file before the first replacement. Interrupted restores
        # may contain a mix of the two pinned states and can be retried safely.
        states = validate_files(root, manifest, restored_allowed=restore)
        if restore:
            for entry in manifest["entries"]:
                partial = root / f"overlay/{entry['roleCode']}.restore.partial"
                if os.path.lexists(partial):
                    require(fingerprint(plain_path(partial, file=True)) == entry["backup"],
                            "shield_fx_candidate_restore_partial_drifted")
            for entry, state in zip(manifest["entries"], states):
                if state == "restored":
                    continue
                role = entry["roleCode"]
                target = root / f"overlay/{role}.bundle"
                temporary = root / f"overlay/{role}.restore.partial"
                payload = (root / f"backup/{role}.bundle").read_bytes()
                require({"sha256": digest(payload), "byteLength": len(payload)} == entry["backup"],
                        "shield_fx_candidate_backup_drifted")
                if os.path.lexists(temporary):
                    require(fingerprint(plain_path(temporary, file=True)) == entry["backup"],
                            "shield_fx_candidate_restore_partial_drifted")
                else:
                    new_file(temporary, payload)
                require(fingerprint(plain_path(target, file=True)) == entry["overlay"],
                        "shield_fx_candidate_overlay_drifted")
                os.replace(temporary, target)
            states = validate_files(root, manifest, restored_allowed=True)
            require(states == ["restored"] * len(ROLES), "shield_fx_candidate_restore_incomplete")
    return {"statusCode": "candidate_restored" if restore else "isolated_candidate_verified",
            "manifestSha256": expected_sha, "variantCount": len(rows),
            "runtimeAdmissionStatusCode": "not_assessed"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    creation = commands.add_parser("create")
    creation.add_argument("--profile", required=True, type=Path)
    creation.add_argument("--profile-sha256", required=True)
    creation.add_argument("--asset-cache-root", required=True, type=Path)
    creation.add_argument("--output-root", required=True, type=Path)
    creation.add_argument("--unitypy-root", type=Path)
    for name in ("verify", "restore"):
        operation = commands.add_parser(name)
        operation.add_argument("--candidate-root", required=True, type=Path)
        operation.add_argument("--manifest-sha256", required=True)
    args = parser.parse_args()
    try:
        if args.command == "create":
            if args.unitypy_root:
                sys.path.insert(0, str(args.unitypy_root.resolve()))
            import UnityPy
            spec = importlib.util.spec_from_file_location(
                "shield_transform", Path(__file__).with_name("materialize-nll-shield-fx-transform-variant.py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            try:
                result = create(args.profile, args.profile_sha256, args.asset_cache_root,
                                args.output_root, module.materialize, UnityPy)
            except module.MaterializationError as exception:
                raise CandidateError(str(exception)) from exception
        else:
            result = inspect_or_restore(args.candidate_root, args.manifest_sha256,
                                        restore=args.command == "restore")
        print(json.dumps(result, sort_keys=True))
        return 0
    except CandidateError as exception:
        print(str(exception), file=sys.stderr)
        return 1
    except Exception:
        print("shield_fx_candidate_invalid_or_uncontrolled_failure", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
