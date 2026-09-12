"""Source-only FX lifecycle/transform boundary tests; no game assets or UnityPy needed."""

import copy
import importlib.util
import json
import os
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


candidate = module("materialize-nll-shield-fx-candidate")
transform = module("materialize-nll-shield-fx-transform-variant")


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory(prefix="nll-synthetic-fx-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.output = self.root / "candidate"
        self.profile = self.root / "profile.json"
        self.source = b"synthetic-electric-source"
        self.originals = {role: ("synthetic-original-" + role).encode() for role in candidate.ROLES}
        self.derived = {role: value + b"-derived" for role, value in self.originals.items()}
        self.profile_value = {
            "schemaVersion": 3, "contractId": "nll/boss-runtime-variant-profile/v3",
            "elementShield": {"fxVariants": []},
            "shieldFxTransformNormalization": {
                "modeCode": "per_execution_target_bundle_overlay", "sourceBossElementCode": "electric",
                "targetBossElementCodes": list(candidate.ROLES), "variants": []}}
        for role in ("fire", "water", "wind", "electric", "iron"):
            payload = self.source if role == "electric" else self.originals.get(role, b"synthetic-water")
            (self.cache / (role + ".bundle")).write_bytes(payload)
            self.profile_value["elementShield"]["fxVariants"].append({
                "bossElementCode": role, "mappings": [{"assetBundles": [
                    {"sha256": candidate.digest(payload), "byteLength": len(payload)}]}]})
        for role in candidate.ROLES:
            row = {"bossElementCode": role, **dict(zip(candidate.EVIDENCE_FIELDS, [14, 14, 13, 4, "a" * 64, "b" * 64]))}
            for prefix, payload in (("sourceBundle", self.source), ("targetBundle", self.originals[role]),
                                    ("variantBundle", self.derived[role])):
                row[prefix + "Sha256"] = candidate.digest(payload)
                row[prefix + "ByteLength"] = len(payload)
            self.profile_value["shieldFxTransformNormalization"]["variants"].append(row)
        self.save_profile()
        self.before = {path.name: path.read_bytes() for path in self.cache.iterdir()}

    def save_profile(self):
        self.profile.write_bytes(candidate.encoded(self.profile_value))
        self.profile_sha = candidate.digest(self.profile.read_bytes())

    def fake_materialize(self, source, target, _):
        self.assertEqual(source.read_bytes(), self.source)
        self.assertNotEqual(source.parent.parent, self.cache)
        role = target.stem
        row = next(row for row in self.profile_value["shieldFxTransformNormalization"]["variants"]
                   if row["bossElementCode"] == role)
        return self.derived[role], {key: row[key] for key in candidate.EVIDENCE_FIELDS}

    def create(self, materializer=None):
        return candidate.create(self.profile, self.profile_sha, self.cache, self.output,
                                materializer or self.fake_materialize, None)

    def assert_cache_unchanged(self):
        self.assertEqual(self.before, {path.name: path.read_bytes() for path in self.cache.iterdir()})

    def test_create_verify_restore_idempotent(self):
        receipt = self.create()
        pin = receipt["manifestSha256"]
        self.assertEqual(candidate.inspect_or_restore(self.output, pin), receipt)
        for _ in range(2):
            restored = candidate.inspect_or_restore(self.output, pin, restore=True)
            self.assertEqual(restored["statusCode"], "candidate_restored")
        for role in candidate.ROLES:
            self.assertEqual((self.output / f"overlay/{role}.bundle").read_bytes(), self.originals[role])
        with self.assertRaisesRegex(candidate.CandidateError, "overlay_drifted"):
            candidate.inspect_or_restore(self.output, pin)
        self.assert_cache_unchanged()

    def test_input_missing_no_output(self):
        (self.cache / "wind.bundle").unlink()
        with self.assertRaisesRegex(candidate.CandidateError, "input_missing"):
            self.create()
        self.assertFalse(self.output.exists())

    def test_wrong_profile_hash_no_output(self):
        self.profile_sha = "0" * 64
        with self.assertRaisesRegex(candidate.CandidateError, "profile_drifted"):
            self.create()
        self.assertFalse(self.output.exists())

    def test_existing_output_not_reused(self):
        self.output.mkdir()
        with self.assertRaisesRegex(candidate.CandidateError, "output_exists"):
            self.create()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_output_cache_overlap(self):
        for output in (self.cache, self.cache / "child", self.root):
            with self.subTest(output=output.name):
                self.output = output
                with self.assertRaisesRegex(candidate.CandidateError, "output_overlaps_input"):
                    self.create()
        self.assert_cache_unchanged()

    def test_plan_drift_rejected_before_write(self):
        original = copy.deepcopy(self.profile_value)
        mutations = (
            lambda p: p.update(schemaVersion=2),
            lambda p: p["shieldFxTransformNormalization"].update(targetBossElementCodes=["fire"]),
            lambda p: p["shieldFxTransformNormalization"]["variants"][0].update(bossElementCode="../escape"),
            lambda p: p["shieldFxTransformNormalization"]["variants"][0].update(targetBundleSha256="0" * 64),
            lambda p: p["shieldFxTransformNormalization"]["variants"][0].update(modifiedTransformCount=True),
            lambda p: p["shieldFxTransformNormalization"]["variants"][0].update(matchedTransformCount=15),
            lambda p: p["shieldFxTransformNormalization"]["variants"][0].update(matchedTransformValueSetSha256="bad"),
        )
        for mutate in mutations:
            self.profile_value = copy.deepcopy(original)
            mutate(self.profile_value)
            self.save_profile()
            with self.subTest(mutation=mutations.index(mutate)):
                with self.assertRaises(candidate.CandidateError):
                    self.create()
                self.assertFalse(self.output.exists())

    def test_derived_drift_never_seals(self):
        def drift(*args):
            payload, evidence = self.fake_materialize(*args)
            return payload + b"wrong", evidence
        with self.assertRaisesRegex(candidate.CandidateError, "derived_drifted"):
            self.create(drift)
        self.assertFalse((self.output / "manifest.json").exists())
        self.assert_cache_unchanged()

    def test_evidence_drift_never_seals(self):
        def drift(*args):
            payload, evidence = self.fake_materialize(*args)
            evidence["modifiedTransformCount"] += 1
            return payload, evidence
        with self.assertRaisesRegex(candidate.CandidateError, "evidence_drifted"):
            self.create(drift)
        self.assertFalse((self.output / "manifest.json").exists())

    def test_second_transform_failure_never_seals(self):
        def fail(source, target, unity):
            if target.stem == "wind":
                raise RuntimeError("synthetic interrupted transform")
            return self.fake_materialize(source, target, unity)
        with self.assertRaises(RuntimeError):
            self.create(fail)
        self.assertTrue((self.output / "overlay/fire.bundle").exists())
        self.assertFalse((self.output / "manifest.json").exists())
        self.assert_cache_unchanged()

    def test_input_changes_during_creation_never_seal(self):
        def change(*args):
            (self.cache / "electric.bundle").write_bytes(b"synthetic external change")
            return self.fake_materialize(*args)
        with self.assertRaisesRegex(candidate.CandidateError, "input_drifted"):
            self.create(change)
        self.assertFalse((self.output / "manifest.json").exists())

    def test_backup_changes_during_transform_never_seal(self):
        def change(source, target, unity):
            result = self.fake_materialize(source, target, unity)
            target.write_bytes(b"synthetic transform bug")
            return result
        with self.assertRaisesRegex(candidate.CandidateError, "backup_drifted"):
            self.create(change)
        self.assertFalse((self.output / "manifest.json").exists())
        self.assert_cache_unchanged()

    def test_manifest_hash_drift(self):
        self.create()
        with self.assertRaisesRegex(candidate.CandidateError, "manifest_drifted"):
            candidate.inspect_or_restore(self.output, "0" * 64, restore=True)

    def test_profile_copy_drift(self):
        pin = self.create()["manifestSha256"]
        (self.output / "profile.json").write_bytes(b"changed")
        with self.assertRaisesRegex(candidate.CandidateError, "profile_drifted"):
            candidate.inspect_or_restore(self.output, pin, restore=True)

    def test_source_copy_drift(self):
        pin = self.create()["manifestSha256"]
        (self.output / "source/electric.bundle").write_bytes(b"changed")
        with self.assertRaisesRegex(candidate.CandidateError, "source_drifted"):
            candidate.inspect_or_restore(self.output, pin, restore=True)

    def test_last_backup_drift_prevents_all_replacements(self):
        pin = self.create()["manifestSha256"]
        (self.output / "backup/iron.bundle").write_bytes(b"changed")
        with self.assertRaisesRegex(candidate.CandidateError, "backup_drifted"):
            candidate.inspect_or_restore(self.output, pin, restore=True)
        self.assertEqual((self.output / "overlay/fire.bundle").read_bytes(), self.derived["fire"])
        self.assert_cache_unchanged()

    def test_unknown_overlay_not_overwritten(self):
        pin = self.create()["manifestSha256"]
        target = self.output / "overlay/iron.bundle"
        target.write_bytes(b"foreign bytes")
        with self.assertRaisesRegex(candidate.CandidateError, "overlay_drifted"):
            candidate.inspect_or_restore(self.output, pin, restore=True)
        self.assertEqual(target.read_bytes(), b"foreign bytes")
        self.assertEqual((self.output / "overlay/fire.bundle").read_bytes(), self.derived["fire"])

    def test_interrupted_restore_retries_pinned_partial(self):
        pin = self.create()["manifestSha256"]
        replace = os.replace
        def interrupt(source, target):
            if Path(target).stem == "wind":
                raise OSError("synthetic interruption")
            replace(source, target)
        with patch.object(candidate.os, "replace", interrupt):
            with self.assertRaises(OSError):
                candidate.inspect_or_restore(self.output, pin, restore=True)
        self.assertEqual((self.output / "overlay/fire.bundle").read_bytes(), self.originals["fire"])
        self.assertTrue((self.output / "overlay/wind.restore.partial").exists())
        self.assertEqual(candidate.inspect_or_restore(self.output, pin, restore=True)["statusCode"],
                         "candidate_restored")
        self.assert_cache_unchanged()

    def test_foreign_partial_not_overwritten(self):
        pin = self.create()["manifestSha256"]
        partial = self.output / "overlay/iron.restore.partial"
        partial.write_bytes(b"foreign partial")
        with self.assertRaisesRegex(candidate.CandidateError, "partial_drifted"):
            candidate.inspect_or_restore(self.output, pin, restore=True)
        self.assertEqual(partial.read_bytes(), b"foreign partial")
        self.assertEqual((self.output / "overlay/fire.bundle").read_bytes(), self.derived["fire"])

    def test_busy_lock_not_removed(self):
        pin = self.create()["manifestSha256"]
        lock = self.output / ".operation.lock"
        lock.write_bytes(b"another operation")
        with self.assertRaisesRegex(candidate.CandidateError, "busy"):
            candidate.inspect_or_restore(self.output, pin, restore=True)
        self.assertEqual(lock.read_bytes(), b"another operation")

    def test_hardlinked_overlay_rejected(self):
        pin = self.create()["manifestSha256"]
        target = self.output / "overlay/fire.bundle"
        sibling = self.root / "shared.bundle"
        os.link(target, sibling)
        with self.assertRaisesRegex(candidate.CandidateError, "file_not_owned"):
            candidate.inspect_or_restore(self.output, pin, restore=True)
        self.assertEqual(sibling.read_bytes(), self.derived["fire"])

    def test_output_symlink_rejected(self):
        try:
            self.output.symlink_to(self.cache, target_is_directory=True)
        except OSError:
            if os.name != "nt":
                raise
            # Windows junction creation needs no symbolic-link privilege. The
            # target and link are both owned temporary directories; remove only
            # the junction itself before TemporaryDirectory cleanup.
            environment = dict(os.environ, NLL_TEST_FX_LINK=str(self.output), NLL_TEST_FX_TARGET=str(self.cache))
            subprocess.run(["pwsh", "-NoProfile", "-Command",
                            "New-Item -ItemType Junction -Path $env:NLL_TEST_FX_LINK "
                            "-Target $env:NLL_TEST_FX_TARGET | Out-Null"],
                           env=environment, check=True, capture_output=True)
            self.addCleanup(os.rmdir, self.output)
        with self.assertRaisesRegex(candidate.CandidateError, "reparse_forbidden"):
            self.create()
        self.assert_cache_unchanged()

    def test_role_path_injection_even_with_new_manifest_pin(self):
        self.create()
        path = self.output / "manifest.json"
        manifest = json.loads(path.read_bytes())
        manifest["entries"][0]["roleCode"] = "../../outside"
        path.write_bytes(candidate.encoded(manifest))
        with self.assertRaisesRegex(candidate.CandidateError, "manifest_invalid"):
            candidate.inspect_or_restore(self.output, candidate.digest(path.read_bytes()), restore=True)


class TransformBoundaryTests(unittest.TestCase):
    def reader(self, key, parent=0, children=()):
        tree = {"m_LocalPosition": {"x": 1}, "m_LocalRotation": {"w": 1},
                "m_LocalScale": {"x": 1}, "m_Father": {"m_PathID": parent}, "extra": 42}
        data = NS(m_Father=NS(path_id=parent), m_Children=[NS(path_id=k) for k in children],
                  m_GameObject=NS(read=lambda: NS(m_Name=str(key))))
        return NS(path_id=key, type=NS(name="Transform"), read=lambda: data,
                  read_typetree=lambda: copy.deepcopy(tree), get_raw_data=lambda: candidate.encoded(tree), tree=tree)

    def test_only_matched_vectors_may_change(self):
        a, b = self.reader(1), self.reader(2)
        graph = {1: {"reader": a}, 2: {"reader": b}}
        before = transform.transform_boundary(graph, {1})
        a.tree["m_LocalScale"] = {"x": 99}
        self.assertEqual(before, transform.transform_boundary(graph, {1}))
        a.tree["extra"] = 43
        self.assertNotEqual(before, transform.transform_boundary(graph, {1}))

    def test_unmatched_vector_change_rejected(self):
        obj = self.reader(1)
        graph = {1: {"reader": obj}}
        before = transform.transform_boundary(graph, set())
        obj.tree["m_LocalScale"] = {"x": 99}
        self.assertNotEqual(before, transform.transform_boundary(graph, set()))

    def test_duplicate_transform_identity(self):
        with self.assertRaisesRegex(transform.MaterializationError, "identity_ambiguous"):
            transform.transform_graph(NS(objects=[self.reader(1), self.reader(1)]))

    def test_duplicate_children(self):
        with self.assertRaisesRegex(transform.MaterializationError, "children_ambiguous"):
            transform.transform_graph(NS(objects=[self.reader(1, children=(2, 2)), self.reader(2, 1)]))

    def test_parent_child_mismatch(self):
        with self.assertRaisesRegex(transform.MaterializationError, "parent_child_mismatch"):
            transform.transform_graph(NS(objects=[self.reader(1, children=(2,)), self.reader(2)]))

    def test_detached_cycle(self):
        with self.assertRaisesRegex(transform.MaterializationError, "graph_not_tree"):
            transform.transform_graph(NS(objects=[self.reader(1), self.reader(2, 3, (3,)), self.reader(3, 2, (2,))]))

    def test_duplicate_branch_role(self):
        graph = {1: {"children": [2, 3]}, 2: {"children": [4]}, 3: {"children": [5]},
                 4: {"children": [6, 7, 8]}, 5: {"children": [9, 10, 11]}}
        with self.assertRaisesRegex(transform.MaterializationError, "branch_ambiguous"):
            transform.branch_roots(1, graph)


if __name__ == "__main__":
    unittest.main()
