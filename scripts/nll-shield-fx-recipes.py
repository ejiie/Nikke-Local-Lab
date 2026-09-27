"""Common, source-pinned FX preparation candidates; never runtime admission.

Sizing corrections use a complete mesh-shell correspondence and an explicit field boundary.
Activation, colour, rotation, timing, animation, audio and topology remain target-owned.
Residual differences stay visible even after a derived candidate is produced.
"""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("shield_recipe_fit", Path(__file__).with_name("nll-shield-fx-assessment.py"))
fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fit)

POLICY = "source_shield_size_candidate/v2"
FIELDS = {
    "Transform": ("m_LocalPosition", "m_LocalScale"),
    "FxHelper": ("UseScaleHelper", "ScaleHelper"),
    "ParticleSystem": ("scalingMode", "InitialModule/startSize"),
    "ParticleSystemRenderer": ("m_MaxParticleSize",),
}


def require(value, code):
    if not value:
        raise ValueError(code)


def pin(payload):
    return {"sha256": fit.digest(payload), "byteLength": len(payload)}


def field_parent(tree, field):
    parts = field.split("/")
    for part in parts[:-1]:
        require(isinstance(tree, dict) and part in tree, "shield_recipe_field_missing")
        tree = tree[part]
    require(isinstance(tree, dict) and parts[-1] in tree, "shield_recipe_field_missing")
    return tree, parts[-1]


def field_value(tree, field):
    parent, name = field_parent(tree, field)
    return parent[name]


def boundary(env, edited):
    rows = []
    for obj in env.objects:
        identity = (obj.type.name, obj.path_id)
        if identity in edited:
            tree = obj.read_typetree()
            for field in edited[identity]:
                parent, name = field_parent(tree, field)
                del parent[name]
            value = fit.canonical(tree)
        else:
            value = fit.digest(obj.get_raw_data())
        rows.append((identity, value))
    return fit.canonical(sorted(rows))


def size_scope(snapshot):
    """Select one complete mesh-emitter branch and its ancestors, not other bursts.

    All direct children must be leaf mesh emitters. This supported asset shape is
    checked from components and mesh identity, without season, element or node IDs.
    Unknown or ambiguous shapes require a separate sizing recipe.
    """
    nodes = snapshot["nodes"]
    branches = []
    for key, node in nodes.items():
        children = [k for k, n in nodes.items() if n["parent"] == key]
        if node["particle"] or not children:
            continue
        if all(nodes[k]["particle"] and nodes[k]["childCount"] == 0
               and dict(nodes[k]["components"]).get("ParticleSystemRenderer", {}).get("m_RenderMode") == 4
               and (dict(nodes[k]["components"])["ParticleSystemRenderer"].get("m_Mesh") or {}).get("meshPayloadSha256")
               for k in children):
            branches.append((key, children))
    require(len(branches) == 1, "shield_recipe_mesh_shell_not_unique")
    branch, children = branches[0]
    selected = set(children)
    while branch is not None:
        selected.add(branch)
        branch = nodes[branch]["parent"]
    return selected


def size_inputs(snapshot, selected):
    """Static sizing evidence only; animation, rotation and colour stay target-owned."""
    result = {}
    for key in sorted(selected):
        node = snapshot["nodes"][key]
        row = {k: node[k] for k in ("parent", "position", "scale")}
        components = dict(node["components"])
        if "ParticleSystem" in components:
            particle = components["ParticleSystem"]
            row["particle"] = {k: particle.get(k) for k in ("scalingMode", "SizeModule", "SizeBySpeedModule")}
            row["particle"]["initial"] = {k: particle["InitialModule"].get(k)
                                           for k in ("startSize", "startSizeY", "startSizeZ", "size3D")}
        if "ParticleSystemRenderer" in components:
            renderer = components["ParticleSystemRenderer"]
            row["renderer"] = {k: renderer.get(k) for k in ("m_RenderMode", "m_Mesh", "m_MinParticleSize", "m_MaxParticleSize")}
        if "FxHelper" in components:
            helper = components["FxHelper"]
            row["helper"] = {k: helper[k] for k in ("UseScaleHelper", "UseWeaponScaleHelper", "UseFocusHelper")}
            for enabled, table in (("UseScaleHelper", "ScaleHelper"), ("UseWeaponScaleHelper", "WeaponScaleHelper"),
                                   ("UseFocusHelper", "FocusHelper")):
                if helper[enabled]:
                    row["helper"][table] = helper[table]
        result[key] = row
    return result


