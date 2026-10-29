"""Export the real URMP-trained MIDI-DDSP timbre decoder for the native demo.

The pitch/expression controls are authored by the score. This export deliberately
does not claim to run the separate learned autoregressive pitch controller.
"""
from pathlib import Path
import hashlib
import json
import struct
import argparse
import numpy as np
from neural_audio_checkpoint import tensors

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'build/neural_audio_source'
SUFFIX = '/.ATTRIBUTES/VARIABLE_VALUE'
PINNED_ARCHIVE_SHA256 = '46bae44c16c3399c24f8f0ba2557fc0432bc12aa23088606d465b22fec2cd05e'
PINNED_INDEX_SHA256 = 'd1529b405eac9a9d365edb6451a946f8e943d2bcffbeda45da4ece9ea25506e4'
PINNED_DATA_SHA256 = '781cf09aebfb28c176b566c5290d953814759b7bc63f417df6bba0c2619991cd'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ordered_weights(checkpoint):
    t = tensors(checkpoint)
    ordered = []
    def take(key, shape):
        a = t[key + SUFFIX]
        if tuple(a.shape) != tuple(shape) or not np.isfinite(a).all():
            raise ValueError(f'invalid tensor {key}: {a.shape}')
        ordered.append((key, a))
    p = 'midi_decoder/z_preconditioning_stack/'
    for i in range(5):
        b = p + f'stack/layer_with_weights-{i}/'
        take(b + 'layer_with_weights-0/kernel', (10 if i == 0 else 512, 512))
        take(b + 'layer_with_weights-0/bias', (512,))
        take(b + 'layer_with_weights-1/gamma', (512,))
        take(b + 'layer_with_weights-1/beta', (512,))
    take(p + 'dense_out/kernel', (512, 256))
    take(p + 'dense_out/bias', (256,))
    take('midi_decoder/instrument_emb/embeddings', (20, 64))
    take('midi_decoder/decoder/q_pitch_emb/kernel', (1, 64))
    take('midi_decoder/decoder/q_pitch_emb/bias', (64,))
    p = 'midi_decoder/decoder/midi_f0_to_harmonic/'
    take(p + 'net/conv_in/kernel', (3, 1, 384, 128))
    take(p + 'net/conv_in/bias', (128,))
    for i in range(20):
        take(p + f'net/layers/{i}/layer_with_weights-0/kernel', (3, 1, 128, 128))
        take(p + f'net/layers/{i}/layer_with_weights-0/bias', (128,))
        take(p + f'net/norms/{i}/scale', (1, 1, 1, 128))
        take(p + f'net/norms/{i}/shift', (1, 1, 1, 128))
    take(p + 'norm/scale', (1, 1, 1, 128))
    take(p + 'norm/shift', (1, 1, 1, 128))
    take(p + 'dense_out/kernel', (128, 126))
    take(p + 'dense_out/bias', (126,))
    return ordered


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--checkpoint', type=Path, default=SOURCE / 'midi_ddsp_model_weights_urmp_9_10/synthesis_generator/50000')
    parser.add_argument('--out', type=Path, default=ROOT / 'models/audio/midi_ddsp_timbre.nad')
    args = parser.parse_args()
    for path, expected in [
        (SOURCE / 'weights.zip', PINNED_ARCHIVE_SHA256),
        (str(args.checkpoint) + '.index', PINNED_INDEX_SHA256),
        (str(args.checkpoint) + '.data-00000-of-00001', PINNED_DATA_SHA256),
    ]:
        if sha(path) != expected:
            raise ValueError(f'Pinned upstream checkpoint hash mismatch: {path}')
    items = ordered_weights(args.checkpoint)
    payload = b''.join(a.astype('<f4').tobytes() for _, a in items)
    header = struct.pack('<4s15I', b'NAD1', 1, len(payload) // 4, 250, 16000, 60, 65, 20, 5, 512, 128, 20, 0, 0, 0, 0)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(header + payload)
    offset = 64
    layout = []
    for name, a in items:
        layout.append({'name': name, 'shape': list(a.shape), 'offset': offset, 'bytes': a.nbytes})
        offset += a.nbytes
    meta = {
        'schema': 1, 'name': 'MIDI-DDSP URMP controlled timbre decoder',
        'source_repository': 'https://github.com/magenta/midi-ddsp',
        'checkpoint_url': 'https://raw.githubusercontent.com/magenta/midi-ddsp/models/midi_ddsp_model_weights_urmp_9_10.zip',
        'checkpoint_archive_sha256': sha(SOURCE / 'weights.zip'),
        'checkpoint_data_sha256': sha(str(args.checkpoint) + '.data-00000-of-00001'),
        'checkpoint_index_sha256': sha(str(args.checkpoint) + '.index'),
        'training_data': 'URMP recordings of real acoustic instrument performances',
        'runtime_inputs': ['authored MIDI pitch', 'six authored expression controls', 'onset', 'offset', 'relative note position', 'instrument ID'],
        'selected_instrument_ids': {'violin': 0, 'double_bass': 3, 'trumpet': 9},
        'precision': 'float32 unchanged trained values',
        'sample_rate_hz': 16000, 'control_rate_hz': 250,
        'excluded': ['audio analysis encoder', 'autoregressive f0 predictor', 'expression generator', 'recorded audio', 'trained reverb'],
        'limitations': ['Not the complete MIDI-DDSP pipeline', '16 kHz source synthesis; resampling cannot restore absent bandwidth', 'No claim of perceptual indistinguishability'],
        'file': args.out.relative_to(ROOT).as_posix(), 'bytes': args.out.stat().st_size,
        'sha256': sha(args.out), 'float_count': len(payload) // 4, 'tensors': layout,
    }
    (args.out.parent / 'provenance.json').write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: meta[k] for k in ['file', 'bytes', 'sha256', 'float_count']}))


if __name__ == '__main__':
    main()
