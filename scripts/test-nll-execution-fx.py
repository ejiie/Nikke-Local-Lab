"""Synthetic staging boundary tests; no game data, UnityPy or installed runtime."""

import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fixtures = load("delivery_fixtures", "test-nll-boss-onboarding-candidate.py")
delivery = load("delivery_stage", "stage-nll-execution-fx.py")


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.CandidateTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        cache = self.fixture.cache
        (cache / "PC/synthetic").mkdir(parents=True)
        for path in list(cache.glob("*.bundle")):
            path.rename(cache / "PC/synthetic" / path.name)
        self.root, self.source = self.fixture.complete_fixture()
        (self.fixture.root / "source-input").mkdir()
        moved_source = self.fixture.root / "source-input/source.pack"
        self.source.rename(moved_source)
        self.source = moved_source
        self.fixture.seal(self.root, self.source)
        self.seal_sha = fixtures.gate.digest(self.root / "onboarding-verified-candidate.receipt.json")
        self.output = self.fixture.root / "delivery"

    def stage(self, weakness="water", output=None):
        return delivery.stage(self.root, self.seal_sha, self.source, self.fixture.cache,
                              output or self.output, "a" * 32, weakness)

    def test_three_roles_are_private_exact_and_independent(self):
        before = {str(p): p.read_bytes() for p in self.fixture.root.rglob("*") if p.is_file()}
        for weakness, target in (("water", "fire"), ("fire", "wind"), ("wind", "iron")):
            output = self.fixture.root / ("delivery-" + weakness)
            result = self.stage(weakness, output)
            manifest = fixtures.gate.read(output / "manifest.private.json")
            self.assertEqual(manifest["requestPath"], f"/PC/synthetic/{target}.bundle")
            self.assertEqual(manifest["bossElementCode"], target)
            self.assertEqual((output / "overlay.bundle").read_bytes(), f"synthetic-{target}-derived".encode())
            self.assertEqual(result["manifestSha256"], fixtures.gate.digest(output / "manifest.private.json"))
            self.assertEqual(result["runtimeAdmissionStatusCode"], "not_assessed")
            self.assertNotIn("requestPath", result)
            self.assertEqual(sorted(p.name for p in output.iterdir()),
                             ["manifest.private.json", "original.bundle", "overlay.bundle"])
        self.assertEqual(before, {p: Path(p).read_bytes() for p in before})

    def test_no_overlay_roles_never_create_folder(self):
        for weakness in ("electric", "iron"):
            with self.assertRaisesRegex(ValueError, "overlay_not_required"):
                self.stage(weakness)
            self.assertFalse(self.output.exists())

    def test_candidate_seal_and_any_past_artifact_are_rechecked(self):
        with self.assertRaisesRegex(ValueError, "seal_drifted"):
            delivery.candidate.verify(self.root, "f" * 64, self.source, self.fixture.cache)
        for name in ("five-affinity-variants/wind.pack", "content-discovery.receipt.json",
                     "shield-fx-candidate/overlay/fire.bundle"):
            path = self.root / name
            before = path.read_bytes()
            path.write_bytes(b"synthetic drift")
            with self.assertRaises(Exception):
                self.stage()
            self.assertFalse(self.output.exists())
            path.write_bytes(before)

    def test_restored_candidate_cannot_be_delivered(self):
        fxroot = self.root / "shield-fx-candidate"
        fixtures.fx.inspect_or_restore(fxroot, fixtures.gate.digest(fxroot / "manifest.json"), restore=True)
        with self.assertRaisesRegex(Exception, "overlay_drifted"):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_duplicate_cache_identity_cannot_choose_an_arbitrary_route(self):
        source = self.fixture.cache / "PC/synthetic/fire.bundle"
        (source.parent / "alias.bundle").write_bytes(source.read_bytes())
        with self.assertRaisesRegex(ValueError, "ambiguous_or_missing"):
            self.stage()
        self.assertFalse(self.output.exists())

    def test_reused_output_and_input_overlap_are_rejected(self):
        self.stage()
        before = (self.output / "manifest.private.json").read_bytes()
        with self.assertRaisesRegex(ValueError, "output_exists"):
            self.stage()
        self.assertEqual(before, (self.output / "manifest.private.json").read_bytes())
        for output in (self.fixture.cache / "new", self.root / "new", self.fixture.root):
            with self.assertRaisesRegex(ValueError, "overlaps_input"):
                self.stage(output=output)

    def test_interrupted_staging_has_no_manifest_and_retry_requires_fresh_root(self):
        verify = delivery.candidate.verify
        calls = 0

        def fail_second(*args):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise ValueError("synthetic_late_input_drift")
            return verify(*args)

        with patch.object(delivery.candidate, "verify", side_effect=fail_second):
            with self.assertRaisesRegex(ValueError, "late_input_drift"):
                self.stage()
        self.assertFalse((self.output / "manifest.private.json").exists())
        with self.assertRaisesRegex(ValueError, "output_exists"):
            self.stage()
        self.stage(output=self.fixture.root / "fresh-retry")

    def test_hardlinked_original_is_rejected_without_writing_through_it(self):
        source = self.fixture.cache / "PC/synthetic/fire.bundle"
        backup = self.fixture.root / "hardlink.bundle"
        os.link(source, backup)
        before = backup.read_bytes()
        with self.assertRaisesRegex(Exception, "file_not_owned"):
            self.stage()
        self.assertEqual(before, backup.read_bytes())

    def test_request_path_contract_rejects_normalization_and_queries(self):
        for path in ("/PC/../a.bundle", "/PC//a.bundle", "/PC/%61.bundle", "/PC/a.bundle?q=1",
                     "/PC/a.bundle#x", "/pc/a.bundle", "https://invalid/PC/a.bundle", "/PC/a\\b.bundle"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                delivery.request_path(path)


if __name__ == "__main__":
    unittest.main()
