"""Stage length-preserving native FX bundles, without touching any installation.

Only equal-sized, verified sizing payloads from a hash-bound native candidate
are copied into their original serialized positions. Container metadata,
object offsets and every other byte stay intact. This is an OFFLINE candidate, not
proof of the game's catalog integrity acceptance or visual correctness.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import re
import struct
import sys


spec = importlib.util.spec_from_file_location(
    "layout_candidate", Path(__file__).with_name("materialize-nll-shield-fx-candidate.py"))
fx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fx)
LIMIT = 64 * 1024 * 1024
CONTRACT = "nll/native-fx-fixed-layout-candidate/v1"


def require(value, suffix):
    fx.require(value, "native_fx_layout_" + suffix)


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, length):
        require(0 <= length <= len(self.data) - self.pos, "truncated")
        result = self.data[self.pos:self.pos + length]
        self.pos += length
        return result

    def unpack(self, fmt):
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))

    def string(self):
        end = self.data.find(b"\0", self.pos, self.pos + 4097)
        require(end >= self.pos, "string_invalid")
        return self.take(end - self.pos + 1)[:-1]


def directory(data, decompress):
    require(0 < len(data) <= LIMIT, "size_invalid")
    head = Reader(data)
    require(head.string() == b"UnityFS", "format_unsupported")
    version, = head.unpack(">I")
    require(version in (7, 8), "version_unsupported")
    head.string()
    head.string()
    size, packed, decoded, flags = head.unpack(">QIII")
    require(size == len(data) and 20 <= decoded <= LIMIT and 0 < packed <= LIMIT,
            "header_invalid")
    require(flags & ~0x2FF == 0 and flags & 63 in (0, 2, 3), "flags_unsupported")
    body_start = (head.pos + 15) & ~15
    info_start = len(data) - packed if flags & 128 else body_start
    require(body_start <= info_start <= len(data) - packed, "info_range_invalid")
    raw_info = data[info_start:info_start + packed]
    info = raw_info if flags & 63 == 0 else decompress(raw_info, decoded)
    require(len(info) == decoded, "info_size_invalid")
    table = Reader(info)
    # A nonzero content hash would need an independently understood update rule.
    require(table.take(16) == bytes(16), "content_digest_unsupported")
    count, = table.unpack(">I")
    require(0 < count <= 65536, "block_count_invalid")
    body_size = 0
    for _ in range(count):
        raw, compressed, block_flags = table.unpack(">IIH")
        # Bit 0x40 is present on the pinned native uncompressed blocks. It is
        # preserved byte-for-byte; only the compression mask and unknown bits
        # constrain whether physical object offsets can be used directly.
        require(raw == compressed and raw > 0 and block_flags in (0, 64),
                "compressed_body_unsupported")
        body_size += raw
        require(body_size <= LIMIT, "size_invalid")
    if not flags & 128:
        body_start = info_start + packed
    if flags & 512:
        body_start = (body_start + 15) & ~15
    require(body_start + body_size == (info_start if flags & 128 else len(data)),
            "body_range_invalid")
    count, = table.unpack(">I")
    require(0 < count <= 4096, "node_count_invalid")
    nodes = {}
    for _ in range(count):
        start, length, _ = table.unpack(">QQI")
        name = table.string().decode("utf-8")
        require(name and name not in nodes and 0 < length <= body_size
                and start <= body_size - length, "node_range_invalid")
        nodes[name] = (body_start + start, length)
    require(table.pos == len(info), "directory_trailing_data")
    previous = body_start
    for start, length in sorted(nodes.values()):
        require(start >= previous, "node_overlap")
        previous = start + length
    return nodes


def objects(environment):
    rows = list(environment.objects)
    result = {int(obj.path_id): obj for obj in rows}
    require(rows and len(rows) == len(result), "object_identity_ambiguous")
    return result


def materialize(original, overlay, unity, decompress, allowed_changes=None):
    nodes = directory(original, decompress)
    original_env, overlay_env = unity.load(original), unity.load(overlay)
    before, after = objects(original_env), objects(overlay_env)
    require(before.keys() == after.keys(), "object_set_changed")
    top = list(original_env.files.values())
    require(len(top) == 1 and set(top[0].files) == set(nodes), "node_binding_invalid")
    candidate = bytearray(original)
    ranges, changes = [], []
    for key, obj in before.items():
        other = after[key]
        require(obj.type.name == other.type.name, "object_type_changed")
        raw, target = obj.get_raw_data(), other.get_raw_data()
        matches = [nodes[name] for name, file in top[0].files.items() if file is obj.assets_file]
        require(len(matches) == 1, "object_file_ambiguous")
        node_start, node_size = matches[0]
        require(len(raw) == obj.byte_size and 0 <= obj.byte_start <= node_size - len(raw),
                "object_range_invalid")
        start, end = node_start + obj.byte_start, node_start + obj.byte_start + len(raw)
        require(original[start:end] == raw, "object_bytes_mismatch")
        ranges.append((start, end))
        if raw == target:
            continue
        allowed = (obj.type.name == "Transform" if allowed_changes is None else
                   allowed_changes.get((obj.type.name, key)) == fx.digest(target))
        require(allowed and len(raw) == len(target), "change_not_allowed")
        candidate[start:end] = target
        changes.append((start, end))
    previous = 0
    for start, end in sorted(ranges):
        require(start >= previous, "object_overlap")
        previous = end
    require(changes and len(candidate) == len(original), "no_transform_change")
    parsed = objects(unity.load(bytes(candidate)))
    require(parsed.keys() == after.keys() and all(
        parsed[key].type.name == obj.type.name and parsed[key].get_raw_data() == obj.get_raw_data()
        for key, obj in after.items()), "roundtrip_mismatch")
    require(directory(bytes(candidate), decompress) == nodes, "directory_changed")
    return bytes(candidate), len(changes)


def stage(source, source_sha256, output, unity, decompress):
    source, output = fx.plain_path(source), fx.plain_path(output)
    require(not output.exists() and output.parent.is_dir() and output != source
            and source not in output.parents and output not in source.parents, "output_invalid")
    if sys.platform == "win32":
        require(all(p != output and p not in output.parents and output not in p.parents
                    for p in (Path("C:/NLL"), Path("C:/NIKKE"))), "output_protected")
    pins = {}

    def read(path, pin):
        path = fx.plain_path(path, file=True)
        require(0 < path.stat().st_size <= LIMIT, "size_invalid")
        data = path.read_bytes()
        require(fx.digest(data) == pin, "input_drift")
        pins[path] = pin
        return data

    receipt = json.loads(read(source / "receipt.json", source_sha256))
    require(receipt.get("contractId") == "nll/native-fx-candidate-receipt/v1"
            and receipt.get("statusCode") == "offline_native_candidate_verified"
            and receipt.get("nativeClientExecuted") is False
            and receipt.get("installedFilesModified") is False
            and receipt.get("runtimeAdmissionStatusCode") == "not_assessed", "source_invalid")
    # Preserve provenance to the exact native catalog binding, without logging keys.
    read(source / "native/binding.private.json", receipt["bindingManifestSha256"])
    read(source / "export-plan.private.json", receipt["exportPlanSha256"])
    entries = receipt["entries"]
    prepared = "recipePolicyCode" in receipt
    if prepared:
        spec = importlib.util.spec_from_file_location("layout_recipes", Path(__file__).with_name("nll-shield-fx-recipes.py"))
        recipes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(recipes)
        require(receipt["recipePolicyCode"] == recipes.POLICY and 0 < len(entries) <= 5
                and len({r["roleCode"] for r in entries}) == len(entries)
                and all(r["roleCode"] in ("fire", "water", "wind", "electric", "iron") for r in entries), "roles_invalid")
    else:
        require(len(entries) == 3 and {r["roleCode"] for r in entries} == set(fx.ROLES), "roles_invalid")
    payloads, rows = {}, []
    for row in sorted(entries, key=lambda item: item["roleCode"]):
        role = row["roleCode"]
        original = read(source / "native" / (role + ".bundle"), row["original"]["sha256"])
        overlay = read(source / (role + ".bundle"), row["overlay"]["sha256"])
        require(len(original) == row["original"]["byteLength"]
                and len(overlay) == row["overlay"]["byteLength"], "input_size_mismatch")
        allowed_changes = None
        if prepared:
            reference = read(source / "native" / (receipt["sourceRoleCode"] + ".bundle"), row["evidence"]["sourceBundle"]["sha256"])
            evidence, regenerated = recipes.materialize_pair(reference, original, unity)
            require(regenerated == overlay and evidence == row["evidence"], "recipe_rederivation_failed")
            before, after = objects(unity.load(original)), objects(unity.load(overlay))
            allowed_changes = {(obj.type.name, key): fx.digest(obj.get_raw_data()) for key, obj in after.items()
                               if obj.get_raw_data() != before[key].get_raw_data()}
        payload, count = materialize(original, overlay, unity, decompress, allowed_changes)
        payloads[role] = payload
        rows.append({"roleCode": role, "original": row["original"],
                     "verifiedOverlay": row["overlay"],
                     "fixedLayout": {"sha256": fx.digest(payload), "byteLength": len(payload)},
                     "changedTransformCount": count if allowed_changes is None else sum(k[0] == "Transform" for k in allowed_changes),
                     "changedObjectCount": count, "objectPayloadsMatchVerifiedOverlay": True,
                     "directoryAndOffsetsUnchanged": True})
    for path, pin in list(pins.items()):
        read(path, pin)
    output.mkdir()  # Exclusive reservation. No receipt on partial/interrupted output.
    for role, payload in payloads.items():
        fx.new_file(output / (role + ".bundle"), payload)
    for path, pin in list(pins.items()):
        read(path, pin)
    require(all(fx.fingerprint(output / (role + ".bundle"))["sha256"] == fx.digest(payload)
                for role, payload in payloads.items()), "output_drift")
    result = {"contractId": CONTRACT, "sourceCandidateSha256": source_sha256,
              "bindingManifestSha256": receipt["bindingManifestSha256"],
              "exportPlanSha256": receipt["exportPlanSha256"], "entries": rows,
              "statusCode": "offline_fixed_layout_verified", "nativeClientExecuted": False,
              "installedFilesModified": False, "runtimeAdmissionStatusCode": "not_assessed"}
    fx.new_file(output / "receipt.json", fx.encoded(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-root", "output-root", "unitypy-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    args = parser.parse_args()
    try:
        sys.path.insert(0, str(fx.plain_path(args.unitypy_root)))
        import UnityPy
        import lz4.block
        print(json.dumps(stage(args.source_root, args.source_sha256, args.output_root, UnityPy,
                               lambda data, size: lz4.block.decompress(data, uncompressed_size=size))))
        return 0
    except Exception as error:
        code = str(error)
        print(code if re.fullmatch("(native|shield)_fx_[a-z0-9_]+", code)
              else "native_fx_layout_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
