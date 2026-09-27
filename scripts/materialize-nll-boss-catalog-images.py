"""Cache exact Enikk boss PNGs, falling back to installed official bundles.

Exact MonsterImage references select images; source files are read-only.
No client launch, runtime installation or guessed boss mappings.
"""
import argparse
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import struct
import sys
import io
import subprocess
import tempfile
import time
import zlib

LIMIT = 20 * 1024 * 1024
PROVIDER = "enikk_then_local_game_dp/v1"


def require(value, code):
    if not value:
        raise ValueError("boss_image_" + code)


def plain(path):
    path = Path(path)
    require(".." not in path.parts, "path_invalid")
    path = path.absolute()
    require(not str(path).startswith("\\\\") and ":" not in str(path)[len(path.anchor):], "path_invalid")
    for current in (path, *path.parents):
        require(not current.is_symlink() and not (hasattr(current, "is_junction") and current.is_junction()), "reparse_forbidden")
    return path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path, pin):
    path = plain(path)
    require(path.is_file() and 0 < path.stat().st_size <= 1024 * 1024, "input_size_invalid")
    raw = path.read_bytes()
    require(digest(raw) == pin, "input_drifted")
    return json.loads(raw)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def new_file(path, data):
    with plain(path).open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def png(data):
    require(33 < len(data) <= LIMIT and data[:8] == b"\x89PNG\r\n\x1a\n", "png_invalid")
    offset, seen, idat, count = 8, False, False, 0
    while offset < len(data):
        require(offset + 12 <= len(data) and count < 10000, "png_invalid")
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        require(length <= LIMIT and offset + length + 12 <= len(data), "png_invalid")
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        require(zlib.crc32(kind + payload) == crc, "png_invalid")
        if count == 0:
            require(kind == b"IHDR" and length == 13, "png_invalid")
            width, height = struct.unpack_from(">II", payload)
            require(0 < width <= 8192 and 0 < height <= 8192 and width * height <= 33554432, "png_dimensions_invalid")
            seen = True
        elif kind == b"IHDR":
            require(False, "png_invalid")
        if kind == b"IDAT":
            idat = True
        offset += length + 12
        count += 1
        if kind == b"IEND":
            require(length == 0 and seen and idat and offset == len(data), "png_invalid")
            return
    require(False, "png_invalid")


class LocalImages:
    def __init__(self, root, hints_pin, loader):
        self.root, self.loader, self.environments = plain(root), loader, {}
        manifest = json.loads((self.root / "images.private.json").read_bytes())
        require(manifest.get("contractId") == "nll/local-boss-image-bundles/v1" and
                manifest.get("hintsSha256") == hints_pin, "local_binding_invalid")
        self.rows = {}
        for row in manifest["images"]:
            name = row["name"]
            require(re.fullmatch(r"full_[A-Za-z0-9_]{1,128}", name) and name not in self.rows, "local_binding_invalid")
            self.rows[name] = row

    def __call__(self, name):
        row = self.rows.get(name)
        require(row is not None and row.get("statusCode") == "resolved", "not_installed")
        pin, leaf = row.get("sha256", ""), row.get("bundle", "")
        require(re.fullmatch(r"[a-f0-9]{64}", pin) and leaf == pin + ".bundle", "local_binding_invalid")
        if pin not in self.environments:
            path = plain(self.root / leaf)
            require(path.is_file() and 0 < path.stat().st_size <= 64 * 1024 * 1024, "bundle_invalid")
            data = path.read_bytes()
            require(digest(data) == pin, "bundle_changed")
            self.environments[pin] = self.loader(data)
        matches = []
        for obj in self.environments[pin].objects:
            if obj.type.name == "Texture2D":
                texture = obj.read()
                if texture.m_Name == name:
                    matches.append(texture)
        require(len(matches) == 1, "texture_unresolved")
        # The full texture retains the game's transparent canvas. A cropped
        # Sprite would change framing across bosses in the existing UI cards.
        image = matches[0].image
        require(0 < image.width <= 8192 and 0 < image.height <= 8192 and
                image.width * image.height <= 33554432, "png_dimensions_invalid")
        output = io.BytesIO()
        image.save(output, format="PNG")
        return output.getvalue()


