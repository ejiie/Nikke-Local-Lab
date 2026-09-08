"""Bounded static PE cross-reference locator; no live process access."""
import bisect
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

PATH = Path(r"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\GameAssembly.dll")


def main():
    data = PATH.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != "23b64ef22957356bfb3f02096a8fd59c5e2b6426bafb44520acd7fcd12a060ed":
        raise RuntimeError("static_callsite_source_pin_drift")
    u16 = lambda off: struct.unpack_from("<H", data, off)[0]
    u32 = lambda off: struct.unpack_from("<I", data, off)[0]
    pe = u32(0x3c)
    if data[pe:pe + 4] != b"PE\x00\x00" or u16(pe + 24) != 0x20b:
        raise RuntimeError("static_callsite_pe_shape_invalid")
    optional = pe + 24
    image_base = struct.unpack_from("<Q", data, optional + 24)[0]
    section_start = optional + u16(pe + 20)
    sections = []
    for index in range(u16(pe + 6)):
        offset = section_start + 40 * index
        sections.append((data[offset:offset + 8].rstrip(b"\0"), u32(offset + 12),
                         u32(offset + 20), u32(offset + 16), u32(offset + 36)))
    def rva_to_offset(rva):
        for _, va, raw, size, _ in sections:
            if va <= rva < va + size:
                return raw + rva - va
        raise RuntimeError("static_callsite_rva_unmapped")
    names = {}
    for section_name, va, raw, size, flags in sections:
        for match in re.finditer(rb"(?:crypto_[a-z0-9_]+|sodium_[a-z0-9_]+)\x00", data[raw:raw + size]):
            names[va + match.start()] = match.group()[:-1].decode("ascii")
    pdata_rva, pdata_size = struct.unpack_from("<II", data, optional + 112 + 3 * 8)
    pdata_offset = rva_to_offset(pdata_rva)
    ranges = [struct.unpack_from("<III", data, pdata_offset + off)[:2]
              for off in range(0, pdata_size, 12)]
    ranges.sort()
    starts = [a for a, _ in ranges]
    matches = []
    direct_targets = {int(v, 0) - image_base for v in sys.argv[1:]}
    direct_calls = []
    for section_name, va, raw, size, flags in sections:
        if not flags & 0x20000000:
            continue
        code = data[raw:raw + size]
        for match in re.finditer(rb"\xe8....", code, re.DOTALL):
            site = va + match.start()
            target = site + 5 + struct.unpack_from("<i", code, match.start() + 1)[0]
            if target not in direct_targets:
                continue
            index = bisect.bisect_right(starts, site) - 1
            interval = ranges[index] if index >= 0 and site < ranges[index][1] else None
            direct_calls.append({"targetVa": hex(image_base + target), "callsiteVa": hex(image_base + site),
                                 "functionRange": [hex(image_base + v) for v in interval] if interval else None})
        # RIP-relative LEA only; the output is a candidate xref, not decoded proof.
        for match in re.finditer(rb"[\x48\x4c]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]....", code, re.DOTALL):
            site = va + match.start()
            target = site + 7 + struct.unpack_from("<i", code, match.start() + 3)[0]
            if target not in names:
                continue
            index = bisect.bisect_right(starts, site) - 1
            interval = ranges[index] if index >= 0 and site < ranges[index][1] else None
            matches.append({"symbol": names[target], "callsiteVa": hex(image_base + site),
                            "functionRange": [hex(image_base + v) for v in interval] if interval else None})
    if hashlib.sha256(PATH.read_bytes()).hexdigest() != digest:
        raise RuntimeError("static_callsite_input_changed")
    print(json.dumps({"contractId": "nll/crypto-static-callsites/v1", "sourceSha256": digest,
                      "symbols": sorted(set(names.values())), "references": matches,
                      "directCallCandidates": direct_calls,
                      "executableSections": [n.decode("ascii", errors="replace") for n, _, _, _, f in sections if f & 0x20000000],
                      "clientStarted": False, "sourceChanged": False}))


if __name__ == "__main__":
    main()
