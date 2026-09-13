"""Synthetic fixed-layout tests; no UnityPy, game bytes, installation or network."""

import importlib.util
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("layout", Path(__file__).with_name("materialize-nll-native-fx-layout.py"))
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


def bundle(payload=b"AAAAzzzz", *, at_end=False, align=True, block_flags=0, digest=None):
    info = (digest or bytes(16)) + struct.pack(">IIIHIQQI", 1, len(payload), len(payload), block_flags,
                                            1, 0, len(payload), 4) + b"synthetic.assets\0"
    prefix = b"UnityFS\0" + struct.pack(">I", 7) + b"test\0test\0"
    start = (len(prefix) + 20 + 15) & ~15
    data_start = start if at_end else start + len(info)
    if align:
        data_start = (data_start + 15) & ~15
    size = data_start + len(payload) + (len(info) if at_end else 0)
    header = prefix + struct.pack(">QIII", size, len(info), len(info), 64 | (128 if at_end else 0) | (512 if align else 0))
    head = header + bytes(start - len(header))
    if not at_end:
        head += info
    return head + bytes(data_start - len(head)) + payload + (info if at_end else b"")


def no_decompress(*_):
    raise AssertionError("synthetic bundle must not decompress")


class SyntheticUnity:
    def __init__(self, mutate=None):
        self.mutate = mutate

    def load(self, data):
        nodes = layout.directory(data, no_decompress)
        start, size = nodes["synthetic.assets"]
        file = object()
        rows = [NS(path_id=i + 1, type=NS(name=name), assets_file=file, byte_start=i * 4,
                   byte_size=4, get_raw_data=lambda i=i: data[start + i * 4:start + i * 4 + 4])
                for i, name in enumerate(("Transform", "Texture2D"))]
        if self.mutate:
            self.mutate(rows, data[start:start + size])
        return NS(objects=rows, files={"bundle": NS(files={"synthetic.assets": file})})