def fetch_enikk(name):
    require(re.fullmatch(r"full_[A-Za-z0-9_]{1,128}", name), "name_invalid")
    # Fixed public image host only: no credentials, cookies, proxies or redirects.
    connection = http.client.HTTPSConnection("enikk.app", timeout=5)
    try:
        deadline = time.monotonic() + 10
        connection.request("GET", "/bosses/" + name + ".png", headers={"Accept": "image/png"})
        response = connection.getresponse()
        require(response.status == 200, "enikk_missing" if response.status == 404 else "enikk_unavailable")
        content = bytearray()
        while len(content) <= LIMIT:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "enikk_unavailable")
            if connection.sock:
                connection.sock.settimeout(min(5, remaining))
            part = response.read1(min(65536, LIMIT + 1 - len(content)))
            if not part:
                break
            content.extend(part)
            require(len(content) <= LIMIT, "png_invalid")
        data = bytes(content)
        png(data)
        return data
    except (OSError, http.client.HTTPException):
        raise ValueError("boss_image_enikk_unavailable") from None
    finally:
        connection.close()


class EnikkFirstImages:
    provider_code = PROVIDER

    def __init__(self, local_factory, remote=fetch_enikk):
        self.local_factory, self.remote = local_factory, remote
        self.cached, self.sources, self.remote_failures = {}, {}, {}
        self.local = None

    def prepare(self, names):
        def attempt(name):
            try:
                data = self.remote(name)
                png(data)
                return name, data, None
            except ValueError as error:
                require(re.fullmatch(r"boss_image_[a-z_]+", str(error)), "provider_failed")
                return name, None, str(error)
        missing = []
        # A unavailable host must not consume the entire five-minute sync window
        # before local extraction. Bound concurrent public GETs to four.
        with ThreadPoolExecutor(max_workers=4) as pool:
            for name, data, failure in pool.map(attempt, sorted(set(names))):
                if data is not None:
                    self.cached[name] = data
                    self.sources[name] = "enikk"
                else:
                    self.remote_failures[name] = failure
                    missing.append(name)
        # Export/decode local bundles only for exact names not obtained remotely.
        if missing:
            self.local = self.local_factory(missing)

    def __call__(self, name):
        if name in self.cached:
            return self.cached[name]
        require(self.local is not None, "not_prepared")
        data = self.local(name)
        png(data)
        self.sources[name] = "local_game_dp"
        return data


