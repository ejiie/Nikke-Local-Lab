"""Static, read-only byte-reference evidence; does not execute client code."""
import hashlib
import json
from pathlib import Path

from compare_resource_crypto_primitives import PATHS

GAME = Path(r"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game")
PATCH = Path(r"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\Unity\com_proximabeta_NIKKE\com.shiftup.patch")


def main():
    stock = PATHS["stock"][0].read_bytes()
    if hashlib.sha256(stock).hexdigest() != PATHS["stock"][1]:
        raise RuntimeError("integrity_reference_stock_pin_drift")
    patterns = {}
    for algorithm in ("sha256", "sha512", "sha1", "md5", "blake2b", "blake2s"):
        digest = hashlib.new(algorithm, stock).digest()
        patterns[algorithm + "/binary"] = digest
        patterns[algorithm + "/hex"] = digest.hex().encode()
        patterns[algorithm + "/hex_upper"] = digest.hex().upper().encode()
        patterns[algorithm + "/utf16_hex"] = digest.hex().encode("utf-16-le")
    signatures = [p.read_bytes() for p in PATCH.rglob("*.nds")]
    if any(len(s) != 96 for s in signatures):
        raise RuntimeError("integrity_reference_signature_shape_drift")
    prefixes = sorted({s[:32] for s in signatures})
    suffixes = sorted({s[64:] for s in signatures})
    results = []
    files = {
        "game_assembly": GAME / "GameAssembly.dll",
        "native_base": GAME / "nikkeBase.dll",
        "stock_crypto": PATHS["stock"][0],
        "global_settings": GAME / "nikke_Data/globalgamemanagers",
        "global_assets": GAME / "nikke_Data/globalgamemanagers.assets",
        "resources": GAME / "nikke_Data/resources.assets",
    }
    for role, path in files.items():
        data = path.read_bytes()
        pin = hashlib.sha256(data).digest()
        results.append({"role": role, "stockFingerprintReferences": [k for k, v in patterns.items() if v in data],
                        "signaturePrefixReferences": sum(v in data for v in prefixes),
                        "signatureSuffixReferences": sum(v in data for v in suffixes)})
        if hashlib.sha256(path.read_bytes()).digest() != pin:
            raise RuntimeError("integrity_reference_input_changed")
    print(json.dumps({"contractId": "nll/resource-integrity-static-references/v1",
                      "signatureCount": len(signatures), "uniquePrefixCount": len(prefixes),
                      "uniqueSuffixCount": len(suffixes), "observations": results,
                      "absenceProvesNoIntegrityCheck": False,
                      "clientStarted": False, "sourceChanged": False}))


if __name__ == "__main__":
    main()
