"""Build/verify/restore an OFFLINE, independently owned FX store copy.

Never install into a client/cache or claim native integrity acceptance. The source
store stays read-only; create and restore stream to a new partial file, verify its
whole-file digest, then rename. Failed outputs remain private diagnostic artifacts.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

spec = importlib.util.spec_from_file_location("store_fx", Path(__file__).with_name("materialize-nll-shield-fx-candidate.py"))
fx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fx)
CONTRACT = "nll/native-fx-offline-store/v1"
SELECTED_CONTRACT = "nll/native-fx-offline-selected-store/v1"


def require(value, suffix):
    fx.require(value, "native_fx_store_" + suffix)


def fingerprint(path):
    path = fx.plain_path(path, file=True)
    digest, length = hashlib.sha256(), 0
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(data)
            length += len(data)
    return {"sha256": digest.hexdigest(), "byteLength": length}


def document(path, pin):
    path = fx.plain_path(path, file=True)
    require(0 < path.stat().st_size <= 1024 * 1024, "manifest_size_invalid")
    raw = path.read_bytes()
    require(fx.digest(raw) == pin, "manifest_drift")
    return json.loads(raw)


def package(root, seal):
    root = fx.plain_path(root)
    receipt = document(root / "receipt.json", seal)
    require(receipt.get("contractId") == "nll/native-fx-chunk-candidate/v1"
            and receipt.get("statusCode") == "offline_chunk_candidate_verified"
            and receipt.get("nativeClientExecuted") is False
            and receipt.get("installedFilesModified") is False
            and receipt.get("oldChunkDigestsMatch") is False
            and receipt.get("indexTrailerVerified") is True
            and receipt.get("exactCompressedLengthRoundTripVerified") is True
            and receipt.get("sourceFilesUnchanged") is True
            and receipt.get("runtimeAdmissionStatusCode") == "not_assessed", "package_invalid")
    manifest = document(root / "manifest.private.json", receipt["manifestSha256"])
    require(manifest.get("contractId") == "nll/native-fx-chunk-candidate-private/v1"
            and manifest.get("nativeClientExecuted") is False
            and manifest.get("oldChunkDigestsMatch") is False
            and manifest.get("runtimeAdmissionStatusCode") == "not_assessed"
            and manifest["layoutSha256"] == receipt["layoutSha256"], "package_invalid")
    source = manifest["sourceStore"]
    source_pin = {"sha256": receipt["sourceStoreSha256"], "byteLength": receipt["sourceStoreByteLength"]}
    require({k: source[k] for k in source_pin} == source_pin and type(source_pin["byteLength"]) is int
            and source_pin["byteLength"] > 256, "source_binding_invalid")
    entries = manifest["entries"]
    require(0 < len(entries) <= 32 and len(entries) == receipt["changedChunkCount"]
            and sorted({r["roleCode"] for r in entries}) == sorted(fx.ROLES)
            and sorted(receipt["roleCodes"]) == sorted(fx.ROLES), "entries_invalid")
    previous, identities, result = 256, set(), []
    for row in sorted(entries, key=lambda entry: entry["offset"]):
        role, ordinal, offset, size = (row[key] for key in ("roleCode", "ordinal", "offset", "byteLength"))
        require(role in fx.ROLES and type(ordinal) is int and ordinal >= 0
                and (role, ordinal) not in identities and type(size) is int and 0 < size <= 16 * 1024 * 1024
                and type(offset) is int and previous <= offset <= source_pin["byteLength"] - size, "range_invalid")
        identities.add((role, ordinal))
        previous = offset + size
        values = {}
        for kind in ("before", "after"):
            name = f"{role}-{ordinal}-{kind}.chunk"
            require(row[kind + "File"] == name, "filename_invalid")
            path = fx.plain_path(root / name, file=True)
            require(path.stat().st_size == size, "chunk_size_invalid")
            values[kind] = path.read_bytes()
            require(fx.digest(values[kind]) == row[kind + "Sha256"], "chunk_drift")
        require(values["before"] != values["after"], "chunk_unchanged")
        result.append({"roleCode": role, "offset": offset, **values})
    return source, source_pin, result


def select_patches(patches, role):
    require(role is None or (type(role) is str and role in fx.ROLES), "selected_role_invalid")
    selected = patches if role is None else [row for row in patches if row["roleCode"] == role]
    require(bool(selected), "selected_role_missing")
    return selected


def copy_with_patches(source, temporary, patches, reverse=False):
    """Each original byte is read once; untouched regions are copied verbatim."""
    fx.plain_path(source, file=True)
    fx.plain_path(temporary.parent)
    require(not os.path.lexists(temporary), "partial_exists")
    before_hash, after_hash, length = hashlib.sha256(), hashlib.sha256(), 0
    with source.open("rb") as reader, temporary.open("xb") as writer:
        def transfer(count):
            nonlocal length
            while count:
                data = reader.read(min(count, 1024 * 1024))
                require(data, "source_truncated")
                before_hash.update(data)
                after_hash.update(data)
                writer.write(data)
                length += len(data)
                count -= len(data)

        for row in patches:
            transfer(row["offset"] - length)
            expected, replacement = ((row["after"], row["before"]) if reverse
                                     else (row["before"], row["after"]))
            raw = reader.read(len(expected))
            require(raw == expected, "source_chunk_mismatch")
            before_hash.update(raw)
            after_hash.update(replacement)
            writer.write(replacement)
            length += len(raw)
        transfer(os.fstat(reader.fileno()).st_size - length)
        require(reader.read(1) == b"", "source_grew")
        writer.flush()
        os.fsync(writer.fileno())
    return ({"sha256": before_hash.hexdigest(), "byteLength": length},
            {"sha256": after_hash.hexdigest(), "byteLength": length})


def writable_root(root):
    root = fx.plain_path(root)
    require(root != Path(root.anchor), "root_invalid")
    if sys.platform == "win32":
        require(all(p != root and p not in root.parents and root not in p.parents
                    for p in (Path("C:/NLL"), Path("C:/NIKKE"))), "root_protected")
    return root


def create(package_root, package_seal, output, role=None):
    package_root, output = fx.plain_path(package_root), writable_root(output)
    source, source_pin, patches = package(package_root, package_seal)
    patches = select_patches(patches, role)
    source_path = fx.plain_path(Path(source["path"]), file=True)
    protected = (package_root, source_path.parent)
    require(not os.path.lexists(output) and output.parent.is_dir() and all(
        p != output and p not in output.parents and output not in p.parents for p in protected), "output_invalid")
    require(fingerprint(source_path) == source_pin, "source_drift")
    output.mkdir()
    temporary = output / "store.cdb.partial"
    before, after = copy_with_patches(source_path, temporary, patches)
    require(before == source_pin and fingerprint(temporary) == after and before != after, "copy_mismatch")
    package(package_root, package_seal)
    require(fingerprint(source_path) == source_pin, "source_drift")
    temporary.rename(output / "store.cdb")
    manifest = {"contractId": CONTRACT if role is None else SELECTED_CONTRACT,
                "packageRoot": str(package_root), "packageSha256": package_seal,
                "original": before, "candidate": after, "nativeClientExecuted": False,
                "installedFilesModified": False, "runtimeAdmissionStatusCode": "not_assessed"}
    if role is not None:
        manifest["roleCode"] = role
    raw = fx.encoded(manifest)
    fx.new_file(output / "manifest.private.json", raw)  # Last: only a complete copy is usable.
    return {"contractId": "nll/native-fx-offline-store-receipt/v1", "manifestSha256": fx.digest(raw),
            "original": before, "candidate": after, "statusCode": "offline_copy_verified",
            "roleCode": role, "allRolesApplied": role is None,
            "nativeClientExecuted": False, "installedFilesModified": False,
            "runtimeAdmissionStatusCode": "not_assessed"}


def inspect(root, seal, restore=False):
    root = writable_root(root)
    manifest = document(root / "manifest.private.json", seal)
    require(manifest.get("contractId") in (CONTRACT, SELECTED_CONTRACT) and manifest.get("nativeClientExecuted") is False
            and manifest.get("installedFilesModified") is False
            and manifest.get("runtimeAdmissionStatusCode") == "not_assessed", "manifest_invalid")
    with fx.locked(root):
        _, original, all_patches = package(Path(manifest["packageRoot"]), manifest["packageSha256"])
        patches = all_patches
        if manifest["contractId"] == SELECTED_CONTRACT:
            require(type(manifest.get("roleCode")) is str and manifest["roleCode"] in fx.ROLES, "selected_role_invalid")
            patches = select_patches(patches, manifest["roleCode"])
        else:
            require("roleCode" not in manifest, "legacy_role_forbidden")
        require(manifest["original"] == original and manifest["candidate"]["byteLength"] == original["byteLength"]
                and manifest["candidate"] != original, "manifest_invalid")
        path, partial = root / "store.cdb", root / "store.cdb.restore-partial"
        current = fingerprint(path)
        require(current in (manifest["candidate"], original), "copy_drift")
        # The whole-file pin alone does not prove the stated selected role. Check
        # every package range, including the other roles that must stay original.
        role = manifest.get("roleCode")
        with path.open("rb") as stream:
            for row in all_patches:
                kind = "after" if current != original and (role is None or row["roleCode"] == role) else "before"
                stream.seek(row["offset"])
                require(stream.read(len(row[kind])) == row[kind], "selected_role_binding_mismatch")
        if restore:
            if current == manifest["candidate"]:
                if os.path.lexists(partial):
                    # A fully flushed, verified interrupted replacement can finish.
                    # Incomplete/foreign partials stay for diagnosis, never deleted.
                    require(fingerprint(partial) == original, "partial_drift")
                else:
                    before, after = copy_with_patches(path, partial, patches, reverse=True)
                    require(before == current and after == original and fingerprint(partial) == original, "restore_mismatch")
                require(fingerprint(path) == current, "copy_drift")
                document(root / "manifest.private.json", seal)
                package(Path(manifest["packageRoot"]), manifest["packageSha256"])
                os.replace(partial, path)  # Only this owned copy; never the source store.
            else:
                require(not os.path.lexists(partial), "partial_unexpected")
            require(fingerprint(path) == original, "restore_mismatch")
        else:
            require(current == manifest["candidate"] and not os.path.lexists(partial), "candidate_not_ready")
    return {"contractId": "nll/native-fx-offline-store-inspection/v1",
            "statusCode": "offline_copy_restored" if restore else "offline_copy_verified",
            "manifestSha256": seal, "nativeClientExecuted": False, "installedFilesModified": False,
            "runtimeAdmissionStatusCode": "not_assessed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("create", "verify", "restore"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--role", choices=fx.ROLES,
                        help="Apply only this boss-element role to the new offline copy (not a weakness code).")
    args = parser.parse_args()
    try:
        require((args.command == "create") == (args.output_root is not None), "arguments_invalid")
        require(args.command == "create" or args.role is None, "arguments_invalid")
        result = (create(args.root, args.sha256, args.output_root, args.role) if args.command == "create"
                  else inspect(args.root, args.sha256, args.command == "restore"))
        print(json.dumps(result))
        return 0
    except Exception as error:
        code = str(error)
        print(code if re.fullmatch("(native|shield)_fx_[a-z0-9_]+", code)
              else "native_fx_store_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
