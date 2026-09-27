"""Cache Blablalink square face artwork under local character UUIDs.

Uses only public character presentation metadata; no account/session data.
Leaves unresolved/ambiguous mappings explicit and never replaces body artwork.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import struct
import unicodedata
import uuid

from presentation_assets import PNG, atomic, digest, download, json_write, normal_resource_uri


def normalized(value):
    return ''.join(c for c in unicodedata.normalize('NFKC', value).upper()
                   if not c.isspace() and not unicodedata.category(c).startswith('P'))


def prepare(presentation_path, output):
    presentation = json.loads(Path(presentation_path).read_text(encoding='utf-8-sig'))
    if presentation.get('contractId') != 'nll/control-center-presentation/v1':
        raise ValueError('Invalid presentation catalog')
    output = Path(output)
    index_path = output / 'catalog.private.json'
    raw = index_path.read_bytes() if index_path.exists() else download(normal_resource_uri('character/ko/nikke_list_v2.json'))
    rows = json.loads(raw)
    atomic(index_path, raw)
    weapons = dict(assault_rifle='AR', machine_gun='MG', rocket_launcher='RL',
                   shotgun='SG', sniper_rifle='SR', submachine_gun='SMG')

    def fetch(character):
        uid = str(uuid.UUID(character['characterUid']))
        matches = [row for row in rows if normalized(row.get('name_localkey', {}).get('name', '')) == normalized(character['displayName'])]
        if len(matches) > 1:
            matches = [row for row in matches
                       if str(row.get('original_rare', '')).lower() == character['rarityCode'].lower()
                       and str(row.get('class', '')).lower() == character['combatClassCode'].lower()
                       and str(row.get('corporation', '')).lower() == character['manufacturerCode'].lower()
                       and row.get('shot_id', {}).get('element', {}).get('weapon_type', '').upper() == weapons.get(character['weaponCode'])]
        if len(matches) != 1:
            return dict(characterUid=uid, status='mapping_unresolved')
        resource = str(matches[0]['resource_id']).zfill(3)
        if not re.fullmatch(r'[0-9]+', resource):
            return dict(characterUid=uid, status='mapping_invalid')
        target = output / 'character-faces' / (uid + '.png')
        try:
            data = target.read_bytes() if target.exists() else download(normal_resource_uri(f'character/si/si_c{resource}_00_s.png'))
            if len(data) < 24 or not data.startswith(PNG):
                raise ValueError('Invalid PNG')
            width, height = struct.unpack('>II', data[16:24])
            if width != height or not 64 <= width <= 2048:
                raise ValueError('Invalid square portrait')
            atomic(target, data)
            return dict(characterUid=uid, status='ready', width=width, height=height, sha256=digest(data))
        except Exception:
            return dict(characterUid=uid, status='image_unavailable')

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(fetch, presentation['characters']))
    receipt = dict(contractId='nll/raid-square-portraits/v1', source='blablalink_public_si',
                   catalogSha256=digest(raw), members=results)
    json_write(output / 'receipt.json', receipt)
    print(json.dumps(dict(ready=sum(r['status'] == 'ready' for r in results), total=len(results))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('presentation')
    parser.add_argument('output')
    args = parser.parse_args()
    prepare(args.presentation, args.output)