def size_correspondence(source, target):
    """Match the shell ancestry and mesh leaves independently of outer burst paths.

    Ancestors are identified by their place in the selected branch. Leaves match
    by mesh. Repeated meshes must have identical sizing inputs within each asset;
    their permutation then cannot change the sizing operation.
    Existing path correspondence is retained for reproducible earlier recipes.
    """
    left, right = size_scope(source), size_scope(target)
    if left == right and all(source['nodes'][k]['parent'] == target['nodes'][k]['parent'] for k in left):
        return {k: k for k in left}
    def roles(snapshot, selected):
        nodes = snapshot['nodes']
        roots = [k for k in selected if nodes[k]['parent'] is None]
        require(len(roots) == 1, 'shield_recipe_size_correspondence_unresolved')
        result = {}
        def visit(key, role):
            require(role not in result, 'shield_recipe_size_correspondence_unresolved')
            result[role] = key
            children = [k for k in selected if nodes[k]['parent'] == key]
            groups = {}
            for child in children:
                node = nodes[child]
                if len(children) == 1:
                    child_role = role + '/child'
                else:
                    renderer = dict(node['components']).get('ParticleSystemRenderer', {})
                    require(node['particle'] and node['childCount'] == 0 and renderer.get('m_Mesh'),
                            'shield_recipe_size_correspondence_unresolved')
                    particle = dict(node['components'])['ParticleSystem']
                    # These curves are preserved, never edited by this recipe.
                    child_role = role + '/mesh/' + fit.canonical([
                        renderer['m_Mesh'], particle.get('SizeModule'), particle.get('SizeBySpeedModule'),
                        {k: particle['InitialModule'].get(k) for k in ('startSizeY', 'startSizeZ', 'size3D')}])
                groups.setdefault(child_role, []).append(child)
            for child_role, group in groups.items():
                if len(group) > 1:
                    inputs = size_inputs(snapshot, set(group))
                    require(len({fit.canonical(v) for v in inputs.values()}) == 1,
                            'shield_recipe_size_correspondence_unresolved')
                for index, child in enumerate(sorted(group)):
                    visit(child, child_role + '/' + str(index))
        visit(roots[0], 'root')
        require(len(result) == len(selected), 'shield_recipe_size_correspondence_unresolved')
        return result
    a, b = roles(source, left), roles(target, right)
    require(set(a) == set(b), 'shield_recipe_size_correspondence_unresolved')
    return {a[role]: b[role] for role in a}


def corresponding_inputs(snapshot, mapping):
    rows = size_inputs(snapshot, set(mapping.values()))
    inverse = {v: k for k, v in mapping.items()}
    return {source: dict(rows[target], parent=inverse.get(rows[target]['parent']))
            for source, target in mapping.items()}


