"""Source-free checks: a v2 onboarding profile cannot silently discard QTE."""

import copy
import importlib.util
from pathlib import Path
import unittest
import json
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace as NS
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "boss_profile", Path(__file__).with_name("materialize-nll-boss-runtime-profile.py")
)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
fit = profile.local_module("shield_fit_tests", "nll-shield-fx-assessment.py")
behavior = profile.local_module("behavior_tests", "inspect-nll-boss-behavior-assets.py")


class BehaviorPreservationTests(unittest.TestCase):
    def test_missing_empty_or_disabled_root_is_rejected(self):
        for graph in (None, [], {}, {"RootTask": {}}, {"RootTask": {"Type": " "}},
                      {"RootTask": {"Type": "SyntheticRoot", "Disabled": True}},
                      {"RootTask": {"Type": "SyntheticRoot", "Disabled": "false"}}):
            with self.subTest(graph=graph), self.assertRaisesRegex(behavior.PipelineError, "graph_invalid"):
                behavior.validate_graph(graph)

    def test_original_disabled_and_detached_tasks_remain_in_exact_receipt_hash(self):
        graph = {"RootTask": {"Type": "SyntheticRoot", "Children": [
            {"Type": "SyntheticAction", "Disabled": True}]},
            "DetachedTasks": [{"Type": "SyntheticDetached", "Disabled": True}]}
        before = copy.deepcopy(graph)
        obj = NS(type=NS(name="MonoBehaviour"),
                 read=lambda: NS(m_Name="synthetic-tree", m_Script=NS(read=lambda: NS(m_ClassName="ExternalBehaviorTree"))),
                 read_typetree=lambda: {"mBehaviorSource": {"mTaskData": {"JSONSerialization": json.dumps(graph)}}})
        with TemporaryDirectory() as directory:
            root = Path(directory)
            source = {"contractId": "nll/boss-content-discovery/v1", "seasonNumber": 1,
                      "profileCode": "synthetic-boss", "behaviorAssembly": {"rootReferenceCount": 1,
                      "rootReferenceSetSha256": behavior.sha256_bytes(b"synthetic-tree")}}
            (root / "source.json").write_text(json.dumps(source))
            (root / "private.json").write_text(json.dumps({"contractId": "nll/private-boss-content-diagnostic/v1",
                "seasonNumber": 1, "behaviorKeys": ["synthetic-tree"]}))
            (root / "synthetic.bundle").write_bytes(b"synthetic-bundle")
            args = NS(source_discovery=root / "source.json", private_discovery=root / "private.json",
                      behavior_bundle=root / "synthetic.bundle", output=root / "receipt.json", unitypy_root=None)
            with patch.dict(sys.modules, {"UnityPy": NS(load=lambda _: NS(objects=[obj]))}):
                behavior.run(args)
            receipt = json.loads(args.output.read_text())
            self.assertEqual((receipt["nodeCount"], receipt["disabledNodeCount"]), (3, 2))
            self.assertEqual(receipt["canonicalGraphSha256"], behavior.sha256_bytes(behavior.canonical_json(before)))
            self.assertFalse(receipt["sourceAssetModified"])
            self.assertEqual(graph, before)
            graph["RootTask"]["Children"][0]["Disabled"] = False
            self.assertNotEqual(receipt["canonicalGraphSha256"], behavior.sha256_bytes(behavior.canonical_json(graph)))

    def test_disabled_root_is_rejected_even_with_enabled_detached_task(self):
        with self.assertRaisesRegex(behavior.PipelineError, "graph_invalid"):
            behavior.validate_graph({"RootTask": {"Type": "SyntheticRoot", "Disabled": True},
                                     "DetachedTasks": [{"Type": "SyntheticAction"}]})


