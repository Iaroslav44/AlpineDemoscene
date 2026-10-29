"""Collect the October 2026 native release checks; refuse incomplete/failed QA.

Run from the project root after the commands recorded in REVIEW_RU.md.
Reports prove numerical/runtime properties, not photographic or acoustic realism.
"""
from pathlib import Path
import hashlib
import json
import statistics

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads((ROOT / path).read_text(encoding='utf-8-sig'))


def sha(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest().upper()


def render_summary(directory):
    m = read(directory + '/metrics.json')
    assert m['debug_errors'] == m['debug_warnings'] == 0, directory
    frames = m['frames']
    for frame in frames:
        assert not frame['gpu_disjoint'], directory
        for key in ['world', 'mesh_composite', 'human_composite', 'cloud_composite', 'resolved']:
            for invalid in ['nonfinite_pixels', 'zero_depth_pixels', 'invalid_depth_pixels']:
                assert frame[key][invalid] == 0, (directory, key, invalid)
        assert frame['instance_counts']['invalid_flags'] == 0, directory
        assert frame['water_state']['nonfinite_values'] == 0, directory
        assert frame['cloud_changed_depth_pixels'] == 0, directory
        assert frame['reflection_cloud_changed_depth_pixels'] == 0, directory
    times = [sum(f['gpu_ms'][1:]) for f in frames[1:]]
    return {'directory': directory, 'frames': len(frames), 'start': frames[0]['time'],
            'end': frames[-1]['time'], 'dt': m['dt'], 'adapter': m['adapter'],
            'debug_errors': 0, 'debug_warnings': 0, 'invalid_pixels': 0,
            'unique_frame_hashes': len({f['rgba_fnv1a64'] for f in frames}),
            'render_ms_excluding_first_and_physics': {'median': statistics.median(times),
                'mean': statistics.mean(times), 'maximum': max(times)},
            'max_water_height_m': max(f['water_state']['max_abs_height_m'] for f in frames)}


exe = 'dist/AlpineDreaming.exe'
size = (ROOT / exe).stat().st_size
assert size < 88000000
native = read('build/oct29_native.json')
assert native['sha256'] == sha(exe)
assert native['exit_code'] == 0 and not native['forced_termination']
assert native['responsive_before_close'] and not native['window_was_visible']
physics = read('build/oct29_physics/physics_tests.json')
assert physics['flight_finite'] and all(t['passed'] for t in physics['tests'])
assert physics['display_partition_bit_exact'] and physics['backwards_replay_bit_exact']
assert physics['debug_warnings_errors'] == 0
camera = read('build/oct29_camera/camera_metrics.json')
assert camera['nonfinite_values'] == 0 and camera['min_ground_clearance'] > 0
audio = read('validation/audio-release.json')
assert audio['passed'] and not audio['errors']
assert audio['source_sha256']['src\\orchestra.inc'].upper() == sha('src/orchestra.inc')
water = read('build/oct29_water/safe/water_normal_metrics.json')
assert water['passed'] and water['debug_warnings_errors'] == 0
equivalence = read('build/oct29_equivalence.json')
assert equivalence['candidate']['SHA256'] == sha(exe)
hdr = read('build/hdr_domain_reference.json')
assert hdr['passed']
report = {'schema': 3, 'date': '2026-10-29', 'executable': exe, 'sha256': sha(exe),
          'bytes': size, 'limit_bytes_exclusive': 88000000,
          'baseline': {'commit': 'e4e4608f', 'tag': 'alpine-before-photoreal-audio-20261029',
                       'bytes': 1274880}, 'size_increase_bytes': size - 1274880,
          'route': render_summary('build/oct29_final_route'),
          'motion': [render_summary('build/oct29_motion_' + name) for name in ['portrait', 'lake', 'glider']],
          'native': native,
          'native_scope': '135-second process lifetime, including startup; not an independently instrumented playback-loop counter.',
          'camera': camera, 'physics': physics,
          'physics_build_sha256': sha('build/physics-validated-oct29.exe'),
          'shader_equivalence': equivalence,
          'flight': read('build/oct29_physics/flight_metrics.json'),
          'terrain': read('build/oct29_final_route/terrain_metrics.json'),
          'terrain_bounds': read('build/oct29_final_route/terrain_bounds_metrics.json'),
          'materials': read('build/oct29_final_route/material_metrics.json'),
          'water_normals_and_fresnel': water, 'hdr_domain_regression': hdr,
          'audio_report': 'validation/audio-release.json',
          'audio_preview': 'preview/orchestral-house.wav',
          'audio_full_wav_sha256': audio['files']['orchestral_house_full.wav']['sha256'],
          'source_sha256': {str(p.relative_to(ROOT)).replace('\\', '/'): sha(p)
                            for p in sorted((ROOT / 'src').glob('*')) if p.is_file()},
          'quality': {'photorealism_achieved': False, 'acoustic_indistinguishability_established': False,
                      'reason': 'Procedural faces, foliage and terrain remain visibly synthetic. Modal instruments lack measured body responses and nonlinear bow/lip interaction. Numerical checks do not establish perceptual realism.'}}
output = ROOT / 'validation/88mb-release.json'
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'bytes': size, 'sha256': report['sha256'], 'report': str(output)}, indent=2))
