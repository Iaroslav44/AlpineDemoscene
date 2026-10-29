"""Collect current neural-release evidence, without reusing procedural QA.
Numerical checks do not establish photographic or acoustic indistinguishability.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import shutil
import statistics
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 400_000_000


def need(condition, message):
    if not condition:
        raise ValueError(message)


def path(value):
    return (ROOT / value).resolve()


def relative(value):
    target = path(value)
    return target.relative_to(ROOT).as_posix() if target.is_relative_to(ROOT) else str(target)


def read(value):
    return json.loads(path(value).read_text(encoding="utf-8-sig"))


def sha(value):
    digest = hashlib.sha256()
    with path(value).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_matches(report, required, label):
    sources = {key.replace("\\", "/"): value.lower()
               for key, value in report.get("source_sha256", {}).items()}
    for name in required:
        need(sources.get(name) == sha(name), f"{label}: missing/stale source fingerprint: {name}")


def render_summary(directory, executable_sha, models):
    metrics = read(path(directory) / "metrics.json")
    label = relative(directory)
    need(metrics["candidate_sha256"].lower() == executable_sha, f"{label}: render is not from current EXE")
    need(metrics["debug_errors"] == metrics["debug_warnings"] == 0 and metrics["debug_layer"],
         f"{label}: D3D debug validation failed")
    neural = metrics["neural_avatar"]
    model = models[200]
    need(neural["source_kind"] == "candidate_resources" and neural["inference_executed"], f"{label}: release QA must execute candidate inference")
    need(neural["model_resource_id"] == 200 and neural["model_bytes"] == model["bytes"],
         f"{label}: wrong avatar package")
    need(neural["model_sha256"].lower() == model["sha256"].lower(), f"{label}: stale avatar weights")
    need(neural["vertex_count"] > 0 and neural["vertex_count"] % 3 == 0, f"{label}: invalid triangles")
    need(neural["invalid_values"] == neural["invalid_joint_ids"] == 0 and neural["active_joint_count"] >= 8,
         f"{label}: invalid vertices or articulation")
    need(neural["max_weight_sum_error"] <= .005 and
         .5 <= neural["normal_length_min"] <= neural["normal_length_max"] <= 1.5,
         f"{label}: invalid normals/weights")
    need(neural.get("rig_bytes") == 512 and neural.get("invalid_rig_values") == 0 and
         len(neural.get("rig_sha256", "")) == 64, f"{label}: missing calibrated body rig")
    head = metrics["neural_head"]
    need(head["source_kind"] == "candidate_resources" and head["inference_executed"], f"{label}: cached heads cannot pass release QA")
    need(head["model_resource_id"] == 202 and head["model_bytes"] == models[202]["bytes"] and
         head["model_sha256"].lower() == models[202]["sha256"].lower(), f"{label}: stale head weights")
    need(head["vertex_stride_bytes"] == 144 and head["vertex_count"] > 0 and head["vertex_count"] % 3 == 0,
         f"{label}: invalid head mesh")
    need(all(head[name] == 0 for name in ["invalid_values", "invalid_joint_ids", "invalid_color_values",
                                        "invalid_morph_values", "invalid_motion_values"]), f"{label}: invalid head data")
    need(head["active_joint_count"] >= 1 and head["max_weight_sum_error"] <= .005 and
         .5 <= head["normal_length_min"] <= head["normal_length_max"] <= 1.5, f"{label}: invalid head normals/weights")
    need(head["motion_frames"] > 1 and head["motion_duration_seconds"] > 0 and
         head["motion_max_difference_from_first"] > 1e-7 and head["max_abs_morph_delta"] > 1e-7,
         f"{label}: missing facial motion")
    material = metrics["neural_material"]
    for name in ["stone", "wood"]:
        run = material[name]
        need(run["source_kind"] == "candidate_resources" and run["inference_executed"] and
             run["candidate_sha256"].lower() == executable_sha, f"{label}: material inference was not from the candidate")
        need(run["model_resource_id"] == 203 and run["model_bytes"] == models[203]["bytes"] and
             run["model_sha256"].lower() == models[203]["sha256"].lower(), f"{label}: stale PhotoMat weights")
        need(run["status"] == 0 and run["width"] == 256 and run["mips"] == 9 and
             run["shader_resource_id"] == 121, f"{label}: invalid material package/result")
        need({entry["name"] for entry in run["maps"]} == {"diffuse_roughness", "normal_height", "specular"},
             f"{label}: incomplete generated material")
        for entry in run["maps"]:
            need(entry["nonfinite_values"] == entry["out_of_range_values"] == entry["invalid_base_normals"] == 0 and
                 entry["max_base_normal_length_error"] < .001 and len(entry["base_level_sha256"]) == 64,
                 f"{label}: invalid material map/mip values")
    need(material["stone"]["seed"] != material["wood"]["seed"] and
         material["stone"]["shader_sha256"] == material["wood"]["shader_sha256"],
         f"{label}: the two material samples must use distinct seeds of the same network")
    world = metrics["world_generation"]
    need(world["source_kind"] == "candidate_resources" and world["generation_executed"] and
         world["candidate_sha256"].lower() == executable_sha and world["shader_resource_id"] == 122,
         f"{label}: world generation is not from the candidate")
    need(world["status"] == 1 and world["resolution"] == 1024 and world["iterations"] == 96 and
         world["nonfinite_values"] == world["out_of_range_values"] == 0 and
         0 < world["changed_height_samples"] <= world["height_samples"] and
         math.isfinite(world["maximum_height_change_m"]), f"{label}: invalid generated landscape")
    need(len(world["channels"]) == 4 and all(0 <= channel["minimum"] <= channel["maximum"] <= 1
         for channel in world["channels"]), f"{label}: ecology fields are outside their domain")
    sh_file = path(directory) / "sh_coefficients.f32"
    sh_data = sh_file.read_bytes()
    need(len(sh_data) == 144, f"{label}: missing nine float4 irradiance coefficients")
    sh_values = struct.unpack("<36f", sh_data)
    need(all(math.isfinite(value) for value in sh_values) and all(value == 0 for value in sh_values[3::4]),
         f"{label}: invalid irradiance coefficient readback")
    frames = metrics["frames"]
    need(bool(frames), f"{label}: no frames")
    for frame in frames:
        need(not frame["gpu_disjoint"], f"{label}: disjoint GPU timing")
        for stage in ["world", "mesh_composite", "human_composite", "cloud_composite", "resolved"]:
            for invalid in ["nonfinite_pixels", "zero_depth_pixels", "invalid_depth_pixels"]:
                need(frame[stage][invalid] == 0, f"{label}: {stage}/{invalid}")
        need(frame["instance_counts"]["invalid_flags"] == frame["water_state"]["nonfinite_values"] == 0,
             f"{label}: invalid instances/water")
        need(frame["instance_counts"]["records"] == 118592 and
             frame["instance_cache"]["nonfinite_values"] == 0, f"{label}: missing/invalid ecology or resident rig cache")
        need(frame["irradiance_sh"]["coefficients"] == 9 and frame["irradiance_sh"]["nonfinite_values"] == 0,
             f"{label}: invalid irradiance basis coefficients")
        need(frame["cloud_changed_depth_pixels"] == frame["reflection_cloud_changed_depth_pixels"] == 0,
             f"{label}: cloud pass changed depth")
    times = [sum(frame["gpu_ms"][1:]) for frame in (frames[1:] if len(frames) > 1 else frames)]
    need(all(math.isfinite(value) and value >= 0 for value in times), f"{label}: invalid timing")
    return {"directory": label, "metrics_sha256": sha(path(directory) / "metrics.json"),
            "frames": len(frames), "start": frames[0]["time"], "end": frames[-1]["time"],
            "time_min": min(f["time"] for f in frames), "time_max": max(f["time"] for f in frames),
            "frame_times": [f["time"] for f in frames],
            "continuous_frame_pairs": sum(0 < b["time"] - a["time"] <= 1 / 24 + 1e-5 for a, b in zip(frames, frames[1:])),
            "dt": metrics["dt"], "adapter": metrics["adapter"], "width": metrics["width"],
            "height": metrics["height"], "invalid_pixels": 0, "debug_errors": 0, "debug_warnings": 0,
            "neural_avatar": neural, "neural_head": head, "neural_material": material, "world_generation": world,
            "world_generation_metrics_sha256": sha(path(directory) / "world_generation_metrics.json"),
            "irradiance_sh": {"first_frame_readback": relative(sh_file), "sha256": sha(sh_file),
                              "coefficients": 9, "all_frame_coefficients_finite": True,
                              "first_frame_minimum": min(sh_values), "first_frame_maximum": max(sh_values)},
            "unique_frame_hashes": len({f["rgba_fnv1a64"] for f in frames}),
            "render_ms_excluding_physics_and_first_when_multiple": {
                "median": statistics.median(times), "mean": statistics.mean(times), "maximum": max(times)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", default="dist/AlpineDreaming.exe")
    parser.add_argument("--native", required=True, help="Current native smoke JSON with rendered frames")
    parser.add_argument("--native-cancel", default="build/native_cancel_generative.json")
    parser.add_argument("--hardware", default="build/gpu_capabilities.json")
    parser.add_argument("--timeline", default="tools/neural_release_times.txt")
    parser.add_argument("--render", action="append", required=True, help="Current render_probe directory; repeat")
    parser.add_argument("--avatar-reference", default="validation/neural-avatar.json")
    parser.add_argument("--head-reference", default="validation/neural-head.json")
    parser.add_argument("--audio-reference", default="validation/neural-audio.json")
    parser.add_argument("--full-score", default="validation/neural-audio-fullscore.json")
    parser.add_argument("--material-reference", default="validation/neural-material.json")
    parser.add_argument("--geometry-reference", default="validation/neural-geometry-refinement.json")
    parser.add_argument("--locomotion-reference", default="validation/neural-locomotion.json")
    parser.add_argument("--world-reference", default="validation/world-generation.json")
    parser.add_argument("--irradiance-reference", default="validation/irradiance-reference.json")
    parser.add_argument("--inherit-report", help="Optional historical release with solver checks")
    parser.add_argument("--resource-equivalence", help="Required with --inherit-report; resources112/113 must match")
    parser.add_argument("--output", default="validation/400mb-release.json")
    parser.add_argument("--date", default="2026-10-29")
    args = parser.parse_args()
    executable = path(args.exe)
    executable_sha, size = sha(executable), executable.stat().st_size
    need(size < LIMIT, "EXE exceeds the strict 400,000,000-byte limit")
    shell = shutil.which("pwsh") or shutil.which("powershell")
    need(shell, "PowerShell is required for the PE verifier")
    verified = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-File",
                               str(ROOT / "tools/verify.ps1"), "-Executable", str(executable), "-AsJson"],
                              check=True, capture_output=True, text=True, encoding="utf-8-sig")
    packaging = json.loads(verified.stdout)
    need(packaging["SHA256"].lower() == executable_sha, "PE fingerprint changed")
    manifest = read("models/runtime-manifest.json")
    need(manifest["schema"] == 1, "Unexpected manifest schema")
    models = {model["resource_id"]: model for model in manifest["models"]}
    need(set(models) == {200, 201, 202, 203}, "Exactly the body, audio, head and material packages are required")
    for model in models.values():
        need(path(model["path"]).stat().st_size == model["bytes"] and
             sha(model["path"]) == model["sha256"].lower(), "Export differs from manifest")

    native = read(args.native)
    need(native["sha256"].lower() == executable_sha, "Native report is from another EXE")
    need(native["exit_code"] == 0 and not native["forced_termination"] and
         native["responsive_before_close"] and not native["window_was_visible"], "Native smoke failed")
    need(native.get("minimum_rendered_frames", 0) > 0 and
         native.get("rendered_frames", 0) >= native["minimum_rendered_frames"],
         "Native report only proves startup; actual rendered frames are required")
    cancelled = read(args.native_cancel)
    need(cancelled["sha256"].lower() == executable_sha and cancelled["exit_code"] == 0 and
         not cancelled["forced_termination"] and not cancelled["window_was_visible"] and
         0 <= cancelled["close_latency_seconds"] <= 3,
         "Startup did not cancel cleanly within three seconds, or used another EXE")
    startup_responsive = cancelled["responsive_before_close"]
    hardware = read(args.hardware)
    avatar = read(args.avatar_reference)
    need(avatar.get("passed") is True and avatar.get("joint_ids_equal") is True, "Avatar reference failed")
    need(avatar.get("model_sha256", "").lower() == models[200]["sha256"].lower(), "Stale avatar reference")
    need(bool(avatar.get("gpu_dump_sha256")), "Avatar comparison lacks GPU-output fingerprints")
    inference_sources = ["src/neural_avatar_runtime.cpp", "src/neural_avatar_runtime.h",
                         "src/neural_avatar.hlsl", "src/neural_mesh_cleanup.h"]
    source_matches(avatar, inference_sources, "Avatar reference")
    head = read(args.head_reference)
    need(head.get("passed") is True and head.get("joint_ids_equal") is True, "Head reference failed")
    need(head.get("model_sha256", "").lower() == models[202]["sha256"].lower(), "Stale head reference")
    need(bool(head.get("gpu_dump_sha256")), "Head comparison lacks GPU-output fingerprints")
    source_matches(head, inference_sources, "Head reference")
    for label, reference in [("Body", avatar), ("Head", head)]:
        need(reference["gpu_metrics"]["candidate_sha256"].lower() == executable_sha and
             reference["gpu_metrics"]["source_kind"] == "candidate_resources" and
             reference["gpu_metrics"]["inference_executed"],
             f"{label}: a fresh numerical comparison from the final EXE is required")
    audio = read(args.audio_reference)
    need(audio["model_sha256"].lower() == models[201]["sha256"].lower() and
         audio["raw_max_absolute_error"] < 1e-3, "Audio checkpoint comparison failed")
    need(audio["timing_and_input_checks"]["truncated_model_rejected"] and
         audio["timing_and_input_checks"]["invalid_magic_rejected"], "Audio input checks failed")
    source_matches(audio, ["src/neural_audio.cpp", "src/neural_audio.h"], "Audio reference")
    score = read(args.full_score)
    need(score.get("passed") is True and not score.get("errors"), "Full-score validation failed")
    need(score["model_sha256"].lower() == models[201]["sha256"].lower(), "Full score used different weights")
    source_matches(score, ["src/orchestra.inc", "src/neural_audio.cpp", "src/neural_audio.h"], "Full score")
    material = read(args.material_reference)
    need(material.get("passed") is True and not material.get("errors") and
         material["model_sha256"].lower() == models[203]["sha256"].lower() and
         material["operator_comparison"]["svbrdf_raw"]["max_absolute"] < .001,
         "PhotoMat checkpoint comparison failed")
    source_matches(material, ["src/neural_material_runtime.cpp", "src/neural_material_runtime.h",
                             "src/neural_material.hlsl"], "PhotoMat reference")
    need(all(material["timing"][field] for field in ["reject_truncated", "reject_bad_magic", "reject_bad_offset"]) and
         material["cancellation"]["status"] == 2 and material["same_seed_repeat_identical"] and
         material["different_seed"]["raw_rms_difference"] > .01, "PhotoMat input/cancellation/diversity checks failed")
    refinement = read(args.geometry_reference)
    need(refinement.get("passed") is True, "Geometry refinement failed")
    source_matches(refinement, ["src/neural_avatar_runtime.cpp", "src/neural_avatar_runtime.h",
                                "src/neural_mesh_cleanup.h"], "Geometry refinement")
    locomotion = read(args.locomotion_reference)
    need(locomotion.get("passed") is True and locomotion["shader_sha256"] == sha("src/neural_resident.hlsli"),
         "Locomotion check failed or used another resident shader")
    world_reference = read(args.world_reference)
    need(world_reference.get("passed") is True and not world_reference.get("errors"), "World transport audit failed")
    source_matches(world_reference, ["src/world_generation.cpp", "src/world_generation.h",
                                    "src/geomorphology.hlsl", "src/geomorph_common.hlsli"], "World transport audit")
    irradiance = read(args.irradiance_reference)
    need(irradiance.get("passed") is True and not irradiance.get("errors"), "Irradiance analytic reference failed")
    source_matches(irradiance, ["src/atmosphere_sh.hlsli", "src/atmosphere_compute.hlsl",
                               "src/atmosphere_common.hlsli"], "Irradiance reference")
    renders = [render_summary(directory, executable_sha, models) for directory in args.render]
    timeline = [float(value) for value in path(args.timeline).read_text(encoding="utf-8-sig").split()]
    need(any(len(item["frame_times"]) == len(timeline) and
             all(abs(a - b) <= .001 for a, b in zip(item["frame_times"], timeline))
             for item in renders), "No render sequence matches the preserved release timeline")
    for render in renders:
        for field, reference in [("neural_avatar", avatar), ("neural_head", head)]:
            generated = render[field]
            need(generated["seed"] == reference["seed"],
                 f"{render['directory']}: {field} has no numerical reference for this seed")
            need(generated["geometry_fnv1a64"] == reference["gpu_metrics"]["geometry_fnv1a64"],
                 f"{render['directory']}: {field} differs from independently checked GPU geometry")
        need(render["neural_avatar"]["rig_sha256"] == locomotion["rig_sha256"], "Rendered body rig differs from the contact check")
        samples = render["neural_material"]
        need(samples["stone"]["seed"] == material["seed"] and samples["wood"]["seed"] == material["different_seed"]["seed"],
             "Material seeds have no numerical/diversity reference")
        need(samples["stone"]["raw_svbrdf_sha256"] == material["output_sha256"]["svbrdf_raw.f32"] and
             samples["wood"]["raw_svbrdf_sha256"] == material["different_seed"]["sha256"],
             "Fresh material outputs differ from the source-bound reference; run the probe with --dump-material")
        for entry in samples["stone"]["maps"]:
            need(entry["base_level_sha256"] == material["output_sha256"][entry["name"] + ".f32"],
                 "Packed material channels differ from the verified output")
        need(render["world_generation"]["shader_sha256"] == world_reference["shader_sha256"],
             "Combined rendering used a world shader other than the independently audited transport code")
    adapter_names = {item["name"] for item in hardware["adapters"] if not item["software"]}
    need(all(item["adapter"] in adapter_names for item in renders), "Hardware report does not match tested GPU")
    need(any(item["continuous_frame_pairs"] > 0 and item["unique_frame_hashes"] > 1 for item in renders),
         "A continuous sequence demonstrating temporal image changes is required")
    need(irradiance.get("gpu_readback", {}).get("finite") and irradiance["gpu_readback"].get("alpha_zero") and
         any(item["irradiance_sh"]["sha256"] == irradiance["gpu_readback"].get("sha256") for item in renders),
         "Irradiance reference lacks a readback from the final render sequence")
    sh_capture = irradiance["gpu_readback"].get("render_probe", {})
    need(sh_capture.get("candidate_sha256", "").lower() == executable_sha and
         any(item["metrics_sha256"] == sh_capture.get("sha256") for item in renders),
         "Irradiance reference was not linked to the final candidate render metrics")
    world_combined = world_reference.get("combined_world_probe", {})
    need(world_combined.get("accepted") is True and world_combined.get("candidate_sha256", "").lower() == executable_sha and
         any(item["world_generation_metrics_sha256"] == world_combined.get("metrics_sha256") for item in renders),
         "World audit lacks combined evidence from the final candidate")

    inherited = []
    if args.inherit_report or args.resource_equivalence:
        need(args.inherit_report and args.resource_equivalence, "Inheritance needs report plus equivalence evidence")
        old, equivalence = read(args.inherit_report), read(args.resource_equivalence)
        need(equivalence["reference"]["SHA256"].lower() == old["sha256"].lower() and
             equivalence["candidate"]["SHA256"].lower() == executable_sha, "Inheritance fingerprints differ")
        resources = {entry["id"]: entry for entry in equivalence["resources"]}
        need(all(resources.get(i, {}).get("identical") for i in [112, 113]), "Physics shader bytes changed")
        previous_physics = old.get("physics", {})
        need(previous_physics.get("flight_finite") and previous_physics.get("tests") and
             all(test.get("passed") for test in previous_physics["tests"]) and
             previous_physics.get("debug_warnings_errors") == 0,
             "Historical physics report did not pass its checks")
        inherited.append({"report": relative(args.inherit_report), "report_sha256": sha(args.inherit_report),
                          "equivalence_report": relative(args.resource_equivalence), "resource_ids": [112, 113],
                          "scope": "Historical flight/water compute-kernel checks only; not fresh host integration."})
    def evidence(name, result):
        return {"path": relative(name), "sha256": sha(name), "result": result}
    report = {
        "schema": 6, "date": args.date, "milestone": "Generated ecosystem, landscape transport, calibrated residents and two neural materials",
        "executable": relative(executable), "sha256": executable_sha, "bytes": size,
        "limit_bytes_exclusive": LIMIT, "packaging": packaging,
        "baseline": {"commit": "8d5e6e6e", "tag": "alpine-before-generative-world-20261029", "bytes": 31750144},
        "previous_audit": {"path": "validation/history/neural-400mb-release-20261029.json",
                           "sha256": sha("validation/history/neural-400mb-release-20261029.json")},
        "size_increase_bytes": size - 31750144, "embedded_neural_models": manifest["models"],
        "model_manifest_sha256": sha("models/runtime-manifest.json"),
        "avatar_reference": evidence(args.avatar_reference, avatar),
        "head_reference": evidence(args.head_reference, head),
        "audio_reference": evidence(args.audio_reference, audio), "full_score": evidence(args.full_score, score),
        "audio_validation_scope": "Retained numerical and full-score evidence for byte-identical audio weights, orchestra source, neural audio source and header. This does not assert that the earlier audio probe used the current full application host.",
        "material_reference": evidence(args.material_reference, material),
        "geometry_refinement": evidence(args.geometry_reference, refinement),
        "locomotion_reference": evidence(args.locomotion_reference, locomotion),
        "world_reference": evidence(args.world_reference, world_reference),
        "irradiance_reference": evidence(args.irradiance_reference, irradiance),
        "native": native, "startup_cancellation": evidence(args.native_cancel, cancelled),
        "startup_responsiveness_target_met": startup_responsive,
        "startup_responsiveness_issue": None if startup_responsive else
            "The 500 ms message-response target was missed during neural startup. Cancellation was orderly within three seconds; this does not pass the responsiveness target.",
        "hardware": evidence(args.hardware, hardware),
        "timeline_input": {"path": relative(args.timeline), "sha256": sha(args.timeline), "times": timeline},
        "render_sequences": renders, "inherited_checks": inherited,
        "source_sha256": {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted((ROOT / "src").glob("*")) if p.is_file()},
        "quality": {"photorealism_achieved": False, "acoustic_indistinguishability_established": False,
                    "reason": "Neural execution, packaging and numerical/runtime behavior are checked. Photographic and acoustic indistinguishability are not established."},
    }
    output = path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".pending")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(output)
    print(json.dumps({"bytes": size, "sha256": executable_sha, "report": str(output)}, indent=2))


if __name__ == "__main__":
    main()
