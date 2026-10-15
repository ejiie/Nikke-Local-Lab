"""Read-only diagnostic for catalog disagreements (CLIENT_UPDATE step 8).

bundles <glob> <catalog.db>...   which AssetBundleProvider bundles each NKDB Addressables catalog binds for a key glob
                                 (e.g. 'externalbehavior_assets_all_*.bundle'), same query as the catalog tool
chunks <catalog.ndb> <name>...   whether the chunk catalog carries a file entry for each bundle name
Catalogs are decoded in memory (AES-OFB per segment, IV = segment index and offset, then zlib) as EpinelPS
NkdbDecryptor does. Nothing is written.
"""
import sqlite3
import struct
import sys
import warnings
import zlib

with warnings.catch_warnings():
    warnings.simplefilter('ignore')
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

QUERY = """
SELECT DISTINCT i.internal_id,d.is_local FROM entries e
JOIN internal_ids i ON i.rowid=e.internal_id_rowid
JOIN provider_ids p ON p.rowid=e.provider_id_rowid
JOIN entry_data d ON d.rowid=e.data_rowid
WHERE p.provider_id='UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider'
  AND i.internal_id GLOB ?
"""


def decode(path):
    data = open(path, 'rb').read()
    if data[:8] != b'NKDB\x00\x00\x00\x01':
        raise SystemExit('not_nkdb')
    key = data[8:24]
    size, count = struct.unpack('>II', data[24:32])
    width = 5 if size * count > 0xFFFFFFFF else 4
    offsets = [int.from_bytes(data[32 + i * width:32 + (i + 1) * width], 'big') for i in range(count + 1)]
    out = bytearray()
    for index in range(count):
        start, end = offsets[index], offsets[index + 1]
        iv = struct.pack('<iI', index, start & 0xFFFFFFFF) + b'\x00' * 8
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            plain = Cipher(algorithms.AES(key), modes.OFB(iv)).decryptor().update(data[start:end])
        out += zlib.decompress(plain)
    db = sqlite3.connect(':memory:')
    db.deserialize(bytes(out))
    return db


def main():
    command = sys.argv[1]
    if command == 'bundles':
        for path in sys.argv[3:]:
            print(path, decode(path).execute(QUERY, (sys.argv[2],)).fetchall())
    elif command == 'chunks':
        db = decode(sys.argv[2])
        for name in sys.argv[3:]:
            print(name, db.execute('SELECT COUNT(*) FROM files_chunktype WHERE key LIKE ?', ('%' + name + '%',)).fetchone()[0])
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
