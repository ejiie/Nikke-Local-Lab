"""Synthetic serialization checks for bounded common FX candidate delivery."""
import copy
import importlib.util
import json
import struct
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace as NS
import unittest


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


recipes = module("recipes", "nll-shield-fx-recipes.py")
fixture = module("fixtures", "test-nll-boss-profile-qte.py")


class Obj:
    def __init__(self, i, kind, tree):
        self.path_id, self.type, self.tree = i, NS(name=kind), tree
    def read_typetree(self): return copy.deepcopy(self.tree)
    def save_typetree(self, tree): self.tree = copy.deepcopy(tree)
    def get_raw_data(self): return json.dumps(self.tree, sort_keys=True).encode()


class Environment:
    def __init__(self, objects):
        self.objects = objects
        self.files = {"synthetic": self}
    def save(self, **_):
        return json.dumps([(o.path_id, o.type.name, o.tree) for o in self.objects], sort_keys=True).encode()


class Unity:
    @staticmethod
    def load(payload): return Environment([Obj(*row) for row in json.loads(payload)])


def payload(**options):
    env = fixture.ShieldFitTests.environment(**options)
    def ptr(i): return {"m_FileID": 0, "m_PathID": i}
    next(o for o in env.objects if o.path_id == 13).tree["m_Component"].append({"component": ptr(90)})
    env.objects.extend([
        Obj(90, "ParticleSystemRenderer", {"m_GameObject": ptr(13), "m_RenderMode": 4,
            "m_Mesh": ptr(91), "m_Materials": [], "m_MaxParticleSize": 1}),
        Obj(91, "Mesh", {"syntheticMesh": [1, 3, 2]})])
    # Opaque objects must retain exact bytes as well as preserving unselected fields.
    env.objects.append(Obj(88, "AudioClip", {"syntheticAudio": [1, 4, 2]}))
    return Environment(env.objects).save()


