"""Independent NumPy evaluation of the original TensorFlow checkpoint graph.

Compares native raw neural outputs before synthesis, then checks pitch and finite
audio. These checks establish implementation fidelity, not perceptual realism.
"""
import os
os.environ['OPENBLAS_NUM_THREADS'] = '1'
os.environ['OMP_NUM_THREADS'] = '1'
from pathlib import Path
import json
import hashlib
import numpy as np
from neural_audio_checkpoint import tensors

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/neural_audio_validation'
CHECKPOINT = ROOT / 'build/neural_audio_source/midi_ddsp_model_weights_urmp_9_10/synthesis_generator/50000'


def reference(control, instrument):
    data = tensors(CHECKPOINT)
    def w(name): return data[name + '/.ATTRIBUTES/VARIABLE_VALUE'].squeeze()
    def norm(x, scale, shift, epsilon, global_field=False):
        axes = None if global_field else -1
        mean = x.mean(axis=axes, keepdims=True, dtype=np.float64).astype(np.float32)
        var = ((x.astype(np.float64) - mean) ** 2).mean(axis=axes, keepdims=True).astype(np.float32)
        return (x - mean) / np.sqrt(var + epsilon) * scale + shift
    def conv(x, weights, bias, dilation):
        y = np.broadcast_to(bias, (len(x), len(bias))).copy()
        weights = weights.reshape(3, x.shape[-1], len(bias))
        for k in range(3):
            delta = (k - 1) * dilation
            if delta < 0: y[-delta:] += x[:delta] @ weights[k]
            elif delta > 0: y[:-delta] += x[delta:] @ weights[k]
            else: y += x @ weights[k]
        return y
    p = 'midi_decoder/z_preconditioning_stack/'
    x = control.copy()
    for layer in range(5):
        b = p + f'stack/layer_with_weights-{layer}/'
        x = x @ w(b + 'layer_with_weights-0/kernel') + w(b + 'layer_with_weights-0/bias')
        x = norm(x, w(b + 'layer_with_weights-1/gamma'), w(b + 'layer_with_weights-1/beta'), .001)
        x = np.where(x >= 0, x, .2 * x)
    x = x @ w(p + 'dense_out/kernel') + w(p + 'dense_out/bias')
    emb = np.broadcast_to(w('midi_decoder/instrument_emb/embeddings')[instrument], (len(x), 64))
    pitch = control[:, 6:7] * w('midi_decoder/decoder/q_pitch_emb/kernel') + w('midi_decoder/decoder/q_pitch_emb/bias')
    x = np.concatenate((x, emb, pitch), axis=-1)
    p = 'midi_decoder/decoder/midi_f0_to_harmonic/'
    x = conv(x, w(p+'net/conv_in/kernel'), w(p+'net/conv_in/bias'), 1)
    for i in range(20):
        y = conv(np.maximum(x, 0), w(p+f'net/layers/{i}/layer_with_weights-0/kernel'), w(p+f'net/layers/{i}/layer_with_weights-0/bias'), 1 << (i % 5))
        x += norm(y, w(p+f'net/norms/{i}/scale'), w(p+f'net/norms/{i}/shift'), 1e-5, True)
    x = norm(x, w(p+'norm/scale'), w(p+'norm/shift'), 1e-5, True)
    return x @ w(p+'dense_out/kernel') + w(p+'dense_out/bias')


def main():
    controls = np.fromfile(OUT/'controls.f32', dtype='<f4').reshape(-1, 10)
    native = np.fromfile(OUT/'raw_native.f32', dtype='<f4').reshape(-1, 126)
    ref = reference(controls, 0)
    diff = np.abs(native - ref)
    assert np.isfinite(native).all()
    assert float(diff.max()) < .0005, f'neural operator mismatch {diff.max()}'
    alt = reference(controls, 9)
    instrument_distance = float(np.sqrt(np.mean((ref-alt)**2)))
    assert instrument_distance > .01
    instruments = []
    for name, midi in [('violin_C4', 60), ('double_bass_A1', 33), ('trumpet_A4',69)]:
        audio = np.fromfile(OUT/(name+'.f32'),dtype='<f4')
        assert len(audio) == 198450 and np.isfinite(audio).all()
        segment = audio[22050:154350]
        spectrum = np.abs(np.fft.rfft(segment*np.hanning(len(segment))))
        frequency = np.fft.rfftfreq(len(segment), 1/44100)
        expected = 440*2**((midi-69)/12)
        mask = np.abs(frequency-expected) < expected*.05
        measured = float(frequency[mask][np.argmax(spectrum[mask])])
        cents = float(1200*np.log2(measured/expected))
        assert abs(cents) < 15
        power_above8k = float(np.sum(spectrum[frequency>8000]**2) / np.sum(spectrum**2))
        instruments.append({'name':name,'midi':midi,'frames':len(audio),'peak':float(np.abs(audio).max()),'rms':float(np.sqrt(np.mean(audio**2))), 'fundamental_hz':measured, 'pitch_error_cents':cents, 'fraction_energy_above8khz':power_above8k})
    provenance = json.loads((ROOT/'models/audio/provenance.json').read_text(encoding='utf8'))
    report = {'schema':1,'model_sha256':hashlib.sha256((ROOT/'models/audio/midi_ddsp_timbre.nad').read_bytes()).hexdigest(),
        'source_sha256': {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in
            ['src/neural_audio.cpp','src/neural_audio.h','tools/neural_audio_checkpoint.py','tools/neural_audio_export.py','tools/neural_audio_validate.py']},
        'checkpoint_data_sha256':provenance['checkpoint_data_sha256'],
        'checkpoint_archive_sha256':provenance['checkpoint_archive_sha256'],
        'model_bytes':provenance['bytes'], 'trained_parameter_count':provenance['float_count'],
        'reference':'Independent NumPy graph using original TensorFlow checkpoint tensors, not the exported blob',
        'raw_max_absolute_error':float(diff.max()),'raw_rms_error':float(np.sqrt(np.mean(diff**2))),
        'instrument_control_rms_distance':instrument_distance,'instruments':instruments,
        'perceptual_indistinguishability_verified':False,'source_sample_rate_hz':16000,
        'output_sample_rate_hz':44100, 'runtime_dependencies':['Windows kernel32', 'SSE2 CPU'],
        'timing_and_input_checks':json.loads((OUT/'timings.json').read_text()),
        'temporary_memory_upper_bound_bytes':14500000,
        'notes':['Authored pitch and expression; trained timbre subnetwork only','Output resampling does not extend source bandwidth','Double-bass timbre derives from URMP, not a separately verified pizzicato model']}
    (ROOT/'validation/neural-audio.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print(json.dumps(report,indent=2))


if __name__ == '__main__': main()
