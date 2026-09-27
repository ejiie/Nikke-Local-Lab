"""Read original shield sizing inputs and emit hash-addressed local reference data.

No asset writes, transform fitting, profile publication or runtime admission.
The numbers are prefab-local inputs, never a claimed world-space/pixel radius.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys


def local_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


fit = local_module("shield_size_fit", "nll-shield-fx-assessment.py")


def describe(payload, unitypy):
    bindings = {}
    snapshot = fit.inspect_bundle(payload, unitypy, bindings)
    nodes = []
    for key, node in sorted(snapshot["nodes"].items()):
        row = {"nodeKey": key, "parentNodeKey": node["parent"],
               "localPosition": node["position"], "localRotation": node["rotation"], "localScale": node["scale"]}
        particle = bindings.get((key, "ParticleSystem"))
        if particle is not None:
            tree = particle.read_typetree()
            initial = tree["InitialModule"]
            row["particleSize"] = {
                "scalingModeRaw": tree["scalingMode"], "size3D": initial.get("size3D"),
                "startSize": {k: initial[k] for k in ("startSize", "startSizeY", "startSizeZ") if k in initial},
                "sizeOverLifetime": tree.get("SizeModule"), "sizeBySpeed": tree.get("SizeBySpeedModule")}
        helper = bindings.get((key, "FxHelper"))
        if helper is not None:
            tree = next(v for kind, v in node["components"] if kind == "FxHelper")
            row["helper"] = {k: tree[k] for k in ("UseScaleHelper", "ScaleHelper", "UseWeaponScaleHelper",
                                                   "WeaponScaleHelper", "UseFocusHelper", "FocusHelper")}
        renderer = bindings.get((key, "ParticleSystemRenderer"))
        if renderer is not None:
            tree = renderer.read_typetree()
            pointer = tree.get("m_Mesh", {"m_FileID": 0, "m_PathID": 0})
            # Mesh payload identity is already normalized by the read-only fit inspector.
            geometry = next(v for kind, v in node["components"] if kind == "ParticleSystemRenderer")
            row["renderer"] = {k: tree.get(k) for k in ("m_RenderMode", "m_MinParticleSize", "m_MaxParticleSize")}
            row["renderer"].update(mesh=geometry.get("m_Mesh"), materialSlotPresent=geometry["materialSlotPresent"])
            if pointer["m_PathID"] and pointer["m_FileID"] == 0:
                mesh = renderer.assets_file.objects.get(pointer["m_PathID"])
                if mesh is not None and mesh.type.name == "Mesh":
                    row["renderer"]["meshLocalBounds"] = mesh.read_typetree().get("m_LocalAABB")
        nodes.append(row)
    return {"bundleSha256": fit.digest(payload), "byteLength": len(payload), "nodes": nodes,
            "inspectionIssues": snapshot["issues"], "coordinateSpaceCode": "prefab_local",
            "worldSpaceSizeStatusCode": "not_measured"}


def size_signature(reference):
    # Orientation remains available in the reference. It is not collapsed into a
    # scalar sizing comparison, nor is equality here a full visual-fit assertion.
    return fit.canonical([{k: v for k, v in row.items() if k != "localRotation"} for row in reference["nodes"]])


def run(args):
    output = args.output.absolute()
    for part in (output, *output.parents):
        if part.is_symlink() or part.exists() and getattr(part.lstat(), "st_file_attributes", 0) & 0x400:
            raise ValueError("shield_size_reference_reparse_output")
    if output.resolve().is_relative_to(args.cache.resolve()):
        raise ValueError("shield_size_reference_output_in_cache")
    profile_bytes = args.profile.read_bytes()
    profile = json.loads(profile_bytes)
    discovery_bytes = args.source_discovery.read_bytes()
    discovery = json.loads(discovery_bytes)
    if (discovery.get("contractId") != "nll/boss-content-discovery/v1"
            or discovery.get("sourceAffinity") != profile["sourceAffinity"]
            or discovery.get("elementShield", {}).get("functionSetSha256") != profile["elementShield"]["functionSetSha256"]):
        raise ValueError("shield_size_reference_discovery_binding_invalid")
    source = profile["sourceAffinity"]["bossElementCode"]
    elements = list(dict.fromkeys([source, *args.compare_element]))
    prepared = {}
    fit.assess(source, profile["elementShield"]["fxVariants"], args.cache, args.unitypy, prepared)
    variants = {v["bossElementCode"]: v for v in profile["elementShield"]["fxVariants"]}
    rows = []
    for element in elements:
        for mapping in variants[element]["mappings"]:
            if len(mapping["assetBundles"]) != 1:
                raise ValueError("shield_size_reference_multi_bundle_unresolved")
            pin = mapping["assetBundles"][0]
            data = describe(prepared["blobs"][pin["sha256"]], args.unitypy)
            rows.append({"bossElementCode": element, "sourceFxPrefabSetSha256": mapping["sourceFxPrefabSetSha256"],
                         "targetFxPrefabSetSha256": mapping["targetFxPrefabSetSha256"],
                         "sizeInputSetSha256": size_signature(data), **data})
    mapping_keys = {r["sourceFxPrefabSetSha256"] for r in rows}
    conditions = discovery["shieldPatterns"]["conditions"]
    if any(c["fxSlotCount"] > 0 and c["fxPrefabSetKey"] not in mapping_keys for c in conditions):
        raise ValueError("shield_size_reference_pattern_mapping_missing")
    if (args.profile.read_bytes() != profile_bytes or args.source_discovery.read_bytes() != discovery_bytes
            or any(fit.digest(path.read_bytes()) != h for path, h in prepared["matchedPaths"].items())):
        raise ValueError("shield_size_reference_source_changed")
    result = {"contractId": "nll/boss-shield-size-reference/v1", "profileSha256": fit.digest(profile_bytes),
              "producerFilesSha256": {p.name: fit.digest(p.read_bytes()) for p in
                                      (Path(__file__), Path(__file__).with_name("nll-shield-fx-assessment.py"))},
              "sourceDiscoverySha256": fit.digest(discovery_bytes),
              "sourceStaticDataSha256": discovery["sourceStaticDataSha256"],
              "patternFxBindings": [{k: c[k] for k in ("functionKey", "fxSlotCount", "fxPrefabSetKey", "fxAttachmentKey")} for c in conditions],
              "sourceBossElementCode": source, "references": rows,
              "comparisonScopeCode": "placement_scale_size_modules_helper_mesh_not_rotation_or_rendering",
              "assetWrites": 0, "runtimeAdmissionStatusCode": "not_assessed"}
    # Names, pointers and source IDs must not enter this portable reference.
    encoded = json.dumps(result, indent=2, allow_nan=False) + "\n"
    if any(token in encoded for token in ('"m_PathID"', '"m_FileID"', '"m_Name"')):
        raise ValueError("shield_size_reference_unresolved_pointer")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as stream:
        stream.write(encoded)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--source-discovery", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--unitypy-root", type=Path, required=True)
    parser.add_argument("--compare-element", action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        sys.path.insert(0, str(args.unitypy_root.resolve()))
        import UnityPy
        args.unitypy = UnityPy
        result = run(args)
        print(json.dumps({"contractId": result["contractId"], "referenceCount": len(result["references"]), "assetWrites": 0}))
        return 0
    except Exception:
        print("shield_size_reference_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
