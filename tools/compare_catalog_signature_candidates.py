"""Read-only candidate characterization, not a claim about the .nds format.

Only counts/status comparisons are emitted. Resource bytes/keys/names stay in
memory; neither the game process nor official service is contacted.
"""
import ctypes as c
import hashlib
import json
from pathlib import Path

from compare_resource_crypto_primitives import PATHS, call, P, U64

ROOT = Path(r"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\Unity\com_proximabeta_NIKKE\com.shiftup.patch")


def main():
    libraries = {}
    for role, (path, expected) in PATHS.items():
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("catalog_comparison_library_pin_drift")
        libraries[role] = c.CDLL(str(path))
        if call(libraries[role], "sodium_init", []) < 0:
            raise RuntimeError("catalog_comparison_init_failed")
    counts = {"signatureFiles": 0, "candidatePairs": 0, "verificationCases": 0,
              "validCandidateInterpretations": 0, "digestSegmentMatches": 0,
              "differentResults": 0, "unpaired": 0}
    for sigpath in sorted(ROOT.rglob("*.nds")):
        blob = sigpath.read_bytes()
        if len(blob) != 96:
            raise RuntimeError("catalog_signature_shape_unexpected")
        counts["signatureFiles"] += 1
        pairs = [sigpath.with_suffix(ext) for ext in ("", ".ndb", ".db", ".cat")
                 if sigpath.with_suffix(ext).is_file()]
        if not pairs:
            counts["unpaired"] += 1
        for bodypath in pairs:
            if bodypath.stat().st_size > 64 * 1024 * 1024:
                raise RuntimeError("catalog_candidate_size_exceeded")
            body = bodypath.read_bytes()
            counts["candidatePairs"] += 1
            digest = hashlib.sha256(body).digest()
            counts["digestSegmentMatches"] += int(digest == blob[:32] or digest == blob[64:])
            # These are explicitly unconfirmed layouts, not format decoding.
            for signature, key in ((blob[32:], blob[:32]), (blob[:64], blob[64:])):
                for message in (body, digest, hashlib.sha512(body).digest()):
                    statuses = [call(lib, "crypto_sign_verify_detached", [P, P, U64, P],
                                     signature, message, len(message), key)
                                for lib in libraries.values()]
                    counts["verificationCases"] += 1
                    counts["differentResults"] += int(statuses[0] != statuses[1])
                    counts["validCandidateInterpretations"] += int(0 in statuses)
            if hashlib.sha256(bodypath.read_bytes()).digest() != digest:
                raise RuntimeError("catalog_body_changed_during_read")
        if sigpath.read_bytes() != blob:
            raise RuntimeError("catalog_signature_changed_during_read")
    for path, expected in PATHS.values():
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError("catalog_comparison_library_changed")
    print(json.dumps({"contractId": "nll/catalog-signature-candidates/v1", **counts,
                      "formatConfirmed": False, "clientStarted": False,
                      "sourceChanged": False, "nativeCompatibilityVerified": False}))


if __name__ == "__main__":
    main()
