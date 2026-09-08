"""Read-only initialized-asset headers; never emits original object IDs or keys."""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(r"C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke_Data")
REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / ".tooling/unitypy"))
import UnityPy

pattern = re.compile(r"DownloadPatch|Integrity|Crypto|Sodium|GameInitialize|PublicKey", re.I)
paths = [ROOT / "globalgamemanagers.assets", ROOT / "resources.assets"]
env = UnityPy.load(*(str(p) for p in paths))
before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
scripts, heads, errors = [], [], 0
for obj in env.objects:
    try:
        if obj.type.name == "MonoScript":
            script = obj.read()
            name = script.m_Namespace + "." + script.m_ClassName
            if pattern.search(name):
                scripts.append(name)
        elif obj.type.name == "MonoBehaviour":
            head = obj.parse_monobehaviour_head()
            script = head.m_Script.deref_parse_as_object()
            name = script.m_Namespace + "." + script.m_ClassName
            if pattern.search(name):
                raw = obj.get_raw_data()
                # Only printable field-like tokens, not scalar/key/path content.
                tokens = sorted(set(x.decode("ascii") for x in re.findall(
                    rb"(?:[A-Za-z_][A-Za-z_]{4,80})", raw)
                    if re.search(rb"sodium|integrity|publickey|hash|check", x, re.I)))
                heads.append({"class": name, "serializedBytes": len(raw),
                              "embeddedFieldLikeTokens": tokens})
    except Exception:
        errors += 1
for path, digest in before.items():
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise RuntimeError("initialization_asset_changed")
print(json.dumps({"scripts": sorted(set(scripts)), "objects": heads,
                  "unreadableObjects": errors, "fieldValuesEmitted": False,
                  "sourceChanged": False, "clientStarted": False}))
