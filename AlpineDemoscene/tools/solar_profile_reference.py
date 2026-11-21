"""Compare direct solar transmittance with a double-precision spherical ray integral."""
import argparse
import json
from pathlib import Path

import numpy as np


def transmittance(heights, sun_y, edges):
    radius = 6360.0 + heights[:, None] / 1000.0
    projection = radius * sun_y
    distance = np.sqrt(6460.0 ** 2 - radius ** 2 + projection ** 2) - projection
    sample = distance * ((edges[1:] + edges[:-1]) * .5)
    h = np.sqrt(radius ** 2 + 2.0 * projection * sample + sample ** 2) - 6360.0
    widths = np.diff(edges) * distance
    columns = np.stack(((widths * np.exp(-h / 8.0)).sum(axis=1),
                        (widths * np.exp(-h / 1.2)).sum(axis=1),
                        (widths * np.maximum(0.0, 1.0 - abs(h - 25.0) / 15.0)).sum(axis=1)), axis=1)
    extinction = np.array([[.005802, .013558, .033100], [.003996 / .9] * 3,
                           [.000650, .001881, .000085]])
    return np.exp(-(columns @ extinction))


def compare(nodes, heights, mu, table):
    interpolated = np.stack([np.interp(heights, nodes, table[:, channel])
                             for channel in range(3)], axis=1)
    reference = transmittance(heights, mu, np.linspace(0.0, 1.0, 2049))
    return np.abs(reference - interpolated)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gpu-dump', type=Path,
                        help='render probe output containing --dump-world solar and camera readbacks')
    args = parser.parse_args()
    nodes = np.linspace(10.0, 12000.0, 65)
    heights = np.linspace(nodes[0], nodes[-1], 257)
    new_errors, previous_errors = [], []
    for mu in np.linspace(.025, .7, 17):
        table = transmittance(nodes, mu, np.linspace(0.0, 1.0, 33) ** 2)
        new_errors.append(compare(nodes, heights, mu, table))
        previous = transmittance(heights, mu, np.linspace(0.0, 1.0, 7) ** 2)
        previous_errors.append(compare(heights, heights, mu, previous))
    result = {'reference_intervals': 2048, 'solar_elevations_tested': 17,
              'altitudes_tested': len(heights), 'worst_transmittance_error': float(np.max(new_errors)),
              'previous_six_step_worst_error': float(np.max(previous_errors))}
    if args.gpu_dump:
        gpu = np.fromfile(args.gpu_dump / 'solar_profile.f32', '<f4').reshape(65, 4)
        camera = np.fromfile(args.gpu_dump / 'camera_float4.bin', '<f4').reshape(15, 4)
        if not np.all(gpu[:, 3] == 1.0):
            raise ValueError('incomplete GPU solar profile')
        result['gpu_max_error'] = float(compare(nodes, heights, camera[8, 1], gpu[:, :3]).max())
    print(json.dumps(result, indent=2, allow_nan=False))
    return max(result['worst_transmittance_error'], result.get('gpu_max_error', 0.0)) >= .005


if __name__ == '__main__':
    raise SystemExit(main())
