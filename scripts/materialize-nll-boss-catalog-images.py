"""Cache operator-approved enikk.app boss presentation PNGs; never game resources.

Exact MonsterImage names from a sealed season snapshot select the public images.
There are no credentials, official endpoints, redirects, live-client requests,
runtime installation, guessed same-boss mappings or native admission claims.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import urllib.error
import urllib.request
import zlib

LIMIT = 20 * 1024 * 1024


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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def fetch(name):
    require(re.fullmatch(r"full_[A-Za-z0-9_]{1,128}", name), "name_invalid")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    request = urllib.request.Request("https://enikk.app/bosses/" + name + ".png",
                                     headers={"User-Agent": "NLL-Boss-Presentation/1.0", "Accept": "image/png"})
    try:
        with opener.open(request, timeout=30) as response:
            require(response.status == 200, "http_failed")
            length = response.headers.get("Content-Length")
            require(length is None or (length.isdecimal() and int(length) <= LIMIT), "response_too_large")
            data = response.read(LIMIT + 1)
            png(data)
            return data
    except urllib.error.HTTPError as error:
        raise ValueError("boss_image_not_found" if error.code == 404 else "boss_image_http_failed") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ValueError("boss_image_transport_failed") from None


def materialize(catalog_path, catalog_pin, hints_path, hints_pin, output, download=fetch):
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
    resolved, failures, payloads, observations = {}, {}, {}, []
    for name in sorted(set(names.values())):
        try:
            data = download(name)
            png(data)
            pin = digest(data)
            if pin not in payloads:
                new_file(image_root / (pin + ".png"), data)
                payloads[pin] = len(data)
            resolved[name] = pin
        except ValueError as error:
            require(re.fullmatch(r"boss_image_[a-z_]+", str(error)), "download_failed")
            failures[name] = str(error)
    result = copy.deepcopy(catalog)
    for row in result["seasons"]:
        season = row["seasonNumber"]
        name = names.get(season)
        pin = resolved.get(name)
        if pin:
            row.update(imageStatusCode="resolved", imageSha256=pin)
        observations.append({"seasonNumber": season, "statusCode": "resolved" if pin else "unresolved",
                             "failureCode": failures.get(name) if name else "boss_image_reference_unresolved"})
    read(catalog_path, catalog_pin)
    read(hints_path, hints_pin)
    for pin, length in payloads.items():
        data = (image_root / (pin + ".png")).read_bytes()
        require(len(data) == length and digest(data) == pin, "output_drifted")
    raw = encode(result)
    new_file(output / "catalog.json", raw)
    # Private provenance only; no original key or remote URL in the public view.
    new_file(output / "bindings.private.json", encode({"contractId": "nll/private-boss-presentation-bindings/v1",
             "hintsSha256": hints_pin, "providerCode": "enikk_app", "bindings": [
                 {"seasonNumber": season, "imageName": name, "imageSha256": resolved.get(name)} for season, name in names.items()]}))
    receipt = {"contractId": "nll/boss-catalog-images/v1", "sourceCatalogSha256": catalog_pin,
               "sourceHintsSha256": hints_pin, "catalogSha256": digest(raw), "providerCode": "enikk_app",
               "resolvedSeasonCount": sum(row["statusCode"] == "resolved" for row in observations),
               "requestedObjectCount": len(set(names.values())), "uniqueImageCount": len(payloads),
               "images": observations, "officialServiceRequested": False, "nativeClientExecuted": False,
               "sourceModified": False, "runtimeAdmissionStatusCode": "not_assessed"}
    new_file(output / "receipt.json", encode(receipt))
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("catalog", "catalog-sha256", "hints", "hints-sha256", "output-root"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        output = plain(args.output_root)
        artifacts = plain(Path(__file__).parent.parent / "artifacts")
        require(artifacts in output.parents, "output_scope_invalid")
        receipt = materialize(args.catalog, args.catalog_sha256, args.hints, args.hints_sha256, output)
        print(json.dumps({key: value for key, value in receipt.items() if key != "images"}))
        return 0
    except Exception as error:
        code = str(error)
        print(code if re.fullmatch(r"boss_image_[a-z_]+", code) else "boss_image_materialization_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
