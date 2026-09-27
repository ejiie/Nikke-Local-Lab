"""Asset helpers adapted from user-owned Nikke-Simul e9d7410; see README.md."""
import hashlib
import json
from pathlib import Path
import time
import urllib.request
import uuid
PNG = b'\x89PNG\r\n\x1a\n'
def digest(data): return hashlib.sha256(data).hexdigest()

def normal_resource_uri(logical):
    path = logical.lstrip('/')
    parts = path.split('/')
    primes = [224737,1000639,2654435761,2654435769,1000621,4294967291]
    if not 2 <= len(parts) <= len(primes)+1 or any(p in ('','..','.') for p in parts):
        raise ValueError('Invalid resource path')
    output = []
    for seed in primes[:len(parts)-1]:
        value = seed
        for ch in path:
            value = (value * 33 + ord(ch)) & 0xffffffff
            if value >= 0x80000000: value -= 0x100000000
        rem = value % seed
        output.append(f'{chr(97+(rem//26)%26)}{chr(97+rem%26)}-{rem%99:02}')
    output.append(hashlib.md5(path.encode()).hexdigest()+'.'+parts[-1].split('.',1)[1])
    return 'https://sg-tools-cdn.blablalink.com/'+'/'.join(output)

def download(url):
    from urllib.parse import urlsplit
    if urlsplit(url).scheme != 'https' or urlsplit(url).hostname not in ('www.blablalink.com','sg-tools-cdn.blablalink.com'):
        raise ValueError('Unexpected asset host')
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent':'Nikke-Simul-Assets/1.0'}),timeout=25) as response:
                data = response.read(16*1024*1024+1)
                if len(data)>16*1024*1024: raise ValueError('Asset too large')
                return data
        except Exception:
            if attempt == 2: raise
            time.sleep(attempt+1)

def atomic(path, data):
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary = path.with_name(path.name+'.tmp-'+uuid.uuid4().hex)
    temporary.write_bytes(data); temporary.replace(path)

def json_write(path, obj): atomic(path,json.dumps(obj,ensure_ascii=False,indent=2).encode())
