"""Inspect RGBA32F output from terrain_trace_probe.hlsl, without image metrics."""
import argparse
import json
import math
from pathlib import Path
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--tolerance', type=float, default=.10)
    args = parser.parse_args()
    data = args.input.read_bytes()
    if len(data) % 16:
        raise SystemExit('Expected tightly packed little-endian RGBA32F pixels.')
    failures, unresolved, classes = [], [], {}
    maximum_error, maximum_residual = 0.0, 0.0
    for i, (actual, reference, residual, flags_float) in enumerate(struct.iter_unpack('<4f', data)):
        if not all(math.isfinite(x) for x in (actual, reference, residual, flags_float)):
            failures.append(dict(index=i, reason='nonfinite'))
            continue
        flags = round(flags_float)
        kind = flags >> 2
        classes[kind] = classes.get(kind, 0)+1
        actual_hit, reference_hit = bool(flags & 1), bool(flags & 2)
        case = dict(index=i, kind=kind, actual=actual, reference=reference, residual=residual)
        if actual_hit:
            maximum_residual = max(maximum_residual, abs(residual))
            if abs(residual) > args.tolerance:
                failures.append(dict(case, reason='off-surface hit'))
        if kind == 2 and actual_hit:
            failures.append(dict(case, reason='known sky ray hit'))
        elif reference_hit and not actual_hit:
            failures.append(dict(case, reason='missed reference hit'))
        elif actual_hit and not reference_hit:
            unresolved.append(dict(case, reason='possible sub-step dense-reference miss'))
        elif actual_hit and reference_hit:
            error = abs(actual-reference)
            maximum_error = max(maximum_error, error)
            tolerance = .01 if kind == 1 else args.tolerance
            if error > tolerance:
                if actual > reference or kind == 1:
                    failures.append(dict(case, reason='late or incorrect hit'))
                else:
                    unresolved.append(dict(case, reason='possible earlier narrow-ridge hit'))
    result = dict(samples=len(data)//16, ray_classes=classes, failures=len(failures),
                  unresolved_dense_reference_cases=len(unresolved),
                  maximum_matching_distance_error_m=maximum_error,
                  maximum_surface_residual_m=maximum_residual,
                  first_failures=failures[:20], first_unresolved=unresolved[:20])
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result, indent=2))
    return 1 if failures else 2 if unresolved else 0


if __name__ == '__main__':
    raise SystemExit(main())