def identity_frame_reference(source, target, source_bindings, target_bindings, target_env):
    """Insert identity coordinate frames into the reference, never into the asset.

    A target-only Transform before the emitter may be neutralized while keeping
    the target hierarchy. Inserting an identity matrix into the source chain is
    exact. Animated/component-bearing or rotated frames are not eligible.
    """
    def chain(snapshot):
        selected = size_scope(snapshot)
        nodes = snapshot['nodes']
        key = next(k for k in selected if nodes[k]['parent'] is None)
        result = [key]
        while True:
            children = [k for k in selected if nodes[k]['parent'] == key]
            if len(children) != 1:
                return result
            key = children[0]
            result.append(key)
    a, b = chain(source), chain(target)
    require(len(b) > len(a), 'shield_recipe_size_correspondence_unresolved')
    reference, bindings = copy.deepcopy(source), dict(source_bindings)
    objects = {o.path_id: o for o in target_env.objects}
    frames, index, previous, seen_particle = [], 0, None, False
    for target_key in b:
        require(index < len(a), 'shield_recipe_size_correspondence_unresolved')
        source_key = a[index]
        left, right = reference['nodes'][source_key], target['nodes'][target_key]
        if (left['particle'] == right['particle'] and
                [c[0] for c in left['components']] == [c[0] for c in right['components']]):
            previous = source_key
            index += 1
            seen_particle |= right['particle']
            continue
        require(previous is not None and not seen_particle and not right['components']
                and not right['particle'], 'shield_recipe_size_correspondence_unresolved')
        transform = target_bindings[(target_key, 'Transform')].read_typetree()
        go = objects[transform['m_GameObject']['m_PathID']].read_typetree()
        components = [p.get('component') if isinstance(p, dict) else p[1] for p in go['m_Component']]
        require(all(p['m_FileID'] == 0 and objects[p['m_PathID']].type.name == 'Transform'
                    for p in components), 'shield_recipe_identity_frame_component_unresolved')
        rotation = right['rotation']
        values = [rotation[k] for k in ('x', 'y', 'z', 'w')] if isinstance(rotation, dict) else rotation
        require(values in ([0, 0, 0, 1], [0, 0, 0, -1]), 'shield_recipe_identity_frame_rotation_unresolved')
        key = fit.canonical(['identity_reference_frame', target_key])
        require(key not in reference['nodes'], 'shield_recipe_identity_frame_conflict')
        def vector(value, number):
            return ({k: type(v)(number) for k, v in value.items()} if isinstance(value, dict)
                    else [type(v)(number) for v in value])
        position, scale = vector(right['position'], 0), vector(right['scale'], 1)
        reference['nodes'][key] = dict(copy.deepcopy(right), parent=previous, childCount=1,
                                        position=position, scale=scale)
        reference['nodes'][source_key]['parent'] = key
        tree = {'m_LocalPosition': position, 'm_LocalScale': scale}
        bindings[(key, 'Transform')] = SimpleNamespace(read_typetree=lambda tree=tree: copy.deepcopy(tree))
        frames.append({'sourceNodeKey': key, 'targetNodeKey': target_key})
        previous = key
    require(index == len(a) and frames, 'shield_recipe_size_correspondence_unresolved')
    return reference, bindings, frames


