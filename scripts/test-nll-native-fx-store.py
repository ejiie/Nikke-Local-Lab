"""Whole-file A -> B -> A and interruption tests on tiny synthetic stores only."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("store", Path(__file__).with_name("materialize-nll-native-fx-store.py"))
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "inputs" / "store.cdb"
        self.source.parent.mkdir()
        self.package = self.root / "package"
        self.package.mkdir()
        self.output = self.root / "owned-output"
        original, rows = bytearray(b"_" * 4096), []
        for i, role in enumerate(store.fx.ROLES):
            before, after, offset = ("old-" + role).encode(), ("new-" + role).encode(), 300 + i * 512
            original[offset:offset + len(before)] = before
            row = {"roleCode": role, "ordinal": i, "offset": offset, "byteLength": len(before)}
            for kind, payload in (("before", before), ("after", after)):
                row[kind + "File"] = f"{role}-{i}-{kind}.chunk"
                row[kind + "Sha256"] = store.fx.digest(payload)
                (self.package / row[kind + "File"]).write_bytes(payload)
            rows.append(row)
        self.original = bytes(original)
        self.source.write_bytes(original)
        self.manifest = {"contractId": "nll/native-fx-chunk-candidate-private/v1", "layoutSha256": "a" * 64,
                         "sourceStore": {"path": str(self.source), **store.fingerprint(self.source)}, "entries": rows,
                         "oldChunkDigestsMatch": False, "nativeClientExecuted": False, "runtimeAdmissionStatusCode": "not_assessed"}
        self.receipt = {"contractId": "nll/native-fx-chunk-candidate/v1", "layoutSha256": "a" * 64,
                        "sourceStoreSha256": store.fx.digest(original), "sourceStoreByteLength": len(original),
                        "changedChunkCount": 3, "roleCodes": sorted(store.fx.ROLES), "indexTrailerVerified": True,
                        "exactCompressedLengthRoundTripVerified": True, "sourceFilesUnchanged": True,
                        "installedFilesModified": False, "nativeClientExecuted": False, "oldChunkDigestsMatch": False,
                        "runtimeAdmissionStatusCode": "not_assessed", "statusCode": "offline_chunk_candidate_verified"}
        self.seal()

    def seal(self):
        raw = store.fx.encoded(self.manifest)
        (self.package / "manifest.private.json").write_bytes(raw)
        self.receipt["manifestSha256"] = store.fx.digest(raw)
        raw = store.fx.encoded(self.receipt)
        self.pin = store.fx.digest(raw)
        (self.package / "receipt.json").write_bytes(raw)

    def create(self):
        self.created = store.create(self.package, self.pin, self.output)
        self.output_pin = self.created["manifestSha256"]
        return self.created

    def test_whole_file_apply_verify_restore_twice_and_reject_restored_candidate(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        created = self.create()
        self.assertNotEqual(created["original"], created["candidate"])
        self.assertEqual(created["original"]["byteLength"], created["candidate"]["byteLength"])
        self.assertFalse(created["nativeClientExecuted"])
        self.assertEqual(created["runtimeAdmissionStatusCode"], "not_assessed")
        copied = (self.output / "store.cdb").read_bytes()
        changed = {i for row in self.manifest["entries"] for i in range(row["offset"], row["offset"] + row["byteLength"])}
        self.assertTrue(all(a == b or i in changed for i, (a, b) in enumerate(zip(self.original, copied))))
        store.inspect(self.output, self.output_pin)
        for _ in range(2):
            self.assertEqual(store.inspect(self.output, self.output_pin, True)["statusCode"], "offline_copy_restored")
        self.assertEqual((self.output / "store.cdb").read_bytes(), self.original)
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        with self.assertRaisesRegex(store.fx.CandidateError, "candidate_not_ready"):
            store.inspect(self.output, self.output_pin)

    def test_source_drift_never_creates_an_output(self):
        self.source.write_bytes(b"drift")
        with self.assertRaisesRegex(store.fx.CandidateError, "source_drift"):
            self.create()
        self.assertFalse(self.output.exists())

    def test_each_selected_role_changes_only_its_own_chunks_and_restores_twice(self):
        for role in store.fx.ROLES:
            with self.subTest(role=role):
                output = self.root / ("selected-" + role)
                created = store.create(self.package, self.pin, output, role)
                self.assertEqual(created["roleCode"], role)
                self.assertFalse(created["allRolesApplied"])
                manifest = json.loads((output / "manifest.private.json").read_bytes())
                self.assertEqual(manifest["contractId"], store.SELECTED_CONTRACT)
                current = (output / "store.cdb").read_bytes()
                expected = bytearray(self.original)
                for row in self.manifest["entries"]:
                    if row["roleCode"] == role:
                        expected[row["offset"]:row["offset"] + row["byteLength"]] = (self.package / row["afterFile"]).read_bytes()
                self.assertEqual(current, bytes(expected))
                self.assertEqual(self.source.read_bytes(), self.original)
                store.inspect(output, created["manifestSha256"])
                for _ in range(2):
                    store.inspect(output, created["manifestSha256"], True)
                self.assertEqual((output / "store.cdb").read_bytes(), self.original)

    def test_invalid_selected_role_fails_before_creating_a_copy(self):
        for role in ("", "water", "electric", "all", True, [], "../fire"):
            with self.subTest(role=role), self.assertRaisesRegex(store.fx.CandidateError, "selected_role_invalid"):
                store.create(self.package, self.pin, self.output, role)
            self.assertFalse(self.output.exists())

    def test_selected_manifest_cannot_change_roles_at_restore(self):
        created = store.create(self.package, self.pin, self.output, "fire")
        manifest_path = self.output / "manifest.private.json"
        manifest = json.loads(manifest_path.read_bytes())
        manifest["roleCode"] = "wind"
        raw = store.fx.encoded(manifest)
        manifest_path.write_bytes(raw)
        for restore in (False, True):
            with self.assertRaisesRegex(store.fx.CandidateError, "selected_role_binding_mismatch"):
                store.inspect(self.output, store.fx.digest(raw), restore)
        self.assertFalse((self.output / 'store.cdb.restore-partial').exists())
        self.assertEqual(store.fingerprint(self.output / "store.cdb"), created["candidate"])
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_legacy_manifest_rejects_silent_selected_role_extension(self):
        self.create()
        manifest_path = self.output / "manifest.private.json"
        manifest = json.loads(manifest_path.read_bytes())
        manifest["roleCode"] = "fire"
        raw = store.fx.encoded(manifest)
        manifest_path.write_bytes(raw)
        with self.assertRaisesRegex(store.fx.CandidateError, "legacy_role_forbidden"):
            store.inspect(self.output, store.fx.digest(raw), True)

    def test_create_refuses_existing_or_overlapping_output(self):
        for target in (self.package, self.package / "nested", self.source.parent / "nested", self.root):
            self.output = target
            with self.subTest(target=target), self.assertRaises(store.fx.CandidateError):
                self.create()

    def test_invalid_offsets_lengths_duplicates_and_paths_fail_before_copy(self):
        initial = copy.deepcopy(self.manifest)
        mutations = [lambda rows: rows[0].update(offset=255), lambda rows: rows[0].update(offset=4096),
                     lambda rows: rows[1].update(offset=rows[0]["offset"]), lambda rows: rows[0].update(byteLength=0),
                     lambda rows: rows[0].update(beforeFile="../store.cdb"), lambda rows: rows[0].update(offset=True),
                     lambda rows: rows[0].update(afterSha256="f" * 64), lambda rows: rows[0].update(roleCode="water")]
        for mutate in mutations:
            self.manifest = copy.deepcopy(initial)
            mutate(self.manifest["entries"])
            self.seal()
            with self.subTest(mutation=mutate), self.assertRaises(store.fx.CandidateError):
                self.create()
            self.assertFalse(self.output.exists())

    def test_native_acceptance_claim_or_mismatched_provenance_rejected(self):
        for field, value in (("nativeClientExecuted", True), ("oldChunkDigestsMatch", True),
                             ("runtimeAdmissionStatusCode", "ready"), ("layoutSha256", "b" * 64)):
            initial = self.manifest[field]
            self.manifest[field] = value
            self.seal()
            with self.subTest(field=field), self.assertRaises(store.fx.CandidateError):
                self.create()
            self.manifest[field] = initial

    def test_create_interruption_has_no_seal_and_never_changes_source(self):
        def fail(source, temporary, patches):
            temporary.write_bytes(b"partial")
            raise OSError("synthetic copy failure")
        with patch.object(store, "copy_with_patches", side_effect=fail), self.assertRaises(OSError):
            self.create()
        self.assertFalse((self.output / "manifest.private.json").exists())
        self.assertFalse((self.output / "store.cdb").exists())
        self.assertEqual(self.source.read_bytes(), self.original)
        with self.assertRaisesRegex(store.fx.CandidateError, "output_invalid"):
            self.create()
        self.output = self.root / "retry"
        self.create()

    def test_interrupted_restore_after_flush_can_finish_without_recopy(self):
        self.create()
        with patch.object(store.os, "replace", side_effect=OSError("synthetic interrupted rename")), self.assertRaises(OSError):
            store.inspect(self.output, self.output_pin, True)
        partial = self.output / "store.cdb.restore-partial"
        self.assertEqual(partial.read_bytes(), self.original)
        self.assertEqual(store.fingerprint(self.output / "store.cdb"), self.created["candidate"])
        with patch.object(store, "copy_with_patches", side_effect=AssertionError("must not recopy")):
            store.inspect(self.output, self.output_pin, True)
        self.assertFalse(partial.exists())
        self.assertEqual((self.output / "store.cdb").read_bytes(), self.original)

    def test_foreign_or_incomplete_partial_is_retained_and_refused(self):
        self.create()
        partial = self.output / "store.cdb.restore-partial"
        partial.write_bytes(b"foreign or incomplete")
        with self.assertRaisesRegex(store.fx.CandidateError, "partial_drift"):
            store.inspect(self.output, self.output_pin, True)
        self.assertEqual(partial.read_bytes(), b"foreign or incomplete")
        self.assertEqual(store.fingerprint(self.output / "store.cdb"), self.created["candidate"])

    def test_drifted_copy_is_not_silently_repaired_or_overwritten(self):
        self.create()
        path = self.output / "store.cdb"
        path.write_bytes(b"unrelated change")
        with self.assertRaisesRegex(store.fx.CandidateError, "copy_drift"):
            store.inspect(self.output, self.output_pin, True)
        self.assertEqual(path.read_bytes(), b"unrelated change")
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_wrong_seal_drifted_package_and_busy_lock_refuse_restore(self):
        self.create()
        with self.assertRaisesRegex(store.fx.CandidateError, "manifest_drift"):
            store.inspect(self.output, "0" * 64, True)
        lock = self.output / ".operation.lock"
        lock.write_bytes(b"existing owner")
        with self.assertRaisesRegex(store.fx.CandidateError, "busy"):
            store.inspect(self.output, self.output_pin, True)
        self.assertEqual(lock.read_bytes(), b"existing owner")
        lock.unlink()
        (self.package / "fire-0-before.chunk").write_bytes(b"drifted")
        with self.assertRaises(store.fx.CandidateError):
            store.inspect(self.output, self.output_pin, True)
        self.assertEqual(store.fingerprint(self.output / "store.cdb"), self.created["candidate"])


if __name__ == "__main__":
    unittest.main()