class RecipeTests(unittest.TestCase):
    @staticmethod
    def without_anchor(blob):
        env = Unity.load(blob)
        env.objects = [o for o in env.objects if o.path_id not in (2, 12)]
        next(o for o in env.objects if o.path_id == 1).tree['m_Children'] = [{'m_FileID': 0, 'm_PathID': 3}]
        next(o for o in env.objects if o.path_id == 3).tree['m_Father'] = {'m_FileID': 0, 'm_PathID': 1}
        return env.save()

    def test_target_only_frame_is_neutralized_without_changing_topology_or_effects(self):
        source = self.without_anchor(payload())
        env = Unity.load(payload(scale=7, colour=3, rotation=0.2))
        frame = next(o for o in env.objects if o.path_id == 2)
        frame.tree['m_LocalPosition'] = [-2.0, 1.0, 3.0]
        frame.tree['m_LocalScale'] = [7.0, 7.0, 7.0]
        original = env.save()
        recipe, derived = recipes.materialize_pair(source, original, Unity)
        self.assertEqual(recipe['operationCode'], 'adjust_candidate')
        self.assertEqual(recipe['sizeStatusCode'], 'reference_inputs_matched')
        self.assertEqual(len(recipe['identityReferenceFrames']), 1)
        before = {o.path_id: o.tree for o in Unity.load(original).objects}
        after = {o.path_id: o.tree for o in Unity.load(derived).objects}
        before[2]['m_LocalPosition'] = [0.0, 0.0, 0.0]
        before[2]['m_LocalScale'] = [1.0, 1.0, 1.0]
        self.assertEqual(before, after)
        self.assertEqual(recipes.materialize_pair(source, original, Unity), (recipe, derived))
        again, overlay = recipes.materialize_pair(source, derived, Unity)
        self.assertEqual(again['operationCode'], 'reuse')
        self.assertIsNone(overlay)

    def test_rotated_or_component_bearing_inserted_frame_is_not_neutralized(self):
        source = self.without_anchor(payload())
        for unsafe in ('rotation', 'animator', 'mesh'):
            with self.subTest(unsafe=unsafe):
                env = Unity.load(payload(scale=7))
                if unsafe == 'rotation':
                    next(o for o in env.objects if o.path_id == 2).tree['m_LocalRotation'] = [0, 0, 0.5, 0.5]
                elif unsafe == 'animator':
                    next(o for o in env.objects if o.path_id == 12).tree['m_Component'].append(
                        {'component': {'m_FileID': 0, 'm_PathID': 100}})
                    env.objects.append(Obj(100, 'Animator', {}))
                else:
                    next(o for o in env.objects if o.path_id == 91).tree['syntheticMesh'] = [9, 8, 7]
                recipe, derived = recipes.materialize_pair(source, env.save(), Unity)
                self.assertEqual(recipe['operationCode'], 'unresolved')
                self.assertIsNone(derived)

    def test_renamed_shell_and_extra_burst_preserve_target_fields(self):
        target = Unity.load(payload(scale=7, helper=1, extra=True, colour=2, rotation=0.2))
        next(o for o in target.objects if o.path_id == 13).tree['m_Name'] = 'different-shell-leaf'
        original = target.save()
        recipe, derived = recipes.materialize_pair(payload(), original, Unity)
        self.assertEqual(recipe['operationCode'], 'adjust_candidate')
        self.assertEqual(recipe['sizeStatusCode'], 'reference_inputs_matched')
        self.assertTrue(recipe['sizeNodeCorrespondence'])
        before = {o.path_id: o.tree for o in Unity.load(original).objects}
        after = {o.path_id: o.tree for o in Unity.load(derived).objects}
        before[2]['m_LocalScale'] = [1, 1, 1]; before[21]['UseScaleHelper'] = 0
        self.assertEqual(before, after)
        self.assertEqual(recipes.materialize_pair(payload(), original, Unity), (recipe, derived))

    def test_renamed_shell_with_different_mesh_remains_unresolved(self):
        env = Unity.load(payload(scale=7))
        next(o for o in env.objects if o.path_id == 13).tree['m_Name'] = 'renamed'
        next(o for o in env.objects if o.path_id == 91).tree['syntheticMesh'] = [8, 3, 1]
        recipe, derived = recipes.materialize_pair(payload(), env.save(), Unity)
        self.assertEqual(recipe['operationCode'], 'unresolved')
        self.assertIsNone(derived)

    def test_mesh_roles_ignore_sibling_order_but_reject_ambiguous_sizing(self):
        def snapshot(prefix, sizes):
            root = recipes.fit.inspect_bundle(payload(), Unity)
            leaf = copy.deepcopy(next(n for n in root['nodes'].values() if n['particle']))
            root['nodes'] = {prefix: dict(parent=None, particle=False, childCount=2, components=[])}
            for i, size in enumerate(sizes):
                node = copy.deepcopy(leaf); node['parent'] = prefix; node['scale'] = [size]*3
                root['nodes'][prefix+str(i)] = node
            return root
        left, right = snapshot('a', [1, 1]), snapshot('b', [7, 7])
        right['nodes'] = dict(reversed(list(right['nodes'].items())))
        mapping = recipes.size_correspondence(left, right)
        self.assertEqual(set(mapping), set(left['nodes']))
        self.assertEqual(set(mapping.values()), set(right['nodes']))
        with self.assertRaisesRegex(ValueError, 'correspondence_unresolved'):
            recipes.size_correspondence(snapshot('a', [1, 2]), right)

    def test_reuse_preserves_colour_rotation_and_does_not_create_overlay(self):
        a, b = payload(), payload(colour=2, rotation=0.2)
        recipe, derived = recipes.materialize_pair(a, b, Unity)
        self.assertEqual(recipe["operationCode"], "reuse")
        self.assertIsNone(derived)
        self.assertEqual(recipe["outputBundle"], recipes.pin(b))

    def test_only_bounded_geometry_changes_and_residual_activation_remains(self):
        a, b = payload(), payload(colour=2, rotation=0.2, scale=7, helper=1)
        env = Unity.load(b)
        next(o for o in env.objects if o.path_id == 13).tree["m_IsActive"] = 0
        next(o for o in env.objects if o.path_id == 22).tree["InitialModule"]["startSize"] = 5
        b = env.save()
        recipe, derived = recipes.materialize_pair(a, b, Unity)
        self.assertEqual(recipe["operationCode"], "adjust_candidate")
        self.assertEqual({c["fieldCode"] for c in recipe["changes"]}, {"m_LocalScale", "UseScaleHelper", "InitialModule/startSize"})
        self.assertEqual(recipe["assessmentAfter"]["reasonCodes"], ["hierarchy_or_activation_differs"])
        self.assertEqual(recipe["runtimeAdmissionStatusCode"], "not_assessed")
        before = {o.path_id: o.tree for o in Unity.load(b).objects}
        after = {o.path_id: o.tree for o in Unity.load(derived).objects}
        before[2]["m_LocalScale"] = [1, 1, 1]
        before[21]["UseScaleHelper"] = 0
        before[22]["InitialModule"]["startSize"] = 1
        self.assertEqual(before, after)

    def test_extra_burst_is_preserved_without_blocking_complete_mesh_shell(self):
        target = payload(extra=True, scale=7)
        recipe, derived = recipes.materialize_pair(payload(), target, Unity)
        self.assertEqual(recipe["operationCode"], "adjust_candidate")
        self.assertEqual(recipe["sizeStatusCode"], "reference_inputs_matched")
        before = {o.path_id: o.tree for o in Unity.load(target).objects}
        after = {o.path_id: o.tree for o in Unity.load(derived).objects}
        before[2]["m_LocalScale"] = [1, 1, 1]
        self.assertEqual(before, after)

    def test_unmatched_mesh_cannot_be_fixed_by_copying_scale(self):
        env = Unity.load(payload(scale=7))
        next(o for o in env.objects if o.path_id == 91).tree["syntheticMesh"] = [9, 8, 7]
        recipe, derived = recipes.materialize_pair(payload(), env.save(), Unity)
        self.assertEqual(recipe["operationCode"], "unresolved")
        self.assertEqual(recipe["changes"], [])
        self.assertIsNone(derived)

    def test_disabled_size_table_is_preserved_and_colour_animation_are_not_size_gates(self):
        env = Unity.load(payload(scale=7, helper=1, colour=3, rotation=0.4))
        next(o for o in env.objects if o.path_id == 21).tree["ScaleHelper"] = {"size": 200}
        next(o for o in env.objects if o.path_id == 22).tree["lengthInSec"] = 17
        env.objects.append(Obj(92, "AnimationClip", {"syntheticCurve": [0, 3, 9]}))
        target = env.save()
        recipe, derived = recipes.materialize_pair(payload(), target, Unity)
        self.assertEqual(recipe["sizeStatusCode"], "reference_inputs_matched")
        before = {o.path_id: o.tree for o in Unity.load(target).objects}
        after = {o.path_id: o.tree for o in Unity.load(derived).objects}
        before[2]["m_LocalScale"] = [1, 1, 1]
        before[21]["UseScaleHelper"] = 0
        self.assertEqual(before, after)

    def test_roundtrip_collateral_change_is_rejected(self):
        class CorruptUnity:
            @staticmethod
            def load(blob):
                env = Unity.load(blob)
                original = env.save
                def corrupt(**kw):
                    next(o for o in env.objects if o.path_id == 88).tree["syntheticAudio"] = []
                    return original(**kw)
                env.save = corrupt
                return env
        with self.assertRaisesRegex(ValueError, "preservation_failed"):
            recipes.materialize_pair(payload(), payload(scale=7), CorruptUnity)

    def inputs(self, cache, source):
        rows = []
        for element in ("fire", "water", "wind", "electric", "iron"):
            blob = payload(scale=1 if element == source else 2, colour=1 if element == source else 2)
            h = recipes.pin(blob)
            (cache / (element + ".bundle")).write_bytes(blob)
            rows.append({"bossElementCode": element, "mappings": [{
                "sourceFxPrefabSetSha256": "a" * 64,
                "targetFxPrefabSetSha256": ("a" if element == source else "b") * 64,
                "assetBundles": [h]}]})
        return rows

    def test_five_original_elements_delivery_and_tamper_checks(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for element in ("fire", "water", "wind", "electric", "iron"):
                cache = root / element; cache.mkdir()
                variants = self.inputs(cache, element)
                originals = {p.name: p.read_bytes() for p in cache.iterdir()}
                manifest, outputs = recipes.prepare(element, list(reversed(variants)), cache, Unity)
                self.assertEqual([r["bossElementCode"] for r in manifest["variants"] if r["operationCode"] == "reuse"], [element])
                out = root / (element + "-out")
                recipes.deliver(out, manifest, outputs)
                recipes.verify_delivery(out, element, variants, cache, Unity)
                with self.assertRaises(FileExistsError): recipes.deliver(out, manifest, outputs)
                self.assertEqual(originals, {p.name: p.read_bytes() for p in cache.iterdir()})
                bundle = next(out.glob("*.bundle")); bundle.write_bytes(b"tampered")
                with self.assertRaisesRegex(ValueError, "output_changed"):
                    recipes.verify_delivery(out, element, variants, cache, Unity)

    def test_changed_recipe_cannot_authorize_extra_field(self):
        with TemporaryDirectory() as directory:
            root = Path(directory); cache = root / "cache"; cache.mkdir()
            variants = self.inputs(cache, "water")
            manifest, outputs = recipes.prepare("water", variants, cache, Unity)
            out = root / "out"; recipes.deliver(out, manifest, outputs)
            path = out / "recipes.receipt.json"; value = json.loads(path.read_text())
            value["variants"][0]["recipe"]["changes"][0]["fieldCode"] = "m_LocalRotation"
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "receipt_changed"):
                recipes.verify_delivery(out, "water", variants, cache, Unity)

    def test_reuse_only_delivery_retains_original_pins_without_synthetic_changes(self):
        with TemporaryDirectory() as directory:
            root = Path(directory); cache = root / "cache"; cache.mkdir()
            variants = self.inputs(cache, "iron")
            for variant in variants:
                blob = payload(colour=1 if variant["bossElementCode"] == "iron" else 2)
                (cache / (variant["bossElementCode"] + ".bundle")).write_bytes(blob)
                variant["mappings"][0]["assetBundles"] = [recipes.pin(blob)]
            manifest, outputs = recipes.prepare("iron", variants, cache, Unity)
            self.assertEqual(manifest["preparationStatusCode"], "reuse_ready")
            self.assertEqual(outputs, {})
            out = root / "out"; recipes.deliver(out, manifest, outputs)
            self.assertEqual([p.name for p in out.iterdir()], ["recipes.receipt.json"])
            self.assertEqual(recipes.verify_delivery(out, "iron", variants, cache, Unity)["assetWrites"], 0)

    def test_null_material_slot_is_absence_but_missing_reference_is_unresolved(self):
        env = Unity.load(payload())
        renderer = next(o for o in env.objects if o.path_id == 90)
        renderer.tree["m_Materials"] = [{"m_FileID": 0, "m_PathID": 0}]
        self.assertEqual(recipes.fit.inspect_bundle(env.save(), Unity)["issues"], [])
        renderer.tree["m_Materials"][0]["m_PathID"] = 999
        self.assertIn("material_reference_unresolved", recipes.fit.inspect_bundle(env.save(), Unity)["issues"])

    def test_profile_binding_and_cross_mapping_drift(self):
        with TemporaryDirectory() as directory:
            root = Path(directory); cache = root / "cache"; cache.mkdir()
            variants = self.inputs(cache, "water")
            manifest, outputs = recipes.prepare("water", variants, cache, Unity)
            out = root / "out"; recipes.deliver(out, manifest, outputs)
            delivered = json.loads((out / "recipes.receipt.json").read_bytes())
            profile = {"sourceAffinity": {"bossElementCode": "water"}, "elementShield": {"fxVariants": variants},
                       "shieldFxPreparation": recipes.profile_binding(delivered, recipes.fit.digest((out / "recipes.receipt.json").read_bytes()))}
            self.assertEqual(len(recipes.verify_profile_binding(profile, out)), 5)
            receipt_path = out / "recipes.receipt.json"
            original = receipt_path.read_bytes()
            historical = copy.deepcopy(delivered)
            historical['policyCode'] = 'source_shield_size_candidate/v2'
            for row in historical['variants']:
                row['recipe']['policyCode'] = historical['policyCode']
            receipt_path.write_text(json.dumps(historical), encoding='utf-8')
            old_profile = copy.deepcopy(profile)
            old_profile['shieldFxPreparation'] = recipes.profile_binding(historical, recipes.fit.digest(receipt_path.read_bytes()))
            self.assertEqual(len(recipes.verify_profile_binding(old_profile, out)), 5)
            receipt_path.write_bytes(original)
            for mutation in (
                lambda p: p["shieldFxPreparation"].update(recipeManifestSha256="0" * 64),
                lambda p: p["elementShield"]["fxVariants"][0]["mappings"][0].update(targetFxPrefabSetSha256="0" * 64),
                lambda p: p["sourceAffinity"].update(bossElementCode="electric"),
                lambda p: p["shieldFxPreparation"]["variants"][0].update(outputBundle={"sha256": "0" * 64, "byteLength": 5}),
            ):
                changed = copy.deepcopy(profile); mutation(changed)
                with self.assertRaises(ValueError): recipes.verify_profile_binding(changed, out)
            output = next(out.glob("*.bundle")); output.write_bytes(b"drift")
            with self.assertRaisesRegex(ValueError, "output_changed"): recipes.verify_profile_binding(profile, out)