def materialize(catalog_path, catalog_pin, hints_path, hints_pin, output, extract):
    catalog_path, hints_path, output = plain(catalog_path), plain(hints_path), plain(output)
    require(not os.path.lexists(output) and output.parent.is_dir() and
            all(source.parent != output and source.parent not in output.parents and output not in source.parents
                for source in (catalog_path, hints_path)), "output_invalid")
    catalog, hints = read(catalog_path, catalog_pin), read(hints_path, hints_pin)
    require(catalog.get("schemaVersion") == 1 and catalog.get("contractId") == "nll/boss-season-catalog/v1" and
            hints.get("schemaVersion") == 1 and hints.get("contractId") == "nll/private-boss-season-images/v1" and
            re.fullmatch(r"[a-f0-9]{64}", catalog.get("sourceStaticDataSha256", "")) and
            catalog["sourceStaticDataSha256"] == hints.get("sourceStaticDataSha256"), "snapshot_binding_invalid")
    maximum = catalog.get("maximumKnownSeason")
    require(type(maximum) is int and 0 < maximum <= 1000 and
            [row.get("seasonNumber") for row in catalog["seasons"]] == list(range(1, maximum + 1)), "season_set_invalid")
    names = {}
    require(type(hints.get("images")) is list and len(hints["images"]) <= maximum, "hints_invalid")
    for row in hints["images"]:
        season, name = row.get("seasonNumber"), row.get("monsterImage")
        require(type(season) is int and 1 <= season <= maximum and season not in names and
                type(name) is str and re.fullmatch(r"full_[A-Za-z0-9_]{1,128}", name), "hints_invalid")
        require(catalog["seasons"][season - 1]["discoveryStatusCode"] == "resolved", "hints_invalid")
        names[season] = name
    require(all(row["imageStatusCode"] == "unresolved" and row["imageSha256"] is None for row in catalog["seasons"]), "already_materialized")
    output.mkdir()
    image_root = output / "images"
    image_root.mkdir()
    if hasattr(extract, "prepare"):
        extract.prepare(names.values())
    resolved, failures, payloads, observations = {}, {}, {}, []
    for name in sorted(set(names.values())):
        try:
            data = extract(name)
            png(data)
            pin = digest(data)
            if pin not in payloads:
                new_file(image_root / (pin + ".png"), data)
                payloads[pin] = len(data)
            resolved[name] = pin
        except ValueError as error:
            require(re.fullmatch(r"boss_image_[a-z_]+", str(error)), "extraction_failed")
            failures[name] = str(error)
    result = copy.deepcopy(catalog)
    for row in result["seasons"]:
        season = row["seasonNumber"]
        name = names.get(season)
        pin = resolved.get(name)
        if pin:
            row.update(imageStatusCode="resolved", imageSha256=pin)
        observations.append({"seasonNumber": season, "statusCode": "resolved" if pin else "unresolved",
                             "failureCode": failures.get(name) if name else "boss_image_reference_unresolved",
                             "providerCode": getattr(extract, "sources", {}).get(name, "local_game_dp" if pin else None),
                             "primaryFailureCode": getattr(extract, "remote_failures", {}).get(name)})
    read(catalog_path, catalog_pin)
    read(hints_path, hints_pin)
    for pin, length in payloads.items():
        data = (image_root / (pin + ".png")).read_bytes()
        require(len(data) == length and digest(data) == pin, "output_drifted")
    raw = encode(result)
    new_file(output / "catalog.json", raw)
    # Private provenance only; no original key in the public view.
    new_file(output / "bindings.private.json", encode({"contractId": "nll/private-boss-presentation-bindings/v1",
             "hintsSha256": hints_pin, "providerCode": getattr(extract, "provider_code", "local_game_dp"), "bindings": [
                 {"seasonNumber": season, "imageName": name, "imageSha256": resolved.get(name),
                  "providerCode": getattr(extract, "sources", {}).get(name, "local_game_dp" if name in resolved else None)}
                 for season, name in names.items()]}))
    receipt = {"contractId": "nll/boss-catalog-images/v1", "sourceCatalogSha256": catalog_pin,
               "sourceHintsSha256": hints_pin, "catalogSha256": digest(raw), "providerCode": getattr(extract, "provider_code", "local_game_dp"),
               "resolvedSeasonCount": sum(row["statusCode"] == "resolved" for row in observations),
               "requestedObjectCount": len(set(names.values())), "uniqueImageCount": len(payloads),
               "images": observations, "officialServiceRequested": False, "nativeClientExecuted": False,
               "sourceModified": False, "runtimeAdmissionStatusCode": "not_assessed"}
    new_file(output / "receipt.json", encode(receipt))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("catalog", "catalog-sha256", "hints", "hints-sha256", "output-root",
                 "local-source", "catalog-tool", "catalog-tool-sha256", "dotnet", "unitypy-root"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        output = plain(args.output_root)
        artifacts = plain(Path(__file__).parent.parent / "artifacts")
        require(artifacts in output.parents, "output_scope_invalid")
        tool = plain(args.catalog_tool)
        require(digest(tool.read_bytes()) == args.catalog_tool_sha256, "tool_changed")
        sys.path.insert(0, str(plain(args.unitypy_root)))
        import UnityPy
        # Temporary native bundles are deleted after PNG creation, including
        # failed extraction. Only UI images and source-free receipts persist.
        with tempfile.TemporaryDirectory(prefix="boss-images-", dir=output.parent) as temporary:
            def local_factory(missing):
                hints = read(args.hints, args.hints_sha256)
                hints["images"] = [row for row in hints["images"] if row["monsterImage"] in missing]
                subset = encode(hints)
                subset_path = Path(temporary) / "hints.private.json"
                new_file(subset_path, subset)
                bundles = Path(temporary) / "bundles"
                try:
                    result = subprocess.run([args.dotnet, str(tool), "export-boss-image-bundles", args.local_source,
                                             str(subset_path), digest(subset), str(bundles)],
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
                    if result.returncode == 0:
                        return LocalImages(bundles, digest(subset), UnityPy.load)
                except subprocess.TimeoutExpired:
                    pass
                # Missing/incomplete install must not discard the old UI image.
                # The caller merges unresolved rows with its previous catalog.
                def unavailable(_):
                    raise ValueError("boss_image_local_source_unavailable")
                return unavailable
            extract = EnikkFirstImages(local_factory)
            receipt = materialize(args.catalog, args.catalog_sha256, args.hints, args.hints_sha256, output, extract)
        print(json.dumps({key: value for key, value in receipt.items() if key != "images"}))
        return 0
    except Exception as error:
        code = str(error)
        print(code if re.fullmatch(r"boss_image_[a-z_]+", code) else "boss_image_materialization_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