def materialize_pair(source: bytes, target: bytes, unitypy):
    """Return a reproducible recipe and optional derived bytes, with no file writes."""
    source_bindings, target_bindings = {}, {}
    source_snapshot = fit.inspect_bundle(source, unitypy, source_bindings)
    env = unitypy.load(target)
    target_snapshot = fit.inspect_bundle(target, SimpleNamespace(load=lambda _: env), target_bindings)
    before = fit.compare(source_snapshot, target_snapshot, source == target)
    recipe = {"policyCode": POLICY, "sourceBundle": pin(source), "targetBundle": pin(target),
              "operationCode": "unresolved", "changes": [], "assessmentBefore": before,
              "assessmentAfter": before, "renderingStatusCode": "unresolved",
              "runtimeAdmissionStatusCode": "not_assessed"}
    if before["statusCode"] in {"source_reuse", "reuse_candidate"} and not before["reasonCodes"]:
        recipe.update(operationCode="reuse", outputBundle=pin(target), sizeStatusCode="original_reuse")
        return recipe, None
    left, right = source_snapshot["nodes"], target_snapshot["nodes"]
    try:
        try:
            mapping = size_correspondence(source_snapshot, target_snapshot)
        except ValueError:
            source_snapshot, source_bindings, frames = identity_frame_reference(
                source_snapshot, target_snapshot, source_bindings, target_bindings, env)
            mapping = size_correspondence(source_snapshot, target_snapshot)
            recipe['identityReferenceFrames'] = frames
        selected = size_scope(source_snapshot)
        require(not source_snapshot["issues"] and not target_snapshot["issues"],
                "shield_recipe_size_correspondence_unresolved")
        selected_bindings = {k for k in source_bindings if k[0] in selected}
        require({(mapping[k], kind) for k, kind in selected_bindings} ==
                {k for k in target_bindings if k[0] in mapping.values()},
                "shield_recipe_size_components_unresolved")
    except ValueError as error:
        code = str(error)
        if code.startswith('shield_recipe_') and all(c.islower() or c == '_' for c in code):
            recipe['reasonCodes'] = [code]
        return recipe, None
    recipe.update(sizeScopeNodeKeys=sorted(selected),
                  sourceSizeInputsSha256=fit.canonical(size_inputs(source_snapshot, selected)),
                  sizeStatusCode="unresolved")
    if any(k != v for k, v in mapping.items()):
        recipe['sizeNodeCorrespondence'] = [{'sourceNodeKey': k, 'targetNodeKey': v}
                                            for k, v in sorted(mapping.items())]
    edits = {}
    pending = []
    for key, kind in sorted(selected_bindings):
        fields = FIELDS[kind]
        source_tree = source_bindings[(key, kind)].read_typetree()
        obj = target_bindings[(mapping[key], kind)]
        target_tree = obj.read_typetree()
        for field in fields:
            if kind == "FxHelper" and field == "ScaleHelper" and not source_tree["UseScaleHelper"]:
                continue
            source_value, target_value = field_value(source_tree, field), field_value(target_tree, field)
            if source_value == target_value:
                continue
            recipe["changes"].append({"nodeKey": mapping[key], "componentCode": kind, "fieldCode": field,
                "beforeSha256": fit.canonical(target_value), "afterSha256": fit.canonical(source_value)})
            parent, name = field_parent(target_tree, field)
            parent[name] = copy.deepcopy(source_value)
            edits.setdefault((obj.type.name, obj.path_id), set()).add(field)
        if (obj.type.name, obj.path_id) in edits:
            pending.append((obj, target_tree))
    # UnityPy may cache typetrees: validate sizing from serialized, reloaded bytes.
    # No output files are written until all sizing and preservation checks pass.
    before_boundary = boundary(env, edits)
    for obj, tree in pending:
        obj.save_typetree(tree)
    if not pending:
        if size_inputs(source_snapshot, selected) == corresponding_inputs(target_snapshot, mapping):
            recipe.update(operationCode="reuse", outputBundle=pin(target), sizeStatusCode="reference_inputs_matched")
        return recipe, None
    files = list(env.files.values())
    require(len(files) == 1, "shield_recipe_container_not_unique")
    payload = files[0].save(packer="original")
    require(isinstance(payload, bytes) and payload and payload != target, "shield_recipe_save_invalid")
    round_trip = unitypy.load(payload)
    require(boundary(round_trip, edits) == before_boundary, "shield_recipe_preservation_failed")
    after_bindings = {}
    after_snapshot = fit.inspect_bundle(payload, SimpleNamespace(load=lambda _: round_trip), after_bindings)
    require(set(after_bindings) == set(target_bindings), "shield_recipe_binding_changed")
    if (size_scope(after_snapshot) != set(mapping.values())
            or corresponding_inputs(after_snapshot, mapping) != size_inputs(source_snapshot, selected)):
        recipe["changes"] = []
        return recipe, None
    for change in recipe["changes"]:
        value = field_value(after_bindings[(change["nodeKey"], change["componentCode"])].read_typetree(), change["fieldCode"])
        require(fit.canonical(value) == change["afterSha256"], "shield_recipe_roundtrip_failed")
    recipe.update(operationCode="adjust_candidate", outputBundle=pin(payload),
                  sizeStatusCode="reference_inputs_matched",
                  preservedObjectFieldsSha256=before_boundary,
                  assessmentAfter=fit.compare(source_snapshot, after_snapshot))
    # Even an equal static snapshot is not evidence of the native helper/render consumer.
    return recipe, payload


