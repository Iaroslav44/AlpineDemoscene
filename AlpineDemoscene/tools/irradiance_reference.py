"""CPU reference for the source SH irradiance projection; no GPU is used.

For L(w)=a+b.w+w^T Q w the normalized Lambert integral is exactly
a + (2/3)b.n + (trace(Q)+n^T Q n)/4. This independent Cartesian moment
identity is the oracle, not a second implementation of the SH convolution.
The SH expressions and projection parameters are read from production HLSL.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import math
from pathlib import Path
import re

import numpy as np


ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def arithmetic(expression: str, variables: dict):
    """Evaluate only a small arithmetic AST, never arbitrary source code."""
    def visit(node):
        if isinstance(node, ast.Expression):
            return visit(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.Name) and node.id in variables:
            return variables[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = visit(node.operand)
            return -value if isinstance(node.op, ast.USub) else value
        if isinstance(node, ast.BinOp):
            left, right = visit(node.left), visit(node.right)
            operations = {ast.Add: np.add, ast.Sub: np.subtract,
                          ast.Mult: np.multiply, ast.Div: np.divide}
            if type(node.op) in operations:
                return operations[type(node.op)](left, right)
        raise ValueError(f"unsupported shader arithmetic: {expression}")
    return visit(ast.parse(expression, mode="eval"))


def source_projection():
    basis_text = (ROOT / "src/atmosphere_sh.hlsli").read_text()
    compute = (ROOT / "src/atmosphere_compute.hlsl").read_text()
    common = (ROOT / "src/atmosphere_common.hlsli").read_text()
    returns = re.findall(r"return\s+([^;]+);", basis_text)
    indices = list(map(int, re.findall(r"if\(k==(\d+)\)", basis_text)))
    if len(returns) != 9 or indices != list(range(8)):
        raise ValueError("SH basis source structure changed: update its parser")
    expressions = [x.replace("d.x", "x").replace("d.y", "y").replace("d.z", "z")
                   for x in returns]

    def basis(directions):
        variables = dict(zip(("x", "y", "z"), directions.T))
        return np.stack([np.broadcast_to(arithmetic(expr, variables), len(directions))
                         for expr in expressions], axis=1)

    band_match = re.search(r"float cosineBand=group\.x==0\?([^:]+):\(group\.x<4\?([^:]+):([^;]+)\);", compute)
    thread_match = re.search(r"\[numthreads\((\d+),(\d+),(\d+)\)\]", compute)
    loop_match = re.search(r"for\(uint j=0;j<(\d+);\+\+j\)", compute)
    lane_match = re.search(r"uint sample=lane\+j\*(\d+);", compute)
    count_match = re.search(r"float y=1-2\*\(sample\+\.5\)/(\d+)\.0;", compute)
    angle_match = re.search(r"float angle=sample\*([\d.]+);", compute)
    norm_match = re.search(r"SHReduction\[0\]\*\(4\*PI/(\d+)\)\*cosineBand", compute)
    if not all((band_match, thread_match, loop_match, lane_match, count_match, angle_match, norm_match)):
        raise ValueError("projection source structure changed: update its parser")
    threads = math.prod(map(int, thread_match.groups()))
    count = int(count_match[1])
    per_lane = int(loop_match[1])
    if threads != int(lane_match[1]) or threads * per_lane != count or count != int(norm_match[1]):
        raise ValueError("projection lane/sample/normalization counts disagree")
    if threads != 64 or not re.search(r"for\(uint stride=32;stride>0;stride>>=1\)", compute):
        raise ValueError("reduction changed: update float32 reduction emulator")
    if "AtmosphereIrradiance.Load(int3(k,0,0)).rgb*AtmosphereSHBasis(k,normal)" not in common:
        raise ValueError("reconstruction source changed: review test assumptions")
    bands = [float(arithmetic(x, {})) for x in band_match.groups()]
    factors = np.asarray([bands[0]] + [bands[1]] * 3 + [bands[2]] * 5)
    return basis, factors, threads, per_lane, count, float(angle_match[1])


def fibonacci(count, angle=math.pi * (3 - math.sqrt(5)), dtype=np.float64):
    sample = np.arange(count, dtype=dtype)
    y = 1 - 2 * (sample + .5) / count
    radius = np.sqrt(np.maximum(0, 1 - y * y))
    return np.column_stack((np.cos(sample * angle) * radius, y,
                            np.sin(sample * angle) * radius)).astype(dtype)


def sphere_quadrature():
    # Independent tensor quadrature is exact for all polynomial products here.
    z, weights = np.polynomial.legendre.leggauss(16)
    phi = np.arange(32) * (2 * math.pi / 32)
    x = np.sqrt(1 - z[:, None] ** 2) * np.cos(phi)
    y = np.sqrt(1 - z[:, None] ** 2) * np.sin(phi)
    directions = np.column_stack((x.ravel(), y.ravel(), np.repeat(z, 32)))
    return directions, np.repeat(weights, 32) * (2 * math.pi / 32)


def environment(directions, a, b, q):
    return a + directions @ b.T + np.einsum("ni,cij,nj->nc", directions, q, directions)


def lambert_oracle(normals, a, b, q):
    return (a + (2 / 3) * normals @ b.T
            + (np.trace(q, axis1=1, axis2=2)
               + np.einsum("ni,cij,nj->nc", normals, q, normals)) / 4)


def cases():
    scales = np.array([1.0, .7, .4])
    def scalar(name, a=0., b=None, q=None):
        return (name, scales * a,
                scales[:, None] * (np.zeros(3) if b is None else b),
                scales[:, None, None] * (np.zeros((3, 3)) if q is None else q))
    yield scalar("constant", a=1)
    for axis, name in enumerate("xyz"):
        b = np.zeros(3)
        b[axis] = .5
        yield scalar("linear_" + name, a=1, b=b)
        q = np.zeros((3, 3))
        q[axis, axis] = 1
        yield scalar("quadratic_" + name + "2", q=q)
    for i, j, name in ((0, 1, "xy"), (1, 2, "yz"), (0, 2, "xz")):
        q = np.zeros((3, 3))
        q[i, j] = q[j, i] = .5
        yield scalar("quadratic_" + name, a=1, q=q)
    yield ("mixed_rgb", np.array([.8, 1.1, .7]),
           np.array([[.2, -.1, .3], [-.2, .3, .1], [.1, .2, -.3]]),
           np.array([[[.1, .2, -.1], [.2, -.1, .05], [-.1, .05, .3]],
                     [[.3, -.1, .04], [-.1, .1, .2], [.04, .2, -.2]],
                     [[-.1, .12, .1], [.12, .2, -.1], [.1, -.1, .15]]]))


def threshold_normals():
    result = []
    for y0 in (-.95, .95):
        for phi in np.arange(64) * (2 * math.pi / 64):
            for delta in (-1e-7, 1e-7):
                y = y0 + delta
                radius = math.sqrt(1 - y * y)
                result.append([radius * math.cos(phi), y, radius * math.sin(phi)])
    return np.asarray(result)


def run(coefficients: Path | None):
    basis, factors, threads, per_lane, count, angle = source_projection()
    directions, weights = sphere_quadrature()
    samples = fibonacci(count, angle, np.float32)
    threshold = threshold_normals()
    normals = np.concatenate((np.eye(3), -np.eye(3), threshold, fibonacci(8192)))
    dense_basis, normal_basis = basis(directions), basis(normals)
    gram_error = float(np.max(np.abs(dense_basis.T @ (weights[:, None] * dense_basis) - np.eye(9))))
    errors = []
    if gram_error > 2e-9:
        errors.append("source SH basis is not orthonormal")
    case_results = []
    for name, a, b, q in cases():
        expected = lambert_oracle(normals, a, b, q)
        dense_coeff = dense_basis.T @ (weights[:, None] * environment(directions, a, b, q))
        exact_result = normal_basis @ (dense_coeff * factors[:, None])
        exact_error = float(np.max(np.abs(exact_result - expected)))
        # The production lane-strided sum and tree reduction in float32. The
        # reference environment stays independent of SH and uses w components.
        products = (basis(samples).astype(np.float32)[:, :, None]
                    * environment(samples, a, b, q).astype(np.float32)[:, None, :])
        lanes = np.zeros((threads, 9, 3), dtype=np.float32)
        for j in range(per_lane):
            lanes += products[j * threads:(j + 1) * threads]
        stride = threads // 2
        while stride:
            lanes[:stride] += lanes[stride:stride * 2]
            stride //= 2
        coeff = lanes[0] * np.float32(4 * math.pi / count) * factors.astype(np.float32)[:, None]
        actual = normal_basis @ coeff
        residual = actual - expected
        max_error = float(np.max(np.abs(residual)))
        pairs = residual[6:6 + len(threshold)].reshape(-1, 2, 3)
        threshold_delta_error = float(np.max(np.abs(pairs[:, 1] - pairs[:, 0])))
        if exact_error > 3e-9:
            errors.append(f"{name}: exact-quadrature SH disagrees with Cartesian Lambert integral")
        if max_error > .006:
            errors.append(f"{name}: 128-point projection exceeds 0.006 absolute radiance error")
        if threshold_delta_error > 1e-8:
            errors.append(f"{name}: discontinuity near old tangent basis threshold")
        case_results.append({"name": name, "exact_quadrature_max_abs_error": exact_error,
                             "fibonacci_128_max_abs_error": max_error,
                             "fibonacci_128_rms_error": float(np.sqrt(np.mean(residual ** 2))),
                             "threshold_pair_delta_error": threshold_delta_error})

    capture = None
    if coefficients:
        raw = coefficients.read_bytes()
        if len(raw) != 9 * 4 * 4:
            raise ValueError("coefficient dump must be exactly 9 little-endian float4 values (144 bytes)")
        values = np.frombuffer(raw, dtype="<f4").reshape(9, 4)
        finite = bool(np.isfinite(values).all())
        alpha_zero = bool((values[:, 3] == 0).all())
        capture = {"path": str(coefficients.resolve()), "sha256": sha256(coefficients),
                   "finite": finite, "alpha_zero": alpha_zero,
                   "coefficients_rgb": values[:, :3].tolist() if finite else None,
                   "note": "Readback integrity only; actual atmospheric coefficients are not an analytic polynomial environment."}
        metrics_path = coefficients.parent / "metrics.json"
        if metrics_path.exists():
            metrics = json.loads(metrics_path.read_text(encoding="utf-8-sig"))
            capture["render_probe"] = {"path": str(metrics_path.resolve()),
                                       "sha256": sha256(metrics_path),
                                       "candidate_sha256": metrics.get("candidate_sha256"),
                                       "debug_errors": metrics.get("debug_errors"),
                                       "debug_warnings": metrics.get("debug_warnings")}
        if finite:
            radiance = normal_basis @ values[:, :3]
            capture.update({"reconstructed_unclamped_min_rgb": radiance.min(axis=0).tolist(),
                            "reconstructed_unclamped_max_rgb": radiance.max(axis=0).tolist(),
                            "negative_fraction": float((radiance < 0).mean())})
        if not finite or not alpha_zero:
            errors.append("GPU coefficient dump contains non-finite values or nonzero alpha")

    sources = ["src/atmosphere_sh.hlsli", "src/atmosphere_compute.hlsl",
               "src/atmosphere_common.hlsli", "src/alpine.asm", "tools/irradiance_reference.py"]
    return {"schema": 1, "passed": not errors, "errors": errors,
            "acceptance_scope": "CPU source-parsed SH projection against independent analytic Lambert moments",
            "source_sha256": {p: sha256(ROOT / p) for p in sources},
            "primary_reference": "https://graphics.stanford.edu/papers/envmap/envmap.pdf",
            "oracle": "For L(w)=a+b.w+w^T Q w, E(n)/pi=a+(2/3)b.n+(trace(Q)+n^T Q n)/4.",
            "normal_count": len(normals), "threshold_pairs": len(threshold) // 2,
            "projection_directions": count, "lanes": threads,
            "cosine_convolution_bands_over_pi": [float(factors[i]) for i in (0, 1, 4)],
            "orthonormal_gram_max_abs_error": gram_error, "cases": case_results,
            "tolerances": {"gram": 2e-9, "analytic": 3e-9, "fibonacci_absolute": .006,
                           "threshold_pair_delta": 1e-8},
            "gpu_execution_performed": False, "gpu_readback": capture,
            "limitations": ["128 equal-area samples are a numerical quadrature, not exact integration of arbitrary sky radiance.",
                            "Nine coefficients retain only SH orders zero through two; sharp sun and high-frequency sky energy need separate treatment.",
                            "This validates irradiance mathematics and source configuration, not appearance, GPU shader execution, or final scene quality.",
                            "Input shading normals must be unit length; truncated reconstruction is clamped to nonnegative RGB by the production shader."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coefficients", type=Path, help="optional raw GPU 9xfloat4 dump")
    parser.add_argument("--output", type=Path, default=ROOT / "validation/irradiance-reference.json")
    args = parser.parse_args()
    report = run(args.coefficients)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "errors": report["errors"],
                      "max_analytic_error": max(x["exact_quadrature_max_abs_error"] for x in report["cases"]),
                      "max_fibonacci_error": max(x["fibonacci_128_max_abs_error"] for x in report["cases"]),
                      "report": str(args.output)}))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
