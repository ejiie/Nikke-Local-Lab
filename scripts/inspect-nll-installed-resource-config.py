"""Read startup configuration objects only; never export assets or run a client."""
import argparse
import json
import hashlib
import re
import sys
from collections import Counter
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--unitypy-root', required=True)
parser.add_argument('--follow-script-types', action='store_true',
                    help='Read MonoBehaviour headers to include unnamed startup settings; no writes.')
parser.add_argument('files', nargs='+')
args = parser.parse_args()
sys.path.insert(0, args.unitypy_root)
import UnityPy

pattern = re.compile(r'^(?:ContentVersion\d*|(?:Project)?Patch\w*|RawPatcher|ChunkPatcher|'
                     r'Resource(?:Config|Manager|Version|Settings)\w*|Addressable\w*|AppInfo\w*|'
                     r'\w*(?:StartupConfig|ResourceConfig|VersionConfig))$', re.I)
version = re.compile(r'^[0-9]{2,4}\.[0-9]+(?:\.[0-9]+|\.b[0-9]+)$')
observations = []
for path in args.files:
    if Path(path).stat().st_size > 64 * 1024 * 1024:
        raise ValueError('startup_asset_size_limit')
# Loading the explicitly listed files together resolves script references without
# requiring names on their MonoBehaviour instances. No typetree injection occurs.
combined = UnityPy.load(*args.files) if args.follow_script_types else None
for path in args.files:
    source = Path(path)
    if source.stat().st_size > 64 * 1024 * 1024:
        raise ValueError('startup_asset_size_limit')
    env = combined or UnityPy.load(str(source))
    matches = []
    script_names = set()
    kinds = Counter()
    headers = Counter()
    for obj in env.objects:
        if combined is not None and Path(obj.assets_file.name).name.lower() != source.name.lower():
            continue
        kinds[obj.type.name] += 1
        if obj.type.name not in ('MonoBehaviour', 'MonoScript', 'TextAsset'):
            continue
        try:
            name = obj.peek_name() or ''
            script_name = ''
            if args.follow_script_types and obj.type.name == 'MonoBehaviour':
                try:
                    head = obj.parse_monobehaviour_head()
                    script = head.m_Script.deref_parse_as_object()
                    # A build may rename the managed class but preserve the
                    # MonoScript asset name. Inspect both, never equate them.
                    script_names_for_instance = [getattr(script, 'm_Name', ''), script.m_ClassName]
                    script_name = next((value for value in script_names_for_instance
                                        if isinstance(value, str) and pattern.search(value)), '')
                    headers['resolved'] += 1
                    if not name:
                        headers['unnamed'] += 1
                    if pattern.search(script_name):
                        name = script_name
                except Exception:
                    headers['unresolved'] += 1
            if not pattern.search(name):
                continue
            if obj.type.name == 'MonoScript':
                # Script type names are not instances or version configuration.
                script_names.add(name)
                continue
            raw_observation = None
            if args.follow_script_types and obj.type.name == 'MonoBehaviour':
                if obj.byte_size > 1024 * 1024:
                    raise ValueError('startup_object_size_limit')
                raw = obj.get_raw_data()
                literals = [match.group().decode('ascii') for match in
                            re.finditer(rb'[A-Za-z0-9:/_?.{}+\-]{4,512}', raw)]
                routes = [value for value in literals if any(token in value for token in
                          ('catalog.ndb', '/pck/', '.pak', 'latest-', '{Platform}'))]
                raw_observation = {
                    'byteLength': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                    'recognizedVersionLiterals': sorted({value for value in literals if version.fullmatch(value)}),
                    'routeLiteralCount': len(routes),
                    'routeLiteralDigests': [hashlib.sha256(value.encode('ascii')).hexdigest() for value in routes]
                }
            try:
                tree = obj.read_typetree()
            except Exception as exc:
                matches.append({'nameCode': name, 'type': obj.type.name,
                                'status': 'typetree_unavailable', 'exceptionType': type(exc).__name__,
                                'boundedRawObservation': raw_observation})
                continue
            # Only structural field names and recognized build-version scalars.
            fields = []
            versions = []
            def inspect(value, prefix='', depth=0):
                if depth > 6:
                    return
                if isinstance(value, dict):
                    for key, child in value.items():
                        if re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]{0,70}', key):
                            field = prefix + '.' + key if prefix else key
                            fields.append(field)
                            inspect(child, field, depth + 1)
                elif isinstance(value, list):
                    for child in value[:30]:
                        inspect(child, prefix + '[]', depth + 1)
                elif isinstance(value, str) and version.fullmatch(value):
                    versions.append({'field': prefix, 'version': value})
            inspect(tree)
            matches.append({'nameCode': name if re.fullmatch(r'[A-Za-z_0-9. ]{1,80}', name) else 'unresolved',
                            'type': obj.type.name, 'fields': fields[:160], 'versions': versions,
                            'boundedRawObservation': raw_observation})
        except Exception as exc:
            matches.append({'type': obj.type.name, 'status': 'typetree_unavailable', 'exceptionType': type(exc).__name__})
    observations.append({'fileRole': source.name, 'objectTypes': dict(kinds),
                         'scriptHeaderResolutionCounts': dict(headers),
                         'matchingScriptNames': sorted(script_names), 'matches': matches})
print(json.dumps({'observations': observations, 'sourceMutationPerformed': False, 'rawContentEmitted': False}, ensure_ascii=False))