def animated_payload(static=1, maintained=2, stop=0.75, hold=1):
    """A synthetic Animator above a non-animated mesh body, never game data."""
    env = Unity.load(payload())
    by_id = {o.path_id: o for o in env.objects}
    def ptr(i): return {'m_FileID': 0, 'm_PathID': i}
    # Insert a separate group, so the compensation branch itself stays static.
    group = copy.deepcopy(by_id[2].tree)
    group.update(m_GameObject=ptr(15), m_Children=[ptr(2)], m_LocalScale=[static]*3)
    by_id[1].tree['m_Children'] = [ptr(5)]
    by_id[2].tree.update(m_Father=ptr(5), m_LocalPosition=[0, -1, 0], m_LocalScale=[6, 6, 3])
    data = b''.join(struct.pack('<fi', time, 3) + b''.join(
        struct.pack('<i4f', axis, 0, 0, 0, value) for axis in range(3))
        for time, value in [(0, 0), (stop, maintained)])
    clip = {'m_MuscleClip': {'m_StartTime': 0, 'm_StopTime': stop, 'm_LoopTime': False,
                'm_Clip': {'data': {'m_StreamedClip': {'curveCount': 3,
                    'data': list(struct.unpack('<' + 'I'*(len(data)//4), data))}}}},
            'm_ClipBindingConstant': {'genericBindings': [{'typeID': 4, 'attribute': 3,
                'path': 0, 'customType': 0, 'isPPtrCurve': 0}]}}
    env.objects.extend([
        Obj(5, 'Transform', group),
        Obj(15, 'GameObject', {'m_Name': 'synthetic-group', 'm_IsActive': 1,
            'm_Component': [{'component': ptr(5)}, {'component': ptr(100)}]}),
        Obj(100, 'Animator', {'m_GameObject': ptr(15), 'm_Enabled': 1, 'm_Controller': ptr(0)}),
        Obj(101, 'MonoBehaviour', {'m_InfiniteClip': ptr(102), 'm_InfiniteClipPostExtrapolation': hold,
                                  'm_Clips': [], 'm_Muted': 0, 'm_Parent': ptr(104)}),
        Obj(102, 'AnimationClip', clip),
        Obj(104, 'MonoBehaviour', {'m_Tracks': [ptr(101)]}),
        Obj(103, 'PlayableDirector', {'m_Enabled': 1, 'm_PlayableAsset': ptr(104),
            'm_SceneBindings': [{'key': ptr(101), 'value': ptr(100)}]})])
    return env.save()


class AnimatedRecipeTests(unittest.TestCase):
    def test_static_override_does_not_match_runtime_but_body_compensation_does(self):
        source = animated_payload(static=5, maintained=6)
        target = animated_payload(static=2, maintained=2)
        a, b = (recipes.fit.inspect_bundle(p, Unity) for p in (source, target))
        sa, ta = {}, {}
        for blob, snapshot, result in ((source, a, sa), (target, b, ta)):
            bindings = {}; recipes.fit.inspect_bundle(blob, Unity, bindings)
            result.update(recipes.animated_inputs(Unity.load(blob), snapshot, bindings, recipes.size_scope(snapshot)))
        mapping = recipes.size_correspondence(a, b)
        static_only = copy.deepcopy(a)
        self.assertFalse(recipes.matrices_match(a, static_only, sa, ta, mapping))
        recipe, derived = recipes.materialize_pair(source, target, Unity)
        self.assertEqual(recipe['operationCode'], 'adjust_candidate')
        self.assertEqual(recipe['sizeStatusCode'], 'animated_frame_inputs_matched')
        before = {o.path_id: o.tree for o in Unity.load(target).objects}
        after = {o.path_id: o.tree for o in Unity.load(derived).objects}
        self.assertEqual(after[5], before[5])
        self.assertEqual(after[102], before[102])
        self.assertEqual(after[2]['m_LocalScale'], [18, 18, 9])
        self.assertEqual(after[2]['m_LocalPosition'], [0, -3, 0])
        before[2] = after[2]
        self.assertEqual(before, after)
        self.assertTrue(recipes.matrices_match(a, recipes.fit.inspect_bundle(derived, Unity), sa, ta, mapping))

    def test_existing_compensation_still_requires_matrix_equality_before_reuse(self):
        source = animated_payload(static=5, maintained=6)
        _, derived = recipes.materialize_pair(source, animated_payload(static=2, maintained=2), Unity)
        recipe, overlay = recipes.materialize_pair(source, derived, Unity)
        self.assertEqual(recipe['operationCode'], 'reuse')
        self.assertIsNone(overlay)
        env = Unity.load(derived)
        next(o for o in env.objects if o.path_id == 3).tree['m_LocalRotation'] = [0, 0, 1, 0]
        recipe, overlay = recipes.materialize_pair(source, env.save(), Unity)
        self.assertEqual(recipe['operationCode'], 'unresolved')
        self.assertEqual(recipe['reasonCodes'], [recipes.ANIMATED_UNRESOLVED])
        self.assertIsNone(overlay)

    def test_same_static_values_do_not_hide_different_animated_values(self):
        recipe, derived = recipes.materialize_pair(animated_payload(maintained=8), animated_payload(), Unity)
        self.assertEqual(recipe['operationCode'], 'adjust_candidate')
        self.assertIsNotNone(derived)

    def test_unsupported_animation_cannot_become_a_static_candidate(self):
        for fault in ('hold', 'rotation', 'nonuniform', 'branch_owned', 'offset', 'missing_stop', 'position', 'leaf_rotation', 'track_rotation', 'controller'):
            with self.subTest(fault=fault):
                env = Unity.load(animated_payload(static=2, maintained=2))
                objects = {o.path_id: o for o in env.objects}
                if fault == 'hold': objects[101].tree['m_InfiniteClipPostExtrapolation'] = 2
                elif fault == 'rotation': objects[5].tree['m_LocalRotation'] = [0, 0, 1, 0]
                elif fault == 'nonuniform':
                    words = objects[102].tree['m_MuscleClip']['m_Clip']['data']['m_StreamedClip']['data']
                    words[-1] = struct.unpack('<I', struct.pack('<f', 3))[0]
                elif fault == 'branch_owned': objects[100].tree['m_GameObject']['m_PathID'] = 12
                elif fault == 'offset': objects[101].tree['m_InfiniteClipTimeOffset'] = 1
                elif fault == 'missing_stop': objects[102].tree['m_MuscleClip']['m_StopTime'] = 1.5
                elif fault == 'leaf_rotation': objects[3].tree['m_LocalRotation'] = [0, 0, 1, 0]
                elif fault == 'track_rotation': objects[101].tree['m_Rotation'] = [0, 0, 1, 0]
                elif fault == 'controller': objects[100].tree['m_Controller']['m_PathID'] = 102
                else: objects[102].tree['m_ClipBindingConstant']['genericBindings'][0]['attribute'] = 1
                recipe, derived = recipes.materialize_pair(animated_payload(static=5, maintained=6), env.save(), Unity)
                self.assertEqual(recipe['operationCode'], 'unresolved')
                self.assertEqual(recipe['reasonCodes'], [recipes.ANIMATED_UNRESOLVED])
                self.assertIsNone(derived)

    def test_static_case_keeps_exact_output_bytes(self):
        target = payload(scale=7, helper=1, colour=3, rotation=0.2)
        expected = Unity.load(target)
        next(o for o in expected.objects if o.path_id == 2).tree['m_LocalScale'] = [1, 1, 1]
        next(o for o in expected.objects if o.path_id == 21).tree['UseScaleHelper'] = 0
        recipe, derived = recipes.materialize_pair(payload(), target, Unity)
        self.assertEqual(recipe['policyCode'], 'source_shield_size_candidate/v3')
        self.assertEqual(derived, expected.save())

    @staticmethod
    def with_loop(blob, last_value=11):
        env = Unity.load(blob); objects = {o.path_id: o for o in env.objects}
        def ptr(i): return {'m_FileID': 0, 'm_PathID': i}
        muscle = objects[102].tree['m_MuscleClip']
        muscle['m_StopTime'] = 1.75
        data = struct.pack('<fi', 1.75, 3) + b''.join(
            struct.pack('<i4f', axis, 0, 0, 0, last_value) for axis in range(3))
        muscle['m_Clip']['data']['m_StreamedClip']['data'].extend(struct.unpack('<'+'I'*(len(data)//4), data))
        objects[104].tree['m_MarkerTrack'] = ptr(105)
        objects[103].tree['m_GameObject'] = ptr(11)
        objects[11].tree['m_Component'].append({'component': ptr(108)})
        env.objects.extend([
            Obj(105, 'MonoBehaviour', {'m_Markers': {'m_Objects': [ptr(106), ptr(107)]}}),
            Obj(106, 'MonoBehaviour', {'m_Script': ptr(116), 'm_Enabled': 1, 'm_Time': 1.125,
                'destinationMarker': ptr(107), 'IsSkip': 0, 'emitOnce': 0}),
            Obj(107, 'MonoBehaviour', {'m_Script': ptr(117), 'm_Enabled': 1, 'm_Time': 0.875, 'active': 1}),
            Obj(108, 'MonoBehaviour', {'m_Script': ptr(118), 'm_Enabled': 1, 'IsJump': 1}),
            Obj(116, 'MonoScript', {'m_ClassName': 'JumpMarker'}),
            Obj(117, 'MonoScript', {'m_ClassName': 'DestinationMarker'}),
            Obj(118, 'MonoScript', {'m_ClassName': 'JumpReceiver'})])
        return env.save()

    def test_bound_constant_loop_excludes_later_destruction_keys(self):
        source = self.with_loop(animated_payload(static=5, maintained=6), last_value=9)
        target = self.with_loop(animated_payload(static=2, maintained=2))
        recipe, derived = recipes.materialize_pair(source, target, Unity)
        self.assertEqual(recipe['operationCode'], 'adjust_candidate')
        after = {o.path_id: o.tree for o in Unity.load(derived).objects}
        self.assertEqual(after[2]['m_LocalScale'], [18, 18, 9])
        self.assertEqual(after[2]['m_LocalPosition'], [0, -3, 0])
        self.assertEqual(after[102], next(o.tree for o in Unity.load(target).objects if o.path_id == 102))
        # Different exit keys alone must not change a non-conflicting output.
        same, overlay = recipes.materialize_pair(
            self.with_loop(animated_payload(static=2, maintained=2), last_value=9), target, Unity)
        self.assertEqual(same['operationCode'], 'reuse')
        self.assertIsNone(overlay)
        self.assertEqual(same['outputBundle'], recipes.pin(target))

    def test_unknown_or_nonconstant_loop_is_unresolved(self):
        for fault in ('slope', 'skip', 'receiver', 'disabled', 'reversed', 'unknown_marker'):
            with self.subTest(fault=fault):
                env = Unity.load(self.with_loop(animated_payload(static=2, maintained=2)))
                objects = {o.path_id: o for o in env.objects}
                if fault == 'slope':
                    words = objects[102].tree['m_MuscleClip']['m_Clip']['data']['m_StreamedClip']['data']
                    words[22] = struct.unpack('<I', struct.pack('<f', 1))[0]
                elif fault == 'skip': objects[106].tree['IsSkip'] = 1
                elif fault == 'receiver': objects[108].tree['IsJump'] = 0
                elif fault == 'disabled': objects[107].tree['active'] = 0
                elif fault == 'reversed': objects[107].tree['m_Time'] = 2
                else: objects[116].tree['m_ClassName'] = 'UnknownMarker'
                recipe, derived = recipes.materialize_pair(animated_payload(static=5, maintained=6), env.save(), Unity)
                self.assertEqual(recipe['operationCode'], 'unresolved')
                self.assertEqual(recipe['reasonCodes'], [recipes.ANIMATED_UNRESOLVED])
                self.assertIsNone(derived)

    def test_relative_transform_binding_is_resolved_from_animator_root(self):
        env = Unity.load(animated_payload(static=2, maintained=2))
        objects = {o.path_id: o for o in env.objects}
        objects[100].tree['m_GameObject']['m_PathID'] = 11
        objects[102].tree['m_ClipBindingConstant']['genericBindings'][0]['path'] = recipes.zlib.crc32(b'synthetic-group')
        recipe, derived = recipes.materialize_pair(animated_payload(static=5, maintained=6), env.save(), Unity)
        self.assertEqual(recipe['operationCode'], 'adjust_candidate')
        self.assertIsNotNone(derived)

    def test_stale_track_from_other_timeline_does_not_own_scale(self):
        env = Unity.load(animated_payload(static=2, maintained=2))
        objects = {o.path_id: o for o in env.objects}
        track = copy.deepcopy(objects[101].tree)
        track['m_Parent']['m_PathID'] = 201
        track['m_InfiniteClipPostExtrapolation'] = 2
        env.objects.extend([Obj(200, 'MonoBehaviour', track), Obj(201, 'MonoBehaviour', {'m_Tracks': []})])
        objects[103].tree['m_SceneBindings'].append({'key': {'m_FileID': 0, 'm_PathID': 200},
                                                   'value': {'m_FileID': 0, 'm_PathID': 100}})
        recipe, derived = recipes.materialize_pair(animated_payload(static=5, maintained=6), env.save(), Unity)
        self.assertEqual(recipe['operationCode'], 'adjust_candidate')
        self.assertIsNotNone(derived)
        track['m_Parent']['m_PathID'] = 104
        next(o for o in env.objects if o.path_id == 200).tree = track
        track['m_InfiniteClipPostExtrapolation'] = 1
        recipe, derived = recipes.materialize_pair(animated_payload(static=5, maintained=6), env.save(), Unity)
        self.assertEqual(recipe['operationCode'], 'unresolved')
        self.assertIsNone(derived)

    def test_profile_binding_preserves_both_policies_and_rejects_unknown(self):
        manifest = {'policyCode': recipes.POLICY, 'preparationStatusCode': 'reuse_ready',
                    'sourceBossElementCode': 'water', 'variants': []}
        for policy in sorted(recipes.SUPPORTED_POLICIES):
            manifest['policyCode'] = policy
            self.assertEqual(recipes.profile_binding(manifest, 'a'*64)['policyCode'], policy)
        manifest['policyCode'] = 'source_shield_size_candidate/v99'
        with self.assertRaisesRegex(ValueError, 'not_prepared'):
            recipes.profile_binding(manifest, 'a'*64)


if __name__ == "__main__": unittest.main()
