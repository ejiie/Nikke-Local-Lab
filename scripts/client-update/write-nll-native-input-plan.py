"""CLIENT_UPDATE step 8a: the nll/native-fx-export-plan/v1 input plan for a sealed clone.

outer = core catalog.ndb pair, inner = the core raw catalog.db pair the outer catalog references, embedded = the shipped
aa/catalog.db pair, indexSha256 = SHA-256 of core/chunk/store.cdb.idx. The catalog tool re-verifies every link. The
shipped and patched catalogs may differ (152.8.13); the exports then follow the patched catalog only when the shipped
choice cannot be supplied by the installed chunk catalog.
usage: write-nll-native-input-plan.py <clientRoot> <output plan path, must not exist>
"""
import hashlib
import json
import os
import sys


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def pin(path):
    return {'path': path, 'sha256': sha(path)}


def main():
    client, out = sys.argv[1].rstrip('\\'), sys.argv[2]
    core = client + r'\Unity\com_proximabeta_NIKKE\com.shiftup.patch\core'
    aa = client + r'\NIKKE\game\nikke_Data\StreamingAssets\aa'
    raw = os.path.join(core, 'raw')
    bodies = [n for n in os.listdir(raw) if n.endswith('.db')]
    signatures = [n for n in os.listdir(raw) if n.endswith('.nds')]
    if len(bodies) != 1 or len(signatures) != 1:
        raise SystemExit('core_raw_catalog_ambiguous')
    if os.path.exists(out):
        raise SystemExit('plan_exists')
    plan = {
        'chunkRoot': core,
        'contractId': 'nll/native-fx-export-plan/v1',
        'localBundleRoot': aa + r'\StandaloneWindows64',
        'outer': {'signature': pin(core + r'\catalog.ndb.nds'), 'body': pin(core + r'\catalog.ndb')},
        'embedded': {'signature': pin(aa + r'\catalog.db.nds'), 'body': pin(aa + r'\catalog.db')},
        'indexSha256': sha(core + r'\chunk\store.cdb.idx'),
        'inner': {'signature': pin(os.path.join(raw, signatures[0])), 'body': pin(os.path.join(raw, bodies[0]))},
    }
    os.makedirs(os.path.dirname(out), exist_ok=True)
    data = (json.dumps(plan, indent=2) + '\n').encode('utf-8')
    with open(out, 'xb') as f:
        f.write(data)
    print(json.dumps({'path': out, 'sha256': hashlib.sha256(data).hexdigest()}))


if __name__ == '__main__':
    main()