def prepare(source_element, variants, cache, unitypy):
    prepared = {}
    assessment = fit.assess(source_element, variants, cache, unitypy, prepared)
    outputs, rows = {}, []
    for row in assessment["variants"]:
        entry = {k: row[k] for k in ("bossElementCode", "sourceFxPrefabSetSha256", "targetFxPrefabSetSha256")}
        source_pins, target_pins = row["sourceAssetBundles"], row["targetAssetBundles"]
        entry.update(operationCode="unresolved", reasonCodes=row["reasonCodes"],
                     sourceAssetBundles=source_pins, targetAssetBundles=target_pins)
        if (len(source_pins) == len(target_pins) == 1
                and all(p["sha256"] in prepared["blobs"] for p in source_pins + target_pins)):
            try:
                recipe, payload = materialize_pair(prepared["blobs"][source_pins[0]["sha256"]],
                                                   prepared["blobs"][target_pins[0]["sha256"]], unitypy)
                entry.update(operationCode=recipe["operationCode"], recipe=recipe,
                             reasonCodes=[] if recipe["operationCode"] in {"reuse", "adjust_candidate"}
                             else recipe.get("reasonCodes", ["shield_size_inputs_unresolved"]))
                if payload is not None:
                    outputs[recipe["outputBundle"]["sha256"]] = payload
            except Exception:
                # No parser messages, identifiers, paths or payloads in portable receipts.
                entry["reasonCodes"] = ["shield_recipe_structure_or_roundtrip_unresolved"]
        rows.append(entry)
    require(all(fit.digest(path.read_bytes()) == h for path, h in prepared["matchedPaths"].items()),
            "shield_recipe_input_changed")
    return {"contractId": "nll/boss-shield-fx-recipes/v1", "sourceBossElementCode": source_element,
            "policyCode": POLICY, "variants": rows, "assetWrites": 0,
            "preparationStatusCode": ("reuse_ready" if all(r["operationCode"] == "reuse" for r in rows)
                                      else "size_candidates_ready" if all(r["operationCode"] in {"reuse", "adjust_candidate"} for r in rows)
                                      else "review_required"),
            "runtimeAdmissionStatusCode": "not_assessed", "renderingStatusCode": "unresolved"}, outputs


def plain_path(path):
    require(path.is_absolute(), "shield_recipe_absolute_path_required")
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            require(not part.is_symlink() and not (getattr(part.lstat(), "st_file_attributes", 0) & 0x400),
                    "shield_recipe_reparse_point")


def deliver(root: Path, manifest: dict, outputs: dict):
    """Consume only content-addressed candidate bytes into one newly owned directory."""
    plain_path(root)
    expected = {r["recipe"]["outputBundle"]["sha256"]: r["recipe"]["outputBundle"]
                for r in manifest["variants"] if r["operationCode"] == "adjust_candidate"}
    require(set(expected) == set(outputs) and all(pin(blob) == expected[h] for h, blob in outputs.items()),
            "shield_recipe_output_pin_mismatch")
    root.mkdir(parents=True, exist_ok=False)
    for h, blob in sorted(outputs.items()):
        with (root / (h + ".bundle")).open("xb") as stream:
            stream.write(blob)
    receipt = copy.deepcopy(manifest)
    receipt["assetWrites"] = len(outputs)
    receipt["bundleLocationCode"] = "recipe_sibling_content_hash"
    with (root / "recipes.receipt.json").open("x", encoding="utf-8") as stream:
        json.dump(receipt, stream, indent=2, allow_nan=False)
        stream.write("\n")
    return receipt


