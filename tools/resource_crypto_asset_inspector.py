"""Read-only Unity configuration field-name scan; emits no field values or IDs."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


def inspect(client_root: Path, unitypy_root: Path) -> dict:
    expected = Path(r"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe")
    if client_root.resolve() != expected.resolve():
        raise ValueError("crypto_asset_client_boundary")
    sys.path.insert(0, str(unitypy_root.resolve()))
    import UnityPy

    needle = re.compile(r"public.?key|server.?key|encryption.?key|sodium|key.?exchange", re.I)
    files = []
    for filename in ("resources.assets", "globalgamemanagers.assets"):
        path = client_root / "NIKKE/game/nikke_Data" / filename
        digest_before = hashlib.sha256(path.read_bytes()).hexdigest()
        env = UnityPy.load(str(path))
        found, parsed, failed = [], 0, 0
        for obj in env.objects:
            if obj.type.name != "MonoBehaviour":
                continue
            try:
                tree = obj.read_typetree()
                parsed += 1
            except Exception:
                failed += 1
                continue
            fields = []

            def walk(value, prefix="", depth=0):
                if depth > 12:
                    return
                if isinstance(value, dict):
                    for key, child in value.items():
                        field = f"{prefix}.{key}" if prefix else str(key)
                        if needle.search(str(key)):
                            fields.append({"field": field, "type": type(child).__name__})
                        walk(child, field, depth + 1)
                elif isinstance(value, list):
                    # Only field names; don't expose array members or scalar values.
                    for child in value:
                        if isinstance(child, (dict, list)):
                            walk(child, prefix + "[]", depth + 1)

            walk(tree)
            if fields:
                script = tree.get("m_Script", {})
                class_name = "unresolved"
                if script.get("m_FileID") == 0:
                    target = obj.assets_file.objects.get(script.get("m_PathID"))
                    if target is not None and target.type.name == "MonoScript":
                        info = target.read_typetree()
                        class_name = info.get("m_Namespace", "") + "." + info.get("m_ClassName", "")
                found.append({"class": class_name, "fields": fields})
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest_before:
            raise ValueError("crypto_asset_input_changed")
        files.append({"file": filename, "sha256": digest_before,
                      "parsedBehaviours": parsed, "unreadableBehaviours": failed, "matches": found})
    return {"contractId": "nll/resource-crypto-asset-fields/v1", "files": files,
            "fieldValuesEmitted": False, "sourceChanged": False, "clientStarted": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-root", type=Path, required=True)
    parser.add_argument("--unitypy-root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(inspect(args.client_root, args.unitypy_root), ensure_ascii=True, indent=2))
