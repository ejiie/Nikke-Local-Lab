"""Read-only FX fit assessment. Asset differences are not transformation recipes."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical(value: Any) -> str:
    return digest(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode())


def inspect_bundle(payload: bytes, unitypy: Any, bindings: dict | None = None) -> dict[str, Any]:
    """Keep names in memory only. Include every Transform, not a leaf-name subset."""
    env = unitypy.load(payload)
    objects = list(env.objects)
    by_id = {obj.path_id: obj for obj in objects}
    if len(by_id) != len(objects):
        raise ValueError("ambiguous_object_identity")
    trees = {obj.path_id: obj.read_typetree() for obj in objects
             if obj.type.name in {"Transform", "RectTransform", "GameObject", "MonoScript"}}
    transforms = {obj.path_id: trees[obj.path_id] for obj in objects if obj.type.name == "Transform"}
    if not transforms or any(obj.type.name == "RectTransform" for obj in objects):
        raise ValueError("unsupported_transform_graph")
    def local(pointer):
        if pointer["m_FileID"] != 0:
            raise ValueError("external_component_reference")
        return pointer["m_PathID"]
    roots = [key for key, row in transforms.items() if local(row["m_Father"]) == 0]
    if len(roots) != 1:
        raise ValueError("ambiguous_root")
    def components_for(key):
        go = trees[local(transforms[key]["m_GameObject"])]
        return [by_id[local(pair.get("component") if isinstance(pair, dict) else pair[1])]
                for pair in go["m_Component"]]
    def state_role(key):
        components = components_for(key)
        particles = [o for o in components if o.type.name == "ParticleSystem"]
        if transforms[key]["m_Children"] and len(particles) == 1 and any(o.type.name == "Animator" for o in components):
            leaves, seen, pending = [], set(), [key]
            while pending:
                current = pending.pop()
                if current in seen or current not in transforms:
                    raise ValueError("invalid_transform_tree")
                seen.add(current)
                children = transforms[current]["m_Children"]
                if not children:
                    leaves.append(trees[local(transforms[current]["m_GameObject"])]["m_Name"])
                pending.extend(local(p) for p in children)
            # A complete leaf-set match is a grouping candidate, not a guessed loop/
            # break semantic. A changed group stays unmatched for explicit review.
            return "emitter_group_" + canonical(sorted(leaves))
        return None
    paths: dict[int, str] = {}
    def walk(key, path):
        if key in paths or key not in transforms:
            raise ValueError("invalid_transform_tree")
        paths[key] = path
        transform_children = transforms[key]["m_Children"]
        for pointer in transform_children:
            child = local(pointer)
            if child not in transforms or local(transforms[child]["m_Father"]) != key:
                raise ValueError("invalid_transform_tree")
            # Match grouping nodes through serialized role/ownership, not a boss-name
            # prefix or sibling order. Ambiguous roles still fail the unique-path check.
            name = state_role(child)
            if name is None and key == roots[0]:
                groups = [local(p) for p in transform_children if transforms[local(p)]["m_Children"]
                          and not any(o.type.name == "ParticleSystem" for o in components_for(local(p)))]
                if groups == [child]:
                    name = "anchor"
            if name is None and state_role(key) is not None and len(transform_children) == 1:
                name = "branch"
            if name is None:
                name = "node_" + trees[local(transforms[child]["m_GameObject"])]["m_Name"]
            walk(child, path + "/" + name)
    walk(roots[0], "")
    if len(paths) != len(transforms) or len(set(paths.values())) != len(paths):
        raise ValueError("incomplete_transform_tree")
    issues = set()
    def geometry(value):
        if isinstance(value, dict):
            if set(value) == {"m_FileID", "m_PathID"}:
                if value["m_PathID"] == 0:
                    return None
                target = by_id.get(value["m_PathID"]) if value["m_FileID"] == 0 else None
                if target is not None and target.type.name == "Mesh":
                    return {"meshPayloadSha256": digest(target.get_raw_data())}
                issues.add("geometry_reference_unresolved")
                return {"unresolvedReference": True}
            return {k: geometry(v) for k, v in value.items()}
        if isinstance(value, list):
            return [geometry(v) for v in value]
        return value
    nodes = {}
    helper_count = 0
    for key, path in paths.items():
        transform = transforms[key]
        node_key = canonical(path)
        if bindings is not None:
            bindings[(node_key, "Transform")] = by_id[key]
        go = trees[local(transform["m_GameObject"])]
        components = []
        particle = False
        for pair in go["m_Component"]:
            pointer = pair.get("component") if isinstance(pair, dict) else pair[1]
            obj = by_id[local(pointer)]
            kind = obj.type.name
            if kind == "Transform":
                continue
            tree = obj.read_typetree()
            if kind == "ParticleSystem":
                particle = True
                # Preserve target colour and opacity; do not copy them from the boss source.
                tree = {k: v for k, v in tree.items() if k not in
                        {"m_GameObject", "ColorModule", "ColorBySpeedModule"}}
                tree["InitialModule"] = {k: v for k, v in tree["InitialModule"].items() if k != "startColor"}
                components.append((kind, geometry(tree)))
            elif kind == "ParticleSystemRenderer":
                materials = tree.get("m_Materials", [])
                for material in materials:
                    if material == {"m_FileID": 0, "m_PathID": 0}:
                        continue
                    target = by_id.get(material["m_PathID"]) if material["m_FileID"] == 0 else None
                    if target is None or target.type.name != "Material":
                        issues.add("material_reference_unresolved")
                tree = {k: v for k, v in tree.items() if k not in {"m_GameObject", "m_Materials"}}
                components.append((kind, {"materialSlotCount": len(materials),
                                         "materialSlotPresent": [m != {"m_FileID": 0, "m_PathID": 0} for m in materials],
                                         **geometry(tree)}))
            elif kind == "MonoBehaviour":
                script = trees.get(local(tree["m_Script"]))
                cls = script.get("m_ClassName") if script else None
                if cls == "FxHelper":
                    helper_count += 1
                    fields = ("m_Enabled", "UseScaleHelper", "ScaleHelper", "UseWeaponScaleHelper", "WeaponScaleHelper",
                              "UseFocusHelper", "FocusHelper", "VisibleOptionHelper")
                    if not all(field in tree for field in fields):
                        raise ValueError("scale_helper_incomplete")
                    components.append((cls, geometry({field: tree[field] for field in fields})))
                elif cls not in {"JumpReceiver", "NKAudioSource"}:
                    issues.add("component_semantics_unresolved")
            elif kind not in {"Animator", "PlayableDirector"}:
                issues.add("component_semantics_unresolved")
            binding_kind = cls if kind == "MonoBehaviour" else kind
            if bindings is not None and binding_kind in {"FxHelper", "ParticleSystem", "ParticleSystemRenderer"}:
                binding_key = (node_key, binding_kind)
                if binding_key in bindings:
                    raise ValueError("component_binding_not_unique")
                bindings[binding_key] = obj
        nodes[canonical(path)] = {
            "parent": canonical(paths[local(transform["m_Father"])] ) if key != roots[0] else None,
            "childCount": len(transform["m_Children"]), "active": bool(go["m_IsActive"]),
            "position": transform["m_LocalPosition"], "rotation": transform["m_LocalRotation"],
            "scale": transform["m_LocalScale"], "particle": particle,
            "components": sorted(components, key=lambda item: (item[0], canonical(item[1]))),
        }
    if helper_count != 1:
        issues.add("scale_helper_not_unique")
    # Validate all values (including finiteness) before treating equal snapshots as evidence.
    canonical(nodes)
    return {"nodes": nodes, "issues": sorted(issues)}


def compare(source: dict, target: dict, identical_payload: bool = False) -> dict:
    left, right = source["nodes"], target["nodes"]
    common = set(left) & set(right)
    reasons = set(source["issues"]) | set(target["issues"])
    rotation_candidates = 0
    differences = []
    def changed_paths(a, b, path=""):
        if a == b:
            return []
        if isinstance(a, dict) and isinstance(b, dict):
            result = []
            for field in sorted(set(a) | set(b)):
                child = path + "/" + field
                result.extend([child] if field not in a or field not in b else changed_paths(a[field], b[field], child))
            return result
        if isinstance(a, (tuple, list)) and isinstance(b, (tuple, list)) and len(a) == len(b):
            return [p for i, (x, y) in enumerate(zip(a, b)) for p in changed_paths(x, y, path + "/" + str(i))]
        return [path]
    if set(left) != set(right):
        reasons.add("full_hierarchy_correspondence_unresolved")
    for key in common:
        a, b = left[key], right[key]
        if any(a[field] != b[field] for field in ("parent", "childCount", "active")):
            reasons.add("hierarchy_or_activation_differs")
        if any(a[field] != b[field] for field in ("position", "scale")):
            reasons.add("placement_or_scale_differs")
        if a["components"] != b["components"]:
            reasons.add("helper_particle_or_renderer_differs")
            ac, bc = dict(a["components"]), dict(b["components"])
            if len(ac) == len(a["components"]) and len(bc) == len(b["components"]):
                for kind in sorted(set(ac) | set(bc)):
                    paths = changed_paths(ac.get(kind), bc.get(kind))
                    if paths:
                        differences.append({"nodeKey": key, "componentCode": kind, "fieldPaths": paths})
        if a["rotation"] != b["rotation"]:
            if a["particle"] and b["particle"] and a["childCount"] == b["childCount"] == 0:
                rotation_candidates += 1
            else:
                reasons.add("non_leaf_rotation_differs")
    status = "source_reuse" if identical_payload else "reuse_candidate" if not reasons else "review_required"
    return {"statusCode": status, "reasonCodes": sorted(reasons),
            "sourceTransformCount": len(left), "targetTransformCount": len(right),
            "matchedTransformCount": len(common), "sourceUnmatchedCount": len(set(left) - set(right)),
            "targetUnmatchedCount": len(set(right) - set(left)),
            "preservedParticleRotationDifferenceCount": rotation_candidates,
            "componentDifferences": sorted(differences, key=lambda row: (row["nodeKey"], row["componentCode"])),
            "automaticTransformAllowed": False, "renderingStatusCode": "unresolved"}


def assess(source_element: str, variants: list[dict], cache: Path, unitypy: Any,
           prepared: dict | None = None) -> dict:
    """Resolve the source from boss.element. Variant order and sourceKind are not fit evidence."""
    by_element = {row["bossElementCode"]: row for row in variants}
    if (len(by_element) != len(variants) or source_element not in by_element
            or set(by_element) != {"fire", "water", "wind", "electric", "iron"}):
        raise ValueError("source_variant_not_unique")
    source_mappings = {row["sourceFxPrefabSetSha256"]: row for row in by_element[source_element]["mappings"]}
    if len(source_mappings) != len(by_element[source_element]["mappings"]) or not source_mappings:
        raise ValueError("source_mapping_not_unique")
    if any(key != row["targetFxPrefabSetSha256"] for key, row in source_mappings.items()):
        raise ValueError("source_variant_not_original")
    wanted = {}
    for v in variants:
        for m in v["mappings"]:
            for pin in m["assetBundles"]:
                h, size = pin["sha256"], pin["byteLength"]
                if (not isinstance(h, str) or len(h) != 64 or any(c not in "0123456789abcdef" for c in h)
                        or type(size) is not int or not 0 < size <= 64 * 1024 * 1024
                        or h in wanted and wanted[h] != size):
                    raise ValueError("bundle_pin_invalid")
                wanted[h] = size
    if cache.is_symlink() or getattr(cache.lstat(), "st_file_attributes", 0) & 0x400:
        raise ValueError("cache_reparse_point")
    blobs = {}
    matched_paths = {}
    for directory, children, files in os.walk(cache, followlinks=False):
        children[:] = [name for name in children if not ((Path(directory) / name).is_symlink()
                       or getattr((Path(directory) / name).lstat(), "st_file_attributes", 0) & 0x400)]
        for name in files:
            path = Path(directory) / name
            if (path.suffix != ".bundle" or path.is_symlink()
                    or getattr(path.lstat(), "st_file_attributes", 0) & 0x400
                    or path.stat().st_size not in wanted.values()):
                continue
            blob = path.read_bytes()
            h = digest(blob)
            if wanted.get(h) == len(blob):
                blobs[h] = blob
                matched_paths[path] = h
    snapshots = {}
    rows = []
    for element, variant in sorted(by_element.items()):
        targets = variant["mappings"]
        if len(targets) != len(source_mappings) or {m["sourceFxPrefabSetSha256"] for m in targets} != set(source_mappings):
            raise ValueError("mapping_set_mismatch")
        for mapping in targets:
            source = source_mappings[mapping["sourceFxPrefabSetSha256"]]
            result = {"statusCode": "unresolved", "reasonCodes": [], "automaticTransformAllowed": False,
                      "renderingStatusCode": "unresolved"}
            pins = source["assetBundles"], mapping["assetBundles"]
            if any(len(p) != 1 for p in pins):
                result["reasonCodes"] = ["multi_bundle_fit_unresolved"]
            elif any(p[0]["sha256"] not in blobs for p in pins):
                result["reasonCodes"] = ["pinned_bundle_missing"]
            else:
                a, b = (p[0]["sha256"] for p in pins)
                try:
                    for h in (a, b):
                        if h not in snapshots:
                            snapshots[h] = inspect_bundle(blobs[h], unitypy)
                    result = compare(snapshots[a], snapshots[b], a == b)
                except Exception:
                    # Never print source object names, paths, parser messages or payloads.
                    result["reasonCodes"] = ["asset_structure_unresolved"]
            rows.append({"bossElementCode": element,
                         "sourceFxPrefabSetSha256": mapping["sourceFxPrefabSetSha256"],
                         "targetFxPrefabSetSha256": mapping["targetFxPrefabSetSha256"],
                         "sourceAssetBundles": source["assetBundles"],
                         "targetAssetBundles": mapping["assetBundles"], **result})
    if any(digest(path.read_bytes()) != h for path, h in matched_paths.items()):
        raise ValueError("pinned_bundle_changed")
    if prepared is not None:
        prepared.update(blobs=blobs, matchedPaths=matched_paths)
    return {"contractId": "nll/boss-shield-fx-assessment/v1", "sourceBossElementCode": source_element,
            "variants": rows, "automaticTransformAllowed": False,
            "assetWrites": 0, "renderingStatusCode": "unresolved"}
