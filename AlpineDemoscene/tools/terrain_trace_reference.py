"""CPU property checks for the shader's hierarchical bilinear terrain traversal.

The oracle evaluates the bilinear surface geometrically, splits its restriction
to each ray interval at the quadratic extremum, and bisects monotone intervals.
It does not reuse the shader's quadratic formula or hierarchical traversal.
No GPU, third-party packages, generated images, or external data are required.
"""
from __future__ import annotations

import argparse
from array import array
import json
import math
import random
import struct
from pathlib import Path


def normalize(v):
    d = math.sqrt(sum(x*x for x in v))
    return tuple(x/d for x in v)


def next_float32(value):
    bits = struct.unpack('I', struct.pack('f', value))[0]
    return struct.unpack('f', struct.pack('I', bits+1))[0]


def bilinear(h, x, z):
    return (h[0]*(1-x)+h[1]*x)*(1-z)+(h[2]*(1-x)+h[3]*x)*z


def reference_patch(h, f, velocity, y, dy, span):
    """Independent monotone-interval bisection, including tangent roots."""
    def gap(u):
        return y+dy*span*u-bilinear(h, f[0]+velocity[0]*span*u,
                                  f[1]+velocity[1]*span*u)
    g0, gm, g1 = gap(0), gap(.5), gap(1)
    if g0 <= .0005:
        return 0.0
    a = 2*(g1+g0-2*gm)
    b = g1-g0-a
    cuts = [0.0, 1.0]
    if abs(a) > 1e-15:
        vertex = -b/(2*a)
        if 0 < vertex < 1:
            cuts.insert(1, vertex)
    for lo, hi in zip(cuts, cuts[1:]):
        flo, fhi = gap(lo), gap(hi)
        if abs(fhi) < 1e-10:
            return hi*span
        if flo*fhi > 0:
            continue
        for _ in range(60):
            mid = (lo+hi)*.5
            if gap(mid) > 0:
                lo = mid
            else:
                hi = mid
        return (lo+hi)*.5*span
    return None


def shader_patch(h, f, velocity, y, dy, span):
    hx, hz, hxz = h[1]-h[0], h[2]-h[0], h[3]-h[1]-h[2]+h[0]
    a = -hxz*velocity[0]*velocity[1]
    b = dy-hx*velocity[0]-hz*velocity[1]-hxz*(f[0]*velocity[1]+f[1]*velocity[0])
    c = y-(h[0]+hx*f[0]+hz*f[1]+hxz*f[0]*f[1])
    if c <= .0005:
        return 0.0
    root = 1e20
    if abs(a) < 1e-8:
        if b < -1e-7:
            root = -c/b
    else:
        disc = b*b-4*a*c
        if disc >= 0:
            q = -.5*(b+(-math.sqrt(disc) if b < 0 else math.sqrt(disc)))
            r0, r1 = q/a, c/q if abs(q) > 1e-12 else 1e20
            if r0 >= 0:
                root = r0
            if r1 >= 0:
                root = min(root, r1)
    return root if root <= span else None


class Grid:
    def __init__(self, n, function, texel=1.0):
        assert n >= 2 and n & (n-1) == 0
        self.n, self.texel = n, texel
        self.extent = (n-1)*texel
        self.height = array('d', (function(x, z) for z in range(n) for x in range(n)))
        first = array('d', (max(self.patch(x, z))+.001 for z in range(n) for x in range(n)))
        self.bounds = [first]
        size = n
        while size > 1:
            old, half = self.bounds[-1], size//2
            self.bounds.append(array('d', (max(old[(2*z+dz)*size+2*x+dx]
                                              for dz in range(2) for dx in range(2))+.001
                                           for z in range(half) for x in range(half))))
            size = half

    def patch(self, x, z):
        xx, zz = min(x+1, self.n-1), min(z+1, self.n-1)
        return (self.height[z*self.n+x], self.height[z*self.n+xx],
                self.height[zz*self.n+x], self.height[zz*self.n+xx])


def slab(grid, ro, rd, max_t):
    start, end = .025, max_t
    for axis in (0, 2):
        if abs(rd[axis]) < 1e-12:
            if not 0 <= ro[axis] <= grid.extent:
                return None
            continue
        a, b = -ro[axis]/rd[axis], (grid.extent-ro[axis])/rd[axis]
        start, end = max(start, min(a, b)), min(end, max(a, b))
    return (start, end) if start <= end else None


