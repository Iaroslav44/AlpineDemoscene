"""Independent scalar regression for temporal HDR history clipping.

No graphics device or third-party packages are needed. This checks the convex
domain of luminance-compressed radiance, not GPU image quality or performance.
The negative fixture reproduces an invalid color from component-wise YCoCg
clipping. Segment clipping must preserve the domain for arbitrary legal HDR
colors, variance boxes, spatial weights and temporal blend weights.
"""
import argparse
import json
import math
from pathlib import Path
import random


LUMA = (0.2126, 0.7152, 0.0722)
SPATIAL = (0.0625, 0.25, 0.0625, 0.25, 1.0, 0.25, 0.0625, 0.25, 0.0625)
NEGATIVE_NEIGHBORS = (
    (21.914628360, .001764970, .287515849),
    (733.144016436, .003832555, 9.830361930),
    (570.151871028, 750.521457457, .064042366),
    (65.667146603, 32.261069506, .058610962),
    (634.818801399, .002556620, 9.900958821),
    (12.855374337, 20.025784553, .499992718),
    (145.466787367, 1.242196773, .005403126),
    (580.108406892, .001591663, .008697085),
    (10.460563933, 401.192712243, .085517515),
)
NEGATIVE_HISTORY = (7.835677172, 93.150881764, 187.098646344)


def luminance(color):
    return sum(a * b for a, b in zip(color, LUMA))


def compress(color):
    denominator = 1.0 + luminance(color)
    return tuple(x / denominator for x in color)


def expand(color):
    positive = tuple(max(0.0, x) for x in color)
    denominator = max(.0001, 1.0 - luminance(positive))
    return tuple(x / denominator for x in positive)


def to_yc(color):
    r, g, b = color
    return ((r + 2 * g + b) * .25, (r - b) * .5,
            (-r + 2 * g - b) * .25)


def from_yc(color):
    y, co, cg = color
    return (y + co - cg, y + cg, y - co - cg)


def blend(a, b, amount):
    return tuple(x + (y - x) * amount for x, y in zip(a, b))


def neighborhood(colors, weights):
    compressed = [compress(c) for c in colors]
    ys = [to_yc(c) for c in compressed]
    lo, hi = [], []
    for channel in zip(*ys):
        mean = sum(channel) / 9
        sigma = math.sqrt(max(0.0, sum(x * x for x in channel) / 9 - mean * mean))
        lo.append(max(min(channel), mean - 1.25 * sigma))
        hi.append(min(max(channel), mean + 1.25 * sigma))
    total = sum(weights)
    current = tuple(sum(c[k] * w for c, w in zip(compressed, weights)) / total
                    for k in range(3))
    return current, lo, hi


def clip_segment(current, history, lo, hi):
    a, b = to_yc(current), to_yc(history)
    # Compute the first intersection of the ray segment with any of the box's
    # six planes. Include the current point so a valid origin is always inside.
    amount = 1.0
    for x, y, lower, upper in zip(a, b, lo, hi):
        lower, upper = min(lower, x), max(upper, x)
        delta = y - x
        if delta > 1e-6:
            amount = min(amount, (upper - x) / delta)
        elif delta < -1e-6:
            amount = min(amount, (lower - x) / delta)
    return from_yc(blend(a, b, max(0.0, min(1.0, amount))))


def run(cases, seed):
    current, lo, hi = neighborhood(NEGATIVE_NEIGHBORS, SPATIAL)
    history = compress(NEGATIVE_HISTORY)
    old_clipped = from_yc(tuple(max(low, min(high, x))
                               for x, low, high in zip(to_yc(history), lo, hi)))
    weight = .86 * 2 ** (-3 * abs(to_yc(history)[0] - to_yc(current)[0]))
    old_mix = blend(current, old_clipped, weight)
    negative_luma = luminance(tuple(max(0.0, x) for x in old_mix))
    assert negative_luma > 1, "Negative fixture no longer exposes the old bug"
    fixed_mix = blend(current, clip_segment(current, history, lo, hi), weight)
    assert min(fixed_mix) >= -1e-12 and luminance(fixed_mix) < 1

    # A plane parallel to the segment imposes no constraint. In particular a
    # completely neutral neighborhood has zero chroma variance and zero chroma
    # delta; dividing zero room by an epsilon must not reject its valid history.
    neutral = [(v, v, v) for v in (.25, .5, 1, 2, 4, 8, 1.5, 3, 6)]
    neutral_current, neutral_lo, neutral_hi = neighborhood(neutral, SPATIAL)
    neutral_history = compress((2, 2, 2))
    neutral_clipped = clip_segment(neutral_current, neutral_history, neutral_lo, neutral_hi)
    assert max(abs(a - b) for a, b in zip(neutral_clipped, neutral_history)) < 1e-12

    rng = random.Random(seed)
    maximum_luma = 0.0
    minimum_component = 0.0
    maximum_convex_error = 0.0
    for case in range(cases):
        def color():
            return tuple(0.0 if rng.random() < .12 else 10 ** rng.uniform(-6, 4.7)
                         for _ in range(3))
        colors, incoming = [color() for _ in range(9)], color()
        weights = tuple(w * 2 ** (-rng.uniform(0, 24)) for w in SPATIAL)
        current, lo, hi = neighborhood(colors, weights)
        history = compress(incoming)
        clipped = clip_segment(current, history, lo, hi)
        mixed = blend(current, clipped, rng.random())
        value = luminance(mixed)
        maximum_luma = max(maximum_luma, value)
        minimum_component = min(minimum_component, min(mixed))
        maximum_convex_error = max(maximum_convex_error,
                                  value - max(luminance(current), luminance(history)))
        assert all(math.isfinite(x) for x in mixed), (case, "nonfinite")
        assert min(mixed) >= -1e-10, (case, "negative radiance", mixed)
        assert value < 1, (case, "invalid compressed domain", value)
        assert value <= max(luminance(current), luminance(history)) + 1e-10
        restored = expand(mixed)
        # The shader's .0001 safety denominator can intentionally attenuate
        # extremely bright endpoints. Bound against their mathematical inverse,
        # not that separately attenuated value: attenuation need not commute
        # with blending, whereas the valid projective inverse preserves a line.
        endpoints = tuple(tuple(x / (1.0 - luminance(c)) for x in c)
                          for c in (current, history))
        assert all(math.isfinite(x) for x in restored), (case, "nonfinite expansion")
        for k, x in enumerate(restored):
            assert x <= max(endpoints[0][k], endpoints[1][k]) + 1e-4, (
                case, "artificial HDR amplification", restored, endpoints)
    return {
        "passed": True, "cases": cases, "seed": seed,
        "scope": "Independent CPU domain property; not a GPU execution test or realism claim",
        "negative_old_component_clip": {
            "compressed_luminance": negative_luma,
            "expanded_rgb": expand(old_mix),
            "failure_reproduced": True,
        },
        "fixed_fixture": {"compressed_luminance": luminance(fixed_mix),
                          "expanded_rgb": expand(fixed_mix)},
        "neutral_history_preserved": True,
        "maximum_tested_compressed_luminance": maximum_luma,
        "minimum_tested_component": minimum_component,
        "maximum_luminance_convex_bound_error": maximum_convex_error,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=int, default=30000)
    parser.add_argument("--seed", type=int, default=88029)
    parser.add_argument("--report", type=Path, default=Path("build/hdr_domain_reference.json"))
    args = parser.parse_args()
    if args.cases < 1:
        parser.error("--cases must be positive")
    report = run(args.cases, args.seed)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