class LayoutTests(unittest.TestCase):
    def test_equal_size_transform_payload_preserves_all_other_bytes(self):
        for at_end in (False, True):
            for align in (False, True):
                with self.subTest(at_end=at_end, align=align):
                    original = bundle(at_end=at_end, align=align)
                    target = bundle(b"BBBBzzzz", at_end=at_end, align=align)
                    output, count = layout.materialize(original, target, SyntheticUnity(), no_decompress)
                    self.assertEqual(output, target)
                    self.assertEqual(count, 1)
                    self.assertEqual(len(output), len(original))
                    self.assertEqual(layout.directory(output, no_decompress), layout.directory(original, no_decompress))

    def test_non_transform_payload_change_is_rejected(self):
        with self.assertRaisesRegex(layout.fx.CandidateError, "change_not_allowed"):
            layout.materialize(bundle(), bundle(b"BBBBxxxx"), SyntheticUnity(), no_decompress)

    def test_native_uncompressed_block_flag_is_preserved(self):
        original, target = bundle(block_flags=64), bundle(b"BBBBzzzz", block_flags=64)
        result, count = layout.materialize(original, target, SyntheticUnity(), no_decompress)
        self.assertEqual(result, target)
        self.assertEqual(count, 1)
        with self.assertRaisesRegex(layout.fx.CandidateError, "compressed_body_unsupported"):
            layout.directory(bundle(block_flags=128), no_decompress)

    def test_no_change_not_presented_as_normalization(self):
        with self.assertRaisesRegex(layout.fx.CandidateError, "no_transform_change"):
            layout.materialize(bundle(), bundle(), SyntheticUnity(), no_decompress)

    def test_every_truncation_is_rejected(self):
        data = bundle()
        for count in range(len(data)):
            with self.subTest(count=count), self.assertRaises(layout.fx.CandidateError):
                layout.directory(data[:count], no_decompress)

    def test_compressed_body_and_unknown_content_digest_are_rejected(self):
        for data in (bundle(block_flags=3), bundle(digest=b"x" * 16)):
            with self.assertRaises(layout.fx.CandidateError):
                layout.directory(data, no_decompress)

    def test_header_size_version_and_flags_are_validated(self):
        original = bundle()
        for offset, value in ((8, struct.pack(">I", 6)), (22, struct.pack(">Q", 1)),
                              (38, struct.pack(">I", 0x10000))):
            bad = bytearray(original)
            bad[offset:offset + len(value)] = value
            with self.subTest(offset=offset), self.assertRaises(layout.fx.CandidateError):
                layout.directory(bytes(bad), no_decompress)

    def test_duplicate_identity_changed_type_and_overlapping_objects_rejected(self):
        mutations = [lambda rows, _: setattr(rows[1], "path_id", 1),
                     lambda rows, payload: setattr(rows[0].type, "name", "Transform" if payload[0] == 65 else "Texture2D"),
                     lambda rows, _: setattr(rows[1], "byte_start", 0),
                     lambda rows, _: setattr(rows[0], "byte_size", 5)]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(layout.fx.CandidateError):
                layout.materialize(bundle(), bundle(b"BBBBzzzz"), SyntheticUnity(mutation), no_decompress)

    def test_reparse_source_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve()
            source = root / "source"
            source.mkdir()
            link = root / "link"
            try:
                link.symlink_to(source, target_is_directory=True)
            except OSError:
                self.skipTest("symlink permission unavailable")
            with self.assertRaisesRegex(layout.fx.CandidateError, "reparse"):
                layout.stage(link, "a" * 64, root / "out", SyntheticUnity(), no_decompress)


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source, self.output = self.root / "source", self.root / "output"
        (self.source / "native").mkdir(parents=True)
        (self.source / "native/binding.private.json").write_bytes(b"synthetic binding")
        (self.source / "export-plan.private.json").write_bytes(b"synthetic plan")
        rows = []
        for role in layout.fx.ROLES:
            original, overlay = self.source / "native" / (role + ".bundle"), self.source / (role + ".bundle")
            original.write_bytes(bundle())
            overlay.write_bytes(bundle(b"BBBBzzzz"))
            rows.append({"roleCode": role, "original": layout.fx.fingerprint(original), "overlay": layout.fx.fingerprint(overlay)})
        self.receipt = {"contractId": "nll/native-fx-candidate-receipt/v1", "entries": rows,
                        "statusCode": "offline_native_candidate_verified", "nativeClientExecuted": False,
                        "installedFilesModified": False, "runtimeAdmissionStatusCode": "not_assessed",
                        "bindingManifestSha256": layout.fx.fingerprint(self.source / "native/binding.private.json")["sha256"],
                        "exportPlanSha256": layout.fx.fingerprint(self.source / "export-plan.private.json")["sha256"]}
        self.seal()

    def seal(self):
        self.pin = layout.fx.digest(layout.fx.encoded(self.receipt))
        (self.source / "receipt.json").write_bytes(layout.fx.encoded(self.receipt))

    def run_stage(self):
        return layout.stage(self.source, self.pin, self.output, SyntheticUnity(), no_decompress)

    def test_sealed_candidate_without_native_admission_and_inputs_unchanged(self):
        before = {p: p.read_bytes() for p in self.source.rglob("*") if p.is_file()}
        result = self.run_stage()
        self.assertEqual(result["contractId"], layout.CONTRACT)
        self.assertFalse(result["nativeClientExecuted"])
        self.assertFalse(result["installedFilesModified"])
        self.assertEqual(result["runtimeAdmissionStatusCode"], "not_assessed")
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertEqual(len(result["entries"]), 3)
        self.assertEqual(json.loads((self.output / "receipt.json").read_bytes()), result)
        with self.assertRaisesRegex(layout.fx.CandidateError, "output_invalid"):
            self.run_stage()

    def test_missing_or_drifted_input_never_creates_output(self):
        (self.source / "wind.bundle").write_bytes(b"drift")
        with self.assertRaisesRegex(layout.fx.CandidateError, "input_drift"):
            self.run_stage()
        self.assertFalse(self.output.exists())

    def test_output_cannot_overlap_input(self):
        self.output = self.source / "nested"
        with self.assertRaisesRegex(layout.fx.CandidateError, "output_invalid"):
            self.run_stage()

    def test_claimed_runtime_admission_and_duplicate_roles_rejected(self):
        for key, value in (("nativeClientExecuted", True), ("installedFilesModified", True),
                           ("runtimeAdmissionStatusCode", "ready")):
            old = self.receipt[key]
            self.receipt[key] = value
            self.seal()
            with self.subTest(key=key), self.assertRaisesRegex(layout.fx.CandidateError, "source_invalid"):
                self.run_stage()
            self.receipt[key] = old
        self.receipt["entries"][0]["roleCode"] = self.receipt["entries"][1]["roleCode"]
        self.seal()
        with self.assertRaisesRegex(layout.fx.CandidateError, "roles_invalid"):
            self.run_stage()

    def test_interruption_leaves_unsealed_output_and_new_root_retry(self):
        original = layout.fx.new_file
        calls = []

        def interrupted(path, data):
            calls.append(path)
            if len(calls) == 2:
                raise OSError("synthetic interruption")
            return original(path, data)

        with patch.object(layout.fx, "new_file", side_effect=interrupted), self.assertRaises(OSError):
            self.run_stage()
        self.assertTrue(self.output.exists())
        self.assertFalse((self.output / "receipt.json").exists())
        with self.assertRaisesRegex(layout.fx.CandidateError, "output_invalid"):
            self.run_stage()
        self.output = self.root / "retry"
        self.assertEqual(self.run_stage()["statusCode"], "offline_fixed_layout_verified")

    def test_mid_write_input_drift_cannot_seal_success(self):
        original = layout.fx.new_file

        def drift(path, data):
            original(path, data)
            (self.source / "receipt.json").write_bytes(b"drift")

        with patch.object(layout.fx, "new_file", side_effect=drift), self.assertRaisesRegex(layout.fx.CandidateError, "input_drift"):
            self.run_stage()
        self.assertFalse((self.output / "receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
