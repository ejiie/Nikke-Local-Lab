"""Offline stock/rebuild characterization. Synthetic bytes only, no game hooks."""
import ctypes as c
import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PATHS = {
    "stock": (Path(r"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll"),
              "11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f"),
    "baseline": (REPO / "artifacts/resource-probe-151/native-key-compat-v1/baseline/sodium.dll",
                 "e42dd6eda126ce4fe5e65254d9dd77b2ec86545513ec4c5db0fd7c4cd754b8ba"),
}
P, U64, SIZE, INT = c.c_void_p, c.c_ulonglong, c.c_size_t, c.c_int


def call(lib, name, types, *args, result=INT):
    fn = getattr(lib, name)
    fn.argtypes, fn.restype = types, result
    return fn(*args)


def sample(length, salt=0):
    return bytes((i * 29 + salt) % 256 for i in range(length))


def aligned_buffer(size):
    owner = c.create_string_buffer(size + 63)
    return owner, c.c_void_p((c.addressof(owner) + 63) & ~63)


def characterize(path, initialize=True):
    lib = c.CDLL(str(path))
    if initialize and call(lib, "sodium_init", []) < 0:
        raise RuntimeError("primitive_init_failed")
    results = {}
    seed, key = sample(32, 3), sample(32, 7)
    pk, sk = c.create_string_buffer(32), c.create_string_buffer(64)
    if call(lib, "crypto_sign_seed_keypair", [P, P, P], pk, sk, seed) != 0:
        raise RuntimeError("synthetic_sign_keypair_failed")
    results["sign_public_key"] = pk.raw
    # Characterize verification edge cases; never alter either implementation.
    edge_message = b"NLL synthetic canonical-signature control"
    edge_sig, edge_len = c.create_string_buffer(64), U64()
    call(lib, "crypto_sign_detached", [P, P, P, U64, P],
         edge_sig, c.byref(edge_len), edge_message, len(edge_message), sk)
    order = 2**252 + 27742317777372353535851937790883648493
    scalar = int.from_bytes(edge_sig.raw[32:], "little")
    edge_vectors = {"valid": (edge_sig.raw, pk.raw)}
    for multiple in (1, 2, 7):
        altered = edge_sig.raw[:32] + (scalar + multiple * order).to_bytes(32, "little")
        edge_vectors[f"noncanonical_s_plus_{multiple}l"] = (altered, pk.raw)
    for label, point in (("zero", bytes(32)), ("identity", b"\x01" + bytes(31)),
                         ("noncanonical_identity", (2**255 - 18).to_bytes(32, "little"))):
        edge_vectors[f"public_key_{label}"] = (edge_sig.raw, point)
        edge_vectors[f"r_{label}"] = (point + edge_sig.raw[32:], pk.raw)
        edge_vectors[f"degenerate_{label}"] = (point + bytes(32), point)
    for label, (signature_bytes, public_bytes) in edge_vectors.items():
        results[f"signature_edge/{label}"] = call(
            lib, "crypto_sign_verify_detached", [P, P, U64, P],
            signature_bytes, edge_message, len(edge_message), public_bytes)
    for length in (0, 1, 15, 16, 31, 32, 63, 64, 65, 127, 128, 129, 255, 256, 1024, 4096):
        message = sample(length, 11)
        for name, size in (("crypto_hash_sha256", 32), ("crypto_hash_sha512", 64)):
            out = c.create_string_buffer(size)
            status = call(lib, name, [P, P, U64], out, message, length)
            results[f"{name}/{length}"] = (status, out.raw)
            state_size = call(lib, name + "_statebytes", [], result=SIZE)
            owner, state = aligned_buffer(state_size)
            init = call(lib, name + "_init", [P], state)
            updates = []
            for offset in range(0, max(length, 1), 17):
                chunk = message[offset:offset + 17]
                updates.append(call(lib, name + "_update", [P, P, U64], state, chunk, len(chunk)))
            incremental = c.create_string_buffer(size)
            final = call(lib, name + "_final", [P, P], state, incremental)
            if incremental.raw != out.raw or init != 0 or final != 0 or any(updates):
                raise RuntimeError("incremental_sha_contract_failed")
            results[f"{name}_incremental/{length}"] = (init, final, incremental.raw)
        for size in (16, 32, 64):
            out = c.create_string_buffer(size)
            status = call(lib, "crypto_generichash", [P, SIZE, P, U64, P, SIZE],
                          out, size, message, length, key, len(key))
            results[f"generichash/{length}/{size}"] = (status, out.raw)
            for keyed in (False, True):
                state_size = call(lib, "crypto_generichash_blake2b_statebytes", [], result=SIZE)
                owner, state = aligned_buffer(state_size)
                hash_key = key if keyed else None
                init = call(lib, "crypto_generichash_blake2b_init", [P, P, SIZE, SIZE],
                            state, hash_key, len(key) if keyed else 0, size)
                updates = []
                for offset in range(0, max(length, 1), 17):
                    chunk = message[offset:offset + 17]
                    updates.append(call(lib, "crypto_generichash_blake2b_update", [P, P, U64],
                                        state, chunk, len(chunk)))
                incremental = c.create_string_buffer(size)
                final = call(lib, "crypto_generichash_blake2b_final", [P, P, SIZE], state, incremental, size)
                if keyed and incremental.raw != out.raw:
                    raise RuntimeError("incremental_blake_contract_failed")
                if init != 0 or final != 0 or any(updates):
                    raise RuntimeError("incremental_blake_status_failed")
                results[f"blake2b_incremental/{length}/{size}/{keyed}"] = (init, final, incremental.raw)
        signature, siglen = c.create_string_buffer(64), U64()
        status = call(lib, "crypto_sign_detached", [P, P, P, U64, P],
                      signature, c.byref(siglen), message, length, sk)
        valid = call(lib, "crypto_sign_verify_detached", [P, P, U64, P], signature, message, length, pk)
        wrong = bytearray(signature.raw)
        wrong[0] ^= 1
        invalid = call(lib, "crypto_sign_verify_detached", [P, P, U64, P], bytes(wrong), message, length, pk)
        results[f"sign/{length}"] = (status, siglen.value, signature.raw, valid, invalid)
        if (status, siglen.value, valid, invalid) != (0, 64, 0, -1):
            raise RuntimeError("synthetic_signature_contract_failed")
        for name, nonce_size in (("crypto_stream_xchacha20_xor", 24), ("crypto_stream_chacha20_ietf_xor", 12),
                                  ("crypto_stream_xsalsa20_xor", 24)):
            out = c.create_string_buffer(length)
            status = call(lib, name, [P, P, U64, P, P], out, message, length, sample(nonce_size, 13), key)
            results[f"{name}/{length}"] = (status, out.raw)
        out, plain = c.create_string_buffer(length + 16), c.create_string_buffer(length)
        nonce = sample(24, 17)
        status = call(lib, "crypto_secretbox_easy", [P, P, U64, P, P], out, message, length, nonce, key)
        opened = call(lib, "crypto_secretbox_open_easy", [P, P, U64, P, P], plain, out, length + 16, nonce, key)
        results[f"secretbox/{length}"] = (status, out.raw, opened, plain.raw)
        if (status, opened, plain.raw) != (0, 0, message):
            raise RuntimeError("synthetic_secretbox_contract_failed")
    for subkey_id in (0, 1, 255, 2**32 + 1):
        out = c.create_string_buffer(32)
        status = call(lib, "crypto_kdf_derive_from_key", [P, SIZE, U64, P, P], out, 32, subkey_id, b"NLLTEST1", key)
        results[f"kdf/{subkey_id}"] = (status, out.raw)
    out = c.create_string_buffer(256)
    call(lib, "randombytes_buf_deterministic", [P, SIZE, P], out, 256, seed, result=None)
    results["deterministic_random"] = out.raw
    return results


def main():
    for path, digest in PATHS.values():
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("primitive_library_pin_drift")
    initialize = "--without-explicit-init" not in sys.argv[1:]
    observations = {role: characterize(path, initialize) for role, (path, _) in PATHS.items()}
    different = [case for case in observations["stock"] if observations["stock"][case] != observations["baseline"][case]]
    for path, digest in PATHS.values():
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("primitive_library_changed")
    print(json.dumps({"contractId": "nll/resource-crypto-primitives-comparison/v1",
                      "cases": len(observations["stock"]), "differences": different,
                      "explicitSodiumInit": initialize,
                      "syntheticInputsOnly": True, "nativeWireCompatibilityVerified": False,
                      "clientStarted": False, "sourceChanged": False}))


if __name__ == "__main__":
    main()
