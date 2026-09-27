"""Synthetic PNG/local-bundle fixtures only; no network or game required."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("boss_images", Path(__file__).with_name("materialize-nll-boss-catalog-images.py"))
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def synthetic_png():
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(b"\0\xff\0\0\xff")) + chunk(b"IEND", b"")


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.catalog_path, self.hints_path = self.inputs / "catalog.json", self.inputs / "hints.json"
        self.catalog = {"schemaVersion": 1, "contractId": "nll/boss-season-catalog/v1", "sourceStaticDataSha256": "a" * 64,
                        "maximumKnownSeason": 3, "seasons": [{"seasonNumber": n, "discoveryStatusCode": "resolved",
                        "imageStatusCode": "unresolved", "imageSha256": None, "defaultWeaknessCode": "fire"} for n in range(1, 4)]}
        self.hints = {"schemaVersion": 1, "contractId": "nll/private-boss-season-images/v1", "sourceStaticDataSha256": "a" * 64,
                      "images": [{"seasonNumber": n, "monsterImage": "full_synthetic"} for n in (1, 2)]}
        self.requests = []
        self.output = self.root / "output"

    def download(self, name):
        self.requests.append(name)
        return synthetic_png()

    def run_materializer(self, download=None):
        for path, data in ((self.catalog_path, self.catalog), (self.hints_path, self.hints)):
            path.write_bytes(images.encode(data))
        before = {path: path.read_bytes() for path in (self.catalog_path, self.hints_path)}
        receipt = images.materialize(self.catalog_path, images.digest(before[self.catalog_path]),
            self.hints_path, images.digest(before[self.hints_path]), self.output, download or self.download)
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        return receipt

    def test_exact_image_reuse_preserves_season_identity_and_missing_reference(self):
        receipt = self.run_materializer()
        self.assertEqual(self.requests, ["full_synthetic"])
        self.assertEqual(receipt["resolvedSeasonCount"], 2)
        self.assertEqual(receipt["uniqueImageCount"], 1)
        public = (self.output / "catalog.json").read_bytes()
        self.assertNotIn(b"full_synthetic", public)
        self.assertNotIn(b"https", public)
        rows = json.loads(public)["seasons"]
        self.assertEqual([row["seasonNumber"] for row in rows], [1, 2, 3])
        self.assertEqual(rows[0]["imageSha256"], rows[1]["imageSha256"])
        self.assertEqual(rows[2]["imageStatusCode"], "unresolved")
        self.assertTrue(all(row["defaultWeaknessCode"] == "fire" for row in rows))
        self.assertFalse(receipt["officialServiceRequested"])
        self.assertFalse(receipt["nativeClientExecuted"])

    def test_missing_local_image_never_falls_back_to_another_boss(self):
        def fail(name):
            self.requests.append(name)
            raise ValueError("boss_image_not_found")
        receipt = self.run_materializer(fail)
        self.assertEqual(receipt["resolvedSeasonCount"], 0)
        self.assertEqual(self.requests, ["full_synthetic"])
        self.assertEqual(receipt["images"][0]["failureCode"], "boss_image_not_found")

    def test_enikk_is_preferred_and_local_bundles_are_not_opened(self):
        provider = images.EnikkFirstImages(lambda _: self.fail('local export should not run'), self.download)
        receipt = self.run_materializer(provider)
        self.assertEqual(self.requests, ['full_synthetic'])
        self.assertEqual(receipt['providerCode'], images.PROVIDER)
        self.assertEqual(receipt['images'][0]['providerCode'], 'enikk')
        self.assertEqual(receipt['images'][1]['providerCode'], 'enikk')

    def test_only_missing_enikk_images_use_exact_local_fallback(self):
        self.hints['images'][1]['monsterImage'] = 'full_missing'
        local_requests = []
        def remote(name):
            if name == 'full_missing':
                raise ValueError('boss_image_enikk_missing')
            return synthetic_png()
        def factory(missing):
            self.assertEqual(missing, ['full_missing'])
            def local(name):
                local_requests.append(name)
                return synthetic_png()
            return local
        receipt = self.run_materializer(images.EnikkFirstImages(factory, remote))
        self.assertEqual(local_requests, ['full_missing'])
        self.assertEqual(receipt['images'][0]['providerCode'], 'enikk')
        self.assertEqual(receipt['images'][1]['providerCode'], 'local_game_dp')
        self.assertEqual(receipt['images'][1]['primaryFailureCode'], 'boss_image_enikk_missing')

    def test_bad_remote_png_and_remote_outage_fall_back_without_guessing(self):
        for reason in ('invalid_png', 'outage'):
            with self.subTest(reason=reason):
                def remote(name):
                    if reason == 'outage':
                        raise ValueError('boss_image_enikk_unavailable')
                    return b'<html>unavailable</html>'
                calls = []
                provider = images.EnikkFirstImages(lambda missing: lambda name: calls.append(name) or synthetic_png(), remote)
                provider.prepare(['full_synthetic'])
                self.assertEqual(provider('full_synthetic'), synthetic_png())
                self.assertEqual(calls, ['full_synthetic'])

    def test_missing_from_both_sources_stays_unresolved(self):
        def missing(_):
            raise ValueError('boss_image_not_installed')
        receipt = self.run_materializer(images.EnikkFirstImages(lambda _: missing, missing))
        self.assertEqual(receipt['resolvedSeasonCount'], 0)
        self.assertEqual(receipt['images'][0]['providerCode'], None)

    def test_malformed_response_preserves_unresolved(self):
        receipt = self.run_materializer(lambda _: b"<html>synthetic failure</html>")
        self.assertEqual(receipt["resolvedSeasonCount"], 0)
        self.assertEqual(receipt["images"][0]["failureCode"], "boss_image_png_invalid")

    def test_snapshot_mismatch_precedes_network_or_output(self):
        self.hints["sourceStaticDataSha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "snapshot_binding_invalid"):
            self.run_materializer()
        self.assertFalse(self.requests)
        self.assertFalse(self.output.exists())

    def test_duplicate_season_precedes_network(self):
        self.hints["images"].append(self.hints["images"][0])
        with self.assertRaisesRegex(ValueError, "hints_invalid"):
            self.run_materializer()
        self.assertFalse(self.requests)
        self.assertFalse(self.output.exists())

    def test_bad_names_never_become_remote_paths(self):
        for name in ("../full_synthetic", "full_other.png", "https://host/x", "full_x?query=y", "full_x\n"):
            self.hints["images"][0]["monsterImage"] = name
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "hints_invalid"):
                self.run_materializer()
            self.assertFalse(self.requests)
            self.assertFalse(self.output.exists())

    def test_output_collision_is_not_reused_or_removed(self):
        self.output.mkdir()
        marker = self.output / "retained.txt"
        marker.write_text("owned elsewhere")
        with self.assertRaisesRegex(ValueError, "output_invalid"):
            self.run_materializer()
        self.assertEqual(marker.read_text(), "owned elsewhere")
        self.assertFalse(self.requests)

    def test_path_traversal_is_rejected_before_normalization(self):
        with self.assertRaisesRegex(ValueError, "path_invalid"):
            images.plain(self.root / "artifacts" / ".." / "outside")

    def test_crc_truncation_trailer_and_duplicate_ihdr_are_rejected(self):
        valid = synthetic_png()
        images.png(valid)
        for payload in (valid[:-1], valid + b"extra", valid[:50] + bytes([valid[50] ^ 1]) + valid[51:],
                        valid[:33] + valid[8:33] + valid[33:], valid[:8] + chunk(b"IEND", b"")):
            with self.assertRaisesRegex(ValueError, "png_invalid"):
                images.png(payload)

    def local_provider(self, objects):
        data = b'synthetic bundle'
        pin = images.digest(data)
        (self.root / (pin + '.bundle')).write_bytes(data)
        (self.root / 'images.private.json').write_bytes(images.encode({
            'contractId': 'nll/local-boss-image-bundles/v1', 'hintsSha256': 'a' * 64,
            'images': [{'name': 'full_synthetic', 'statusCode': 'resolved', 'bundle': pin + '.bundle', 'sha256': pin}]}))
        calls = []
        def loader(raw):
            calls.append(raw)
            return SimpleNamespace(objects=objects)
        return images.LocalImages(self.root, 'a' * 64, loader), calls, pin

    def test_local_texture_preserves_canvas_and_bundle_is_loaded_once(self):
        class Png:
            width, height = 1, 1
            def save(self, stream, format):
                self_format = format
                assert self_format == 'PNG'
                stream.write(synthetic_png())
        texture = SimpleNamespace(m_Name='full_synthetic', image=Png())
        objects = [SimpleNamespace(type=SimpleNamespace(name='Texture2D'), read=lambda: texture),
                   SimpleNamespace(type=SimpleNamespace(name='Sprite'), read=lambda: self.fail('must retain full canvas'))]
        local, calls, _ = self.local_provider(objects)
        self.assertEqual(local('full_synthetic'), synthetic_png())
        self.assertEqual(local('full_synthetic'), synthetic_png())
        self.assertEqual(len(calls), 1)
        with self.assertRaisesRegex(ValueError, 'not_installed'):
            local('full_other')

    def test_changed_bundle_is_rejected_before_decode(self):
        local, calls, pin = self.local_provider([])
        (self.root / (pin + '.bundle')).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'bundle_changed'):
            local('full_synthetic')
        self.assertFalse(calls)

    def test_ambiguous_texture_does_not_select_first(self):
        obj = SimpleNamespace(type=SimpleNamespace(name='Texture2D'),
                              read=lambda: SimpleNamespace(m_Name='full_synthetic'))
        local, _, _ = self.local_provider([obj, obj])
        with self.assertRaisesRegex(ValueError, 'texture_unresolved'):
            local('full_synthetic')


if __name__ == "__main__":
    unittest.main()
