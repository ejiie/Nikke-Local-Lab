"""List every path/sha256 pin in a boss-pipeline configuration and compare it with the live file.

Pins are objects with path+sha256 and sibling pairs <x>Path/<x>Sha256. Non-ok pins print as JSON lines
{"pointer", "path", "state"} (--all prints every pin); the last line is the summary with counts per state.
usage: check-nll-config-pins.py <configuration.json> [--all]
"""
import hashlib
import json
import os
import sys

_cache = {}


def sha256(path):
    if path in _cache:
        return _cache[path]
    if not os.path.isfile(path):
        _cache[path] = None
        return None
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    _cache[path] = h.hexdigest()
    return _cache[path]


def walk(node, pointer, out):
    if isinstance(node, dict):
        if isinstance(node.get('path'), str) and isinstance(node.get('sha256'), str):
            out.append((pointer, node['path'], node['sha256']))
        for key, value in node.items():
            if key.endswith('Path') and isinstance(value, str):
                pair = key[:-4] + 'Sha256'
                if isinstance(node.get(pair), str):
                    out.append((pointer + '/' + key, value, node[pair]))
            walk(value, pointer + '/' + key, out)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            walk(value, pointer + '/' + str(index), out)


def main():
    config = sys.argv[1]
    verbose = '--all' in sys.argv
    with open(config, encoding='utf-8-sig') as f:
        data = json.load(f)
    pins = []
    walk(data, '', pins)
    counts = {}
    for pointer, path, pinned in pins:
        live = sha256(path)
        state = 'missing' if live is None else ('ok' if live == pinned.lower() else 'drift')
        counts[state] = counts.get(state, 0) + 1
        if verbose or state != 'ok':
            print(json.dumps({'pointer': pointer, 'path': path, 'state': state}, ensure_ascii=False))
    print(json.dumps({'config': config, 'pins': len(pins), 'counts': counts}))


if __name__ == '__main__':
    main()