class ShieldFitTests(unittest.TestCase):
    @staticmethod
    def environment(colour=1, scale=1, helper=0, extra=False, rotation=0):
        def ptr(i): return {"m_FileID": 0, "m_PathID": i}
        class Obj:
            def __init__(self, i, kind, tree): self.path_id, self.type, self.tree = i, NS(name=kind), tree
            def read_typetree(self): return copy.deepcopy(self.tree)
        def transform(go, parent, children, s=1, r=0):
            return {"m_GameObject": ptr(go), "m_Father": ptr(parent), "m_Children": [ptr(i) for i in children],
                    "m_LocalPosition": [0, 0, 0], "m_LocalRotation": [0, 0, r, 1], "m_LocalScale": [s, s, s]}
        objects = [
            Obj(1, "Transform", transform(11, 0, [2] + ([4] if extra else []))),
            Obj(2, "Transform", transform(12, 1, [3], scale)),
            Obj(3, "Transform", transform(13, 2, [], r=rotation)),
            Obj(11, "GameObject", {"m_Name": "synthetic-root", "m_IsActive": 1,
                "m_Component": [{"component": ptr(1)}, {"component": ptr(21)}]}),
            Obj(12, "GameObject", {"m_Name": "anchor", "m_IsActive": 1, "m_Component": [{"component": ptr(2)}]}),
            Obj(13, "GameObject", {"m_Name": "particle", "m_IsActive": 1,
                "m_Component": [{"component": ptr(3)}, {"component": ptr(22)}]}),
            Obj(21, "MonoBehaviour", {"m_Script": ptr(31), "m_Enabled": 1, "UseScaleHelper": helper, "ScaleHelper": {"size": 3},
                "UseWeaponScaleHelper": 0, "WeaponScaleHelper": {}, "UseFocusHelper": 0, "FocusHelper": {}, "VisibleOptionHelper": {}}),
            Obj(22, "ParticleSystem", {"m_GameObject": ptr(13), "InitialModule": {"startColor": colour, "startSize": 1},
                "ColorModule": {"enabled": bool(colour)}, "scalingMode": 0}),
            Obj(31, "MonoScript", {"m_ClassName": "FxHelper"})]
        if extra:
            objects += [Obj(4, "Transform", transform(14, 1, [])),
                        Obj(14, "GameObject", {"m_Name": "outside-anchor", "m_IsActive": 1,
                            "m_Component": [{"component": ptr(4)}, {"component": ptr(23)}]}),
                        Obj(23, "ParticleSystem", {"m_GameObject": ptr(14), "InitialModule": {"startSize": 1}})]
        return NS(objects=objects)

    def snapshot(self, **options):
        return fit.inspect_bundle(b"synthetic", NS(load=lambda _: self.environment(**options)))

    def test_colour_and_particle_rotation_are_preserved_candidates(self):
        source, target = self.snapshot(), self.snapshot(colour=2, rotation=0.1)
        before = copy.deepcopy(target)
        result = fit.compare(source, target)
        self.assertEqual(result["statusCode"], "reuse_candidate")
        self.assertEqual(result["preservedParticleRotationDifferenceCount"], 1)
        self.assertFalse(result["automaticTransformAllowed"])
        self.assertEqual(target, before)

    def test_helper_mismatch_rejected_even_with_equal_transforms(self):
        result = fit.compare(self.snapshot(), self.snapshot(helper=1))
        self.assertEqual(result["statusCode"], "review_required")
        self.assertIn("helper_particle_or_renderer_differs", result["reasonCodes"])

    def test_full_graph_includes_outside_anchor_emitter(self):
        result = fit.compare(self.snapshot(), self.snapshot(extra=True))
        self.assertEqual(result["targetUnmatchedCount"], 1)
        self.assertIn("full_hierarchy_correspondence_unresolved", result["reasonCodes"])

    def test_scale_difference_is_not_an_automatic_copy_recipe(self):
        result = fit.compare(self.snapshot(), self.snapshot(scale=7))
        self.assertIn("placement_or_scale_differs", result["reasonCodes"])
        self.assertFalse(result["automaticTransformAllowed"])

    def test_graph_cycle_and_invalid_parent_are_unresolved(self):
        for mutation in (lambda e: e.objects[0].tree["m_Children"].append({"m_FileID": 0, "m_PathID": 1}),
                         lambda e: e.objects[1].tree["m_Father"].update(m_PathID=99)):
            env = self.environment(); mutation(env)
            with self.assertRaises(ValueError): fit.inspect_bundle(b"synthetic", NS(load=lambda _: env))

    def test_activation_and_unreadable_helper_are_not_reuse(self):
        env = self.environment()
        next(o for o in env.objects if o.path_id == 13).tree["m_IsActive"] = 0
        result = fit.compare(self.snapshot(), fit.inspect_bundle(b"synthetic", NS(load=lambda _: env)))
        self.assertIn("hierarchy_or_activation_differs", result["reasonCodes"])
        del next(o for o in env.objects if o.path_id == 21).tree["UseFocusHelper"]
        with self.assertRaises(ValueError): fit.inspect_bundle(b"synthetic", NS(load=lambda _: env))

    def test_source_element_and_variant_order_are_data_driven(self):
        with TemporaryDirectory() as directory:
            cache = Path(directory)
            variants = []
            for element in profile.ELEMENTS:
                payload = ("synthetic-" + element).encode()
                (cache / (element + ".bundle")).write_bytes(payload)
                variants.append({"bossElementCode": element, "mappings": [{
                    "sourceFxPrefabSetSha256": "a" * 64, "targetFxPrefabSetSha256": "a" * 64,
                    "assetBundles": [{"sha256": fit.digest(payload), "byteLength": len(payload)}]}]})
            before = {p.name: p.read_bytes() for p in cache.iterdir()}
            for element in profile.ELEMENTS:
                result = fit.assess(element, list(reversed(variants)), cache, NS(load=lambda _: self.environment()))
                self.assertEqual(result["sourceBossElementCode"], element)
                self.assertEqual([r["bossElementCode"] for r in result["variants"] if r["statusCode"] == "source_reuse"], [element])
                self.assertFalse(result["automaticTransformAllowed"])
            self.assertEqual(before, {p.name: p.read_bytes() for p in cache.iterdir()})
            with self.assertRaises(ValueError):
                fit.assess("water", variants[:-1], cache, NS(load=lambda _: self.environment()))
            (cache / "wind.bundle").unlink()
            result = fit.assess("water", variants, cache, NS(load=lambda _: self.environment()))
            self.assertIn("pinned_bundle_missing", next(r for r in result["variants"] if r["bossElementCode"] == "wind")["reasonCodes"])

    def test_missing_discovery_is_not_shield_absence(self):
        result = profile.assess_shield_patterns({"sourceAffinity": {"bossElementCode": "fire"}},
                                               {"modeCode": "none", "functionRecordCount": 0}, Path("."), None)
        self.assertEqual(result["preparationStatusCode"], "review_required")

    def test_closed_shield_absence_preserves_common_path(self):
        source = {"sourceAffinity": {"bossElementCode": "fire"}, "quickTimeEventAffinity": {"recordCount": 0},
                  "shieldPatterns": {"contractId": "nll/boss-shield-pattern-discovery/v1",
                    "staticReferenceStatusCode": "resolved", "missingReferenceCount": 0,
                    **{k: [] for k in ("entryPoints", "partTargets", "conditions", "normalInterrupts", "quickTimeEvents")}}}
        result = profile.assess_shield_patterns(source, {"modeCode": "none", "functionRecordCount": 0}, Path("."), None)
        self.assertEqual(result["preparationStatusCode"], "not_required")
        source["shieldPatterns"]["conditions"] = [{"fxSlotCount": 0}]
        self.assertEqual(profile.assess_shield_patterns(source, {"modeCode": "none", "functionRecordCount": 0},
                        Path("."), None)["preparationStatusCode"], "review_required")

    def test_review_receipt_is_written_before_any_profile_or_transform(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            source = {"contractId": "nll/boss-content-discovery/v1", "discoveryStatusCode": "static_graph_resolved",
                "unresolvedReasonCodes": [], "seasonNumber": 3, "profileCode": "synthetic-boss",
                "sourceAffinity": {"bossElementCode": "water"},
                "behaviorAssembly": {"rootReferenceCount": 1, "rootReferenceSetSha256": "a" * 64}}
            source_path = root / "source.json"; source_path.write_text(json.dumps(source))
            private_path = root / "private.json"
            private_path.write_text(json.dumps({"contractId": "nll/private-boss-content-diagnostic/v1", "seasonNumber": 3}))
            behavior_path = root / "behavior.json"
            behavior_path.write_text(json.dumps({"contractId": "nll/boss-behavior-assembly/v1", "seasonNumber": 3,
                "profileCode": "synthetic-boss", "sourceDiscoverySha256": profile.hash_file(source_path),
                "rootReferenceCount": 1, "rootReferenceSetSha256": "a" * 64, "graphMatchCount": 1, "disabledNodeCount": 6}))
            args = NS(source_discovery=source_path, private_discovery=private_path, behavior_receipt=behavior_path,
                asset_cache_root=root, profile_output=root / "profile.json", receipt_output=root / "candidate.json", unitypy_root=None)
            with patch.object(profile, "resolve_shield", return_value={"modeCode": "dynamic_affinity_linked"}), \
                 patch.object(profile, "assemble_normalization") as transform:
                with self.assertRaisesRegex(profile.PipelineError, "shield_assessment_review_required"):
                    profile.run(args)
                transform.assert_not_called()
            self.assertFalse(args.profile_output.exists()); self.assertFalse(args.receipt_output.exists())
            report = json.loads((root / "shield-pattern-fx-assessment.receipt.json").read_text())
            self.assertEqual(report["runtimeAdmissionStatusCode"], "not_assessed")
            self.assertIn("shield_pattern_discovery_refresh_required", report["reasonCodes"])


class ShieldSizeReferenceTests(unittest.TestCase):
    def test_size_signature_ignores_colour_but_detects_scale_and_helper(self):
        ref = profile.local_module("size_reference_tests", "inspect-nll-shield-size-reference.py")
        def capture(**kw):
            return ref.describe(b"synthetic", NS(load=lambda _: ShieldFitTests.environment(**kw)))
        baseline = capture()
        self.assertEqual(ref.size_signature(baseline), ref.size_signature(capture(colour=2)))
        self.assertNotEqual(ref.size_signature(baseline), ref.size_signature(capture(scale=7)))
        self.assertNotEqual(ref.size_signature(baseline), ref.size_signature(capture(helper=1)))
        self.assertEqual(baseline["worldSpaceSizeStatusCode"], "not_measured")

    def test_rotation_is_recorded_without_claiming_full_shape_equality(self):
        ref = profile.local_module("size_rotation_tests", "inspect-nll-shield-size-reference.py")
        a = ref.describe(b"a", NS(load=lambda _: ShieldFitTests.environment()))
        b = ref.describe(b"b", NS(load=lambda _: ShieldFitTests.environment(rotation=0.2)))
        self.assertEqual(ref.size_signature(a), ref.size_signature(b))
        self.assertNotEqual(a["nodes"], b["nodes"])

    def test_bound_reference_is_reproducible_exclusive_and_preserves_inputs(self):
        ref = profile.local_module("size_delivery_tests", "inspect-nll-shield-size-reference.py")
        with TemporaryDirectory() as directory:
            root = Path(directory); cache = root / "cache"; cache.mkdir()
            variants = []
            for element in profile.ELEMENTS:
                blob = element.encode(); (cache / (element + ".bundle")).write_bytes(blob)
                variants.append({"bossElementCode": element, "mappings": [{
                    "sourceFxPrefabSetSha256": "a" * 64, "targetFxPrefabSetSha256": "a" * 64,
                    "assetBundles": [{"sha256": fit.digest(blob), "byteLength": len(blob)}]}]})
            source = {"bossElementCode": "water", "weaknessCode": "electric"}
            p = root / "profile.json"; p.write_text(json.dumps({"sourceAffinity": source,
                "elementShield": {"functionSetSha256": "b" * 64, "fxVariants": variants}}))
            d = root / "discovery.json"; d.write_text(json.dumps({"contractId": "nll/boss-content-discovery/v1",
                "sourceAffinity": source, "sourceStaticDataSha256": "c" * 64,
                "elementShield": {"functionSetSha256": "b" * 64}, "shieldPatterns": {"conditions": [{
                    "functionKey": "d" * 64, "fxSlotCount": 1, "fxPrefabSetKey": "a" * 64, "fxAttachmentKey": "e" * 64}]}}))
            args = NS(profile=p, source_discovery=d, cache=cache, compare_element=["electric"],
                unitypy=NS(load=lambda _: ShieldFitTests.environment()), output=root / "reference.json")
            originals = {x: x.read_bytes() for x in [p, d, *cache.iterdir()]}
            result = ref.run(args)
            self.assertEqual(result["sourceBossElementCode"], "water")
            self.assertEqual(result["sourceDiscoverySha256"], fit.digest(d.read_bytes()))
            self.assertEqual(len(result["references"]), 2)
            with self.assertRaises(FileExistsError): ref.run(args)
            self.assertEqual(originals, {x: x.read_bytes() for x in originals})
            args.output = cache / "bad.json"
            with self.assertRaisesRegex(ValueError, "output_in_cache"): ref.run(args)
            args.output = root / "bad.json"
            bad = json.loads(d.read_text()); bad["elementShield"]["functionSetSha256"] = "f" * 64
            d.write_text(json.dumps(bad))
            with self.assertRaisesRegex(ValueError, "discovery_binding_invalid"): ref.run(args)
            self.assertFalse(args.output.exists())


class QteAdmissionTests(unittest.TestCase):
    def baseline(self):
        return {"quickTimeEventAffinity": {
            "modeCode": "not_applicable", "recordCount": 0, "monsterReferenceCount": 0,
            "sourceElementCodes": [], "recordSetSha256": profile.EMPTY_SHA256,
            "immutablePayloadSetSha256": profile.EMPTY_SHA256,
            "sourceElementSetSha256": profile.EMPTY_SHA256,
        }}

    def test_closed_no_qte_allowed(self):
        source = self.baseline()
        before = copy.deepcopy(source)
        profile.require_v2_qte_compatibility(source)
        self.assertEqual(before, source)

    def test_absent_discovery_rejected(self):
        for value in ({}, {"quickTimeEventAffinity": None}, {"quickTimeEventAffinity": []}):
            with self.subTest(value=value):
                with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_discovery_missing$"):
                    profile.require_v2_qte_compatibility(value)

    def test_elemental_qte_requires_v3(self):
        source = self.baseline()
        source["quickTimeEventAffinity"].update({
            "modeCode": "target_monster_linked_element_only", "recordCount": 5,
            "monsterReferenceCount": 3, "sourceElementCodes": ["electric"],
        })
        with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_v3_pipeline_required$"):
            profile.require_v2_qte_compatibility(source)

    def test_inconsistent_or_incomplete_closure_rejected(self):
        changes = {
            "modeCode": [None, "unresolved", "target_monster_linked_element_only"],
            "recordCount": [False, "0", -1, 1],
            "monsterReferenceCount": [False, "0", -1, 1],
            "sourceElementCodes": [None, ["unresolved"], ["electric"]],
            "recordSetSha256": [None, "0" * 64],
            "immutablePayloadSetSha256": [None, "0" * 64],
            "sourceElementSetSha256": [None, "0" * 64],
        }
        for field, values in changes.items():
            for value in values:
                source = self.baseline()
                source["quickTimeEventAffinity"][field] = value
                with self.subTest(field=field, value=value):
                    with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_v3_pipeline_required$"):
                        profile.require_v2_qte_compatibility(source)
            source = self.baseline()
            del source["quickTimeEventAffinity"][field]
            with self.subTest(missing=field):
                with self.assertRaisesRegex(profile.PipelineError, "^boss_profile_qte_v3_pipeline_required$"):
                    profile.require_v2_qte_compatibility(source)


if __name__ == "__main__":
    unittest.main()