def reference_grid(grid, ro, rd, max_t):
    interval = slab(grid, ro, rd, max_t)
    if interval is None:
        return None
    start, end = interval
    cuts = {start, end}
    for axis in (0, 2):
        if abs(rd[axis]) > 1e-12:
            for i in range(1, grid.n-1):
                t = (i*grid.texel-ro[axis])/rd[axis]
                if start < t < end:
                    cuts.add(t)
    cuts = sorted(cuts)
    for lo, hi in zip(cuts, cuts[1:]):
        mid = (lo+hi)*.5
        cell = [max(0, min(grid.n-2, math.floor((ro[a]+rd[a]*mid)/grid.texel))) for a in (0, 2)]
        f = tuple((ro[a]+rd[a]*lo)/grid.texel-cell[k] for k, a in enumerate((0, 2)))
        hit = reference_patch(grid.patch(*cell), f, (rd[0]/grid.texel, rd[2]/grid.texel),
                              ro[1]+rd[1]*lo, rd[1], hi-lo)
        if hit is not None:
            return lo+hit
    return None


def shader_grid(grid, ro, rd, max_t, budget=16416):
    interval = slab(grid, ro, rd, max_t)
    if interval is None:
        return None, 0, False
    t, end = interval
    max_level, level = len(grid.bounds)-1, min(10, len(grid.bounds)-1)
    for iteration in range(budget):
        if t >= end:
            return None, iteration, False
        p = tuple(ro[a]+rd[a]*t for a in range(3))
        scale, size = 2**level, grid.n >> level
        coords = (p[0]/grid.texel, p[2]/grid.texel)
        whole = tuple(math.floor(coords[k]/scale) for k in range(2))
        cell = tuple(max(0, min(size-1, whole[k]-(1 if rd[a] < 0 and coords[k]/scale == whole[k] else 0)))
                     for k, a in enumerate((0, 2)))
        deltas = []
        for k, axis in enumerate((0, 2)):
            edge = max(0, min(grid.extent, (cell[k]+(1 if rd[axis] >= 0 else 0))*scale*grid.texel))
            deltas.append((edge-p[axis])/rd[axis] if abs(rd[axis]) > 1e-8 else 1e20)
        span = max(.0001, min(*deltas, end-t))
        maximum = grid.bounds[level][cell[1]*size+cell[0]]
        if min(p[1], p[1]+rd[1]*span) > maximum:
            t = next_float32(t+span)
            level = min(level+1, max_level)
            continue
        if level:
            level -= 1
            continue
        f = (coords[0]-cell[0], coords[1]-cell[1])
        hit = shader_patch(grid.patch(*cell), f, (rd[0]/grid.texel, rd[2]/grid.texel),
                           p[1], rd[1], span)
        if hit is not None:
            return t+hit, iteration+1, False
        t = next_float32(t+span)
        level = 1
    return None, budget, True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seed', type=int, default=88027)
    parser.add_argument('--patches', type=int, default=5000)
    parser.add_argument('--rays', type=int, default=1200)
    parser.add_argument('--budget', type=int, default=16416)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    failures, cases, exhausted, max_iterations = [], 0, 0, 0

    def compare(name, expected, actual, tolerance=.002, details=None):
        nonlocal cases
        cases += 1
        mismatch = (expected is None) != (actual is None)
        if expected is not None and actual is not None:
            mismatch |= abs(expected-actual) > tolerance
        if mismatch:
            failures.append(dict(case=name, expected=expected, actual=actual, details=details))

    for i in range(args.patches):
        heights = tuple(rng.uniform(-100, 100) for _ in range(4))
        f, end = (rng.random(), rng.random()), (rng.random(), rng.random())
        y = bilinear(heights, *f)+rng.uniform(.001, 30)
        y_end = bilinear(heights, *end)+rng.uniform(-30, 30)
        delta = (end[0]-f[0], y_end-y, end[1]-f[1])
        span = math.sqrt(sum(x*x for x in delta))
        rd = normalize(delta)
        velocity = (rd[0], rd[2])
        expected = reference_patch(heights, f, velocity, y, rd[1], span)
        actual = shader_patch(heights, f, velocity, y, rd[1], span)
        compare(f'patch-{i}', expected, actual, details=dict(h=heights, f=f, rd=rd, y=y, span=span))

    def check_ray(name, grid, ro, rd, limit):
        nonlocal exhausted, max_iterations
        expected = reference_grid(grid, ro, rd, limit)
        actual, iterations, did_exhaust = shader_grid(grid, ro, rd, limit, args.budget)
        exhausted += did_exhaust
        max_iterations = max(max_iterations, iterations)
        tolerance, actual_gap = .002, None
        if actual is not None:
            p = tuple(ro[a]+rd[a]*actual for a in range(3))
            cell = [max(0, min(grid.n-2, math.floor(p[a]/grid.texel))) for a in (0, 2)]
            f = (p[0]/grid.texel-cell[0], p[2]/grid.texel-cell[1])
            actual_gap = p[1]-bilinear(grid.patch(*cell), *f)
            # The production field accepts a positive vertical gap <=0.5mm
            # at cell entry. Near tangency that can correspond to a larger
            # ray-distance difference; verify its actual geometric residual.
            if expected is not None and actual < expected and 0 <= actual_gap <= .000501:
                tolerance = max(tolerance, expected-actual+1e-10)
        compare(name, expected, actual, tolerance=tolerance,
                details=dict(ro=ro, rd=rd, limit=limit, actual_gap=actual_gap,
                             iterations=iterations, exhausted=did_exhaust))

    flat = Grid(16, lambda x, z: 10)
    check_ray('vertical-flat', flat, (7, 25, 7), (0, -1, 0), 100)
    check_ray('vertical-miss', flat, (7, 25, 7), (0, 1, 0), 100)
    check_ray('parallel-outside', flat, (-1, 25, 7), (0, -1, 0), 100)
    ridge = Grid(2, lambda x, z: float(x != z))
    check_ray('grazing-bilinear-ridge', ridge, (0, .4, 0), normalize((1, 0, 1)), 2)
    check_ray('tangent-bilinear-ridge', ridge, (0, .5, 0), normalize((1, 0, 1)), 2)
    steep_boundary = Grid(4, lambda x, z: 1000.0 if x == 0 else 0.0)
    check_ray('near-boundary-containing-cell', steep_boundary, (.9745, .1, .1), (1, 0, 0), 2)
    negative_boundary = Grid(4, lambda x, z: 10.0 if x == 2 else 0.0)
    check_ray('negative-boundary-extrapolation', negative_boundary, (2.025, 10.0012, .5), (-1, 0, 0), 1)
    compare('root-outside-cell-must-not-clamp', None,
            shader_patch((0, 0, 0, 0), (.5, .5), (.1, 0), .0011, -1, .001))
    # Shader advances must make progress at the actual far-distance precision.
    for t in (8192.0, 9000.0, 12000.0):
        compare(f'float32-progress-{t}', True, next_float32(t+.0001) > t, tolerance=0)
    for x in (0, 1, 7, 15):
        for z in (0, 1, 7, 15):
            for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1)):
                check_ray(f'boundary-{x}-{z}-{dx}-{dz}', flat, (x, 11, z), normalize((dx, -.3, dz)), 100)

    random_grid = Grid(32, lambda x, z: rng.uniform(-5, 30))
    for i in range(args.rays):
        ro = (rng.uniform(-5, 36), rng.uniform(12, 70), rng.uniform(-5, 36))
        rd = normalize((rng.uniform(-1, 1), rng.uniform(-1, .2), rng.uniform(-1, 1)))
        check_ray(f'random-grid-{i}', random_grid, ro, rd, 120)

    # Every max cell is above the grazing ray, although the actual sampled
    # strip remains below it until x=900. This catches finite-budget holes.
    loose = Grid(1024, lambda x, z: 1.0 if z > 0 or x >= 900 else 0.0)
    check_ray('loose-bounds-long-grazing', loose, (.1, .5, .1), (1, 0, 0), 1023)
    report = dict(seed=args.seed, cases=cases, failures=len(failures), exhausted=exhausted,
                  max_iterations=max_iterations, traversal_budget=args.budget, first_failures=failures[:20])
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
