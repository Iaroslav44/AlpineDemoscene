"""Freeze compact, source-bound evidence from a completed neural GPU comparison.

This tool performs no GPU work and does not turn development-file or cached
execution into evidence of execution from a final executable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from neural_avatar_reference import ROOT, load_nav


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def relative(path):
    path = Path(path).resolve()
    return path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)


def morphology(model, gpu_dir):
    tensors = load_nav(model)
    positions = np.fromfile(gpu_dir / "positions.f32", dtype="<f4").reshape(-1, 3)
    attributes = np.fromfile(gpu_dir / "attributes.f32", dtype="<f4").reshape(-1, 32)
    motion = tensors["motion.frames"]
    scale = np.float32(.33) / np.maximum(np.ptp(positions[:, 1]), np.float32(.1))
    directions = attributes[:, 16:32].reshape(-1, 4, 4)[:, :, :3] * scale
    maximum, axis_maximum = 0.0, np.zeros(3, np.float32)
    # Exact over every generated unique vertex and every stored control frame.
    # Linear interpolation cannot exceed these per-segment convex-norm bounds.
    for first in range(0, len(positions), 512):
        delta = np.einsum("fc,vcd->fvd", motion[:, :4], directions[first:first + 512], optimize=True)
        maximum = max(maximum, float(np.sqrt(np.sum(delta * delta, axis=2)).max()))
        axis_maximum = np.maximum(axis_maximum, np.abs(delta).max(axis=(0, 1)))
    duration = float(tensors["motion.duration"][0])
    return {
        "measured_unique_vertices": len(positions),
        "measured_control_frames": len(motion),
        "expression_modes": 4,
        "control_duration_seconds": duration,
        "control_keyframes_per_second": len(motion) / duration,
        "control_format": "Two float4 records per frame: four expression coefficients; relative jaw axis-angle XYZ plus padding",
        "packed_control_bytes": int(motion.nbytes),
        "expression_control_bytes": len(motion) * 16,
        "interpolation": "Linear in the vertex shader; whole loop duration is authored, not a claim about source capture frame rate",
        "coefficient_minimum": motion[:, :4].min(axis=0).tolist(),
        "coefficient_maximum": motion[:, :4].max(axis=0).tolist(),
        "endpoint_maximum_difference": float(np.abs(motion[0] - motion[-1]).max()),
        "normalization_scale_metres_per_model_unit": float(scale),
        "maximum_expression_displacement_metres": maximum,
        "maximum_absolute_expression_displacement_xyz_metres": axis_maximum.tolist(),
        "measurement_scope": "All stored coefficients times every generated vertex's learned four displacement directions, before global head articulation",
        "jaw_controls_applied_by_renderer": False,
        "expression_normals_recomputed_by_renderer": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("body", "head"), required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = json.loads(args.reference.read_text(encoding="utf-8-sig"))
    if report.get("passed") is not True or report.get("joint_ids_equal") is not True:
        raise ValueError("A passing numerical comparison with exact selected joint IDs is required")
    head = args.kind == "head"
    model = ROOT / ("models/head/ganhead-faceverse.nah" if head else "models/avatar/gdna-thuman.nav")
    metadata_path = model.with_suffix(".json")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8-sig"))
    if sha(model) != report["model_sha256"] or model.stat().st_size != report["model_bytes"]:
        raise ValueError("Compared model is stale")
    gpu_dir = Path(report["gpu_dir"])
    for name, digest in report["gpu_dump_sha256"].items():
        if sha(gpu_dir / (name + ".f32")) != digest:
            raise ValueError("GPU dump changed: " + name)
    if sha(gpu_dir / "neural_avatar_metrics.json") != report["gpu_metrics_sha256"]:
        raise ValueError("GPU metrics changed")
    sources = [
        "src/neural_avatar_runtime.cpp", "src/neural_avatar_runtime.h",
        "src/neural_avatar.hlsl", "src/neural_mesh_cleanup.h",
        "tools/neural_avatar_export.py", "tools/neural_avatar_reference.py",
        "tools/neural_avatar_validation_report.py",
    ]
    if head:
        sources += ["tools/neural_head_export.py", "tools/neural_head_reference.py"]
    report.update({
        "schema": 1,
        "validation_scope": "Independent NumPy versus actual D3D11 compute output; numerical graph correctness for one seed, not a perceptual realism claim",
        "reference_report": relative(args.reference),
        "reference_report_sha256": sha(args.reference),
        "model_path": relative(model),
        "model_metadata_sha256": sha(metadata_path),
        "source_sha256": {name: sha(ROOT / name) for name in sources},
        "provenance": {key: value for key, value in metadata.items() if key not in ("tensors", "path", "sha256", "bytes", "magic_hex")},
        "comparison_sample_counts": {
            "latent_scalars": 640 if head else 128,
            "feature_scalars": 4_194_304,
            "occupancy_coordinates": 1024,
            "surface_attribute_coordinates": 1024,
            "motion_scalars": 14_600 if head else 0,
        },
        "geometry_pipeline": {
            "runtime_input": "Seed and generated 3D coordinates; embedded learned network parameters",
            "occupancy_grid_xyz": [81, 97, 81] if head else [65, 129, 49],
            "surface_extraction": "Marching tetrahedra with shared edge vertices",
            "component_filter": "Largest connected component by vertex count, before bounds normalization and surface-attribute inference",
            "normalization": "Uniform scale to %.2f metres high; minimum Y translated to zero; X/Z origin retained" % (.33 if head else 1.75),
            "up_axis": "+Y",
            "face_forward_axis": "+Z",
            "runtime_images_or_source_meshes": False,
            "generation_occurs_at_startup": True,
            "network_evaluated_every_animation_frame": False,
        },
        "quality": {
            "photographic_indistinguishability_established": False,
            "physical_face_or_muscle_simulation": False,
            "independent_held_out_seed_validation": False,
        },
        "integration_limits": [
            "Largest-component filtering can remove real disconnected parts as well as generated floaters.",
            "Uniform bounds normalization is not a fitted skeletal registration.",
            "Numerical correctness does not establish anatomical realism or artifact-free pose deformation.",
        ] + ([
            "Learned RGB may contain photographic illumination; it is not verified relightable PBR albedo.",
            "Four learned expression directions retain a limited subspace; jaw/eye bone transforms are not applied and canonical normals are unchanged during expressions.",
            "Head is attached at body-local Y=1.42m, body clipped above Y=1.44m; this is an authored seam rather than learned body/head correspondence.",
            "Five predicted head skin weights are verified but renderer follows the body's head bone as a whole.",
        ] if head else [
            "Body skinning uses learned weights with an authored approximate 24-joint rig; no fitted SMPL template is embedded.",
            "Body checkpoint supplies geometry and normals, not learned appearance; materials are procedural.",
        ]),
    })
    report["gpu_dir"] = relative(gpu_dir)
    if head:
        report["morphology"] = morphology(model, gpu_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({"output": relative(args.output), "bytes": args.output.stat().st_size,
                      "passed": report["passed"], "source_kind": report["gpu_metrics"]["source_kind"]}))


if __name__ == "__main__":
    main()
