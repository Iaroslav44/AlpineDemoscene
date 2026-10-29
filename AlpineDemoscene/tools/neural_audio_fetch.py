"""Fetch the pinned official MIDI-DDSP checkpoint for reproducible export.

Developer-time utility only. The shipped EXE never fetches weights or audio.
"""
from pathlib import Path
import hashlib
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'build/neural_audio_source'
URL = 'https://raw.githubusercontent.com/magenta/midi-ddsp/models/midi_ddsp_model_weights_urmp_9_10.zip'
SHA = '46bae44c16c3399c24f8f0ba2557fc0432bc12aa23088606d465b22fec2cd05e'


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    path = DEST / 'weights.zip'
    if not path.exists():
        with urllib.request.urlopen(URL, timeout=60) as response:
            payload = response.read(60_000_001)
        if len(payload) > 60_000_000 or hashlib.sha256(payload).hexdigest() != SHA:
            raise ValueError('The official checkpoint does not match its pinned hash')
        path.write_bytes(payload)
    if hashlib.sha256(path.read_bytes()).hexdigest() != SHA:
        raise ValueError('Existing checkpoint archive hash mismatch')
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            target = (DEST / info.filename).resolve()
            if not target.is_relative_to(DEST.resolve()):
                raise ValueError('Archive path escapes destination')
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(info))
    print(f'Pinned official checkpoint verified: {path}')


if __name__ == '__main__': main()
