"""Fetch only the two official PhotoMat 256px checkpoints by ZIP ranges.

The 1.28 GB release also includes unrelated resolutions; they are never fetched.
This is an offline developer operation, never part of the executable runtime.
"""
from pathlib import Path
import hashlib
import json
import struct
import urllib.request
import zlib

ROOT = Path(__file__).resolve().parents[1]
URL = 'https://drive.usercontent.google.com/download?id=1ji3y5GJEQpJLAJbxPdyJpSMPD4M2yhny&export=download&confirm=t'
ARCHIVE_BYTES = 1282866064
MEMBERS = [
    ('G_256.pkl', 343797060, 263755365, 286321144, 4031753162),
    ('MatUnet_256.pt', 1219665083, 21064913, 22713221, 3387761413),
]
CHECKPOINT_SHA256 = {
    'G_256.pkl': '4648af64714a59d3c6a40eef176935c6b8374d348fa10a40f40b6791a21b55ba',
    'MatUnet_256.pt': '8e08510fdd91ce5004a2cd63fdbd37b7e1292c724474e24861760218a8e5fd1e',
}
REPOSITORY_REVISION = '035067e96c6fa7ed3c3c5412285fef5c6152316f'
SOURCE_FILES = {
    'LICENSE.txt': '877d9dcaeaea87c5bd61f19fc547923431b6ccf2a750c0fe09b10ebd331484e1',
    'LICENSE-stylegan.txt': '8f5e467a7bffe111d57b51e940d56b0d5e342835489118b7efd1127680c99839',
    'training/networks.py': 'a4e53b902059f2cb974465e9b60b9cbe0a7d08da97d661f825402f9237b5723e',
    'torch_utils/ops/conv2d_resample.py': 'f7a68220f8d03a042b3d44bea460accea28af54b04857890a6906a0074f23534',
    'torch_utils/ops/upfirdn2d.py': '38865dbf89604a5e6bd6c0ec167143d01392fb1ffaca13649143d08689c089d7',
    'torch_utils/render.py': 'de5e08941804a1996bceb8047717ef72dd58ed45c978ac3416a89bd50ac392d4',
}

def request(start, count):
    response = urllib.request.urlopen(urllib.request.Request(URL, headers={
        'Range': f'bytes={start}-{start + count - 1}'}), timeout=60)
    expected = f'bytes {start}-{start + count - 1}/{ARCHIVE_BYTES}'
    if response.status != 206 or response.headers.get('Content-Range') != expected:
        response.close()
        raise RuntimeError('Source did not honor the exact checked byte range')
    return response

def main():
    folder = ROOT / 'build/neural_material_source'
    folder.mkdir(parents=True, exist_ok=True)
    source_folder = ROOT / 'build/neural_material_research'
    source_folder.mkdir(parents=True, exist_ok=True)
    for name, sha in SOURCE_FILES.items():
        path = source_folder / name.replace('/', '_')
        if not path.exists():
            url = f'https://raw.githubusercontent.com/xilongzhou/PhotoMat/{REPOSITORY_REVISION}/{name}'
            with urllib.request.urlopen(url, timeout=30) as stream:
                raw = stream.read(256 * 1024)
            if hashlib.sha256(raw).hexdigest() != sha:
                raise RuntimeError('Pinned official source changed')
            path.write_bytes(raw)
        if hashlib.sha256(path.read_bytes()).hexdigest() != sha:
            raise RuntimeError(f'Pinned source integrity mismatch: {name}')
    records = []
    for name, offset, packed, size, crc in MEMBERS:
        target = folder / name
        if not target.exists():
            with request(offset, 64) as stream:
                head = stream.read()
            h = struct.unpack_from('<4s5H3I2H', head)
            if h[0] != b'PK\x03\x04' or h[3] != 8 or head[30:30+h[9]].decode() != name:
                raise RuntimeError('Official ZIP member header changed')
            start = offset + 30 + h[9] + h[10]
            temp = target.with_suffix(target.suffix + '.partial')
            inflater = zlib.decompressobj(-15)
            with request(start, packed) as stream, temp.open('wb') as out:
                received = 0
                while block := stream.read(1024 * 1024):
                    received += len(block)
                    out.write(inflater.decompress(block))
                    if received % (32 * 1024 * 1024) == 0:
                        print(f'{name}: {received}/{packed} compressed bytes', flush=True)
                out.write(inflater.flush())
            if received != packed or not inflater.eof or temp.stat().st_size != size:
                raise RuntimeError('Incomplete checkpoint')
            temp.replace(target)
        sha = hashlib.sha256()
        actual_crc = 0
        with target.open('rb') as stream:
            while block := stream.read(1024 * 1024):
                sha.update(block)
                actual_crc = zlib.crc32(block, actual_crc)
        if target.stat().st_size != size or actual_crc != crc or sha.hexdigest() != CHECKPOINT_SHA256[name]:
            raise RuntimeError(f'Checkpoint integrity mismatch: {name}')
        records.append(dict(name=name, bytes=size, sha256=sha.hexdigest(), zip_crc32=f'{crc:08x}'))
        print(records[-1], flush=True)
    (folder / 'download.json').write_text(json.dumps(dict(source=URL, archive_bytes=ARCHIVE_BYTES, members=records), indent=2))

if __name__ == '__main__':
    main()