def verify_delivery(root: Path, source_element, variants, cache, unitypy):
    """Re-derive every recipe from original pins; never trust caller-supplied edits."""
    plain_path(root)
    expected, outputs = prepare(source_element, variants, cache, unitypy)
    expected.update(assetWrites=len(outputs), bundleLocationCode="recipe_sibling_content_hash")
    plain_path(root / "recipes.receipt.json")
    receipt = json.loads((root / "recipes.receipt.json").read_text(encoding="utf-8"))
    require(receipt == expected, "shield_recipe_receipt_changed")
    require({p.name for p in root.iterdir()} == {"recipes.receipt.json", *(h + ".bundle" for h in outputs)},
            "shield_recipe_output_set_changed")
    for h, payload in outputs.items():
        path = root / (h + ".bundle")
        plain_path(path)
        require(path.read_bytes() == payload, "shield_recipe_output_changed")
    return receipt


def profile_binding(manifest, manifest_sha):
    require(manifest["policyCode"] == POLICY and manifest["preparationStatusCode"] in
            {"reuse_ready", "size_candidates_ready"}, "shield_recipe_not_prepared")
    rows = []
    for row in manifest["variants"]:
        require(row["operationCode"] in {"reuse", "adjust_candidate"}
                and len(row["sourceAssetBundles"]) == len(row["targetAssetBundles"]) == 1,
                "shield_recipe_binding_unresolved")
        rows.append({k: row[k] for k in ("bossElementCode", "sourceFxPrefabSetSha256", "targetFxPrefabSetSha256", "operationCode")}
                    | {"sourceBundle": row["sourceAssetBundles"][0], "targetBundle": row["targetAssetBundles"][0],
                       "outputBundle": row["recipe"]["outputBundle"]})
    return {"contractId": "nll/boss-shield-fx-preparation/v1", "policyCode": POLICY,
            "sourceBossElementCode": manifest["sourceBossElementCode"],
            "recipeManifestSha256": manifest_sha, "variants": rows}


def verify_profile_binding(profile, root):
    """Consume the assembly's pinned receipt; full source re-derivation precedes sealing."""
    plain_path(root)
    manifest_path = root / "recipes.receipt.json"
    plain_path(manifest_path)
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    require(manifest["contractId"] == "nll/boss-shield-fx-recipes/v1"
            and profile["shieldFxPreparation"] == profile_binding(manifest, fit.digest(raw))
            and manifest["sourceBossElementCode"] == profile["sourceAffinity"]["bossElementCode"],
            "shield_recipe_profile_binding_changed")
    expected = {(v["bossElementCode"], m["sourceFxPrefabSetSha256"]): m
                for v in profile["elementShield"]["fxVariants"] for m in v["mappings"]}
    rows = profile["shieldFxPreparation"]["variants"]
    require(len(rows) == len(expected) and {(r["bossElementCode"], r["sourceFxPrefabSetSha256"]) for r in rows} == set(expected),
            "shield_recipe_profile_mapping_changed")
    outputs = set()
    for row in rows:
        mapping = expected[(row["bossElementCode"], row["sourceFxPrefabSetSha256"])]
        source = expected[(manifest["sourceBossElementCode"], row["sourceFxPrefabSetSha256"]) ]
        require(mapping["targetFxPrefabSetSha256"] == row["targetFxPrefabSetSha256"]
                and mapping["assetBundles"] == [row["targetBundle"]]
                and source["assetBundles"] == [row["sourceBundle"]], "shield_recipe_profile_mapping_changed")
        if row["operationCode"] == "reuse":
            require(row["outputBundle"] == row["targetBundle"], "shield_recipe_reuse_pin_changed")
        else:
            h = row["outputBundle"]["sha256"]
            require(len(h) == 64 and all(c in "0123456789abcdef" for c in h), "shield_recipe_pin_invalid")
            path = root / (h + ".bundle"); plain_path(path)
            require(pin(path.read_bytes()) == row["outputBundle"], "shield_recipe_output_changed")
            outputs.add(path.name)
    require({p.name for p in root.iterdir()} == {"recipes.receipt.json", *outputs}, "shield_recipe_output_set_changed")
    return rows
