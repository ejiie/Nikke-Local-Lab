"""CLIENT_UPDATE step 2: the official StaticData.pack named by the pinned upstream game config.

fetch  -- one anonymous GET of exactly that URL (SECURITY_BOUNDARY "Micron 업데이트용 공개 정적 입력 수집"): no cookies,
          credentials, proxy, redirects, TLS override or retry; 64 MiB limit; kept only if it decodes and verifies.
decode -- offline decode of any pack with a game config: outer AES-CBC, RSA PKCS#1 SHA-256 signature, inner AES-CTR,
          ZIP CRC and required tables. The decoded SHA-256 is the materializer's RuntimeVersionBinding value.
Key constants are read from the EpinelPS source (Data/GameData.cs); nothing secret is stored here.
"""
import argparse
import base64
import hashlib
import io
import json
import re
import ssl
import sys
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.asymmetric import padding as rsa_padding
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

LIMIT = 64 * 1024 * 1024
REQUIRED = ('CharacterTable.mpk', 'SoloRaidManagerTable.mpk', 'MonsterTable.mpk')


def need(value, code):
    if not value:
        raise ValueError(code)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def constant(source, name):
    match = re.search(name + r'\s*=\s*\[([^\]]+)\]', source)
    need(match is not None, 'reference_constant_missing')
    return bytes(int(v, 16) for v in re.findall(r'0x([0-9a-fA-F]{2})', match[1]))


def decode(body, config, reference):
    need(0 < len(body) <= LIMIT and len(body) % 16 == 0, 'pack_size_invalid')
    source = Path(reference).read_text(encoding='utf-8-sig')
    shared = constant(source, 'PresharedValue')

    def key(name):
        return hashlib.pbkdf2_hmac('sha256', shared, base64.b64decode(config['StaticDataMpk'][name], validate=True), 10000, 32)

    k = key('Salt2')
    plain = Cipher(algorithms.AES(k[:16]), modes.CBC(k[16:])).decryptor()
    unpad = padding.PKCS7(128).unpadder()
    try:
        outer = unpad.update(plain.update(body) + plain.finalize()) + unpad.finalize()
    except ValueError:
        raise ValueError('outer_cbc_padding_invalid') from None
    with zipfile.ZipFile(io.BytesIO(outer)) as archive:
        need(set(archive.namelist()) == {'data', 'sign'}, 'outer_members_invalid')
        data, sign = archive.read('data'), archive.read('sign')
    public = rsa.RSAPublicNumbers(int.from_bytes(constant(source, 'Exponent'), 'big'),
                                  int.from_bytes(constant(source, 'Modulus'), 'big')).public_key()
    try:
        public.verify(sign, data, rsa_padding.PKCS1v15(), hashes.SHA256())
    except Exception:
        raise ValueError('data_signature_invalid') from None
    k = key('Salt1')
    inner = Cipher(algorithms.AES(k[:16]), modes.CTR(k[16:])).decryptor().update(data)
    with zipfile.ZipFile(io.BytesIO(inner)) as archive:
        need(archive.testzip() is None, 'inner_crc_invalid')
        names = archive.namelist()
        need(len(set(names)) == len(names) and all(n in names for n in REQUIRED), 'required_table_missing')
    return {'packSha256': sha256(body), 'packBytes': len(body), 'decodedSha256': sha256(inner),
            'decodedBytes': len(inner), 'tableCount': len(names)}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('redirect_forbidden')


def fetch(plan_path):
    plan = json.loads(Path(plan_path).read_text(encoding='utf-8-sig'))
    config_path, out = Path(plan['gameConfigPath']), Path(plan['staticDataPackPath'])
    receipt_path = Path(plan['stagingRoot']) / 'staticdata.receipt.json'
    need(sha256(config_path.read_bytes()) == plan['gameConfigSha256'], 'config_drifted')
    need(not out.exists() and not receipt_path.exists(), 'already_fetched')
    config = json.loads(config_path.read_text(encoding='utf-8-sig'))
    url = config['StaticDataMpk']['Url']
    parts = urllib.parse.urlsplit(url)
    need(parts.scheme == 'https' and parts.hostname == 'cloud.nikke-kr.com' and not parts.username and not parts.password
         and not parts.query and not parts.fragment and parts.path.endswith('/StaticData.pack')
         and config['StaticDataMpk']['Version'].split('/')[-1] in parts.path, 'url_invalid')
    (receipt_path.parent / 'staticdata.started.json').write_text(json.dumps({'url': url, 'attempt': 1}), encoding='utf-8')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                         urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    status = None
    try:
        with opener.open(urllib.request.Request(url, headers={'User-Agent': 'NLL-StaticData-ReadOnly'}), timeout=60) as response:
            status = response.status
            need(status == 200, 'http_status_invalid')
            body = response.read(LIMIT + 1)
        result = decode(body, config, Path(plan['serverSourceRoot']) / 'EpinelPS' / 'Data' / 'GameData.cs')
        out.write_bytes(body)
        receipt = {'status': 'fetched_signature_and_crc_verified', 'version': config['StaticDataMpk']['Version'],
                   'configSha256': plan['gameConfigSha256'], 'upstreamCommit': plan['upstreamCommit'], 'httpStatus': status,
                   **result, 'requests': 1, 'cookiesOrCredentialsSent': False, 'redirectsFollowed': False, 'clientStarted': False}
    except Exception as error:
        receipt = {'status': 'failed', 'code': str(error) if re.fullmatch(r'[a-z_]+', str(error)) else type(error).__name__,
                   'httpStatus': getattr(error, 'code', status), 'requests': 1, 'retried': False}
    receipt_path.write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    print(json.dumps(receipt))
    return 0 if receipt['status'] != 'failed' else 1


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('fetch').add_argument('--plan', required=True)
    d = commands.add_parser('decode')
    for name in ('--pack', '--config', '--reference'):
        d.add_argument(name, required=True)
    args = parser.parse_args()
    if args.command == 'fetch':
        return fetch(args.plan)
    body = Path(args.pack).read_bytes()
    print(json.dumps({'status': 'decoded_signature_and_crc_verified',
                      **decode(body, json.loads(Path(args.config).read_text(encoding='utf-8-sig')), args.reference)}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except ValueError as error:
        print(json.dumps({'status': 'failed', 'code': str(error)}))
        sys.exit(1)
